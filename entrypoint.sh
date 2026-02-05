#!/bin/sh
set -e

# 1. ホスト名の設定
if [ -f /host_hostname ]; then
    export TS_HOSTNAME="warp--$(cat /host_hostname | tr -d '\n')"
else
    export TS_HOSTNAME="warp--docker"
fi
echo "Hostname set to: $TS_HOSTNAME"

# 2. バックグラウンドで遅延設定を行う関数
setup_routes() {
    echo "Background: Waiting 10s for Tailscale to start..."
    sleep 10

    echo "Background: Setting up NAT & MSS Clamping..."
    # NAT (Masquerade)
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv6 NAT failed."

    # 【追加】MSS Clamping (パケットサイズ調整)
    # これがないと、大きなパケット（動画やスピードテストなど）が詰まって接続が切れることがある
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true

    echo "Background: Switching Gateway to WARP..."
    ip route del default
    ip route add default via 172.25.0.2
    ip -6 route del default 2>/dev/null || true
    ip -6 route add default via fd00:cafe::2

    echo "Background: Setup COMPLETE."
 }

# 3. バックグラウンド処理を開始
setup_routes &

# 4. Tailscale本体を起動
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot