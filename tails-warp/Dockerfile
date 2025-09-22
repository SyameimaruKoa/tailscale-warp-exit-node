FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl iproute2 iptables ca-certificates gnupg lsb-release procps
# Tailscale repo & install
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.gpg | gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu focal main" > /etc/apt/sources.list.d/tailscale.list
RUN apt-get update && apt-get install -y tailscale
# Cloudflare WARP repo & install (consumer client)
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] http://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list
RUN apt-get update && apt-get install -y cloudflare-warp
# clean
RUN apt-get clean && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

