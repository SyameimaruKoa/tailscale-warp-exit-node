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
# 3. nftables互換性の設定
#    Alpine/Tailscaleイメージ内のiptablesをiptables-nftに切り替える
# ------------------------------------------------------------
if [ -x /usr/sbin/iptables-nft ]; then
    ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables
fi
if [ -x /usr/sbin/ip6tables-nft ]; then
    ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
fi

# ------------------------------------------------------------
# 4. ルーティング・NAT 設定関数
# ------------------------------------------------------------
WARP_GW="${WARP_GW:-10.1.0.2}"
WARP_GW6="${WARP_GW6:-fd6a:204b:1e8d::2}"

# ------------------------------------------------------------
# 4.1 経路分離 (Issue #1)
#    - tailscaled自身の通信 (制御プレーン・DERP・direct接続) は、
#      tailscaledがソケットに付ける bypass fwmark で識別し、
#      元のDockerゲートウェイ (通常回線) へ送る
#    - Exit Nodeとして転送する通信 (マークなし) は従来どおり
#      mainテーブルのデフォルトルートでWARPへ送る
#    - 分離の仕組み:
#        1. 起動直後・WARPへ書き換える前に元のゲートウェイを退避する
#        2. 退避したゲートウェイを専用テーブル (UNDERLAY_TABLE) に保持する
#        3. fwmark付きパケットをそのテーブルへ振り分ける ip rule を、
#           tailscaled自身のルール (優先度5210〜) より前に置く
#        4. 専用テーブルで解決できない場合は unreachable とし、
#           WARP側へフォールバックさせない (fail-closed)
#    - 注意: fwmarkは「Tailscaleのテーブル52を迂回する」ための印であり、
#      それだけでは元のゲートウェイへは戻らない。本処理で初めて
#      通常回線への経路が保証される
# ------------------------------------------------------------
# tailscaledの bypass fwmark (tsconst: LinuxBypassMark=0x80000 / LinuxFwmarkMask=0xff0000)
# TS_FWMARKが未指定なら tailscaled が実際に導入したルールから検出し、
# 検出できない場合のみ既定値を使う。バージョン差異は環境変数で上書きできる
TS_FWMARK="${TS_FWMARK:-}"
TS_FWMARK_DEFAULT="0x80000/0xff0000"
UNDERLAY_TABLE="${UNDERLAY_TABLE:-100}"   # Tailscaleのテーブル52と重ならない番号
UNDERLAY_PRIO="${UNDERLAY_PRIO:-5200}"    # tailscaledの5210より小さい (優先される) こと
UPLINK_DEV="${UPLINK_DEV:-eth0}"

# 起動時に退避する元のゲートウェイ (apply_routesでWARPに書き換わる前の値)
ORIG_GW=""
ORIG_GW6=""
ORIG_DEV=""

# 元のデフォルトゲートウェイを退避する
# WARPへ書き換えた後の値を「元のゲートウェイ」と誤認しないよう、
# 退避済みの場合と現在値がWARP自身の場合は上書きしない (冪等)
capture_default_gateways() {
    if [ -z "$ORIG_GW" ]; then
        gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$gw" ] && [ "$gw" != "$WARP_GW" ]; then
            ORIG_GW="$gw"
        fi
    fi
    if [ -z "$ORIG_GW6" ]; then
        gw6=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [ -n "$gw6" ] && [ "$gw6" != "$WARP_GW6" ]; then
            ORIG_GW6="$gw6"
        fi
    fi
    if [ -z "$ORIG_DEV" ]; then
        ORIG_DEV=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        if [ -z "$ORIG_DEV" ]; then
            ORIG_DEV="$UPLINK_DEV"
        fi
    fi
}

# tailscaledが使う bypass fwmark を返す
# 優先順位: 環境変数 TS_FWMARK > tailscaled導入済みルールからの検出 > 既定値
# 自分で入れたルール (lookup UNDERLAY_TABLE) を検出対象にしないため、
# 「lookup main」のルールだけを見る
detect_ts_fwmark() {
    if [ -n "$TS_FWMARK" ]; then
        echo "$TS_FWMARK"
        return
    fi
    mark=$(ip rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    if [ -z "$mark" ]; then
        mark=$(ip -6 rule show 2>/dev/null | awk '/fwmark/ && /lookup main/ {for(i=1;i<=NF;i++) if($i=="fwmark") {print $(i+1); exit}}')
    fi
    if [ -n "$mark" ]; then
        echo "$mark"
    else
        echo "$TS_FWMARK_DEFAULT"
    fi
}

# 指定デバイスの接続済みルート (サブネット直結ルート) を専用テーブルへ複写する
# ゲートウェイへの到達性そのものを専用テーブル内でも保証するために必要
# $1: "" (IPv4) または "-6" / $2: デバイス名
copy_connected_routes() {
    fam="$1"
    dev="$2"
    ip $fam -o route show dev "$dev" 2>/dev/null | awk '{print $1}' | while read -r pfx; do
        case "$pfx" in
            ""|default|unreachable|prohibit|blackhole|throw|local|broadcast|multicast|anycast|nat)
                continue
                ;;
        esac
        ip $fam route replace "$pfx" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null || true
    done
}

