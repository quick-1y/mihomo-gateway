---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
<!-- refreshed: 2026-09-16 -->

# Architecture

**Analysis Date:** 2026-09-16

## System Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                   UBUNTU GATEWAY ORCHESTRATOR                    │
│        install-gateway-docker.sh (1536 lines, interactive)       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ UI Layer: Menu system (main_menu, settings_menu, etc.)     │  │
│  │ `install-gateway-docker.sh:1471–1507`                      │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
          │                      │                      │
          ▼                      ▼                      ▼
┌─────────────────┐   ┌──────────────────┐  ┌──────────────────┐
│ Network Config  │   │ DNS/DHCP Config  │  │ NAT/Forwarding   │
│ (Netplan)       │   │ (dnsmasq)        │  │ (nftables)       │
│ Lines:353–481   │   │ Lines:484–564    │  │ Lines:567–575    │
│ /etc/netplan/   │   │ /etc/dnsmasq.conf│  │ /etc/nftables.   │
│ 01-gateway.yaml │   │ /etc/systemd/... │  │ conf              │
└─────────────────┘   └──────────────────┘  └──────────────────┘
          │                      │                      │
          └──────────┬───────────┴───────────┬──────────┘
                     ▼
        ┌────────────────────────────────────┐
        │   Host System Services             │
        │   • systemd-networkd (Netplan)     │
        │   • dnsmasq (DHCP + DNS)           │
        │   • nftables (NAT + Firewall)      │
        │   • Docker daemon                  │
        └────────────────────────────────────┘
                     │
                     ▼
        ┌────────────────────────────────────┐
        │   Docker Compose Stack             │
        │   /opt/mihomo-gateway/             │
        │   ├── compose.yaml (L803–881)      │
        │   ├── .env (L785–801)              │
        │   └── config/                      │
        │       └── config.yaml (rendered)   │
        └────────────────────────────────────┘
             │                        │
             ▼                        ▼
        ┌──────────────┐         ┌─────────────────┐
        │ Mihomo       │         │ Zashboard       │
        │ (Proxy)      │◄────────│ (Web Dashboard) │
        │ Port 7890    │         │ Port 80         │
        │ API :9090    │         │ Connects to API │
        └──────────────┘         └─────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File Location |
|-----------|----------------|---|
| **Orchestrator** | Entry point, main menu loop, error handling | `install-gateway-docker.sh:1519–1536` |
| **Network Config** | Netplan YAML generation, interface naming, DHCP setup | `install-gateway-docker.sh:353–481` |
| **DNS/DHCP** | dnsmasq configuration, upstream DNS, DHCP range | `install-gateway-docker.sh:484–564` |
| **NAT/Firewall** | nftables rules, IP masquerade, port forwarding | `install-gateway-docker.sh:567–575` |
| **State Manager** | Persist/load config from `/var/lib/mihomo-gateway/gateway.env` | `install-gateway-docker.sh:183–220` |
| **Template Engine** | Fetch & render Mihomo config.yaml with placeholders | `install-gateway-docker.sh:723–783` |
| **Docker Manager** | Compose file generation, image pull, container lifecycle | `install-gateway-docker.sh:803–881` |
| **Status Monitor** | Health checks, diagnostics, container state polling | `install-gateway-docker.sh:854–983` |
| **UI/Menu System** | Interactive prompts, settings changes, user feedback | `install-gateway-docker.sh:1257–1507` |
| **Cleanup/Restore** | Backup originals, restore network, remove stack | `install-gateway-docker.sh:329–352, 1081–1208` |

## Pattern Overview

**Overall:** Infrastructure-as-Shell-Script (IaC via Bash orchestrator)

**Key Characteristics:**

- Single entry point script manages all infrastructure provisioning and lifecycle
- State persisted to a simple env file (`gateway.env`), not a database
- Declarative config generation (templates + sed substitution)
- Layered separation: host services → Docker containers
- Idempotent design: re-running script applies changes without breaking
- Interactive menus allow post-install modification without re-running full setup
- Host network namespace (host mode) for container to control host routing/NAT

