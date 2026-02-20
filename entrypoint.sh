#!/bin/sh
set -e

# ============================================================
# Tailscale + Cloudflare WARP Exit Node エントリーポイント
# ============================================================

# ------------------------------------------------------------
# 1. ホスト名の設定
# ------------------------------------------------------------
if [ -f /host_hostname ]; then
    export TS_HOSTNAME="warp--$(cat /host_hostname | tr -d '\n')"
else
    export TS_HOSTNAME="warp--docker"
fi
echo "Hostname set to: $TS_HOSTNAME"

# TailscaleのインターフェースMTUを少し下げる（IPv6の最小値1280ギリギリを攻める）
export TS_DEBUG_MTU=1280

# ------------------------------------------------------------
# 2. Tailscale認証キーのスマート処理
#    - 既に認証済み（状態が保存されている）場合はTS_AUTHKEYを無視する
#    - これによりAuth Keyが期限切れでも再起動できる
# ------------------------------------------------------------
TS_STATE_FILE="${TS_STATE_DIR}/tailscaled.state"

if [ -f "$TS_STATE_FILE" ] && [ -s "$TS_STATE_FILE" ]; then
    echo "Tailscale state found at $TS_STATE_FILE — skipping auth key (already registered)."
    unset TS_AUTHKEY
else
    if [ -z "$TS_AUTHKEY" ]; then
        echo "ERROR: No Tailscale state found and TS_AUTHKEY is not set."
        echo "       Please set TS_AUTHKEY in your .env file for initial registration."
        exit 1
    fi
    echo "No existing Tailscale state — using TS_AUTHKEY for initial registration."
fi

# ------------------------------------------------------------
# 3. ルーティング・NAT 設定関数
# ------------------------------------------------------------
WARP_GW="172.25.0.2"
WARP_GW6="fd00:cafe::2"

apply_routes() {
    # NAT (Masquerade) — 重複追加を防ぐためチェック
    if ! iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    fi
    if ! ip6tables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv6 NAT failed."
    fi

    # MSS Clamping — 重複追加を防ぐためチェック
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120
    fi
    if ! ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 2>/dev/null; then
        ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 || true
    fi

    # デフォルトゲートウェイをWARPに向ける
    current_gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$current_gw" != "$WARP_GW" ]; then
        ip route del default 2>/dev/null || true
        ip route add default via "$WARP_GW"
        echo "Route: Default gateway set to $WARP_GW"
    fi

    current_gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$current_gw6" != "$WARP_GW6" ]; then
        ip -6 route del default 2>/dev/null || true
        ip -6 route add default via "$WARP_GW6"
        echo "Route: Default IPv6 gateway set to $WARP_GW6"
    fi
}

# ------------------------------------------------------------
# 4. 初期セットアップ（遅延実行）
#    Tailscaleが起動しルーティングテーブルを書き換えた後に
#    WARP向けのルーティングとNAT設定を上書きする
# ------------------------------------------------------------
initial_setup() {
    echo "Background: Waiting 10s for Tailscale to start..."
    sleep 10

    echo "Background: Applying routes, NAT & MSS Clamping..."
    apply_routes

    echo "Background: Initial setup COMPLETE. Traffic should now go via WARP."
}

# ------------------------------------------------------------
# 5. ネットワーク監視ウォッチドッグ
#    - WARPゲートウェイへの疎通を定期的に確認
#    - ネットワーク復旧を検知したらルートを再適用し、
#      tailscaledにSIGHUPを送って再接続を促す
# ------------------------------------------------------------
WATCHDOG_INTERVAL=15    # チェック間隔（秒）
WATCHDOG_START_DELAY=30 # 初期セットアップ完了を待つ（秒）

network_watchdog() {
    sleep "$WATCHDOG_START_DELAY"
    echo "Watchdog: Started (interval=${WATCHDOG_INTERVAL}s)"

    was_down=0

    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # WARPゲートウェイへの疎通チェック（ping 1回、タイムアウト3秒）
        if ping -c 1 -W 3 "$WARP_GW" >/dev/null 2>&1; then
            if [ "$was_down" -eq 1 ]; then
                echo "Watchdog: Network recovered! Re-applying routes..."
                apply_routes

                # tailscaledにSIGHUPを送り、ネットワーク変更を通知
                # これによりDERPサーバーへの再接続が即座にトリガーされる
                if pid=$(pidof tailscaled 2>/dev/null); then
                    kill -HUP "$pid" 2>/dev/null && \
                        echo "Watchdog: Sent SIGHUP to tailscaled (pid=$pid)"
                fi

                was_down=0
                echo "Watchdog: Recovery actions completed."
            fi
        else
            if [ "$was_down" -eq 0 ]; then
                echo "Watchdog: WARP gateway unreachable — network may be down."
                was_down=1
            fi
        fi
    done
}

# ------------------------------------------------------------
# 6. バックグラウンド処理を開始
# ------------------------------------------------------------
initial_setup &
network_watchdog &

# ------------------------------------------------------------
# 7. Tailscale本体を起動
# ------------------------------------------------------------
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot
