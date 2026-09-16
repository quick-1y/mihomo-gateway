---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# Technology Stack

**Analysis Date:** 2026-09-16

## Languages

**Primary:**

- **Bash** - Entire install-gateway-docker.sh (~1536 lines) manages system configuration, network setup, Docker orchestration, and interactive setup menus

**Secondary:**

- **YAML** - Netplan network configuration, Docker Compose service definitions, Mihomo proxy configuration

## Runtime

**Environment:**

- **Ubuntu/Debian Linux** - Primary OS requirement (checked via /etc/os-release)
- **systemd** - Service management for dnsmasq, nftables, Docker

**Package Manager:**

- **apt-get** - Ubuntu/Debian package installation
- **Docker Compose** - Container orchestration (v2+, installed as docker-compose-plugin)

## Frameworks

**Core:**

- **Docker Engine** - Container runtime; installed via official Ubuntu/Debian repository
  - `docker-ce`, `docker-ce-cli`, `containerd.io`
  - `docker-buildx-plugin`, `docker-compose-plugin`
  - Managed as systemd service (docker.service)

**Network:**

- **Netplan** - Network configuration abstraction layer; generates /etc/netplan/01-gateway.yaml
- **systemd-networkd** - Renderer used by Netplan for interface configuration
- **dnsmasq** - Dual-purpose DHCP server and DNS resolver
- **nftables** - Kernel netfilter rules for NAT and firewall filtering

**System:**

- **sysctl** - Kernel parameter management (IPv4 forwarding, non-local bind)

## Key Dependencies

**Critical:**

- **curl** (>= 7.x) - HTTP client for image verification, subscription health checks, template downloads from GitHub
- **openssl** - Random secret generation for Mihomo API authentication; fallback uses /dev/urandom + tr
- **ca-certificates** - Required for HTTPS/TLS certificate validation (Docker repo, GitHub raw, subscription URLs)

**Infrastructure:**

- **dnsmasq** - DHCP server (binds to `${LAN_IP}`, range `${DHCP_START}-${DHCP_END}`)
- **nftables** - Stateful firewall NAT table (gateway_nat) and filter rules (gateway_filter)
- **Docker images**:
  - `metacubex/mihomo:latest` - Proxy server implementing Clash protocol
  - `ghcr.io/zephyruso/zashboard:latest` - Web UI for Mihomo management

## Configuration

**Environment:**

- **State directory**: `/var/lib/mihomo-gateway/`
  - `gateway.env` - Persists configuration: LAN_IP, DHCP_START/END, DNS1/DNS2, interface MACs, NAT_ENABLED, subscription URL, API secret
  - `network-configured` - Marker file set after Netplan is applied (prevents network re-setup on re-runs)
  - `original/` - Backup of original system configs before Gateway modifications

- **Project directory**: `/opt/mihomo-gateway/`
  - `.env` - Docker Compose environment file (TZ, LAN_IP, MIHOMO_IMAGE, ZASHBOARD_IMAGE)
  - `compose.yaml` - Docker Compose service definitions
  - `config/` - Mihomo configuration directory
    - `config.yaml` - Main Mihomo configuration (rendered from template with substitutions)
    - `ruleset/` - Rule definitions (youtube.mrs, discord.mrs, etc., fetched from CDN)
    - `proxy_providers/` - Subscription proxy list (subscription.yaml, fetched from user-provided URL)

**System Config Files:**

- `/etc/netplan/01-gateway.yaml` - Network configuration (WAN via DHCP, LAN static IP)
- `/etc/dnsmasq.conf` - DHCP pool and DNS upstream servers
- `/etc/systemd/system/dnsmasq.service.d/override.conf` - dnsmasq restart policy (Restart=always, RestartSec=5)
- `/etc/nftables.conf` - NAT masquerading and firewall rules
- `/etc/sysctl.d/99-router.conf` - Kernel parameters (net.ipv4.ip_forward=1, net.ipv4.ip_nonlocal_bind=1)

**Build:**

- No separate build configuration; installer is self-contained bash script
- Uses curl to download Mihomo config template if not present locally
- Docker images pulled via `docker compose pull` during installation

## Platform Requirements

**Development/Deployment:**

- **Minimum**: Ubuntu 20.04 LTS or Debian 11
- **Network**: Two physical Ethernet interfaces (LAN and WAN)
  - Detection via `/sys/class/net/` device directory presence
  - MAC address read from `/sys/class/net/{iface}/address`
  - Carrier/link status checked via `/sys/class/net/{iface}/carrier`

**Kernel Requirements:**

- nftables support (kernel >= 3.13, typically present in modern Ubuntu/Debian)
- TUN device support (`/dev/net/tun`) for Mihomo's TUN mode
- IPv4 forwarding capability

**Root Access:**

- Must run with sudo/root privileges (`EUID == 0`)
- Systemd service management required
- iptables/netfilter administrative access

**Memory/Disk:**

- Docker daemon running and responsive
- ~500MB disk space for Docker images (Mihomo + Zashboard)
- ~200MB for log rotation (json-file driver: max-size 10m, max-file 3)

## Production Deployment Notes

**Docker Compose Services** (`compose.yaml`):

- **Mihomo**: `network_mode: host` (direct access to gateway interfaces), capabilities NET_ADMIN/NET_RAW, device /dev/net/tun
- **Zashboard**: Bound to `${LAN_IP}:80`, maps to container port 80
- Both services use `restart: unless-stopped` policy
- Logging via json-file driver with rotation (10MB per file, 3 files max)

**API/Port Configuration**:

- Mihomo mixed-port: 7890 (SOCKS5/HTTP proxy)
- Mihomo external-controller: 0.0.0.0:9090 (REST API)
- Zashboard: HTTP :80 on LAN interface
- DNS: 53 (dnsmasq, bind-dynamic to lan interface)

**TLS/Certificates**:

- HTTPS for subscription URL validation and rule provider downloads
- All external-controller requests validated via Bearer token (CLASH_SECRET)
- Mihomo external-controller-cors configured for same LAN IP

---

*Stack analysis: 2026-09-16*
