---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# External Integrations

**Analysis Date:** 2026-09-16

## APIs & External Services

**Proxy Subscription Service:**

- **Service**: User-provided HTTP(S) URL
  - Used for: Fetching proxy server list in Clash protocol format
  - Configuration: `SUBSCRIPTION_URL` stored in `/var/lib/mihomo-gateway/gateway.env`
  - Client: curl (health check validation), Mihomo (fetches at startup and on interval)
  - Health check: HTTP GET with 10s timeout, validates HTTP status 200 OK
  - Mihomo refresh interval: 3600s (hourly), configured in `mihomo/config.yaml`
  - Status: Stored in `/opt/mihomo-gateway/config/proxy_providers/subscription.yaml`

**CDN Rule Providers (jsdelivr.net):**

- **Service**: jsDelivr CDN for domain/routing rules
  - Rules fetched: youtube.mrs, discord.mrs, discord-ip.mrs, telegram.mrs, telegram-ip.mrs (and others)
  - URLs: `https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/[ruleset].mrs`
  - Format: MRS (Mihomo Rule Set, binary format)
  - Refresh interval: 86400s (daily)
  - Storage: `/opt/mihomo-gateway/config/ruleset/`
  - Used by: Mihomo rule engine for traffic classification
  - Client: Mihomo internal HTTP proxy provider

**Connectivity Testing:**

- **Service**: Google Connectivity Check
  - Endpoint: `https://www.gstatic.com/generate_204`
  - Purpose: Health check for proxy servers and TUN connectivity
  - Method: HTTP GET expecting 204 No Content response
  - Timeout: 5000ms, interval: 300s (5 minutes)
  - Used in: Mihomo proxy health checks in `AUTO` group configuration

## Data Storage

**Databases:**

- None detected. State is file-based in `/var/lib/mihomo-gateway/` and `/opt/mihomo-gateway/`.

**File Storage:**

- **Local filesystem** (entire deployment):
  - System configs: `/etc/netplan/`, `/etc/dnsmasq.conf`, `/etc/nftables.conf`, `/etc/sysctl.d/`
  - Project data: `/opt/mihomo-gateway/` (Docker volumes: config, ruleset, proxy_providers directories)
  - State: `/var/lib/mihomo-gateway/` (persisted configuration, backups)
  - Docker data: `/var/lib/docker/`, `/var/lib/containerd/`

**Caching:**

- None explicit. Docker layer caching used for image pulls.

## Authentication & Identity

**Auth Provider:**

- **Custom/Bearer Token**
  - Implementation: Mihomo API uses Bearer token authentication
  - Secret: `CLASH_SECRET` (8+ chars, alphanumeric + @._-)
  - Generation: `openssl rand -hex 24` or `tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32`
  - Prompt: Interactive during installation via `prompt_secret()` (`install-gateway-docker.sh:676–698`)
  - Storage: Persisted in `/var/lib/mihomo-gateway/gateway.env` as `CLASH_SECRET='...'`
  - Usage: HTTP Authorization header for all Mihomo external-controller API calls (port 9090)

**Access Control:**

- Mihomo external-controller CORS allows origins: `http://${LAN_IP}` and private network access
- Zashboard (web UI) binds to LAN IP only, no public internet exposure
- nftables firewall drops external WAN traffic to ports 80, 9090, 53, 7890

## Monitoring & Observability

**Error Tracking:**

- None detected. No centralized error tracking service.

**Logs:**

- **Host logs**: systemd journal (journalctl) for dnsmasq, nftables, docker services
  - Accessed via: `journalctl -u [service] -n [lines]`
  - Example: `journalctl -u dnsmasq -n 40 --no-pager`

- **Container logs**: Docker json-file driver with rotation
  - File locations: `/var/lib/docker/containers/[container-id]/[container-id]-json.log`
  - Rotation: max-size 10m, max-file 3
  - Access via: `docker logs --tail [N] [container]`
  - Mihomo log-level configurable in config.yaml (default: info)

**Health Checks:**