## Layers

**Layer 1: Orchestration**

- Purpose: User interaction, state management, error recovery, lifecycle control
- Location: `install-gateway-docker.sh` (entire script, but especially 1471–1536 for main loop)
- Contains: Main menu, settings menus, function dispatch, status reporting
- Depends on: All lower layers
- Used by: End user (runs script directly)

**Layer 2: Host System Configuration**

- Purpose: Configure Linux networking stack (interfaces, routing, firewall, DNS)
- Location: Multiple functions in `install-gateway-docker.sh`:
  - Network: Lines 353–481 (netplan generation)
  - DNS/DHCP: Lines 484–564 (dnsmasq)
  - NAT: Lines 567–575 (nftables)
- Contains: Bash functions that generate config files and systemctl commands
- Depends on: Operating system (Ubuntu/Debian, systemd, nftables)
- Used by: Layer 3 (containers rely on NAT, DNS, routing)

**Layer 3: Container Orchestration**

- Purpose: Deploy and manage Mihomo + Zashboard via Docker Compose
- Location: `install-gateway-docker.sh` lines 803–881 (create_compose), 1009–1062 (install_stack)
- Contains: Compose YAML generation, image pulling, container startup/restart logic
- Depends on: Docker daemon, Layer 2 network config
- Used by: Mihomo/Zashboard services

**Layer 4: Application (Mihomo)**

- Purpose: HTTP proxy, DNS sniffer, traffic routing via rules
- Location: `mihomo/config.yaml` (template, rendered at runtime)
- Contains: Proxy providers, rule sets, TUN interface config, logging
- Depends on: Mihomo Docker image, subscription URL, LAN network setup
- Used by: Zashboard (dashboard UI), LAN clients (transparent proxy)

## Data Flow

### Primary Request Path: Full Installation

1. User runs `sudo bash install-gateway-docker.sh` (`install-gateway-docker.sh:1519–1536`)
2. `main()` checks OS, creates state dir, loads existing config (`install-gateway-docker.sh:1519–1534`)
3. If network not ready, call `configure_network_first()` (lines 400–481):
   - Detect physical interfaces (line 413)
   - User selects LAN/WAN manually (lines 416–419)
   - Get MAC addresses (line 420)
   - Generate Netplan YAML (line 378–389)
   - Apply netplan, rename interfaces to `lan` / `wan` (line 458)
   - Save config to `gateway.env` (line 439)
4. Configure dnsmasq (line 469):
   - Generate `/etc/dnsmasq.conf` with DHCP range, DNS upstream
   - Restart systemd service (line 557)
5. Main menu loop (line 1533):
   - Display status (line 1481)
   - Wait for user input (line 1495)
   - Dispatch to submenu or action

### Sub-Flow: Install Gateway (Menu Option 1)

1. `install_stack()` (lines 1009–1062)
2. Configure forwarding & IP masquerade (line 1011–1012)
3. Create directories `/opt/mihomo-gateway/config`, `ruleset/`, `proxy_providers/` (line 1016)
4. Prompt for API secret, subscription URL (lines 1018–1019)
5. Call `render_mihomo_config()` (line 1020):
   - Fetch template from repo or local file (line 746)
   - Validate placeholders exist (lines 748–752)
   - Escape special characters in values (lines 758–763)
   - Render to temp file, then atomic move (lines 766–780)
   - Result: `/opt/mihomo-gateway/config/config.yaml` with actual values
6. Create `.env` file with TZ, LAN_IP, image names (line 1021)
7. Generate `compose.yaml` (line 1022)
8. Pull Docker images (line 1025)
9. Validate config syntax (line 1027)
10. Start containers (line 1033)
11. Poll API for readiness (lines 1037–1040)
12. Check container states (lines 1042–1060)
13. Display success/warnings (line 1061)

