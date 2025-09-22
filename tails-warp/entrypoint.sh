#!/bin/bash
set -euo pipefail

# env:
#  TS_AUTHKEY (optional)
#  WARP_REGISTER_TOKEN (optional, for automation if available)

log(){ echo "[$(date -Is)] $*"; }

# 1) start warp service in background
log "starting warp-svc..."
warp-svc & sleep 1

# 2) try to register/connect WARP if token provided, else print hint
if [ -n "${WARP_REGISTER_TOKEN:-}" ]; then
  log "registering warp using token..."
  yes | warp-cli registration || true
  warp-cli connect || true
else
  log "no WARP_REGISTER_TOKEN provided; you may need to run 'warp-cli register' manually inside container and then 'warp-cli connect'"
fi

# 3) start tailscaled
log "starting tailscaled..."
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state & sleep 1

# 4) bring up tailscale
# ホスト名指定がある場合は --hostname を付ける
TS_HOSTNAME_OPT=""
if [ -n "$TS_HOSTNAME" ]; then
  TS_HOSTNAME_OPT="--hostname=${TS_HOSTNAME}"
fi
if [ -n "${TS_AUTHKEY:-}" ]; then
  log "running tailscale up with authkey and advertising exit node..."
  tailscale up --authkey ${TS_AUTHKEY:-} --advertise-exit-node $TS_HOSTNAME_OPT
else
  log "no TS_AUTHKEY provided; run 'tailscale up' interactively inside the container (or set TS_AUTHKEY env)"
fi

# 5) enable forwarding and add NAT from tailscale0 to the WARP interface
log "enabling ip forwarding..."
sysctl -w net.ipv4.ip_forward=1

# detect outgoing (WARP) interface by querying route to a public IP
WARP_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
if [ -z "$WARP_IF" ]; then
  log "could not auto-detect WARP interface; listing interfaces:"
  ip -br a
  log "please set WARP_IF manually inside container and run iptables rules."
else
  log "detected outgoing interface: $WARP_IF"
  iptables -t nat -C POSTROUTING -o "$WARP_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$WARP_IF" -j MASQUERADE
  iptables -C FORWARD -i tailscale0 -o "$WARP_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tailscale0 -o "$WARP_IF" -j ACCEPT
  iptables -C FORWARD -i "$WARP_IF" -o tailscale0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WARP_IF" -o tailscale0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi

# 6) simple watchdog / keep container running and print status every 30s
while true; do
  log "status: tailscale=$(tailscale status --json 2>/dev/null | jq -r '.Self?.ID // "?"' 2>/dev/null || echo "n/a") warp=$(warp-cli status 2>/dev/null | head -n1 || echo "n/a")"
  sleep 30
done

