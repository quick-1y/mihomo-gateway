---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# Codebase Structure

**Analysis Date:** 2026-09-16

## Directory Layout

```
mihomo-gateway/                          # Repository root
├── install-gateway-docker.sh             # Main orchestrator script (1536 lines, executable)
├── mihomo/                               # Mihomo configuration directory
│   └── config.yaml                       # Mihomo config template (placeholders)
├── README.md                             # User documentation
├── LICENSE                               # License file
├── .mcp.json                             # MCP (Model Context Protocol) configuration
│
└── .planning/                            # GSD planning metadata
    └── codebase/                         # Architecture documentation
        ├── ARCHITECTURE.md
        └── STRUCTURE.md (this file)

# Runtime directories created on target machine:

#

# /var/lib/mihomo-gateway/                # State directory (script-managed)

# ├── gateway.env                         # Persistent config (key=value)

# ├── NETWORK_MARKER                      # Flag: network is configured

# ├── BACKUP_DONE                         # Flag: originals backed up

# └── original/                           # Backups of system config

#     ├── netplan/                        # Backed-up netplan files

#     ├── dnsmasq.conf                    # Original dnsmasq config

#     ├── nftables.conf                   # Original nftables rules

#     └── 99-router.conf                  # Original sysctl config

#

# /opt/mihomo-gateway/                    # Application directory (long-lived)

# ├── compose.yaml                        # Docker Compose config (generated)

# ├── .env                                # Docker compose env vars (TZ, LAN_IP, images)

# └── config/                             # Mihomo runtime config

#     ├── config.yaml                     # Rendered config (from template)

#     ├── proxy_providers/                # Downloaded proxy subscriptions

#     │   └── subscription.yaml           # Provider list (fetched by Mihomo)

#     └── ruleset/                        # Downloaded traffic rules

#         ├── youtube.mrs

#         ├── discord.mrs

#         ├── telegram.mrs

#         └── ... (rule files)

#

# /etc/netplan/                           # Netplan config (system-wide)

# └── 01-gateway.yaml                     # Generated interface config

#

# /etc/dnsmasq.conf                       # DHCP/DNS config (system-wide)

# /etc/nftables.conf                      # Firewall rules (system-wide)

# /etc/sysctl.d/99-router.conf            # IP forwarding settings

```

## Directory Purposes

**Repository Root (`mihomo-gateway/`):**

- Purpose: Project source tree
- Contains: Installation script, config template, docs
- Persisted: Yes (git repo)
- Committed: Yes (all tracked files)

**`mihomo/`:**

- Purpose: Hold configuration templates
- Contains: `config.yaml` (Mihomo runtime config with `__PLACEHOLDER__` tokens)
- Key files: `mihomo/config.yaml`
- Persisted: Yes (git repo)

**`.planning/codebase/`:**

- Purpose: Architecture documentation for GSD tools
- Contains: ARCHITECTURE.md, STRUCTURE.md (this guide)
- Persisted: Yes (git repo, for future analysis)

**`/var/lib/mihomo-gateway/` (Runtime):**

- Purpose: Persistent state and backups
- Contains: `gateway.env` (config), markers, backed-up original system files
- Persisted: Yes (filesystem)
- Generated: Yes (created by script)
- Committed: No (on target machine only)

**`/opt/mihomo-gateway/` (Runtime):**

- Purpose: Application deployment directory
- Contains: Docker Compose config, Mihomo runtime config, downloaded rules
- Persisted: Yes (filesystem)
- Generated: Yes (created by script)
- Committed: No (on target machine only)

## Key File Locations

**Entry Points:**

- `install-gateway-docker.sh`: Main orchestrator script (lines 1519–1536 invoke main())
- Execution: `sudo bash install-gateway-docker.sh`

**Configuration Templates:**

- `mihomo/config.yaml`: Mihomo proxy config with `__LAN_IP__`, `__LAN_NETWORK__`, `__CLASH_SECRET__`, `__SUBSCRIPTION_URL__` placeholders

**Core Logic Files:**

- `install-gateway-docker.sh`: All orchestration, configuration, UI
  - No separate modules (single monolithic file by design for portability)
  - ~200 functions organized by domain
  - ~1500 lines of executable code

**Testing:**

- `install-gateway-docker.sh:1509–1517` (`self_test()` function): Pre-flight checks for bash version, required commands
- No separate test suite; validation is inline during execution

## Naming Conventions

**Files:**

- Installation script: `install-gateway-docker.sh` (kebab-case with .sh)
- Config: `config.yaml` (yaml extension)
- Compose: `compose.yaml` (docker-compose standard)
- Environment: `.env` (dotfile for compose)