### Data Flow: Template Rendering

```
mihomo/config.yaml (repo, with __PLACEHOLDER__)
         │
         ▼ fetch_template() [line 723]
    temp file (with placeholders)
         │
         ├─ __LAN_IP__ ← LAN_IP variable (e.g. "192.168.100.1")
         ├─ __LAN_NETWORK__ ← subnet_of(LAN_IP) (e.g. "192.168.100.0/24")
         ├─ __CLASH_SECRET__ ← User-provided API password
         └─ __SUBSCRIPTION_URL__ ← User-provided proxy list URL
         │
         ▼ sed substitution [line 767–770]
   /opt/mihomo-gateway/config/config.yaml (rendered, ready to use)
         │
         ▼ Docker mount
   Mihomo container reads at /root/.config/mihomo/config.yaml
```

**State Management:**

- **Master state file**: `/var/lib/mihomo-gateway/gateway.env`
  - Contains: LAN_IP, DHCP_START, DHCP_END, DNS1, DNS2, LAN_IFACE, WAN_IFACE, LAN_MAC, WAN_MAC, NAT_ENABLED, SUBSCRIPTION_URL, CLASH_SECRET
  - Persisted after each change
  - Loaded at script startup (line 1524) and before menu display (line 1474)
  
- **Backup originals**: `/var/lib/mihomo-gateway/original/`
  - netplan configs, dnsmasq.conf, nftables.conf, sysctl.d
  - Used for safe restoration (lines 1109–1135)

## Key Abstractions

**Configuration Template Pattern:**

- Purpose: Parameterize infrastructure config with runtime values
- Examples: `mihomo/config.yaml`
- Pattern: Placeholder substitution via sed (line 767–770)
  - Allows template to live in repo
  - Safe rendering to temp file before atomic move
  - Validates no placeholders remain after rendering

**State Persistence:**

- Purpose: Survive SSH session drops, allow incremental setup
- Examples: `gateway.env`, `NETWORK_MARKER`, `BACKUP_MARKER`
- Pattern: Write state before risky operations (e.g., line 456: write marker before netplan apply)

**Health Check Pattern:**

- Purpose: Verify service readiness before declaring success
- Examples: `check_api()`, `check_container()`, `network_is_ready()`
- Pattern: Retry loops with sleep (lines 1037–1040), curl timeouts (line 860)

**Config Key Allowlist:**

- Purpose: Prevent injection attacks from partial state loads
- Location: Line 69 (`readonly CONFIG_KEYS`)
- Pattern: Split on `=`, validate key is in allowlist before adding to env

## Entry Points

**Primary Entry Point: Script Invocation**

- Location: `install-gateway-docker.sh:1519–1536`
- Triggers: `sudo bash install-gateway-docker.sh` (no args = interactive menu)
- Responsibilities:
  - Check root privileges
  - Verify bash version and required commands
  - Create state directory
  - Load config from persistent state
  - Check if network is ready (if not, run initial setup)
  - Enter main menu loop

**Secondary Entry Points: Menu Options**

1. Install/reinstall (line 1497) → `install_stack()`
2. Services menu (line 1498) → `services_menu()`
3. Settings menu (line 1499) → `settings_menu()`
4. Diagnostics (line 1500) → `full_diagnostics()`
5. Remove gateway (line 1501) → `remove_stack()`
6. Full removal (line 1502) → `full_remove()`
7. Exit (line 1503)

## Architectural Constraints

- **Threading:** Bash is single-threaded; script execution is sequential (no async)
- **Global state:** All configuration stored in shell variables loaded from `gateway.env`; no singletons beyond script scope
- **Circular imports:** Not applicable (Bash script, no modules)
- **Root privilege:** Entire script must run as root (`sudo`); enforced at line 106
- **Network mode:** Containers run in `host` mode (line 850) so they control host routing directly
- **Atomicity:** Config files written to temp then moved to ensure partial writes don't corrupt production (line 766–780)
- **Error propagation:** Script uses `set -Eeuo pipefail` (line 3) to fail fast
- **Idempotency:** Functions designed to be rerunnable; `backup_once()` (line 329) ensures originals backed up only once