# fwmark付きパケットを専用テーブルへ振り分けるルールを入れる (冪等)
# $1: "" (IPv4) または "-6" / $2: fwmark
add_underlay_rules() {
    fam="$1"
    mark="$2"
    guard_prio=$((UNDERLAY_PRIO + 1))

    if ! ip $fam rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*fwmark ${mark}.*lookup ${UNDERLAY_TABLE}"; then
        ip $fam rule del priority "$UNDERLAY_PRIO" 2>/dev/null || true
        ip $fam rule add fwmark "$mark" lookup "$UNDERLAY_TABLE" priority "$UNDERLAY_PRIO" 2>/dev/null || \
            echo "WARNING: Failed to add underlay ip rule (family='${fam:-4}')."
    fi
    # 専用テーブルで解決できないfwmark付きパケットは破棄する
    # ここでmain (WARP) へ落とすと経路分離が崩れるため unreachable にする
    if ! ip $fam rule show 2>/dev/null | grep -q "^${guard_prio}:.*fwmark ${mark}.*unreachable"; then
        ip $fam rule del priority "$guard_prio" 2>/dev/null || true
        ip $fam rule add fwmark "$mark" unreachable priority "$guard_prio" 2>/dev/null || true
    fi
}

# 経路分離を (再) 適用する: 元ゲートウェイ退避 → 専用テーブル → fwmarkルール
# 失敗してもtailscaledの起動自体は止めない (警告のみ)。分離の成否は
# verify-routing.sh で確認できる
setup_underlay() {
    capture_default_gateways
    mark=$(detect_ts_fwmark)
    dev="${ORIG_DEV:-$UPLINK_DEV}"

    if [ -n "$ORIG_GW" ]; then
        copy_connected_routes "" "$dev"
        if ip route replace default via "$ORIG_GW" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null; then
            add_underlay_rules "" "$mark"
            echo "Underlay: Tailscale traffic (fwmark $mark) -> $ORIG_GW via table $UNDERLAY_TABLE"
        else
            echo "WARNING: Failed to set underlay IPv4 default route via $ORIG_GW (table $UNDERLAY_TABLE)."
        fi
    else
        echo "WARNING: Original IPv4 gateway unknown — cannot separate Tailscale traffic (IPv4)."
    fi

    if [ -n "$ORIG_GW6" ]; then
        copy_connected_routes "-6" "$dev"
        if ip -6 route replace default via "$ORIG_GW6" dev "$dev" table "$UNDERLAY_TABLE" 2>/dev/null; then
            add_underlay_rules "-6" "$mark"
            echo "Underlay: Tailscale traffic (fwmark $mark) -> $ORIG_GW6 via table $UNDERLAY_TABLE (IPv6)"
        else
            echo "WARNING: Failed to set underlay IPv6 default route via $ORIG_GW6 (table $UNDERLAY_TABLE)."
        fi
    else
        echo "WARNING: Original IPv6 gateway unknown — cannot separate Tailscale traffic (IPv6)."
    fi
}

# 経路分離が生きているか確認する (ウォッチドッグ用)
# fwmark付きの経路検索が元のゲートウェイを向いていれば正常
underlay_intact() {
    [ -n "$ORIG_GW" ] || return 1
    ip rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*lookup ${UNDERLAY_TABLE}" || return 1
    mark=$(detect_ts_fwmark)
    mark_value="${mark%%/*}"
    got=$(ip route get 1.1.1.1 mark "$mark_value" 2>/dev/null | head -1)
    case "$got" in
        *"$ORIG_GW"*) ;;
        *) return 1 ;;
    esac
    if [ -n "$ORIG_GW6" ]; then
        ip -6 rule show 2>/dev/null | grep -q "^${UNDERLAY_PRIO}:.*lookup ${UNDERLAY_TABLE}" || return 1
        got6=$(ip -6 route get 2606:4700:4700::1111 mark "$mark_value" 2>/dev/null | head -1)
        case "$got6" in
            *"$ORIG_GW6"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

apply_routes() {
    # 経路分離を先に (再) 適用する
    # mainのデフォルトをWARPへ書き換える前に元ゲートウェイを退避するため、
    # 必ずWARP向けルート変更より前に呼ぶこと
    setup_underlay

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
    # これはマークなし通信 (Exit Node転送) 用。tailscaled自身の通信は
    # 上記 ip rule により main より先に専用テーブルで処理される
    # WARP障害時もこのデフォルトはWARPのままにし、通常回線へ
    # フォールバックさせない (Exit Node通信の漏洩防止)
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
# 5. 初期セットアップ（遅延実行）
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
# 6. ネットワーク監視ウォッチドッグ
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

        # 経路分離の維持確認
        # tailscaledの再起動等でルールやテーブルが消えていたら再適用する
        # (この確認自体はWARP疎通の成否に依存しない)
        if ! underlay_intact; then
            echo "Watchdog: Routing separation lost — re-applying routes..."
            apply_routes
        fi

        # WARPゲートウェイへの疎通チェック（ping 1回、タイムアウト3秒）
        # pingはfwmarkなしのためmain (WARP経由) で評価される。
        # tailscaled自身の通信 (fwmark付き・通常回線) の疎通とは独立
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
# 7. バックグラウンド処理を開始
# ------------------------------------------------------------
# tailscaled起動前に元のゲートウェイを退避し経路分離を先行適用する
# 優先度 (5200) が tailscaled のルール (5210〜) より小さいため、
# 後から tailscaled がルールを追加しても分離は崩れない
capture_default_gateways
setup_underlay

initial_setup &
network_watchdog &

# ------------------------------------------------------------
# 8. Tailscale本体を起動
# ------------------------------------------------------------
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot
