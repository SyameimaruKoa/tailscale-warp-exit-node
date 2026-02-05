#!/bin/sh
set -e

# 1. ホスト名の設定
if [ -f /host_hostname ]; then
    export TS_HOSTNAME="warp-$(cat /host_hostname | tr -d '\n')"
else
    export TS_HOSTNAME="warp-docker"
fi
echo "Hostname set to: $TS_HOSTNAME"

# TailscaleのインターフェースMTUを少し下げる（IPv6の最小値1280ギリギリを攻める）
export TS_DEBUG_MTU=1280

# 2. 遅延設定関数
setup_routes() {
    echo "Background: Waiting 10s for Tailscale to start..."
    sleep 10
    
    echo "Background: Enabling IP Forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

    echo "Background: Setting up NAT & MSS Clamping (Aggressive)..."
    
    # NAT (Masquerade)
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || echo "WARNING: IPv6 NAT failed."

    # 【重要】MSS Clamping (パケットサイズを1120まで強制縮小)
    # VPN in VPNのオーバーヘッドを考慮してかなり小さめに設定する
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120
    ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1120 || true

    echo "Background: Switching Gateway to WARP..."
    ip route del default || true
    ip route add default via 172.25.0.2
    
    ip -6 route del default || true
    ip -6 route add default via fd00:cafe::2
    
    echo "Background: Setup COMPLETE. Traffic should now go via WARP."
}

# 3. バックグラウンド処理を開始
setup_routes &

# 4. Tailscale本体を起動
echo "Starting Tailscale..."
exec /usr/local/bin/containerboot