**Directories:**

- Runtime state: `/var/lib/mihomo-gateway/` (follows FHS for `/var/lib`)
- Application: `/opt/mihomo-gateway/` (follows FHS for third-party apps)
- System config: `/etc/netplan/`, `/etc/systemd/system/` (standard system locations)
- Subdirectories: `config/`, `ruleset/`, `proxy_providers/` (descriptive snake_case)

**Functions in Script:**

- Naming: `snake_case` (line 80–111 for output functions, 268+ for utility functions)
- Prefix conventions:
  - `check_*`: Health checks that return 0/1 (line 854–862)
  - `configure_*`: Setup functions (line 400, 484, etc.)
  - `prompt_*`: User input functions (line 676, 700)
  - `write_*`: File generation functions (line 378, 530, 567)
  - `restore_*`: Cleanup/rollback (line 1109, 1126)
  - `render_*`: Template rendering (line 741)
  - `status_*`: Status reporting (line 880, 1625)

**Variables:**

- Shell variables: `UPPERCASE_SNAKE_CASE` for readonly/important (line 7–69)
- Local variables: `lowercase_snake_case` (within functions)
- User-configurable: `LAN_IP`, `DHCP_START`, `DNS1` (uppercase, stored in gateway.env)
- Temp files: `${VAR_DIR}/.filename.XXXXXX` (mktemp pattern at line 766)

## Where to Add New Code

**New Feature / Service Integration:**

- Configuration generation: Add function in `install-gateway-docker.sh` following pattern of `write_netplan()` (line 378) or `configure_dnsmasq()` (line 484)
  - Generate config file from template or inline
  - Call systemctl to enable/restart
  - Store state in `gateway.env` if needed
- Menu option: Add case in `main_menu()` (line 1496–1505) or submenu (e.g., `services_menu()`)
- Example: To add PPPoE support, use functions at lines 936–1007 as template

**New Configuration Option:**

- Add key to `readonly CONFIG_KEYS` allowlist (line 69)
- Add variable declaration (lines 71–74)
- Create user prompt function: `prompt_*()` or `*_menu()` (see line 676–1404 for examples)
- Store in `gateway.env` via `write_config()` (line 183)
- Use in generated configs via template substitution

**New Validation Check:**

- Add function following pattern of `check_container()`, `check_api()` (lines 862–862)
  - Return 0 on success, 1 on failure
  - No console output (output goes to caller)
- Use in `quick_status()` (line 1638) or `full_diagnostics()` (line 1685)

**New Host System Service:**

- Create configuration generation function (see `write_nftables()` at line 567 for pattern)
- Call `systemctl enable` and `systemctl restart` for the service
- Backup original config to `/var/lib/mihomo-gateway/original/` via `backup_once()` (line 329)
- Add restoration logic to `restore_netplan_files()` or `full_remove()` (line 1109–1208)

**New Docker Container:**

- Add environment variables to `create_env()` (line 785)
- Add service to `create_compose()` (line 803)
- Add health check to `quick_status()` (line 1638) using `check_container()` pattern
- Consider volume mounts for config/data persistence (see Mihomo at line 857)

**Utilities and Helpers:**

- String manipulation: Add after line 161 (near `last_octet()`, `subnet_of()`)
- IP/network logic: Add after line 278 (near `mac_of()`, `carrier_of()`)
- System queries: Add after line 908 (near `iface_ipv4()`, `default_gw_via()`)

## Special Directories

**`/var/lib/mihomo-gateway/`:**

- Purpose: Persistent state and backups
- Generated: Yes (created by script at line 1523)
- Committed: No (on target machine, not in repo)
- Permissions: 700 (readable/writable only by root, line 1523)
- Cleanup: User can delete manually; script will recreate on next run

**`/opt/mihomo-gateway/`:**

- Purpose: Application runtime (Docker configs, Mihomo data)
- Generated: Yes (created at line 1016)
- Committed: No (target machine only)
- Permissions: Generally 755 (world-readable for config, but secrets in 600 files)
- Volumes: Mounted into Docker containers at `/root/.config/mihomo` (line 857)
- Cleanup: User can delete; Docker images will need to be re-pulled on reinstall

**`.planning/codebase/`:**

- Purpose: GSD architecture documentation
- Generated: No (manually created by mapping agent)
- Committed: Yes (git repo)
- Contents: ARCHITECTURE.md, STRUCTURE.md (this file)
- Used by: GSD `/gsd-plan-phase` and `/gsd-execute-phase` tools to understand codebase patterns

---

*Structure analysis: 2026-09-16*