## Anti-Patterns

### Anti-Pattern 1: Partial Configuration in State File

**What happens:** User modifies settings in menu, then script crashes before writing state. On rerun, the in-memory variables don't match the file.

**Why it's wrong:** 

- Inconsistent state between script runtime and persistent storage
- Menu may show stale values
- Changes may be lost or applied twice

**Do this instead:** 

- Always call `write_config()` (line 183) after each state change in menus
- Example: `lan_menu()` (line 1257) calls `write_config` at line 1296
- Use atomic writes: temp file → move

### Anti-Pattern 2: Assuming Interface Names

**What happens:** Old scripts hardcoded `eth0`/`eth1` interface names.

**Why it's wrong:** 

- Newer systems use `enp1s0`, `enp2s0` (predictable) or random names
- Breaks on different hardware

**Do this instead:** 

- Auto-detect and rename via Netplan MAC matching (line 362–363)
- Use generated `lan` and `wan` names consistently
- Example: `detect_interfaces()` (line 268) queries `/sys/class/net/`

### Anti-Pattern 3: Hardcoded Image Versions

**What happens:** Script embeds `metacubex/mihomo:v1.2.3` tag.

**Why it's wrong:** 

- Breaks when image is removed from registry
- No automatic security updates
- Difficult to test new versions

**Do this instead:** 

- Use `:latest` tag and pull fresh (line 1025)
- Allow override via env var (line 797: `MIHOMO_IMAGE=${MIHOMO_IMAGE}`)
- Document how to pin versions if needed

### Anti-Pattern 4: No Placeholder Validation

**What happens:** Template is rendered but placeholders remain.

**Why it's wrong:** 

- Mihomo config is broken but script doesn't catch it
- Container fails silently
- Hard to debug

**Do this instead:** 

- Validate all placeholders are defined before rendering (lines 748–752)
- Check no placeholders remain after rendering (lines 773–776)
- Use validation docker run before deploying (line 885–889)

## Error Handling

**Strategy:** Fail-fast with descriptive error messages

**Patterns:**

- Early exit on missing prerequisites: `die()` function (line 84) prints error and exits 1
- Non-fatal warnings: `warn()` prints but continues (line 82)
- Informational logs: `info()`, `success()` for user feedback (lines 80–81)
- All diagnostics to stderr (line 79), stdout reserved for return values
- Pre-flight checks: `self_test()` (line 1509) verifies bash version, required commands
- Atomic operations: Temp file → move pattern ensures partial writes don't corrupt (line 766–780)

## Cross-Cutting Concerns

**Logging:**

- Approach: Direct stderr output with color codes
- Functions: `info()`, `success()`, `warn()`, `error()`, `die()`
- Conditional colors: Detect TTY (line 57) to disable color in non-interactive shells
- Level: No log levels; all output goes to console

**Validation:**

- Approach: Inline validation at each step
- Examples: 
  - DHCP range validation (line 165–180)
  - Netplan syntax check (line 392)
  - Config placeholder check (lines 748–752, 773–776)
  - Container readiness polling (lines 1037–1040)

**Authentication:**

- Approach: 
  - Root check at entry (line 106)
  - Mihomo API secret stored in config.yaml, protected via docker secrets mount
  - dnsmasq/nftables require root, enforced by systemctl
  - Docker operations require root or docker group (handled by docker daemon)

**Secret Handling:**

- Approach: Never log secrets, mask in status output
- Functions: `mask_secret()` (line 901–906) shows only first 2 and last 1 character
- Storage: Secrets in `/opt/mihomo-gateway/.env` (mode 600) and config.yaml (mode 600)
- No secrets in stdout; they're read from stdin or loaded silently

---

*Architecture analysis: 2026-09-16*