- **Status monitoring** (install-gateway-docker.sh:853–927):
  - API check: `curl -fsS -H "Authorization: Bearer ${CLASH_SECRET}" http://127.0.0.1:9090/version`
  - UI check: `curl -fsS http://${LAN_IP}/`
  - Container status: `docker inspect -f '{{.State.Status}}'`
  - TUN device: `ip link show Meta` or `ip link show meta`
  - dnsmasq: `systemctl is-active --quiet dnsmasq`
  - nftables: `nft list table ip gateway_nat`

## CI/CD & Deployment

**Hosting:**

- Self-hosted on Ubuntu/Debian mini-PC (two Ethernet interfaces)
- No cloud provider integration

**Docker Registry:**

- **Docker Hub**: `metacubex/mihomo:latest` (proxy server image)
- **GitHub Container Registry (ghcr.io)**: `ghcr.io/zephyruso/zashboard:latest` (dashboard image)
- Registry authentication: None required (public images)
- Pull mechanism: `docker compose pull` during installation

**Deployment Process:**

- Single-file bash installer (`install-gateway-docker.sh`)
- Downloaded via: `curl -fsSL -o install-gateway-docker.sh https://raw.githubusercontent.com/quick-1y/mihomo-gateway/main/install-gateway-docker.sh`
- Interactive menu-driven setup (network, secrets, subscription)
- No automated CI/CD pipeline detected

## Environment Configuration

**Required env vars (persisted in `gateway.env`):**

- `LAN_IP` - Static IP for LAN interface (e.g., 192.168.100.1)
- `DHCP_START`, `DHCP_END` - DHCP pool range (must be in same subnet as LAN_IP)
- `DNS1`, `DNS2` - Upstream DNS servers for dnsmasq (default: 1.1.1.1, 8.8.8.8)
- `LAN_IFACE`, `WAN_IFACE` - Physical interface names (detected and stored with MACs)
- `LAN_MAC`, `WAN_MAC` - MAC addresses for Netplan interface matching
- `NAT_ENABLED` - Boolean (1/0) to enable/disable NAT masquerading
- `SUBSCRIPTION_URL` - HTTP(S) URL to proxy subscription (user-provided)
- `CLASH_SECRET` - API authentication token for Mihomo

**Environment variables for Docker containers** (`.env` file):

- `TZ` - Timezone (auto-detected from timedatectl or defaults to Europe/Moscow)
- `LAN_IP` - Passed to Zashboard for port binding
- `MIHOMO_IMAGE`, `ZASHBOARD_IMAGE` - Image references for docker-compose

**Secrets location:**

- `/var/lib/mihomo-gateway/gateway.env` (mode 600, root-readable only)
- `/opt/mihomo-gateway/.env` (mode 600, root-readable only)
- Mihomo config: `/opt/mihomo-gateway/config/config.yaml` (mode 600, contains CLASH_SECRET placeholder after rendering)

**Configuration Files Location:**

- Network: `/etc/netplan/01-gateway.yaml`
- DNS/DHCP: `/etc/dnsmasq.conf`, `/etc/systemd/system/dnsmasq.service.d/override.conf`
- Firewall: `/etc/nftables.conf`
- Kernel: `/etc/sysctl.d/99-router.conf`
- Backup originals: `/var/lib/mihomo-gateway/original/`

## Webhooks & Callbacks

**Incoming Webhooks:**

- None detected. Gateway is not a webhook receiver.

**Outgoing Webhooks:**

- None detected. Mihomo does not send outbound webhooks.

**Proxy/Forward Traffic:**

- **Outbound proxy via Mihomo**:
  - All LAN traffic (from clients on LAN) can be proxied through Mihomo
  - TUN mode (`enable: true`) automatically routes matching traffic to proxy servers
  - Bypass list: `route-exclude-address` includes LAN network, 1.1.1.1, 8.8.8.8
  
**Outbound HTTP/HTTPS Requests from Gateway Host:**

- Template fetch: `curl https://raw.githubusercontent.com/quick-1y/mihomo-gateway/main/mihomo/config.yaml`
- Subscription validation: `curl [SUBSCRIPTION_URL]` (user-provided URL)
- Image pulls: Docker daemon fetches from `docker.io` and `ghcr.io`
- Rule provider updates: Mihomo fetches from `cdn.jsdelivr.net` on schedule
- Health checks: Mihomo checks `https://www.gstatic.com/generate_204`

---

*Integration audit: 2026-09-16*
