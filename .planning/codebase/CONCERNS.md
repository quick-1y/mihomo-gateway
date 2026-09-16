---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# Codebase Concerns

**Analysis Date:** 2026-09-16

## Tech Debt

**Hardcoded Dependencies and Defaults:**

- Issue: Default LAN IP (192.168.100.1), DHCP range (192.168.100.100-250), and DNS upstreams (Cloudflare 1.1.1.1, Google 8.8.8.8) are hardcoded with no flexibility for operators preferring private DNS or different subnets
- Files: `install-gateway-docker.sh` (lines 41-45)
- Impact: Operators cannot easily customize defaults; DNS privacy concerns for users in restricted regions
- Fix approach: Move defaults to a configuration profile system or allow sourcing from external config file

**Container Image Versioning Using `latest` Tag:**

- Issue: Both Mihomo and Zashboard images use `:latest` tag with no version pinning
- Files: `install-gateway-docker.sh` (lines 31-32)
- Impact: Unpredictable behavior on updates; breaking changes from upstream without warning; no rollback path to known-good versions
- Fix approach: Pin to specific semantic versions (e.g., `metacubex/mihomo:v1.18.0`); implement version update policy with release notes

**External Template Download Dependency:**

- Issue: If local template not found, script downloads `mihomo/config.yaml` from GitHub main branch with hardcoded URL
- Files: `install-gateway-docker.sh` (lines 39, 724-739)
- Impact: Installation fails if GitHub is unreachable; no fallback for offline deployments; no validation of downloaded content
- Fix approach: Include template in repository or provide local fallback; add checksum verification if downloading

**Password Minimum Too Weak:**

- Issue: `CLASH_SECRET` validation allows passwords as short as 8 characters
- Files: `install-gateway-docker.sh` (line 692)
- Impact: API secrets vulnerable to brute force in isolated LAN environments
- Fix approach: Increase minimum to 16+ characters or enforce entropy requirements

**Unvalidated Interface Names:**

- Issue: Interface names from `choose_iface_manual()` are used directly in Netplan config without validation
- Files: `install-gateway-docker.sh` (lines 363-374, 416-419)
- Impact: Malformed Netplan configs if interface names contain special characters; potential for YAML injection
- Fix approach: Validate interface names against `/sys/class/net/` before using in config

---

## Known Bugs

**Zashboard Port Binding Fails When LAN Link Down:**

- Symptoms: Zashboard container exits or fails to bind to `${LAN_IP}:80` during initial setup if no cable plugged into LAN port
- Files: `install-gateway-docker.sh` (lines 1030-1056)
- Trigger: Netplan configures LAN with `optional: true` but Zashboard port binding requires the address to exist; with no link, `ip_nonlocal_bind=1` mitigates but not guaranteed
- Workaround: Plug LAN cable in before running install, or accept that panel starts after cable connection (restart policy handles this, but not obvious to users)

**SSH Session Drop During Netplan Apply:**

- Symptoms: SSH connection drops mid-install if operator chooses a connected LAN interface (with carrier/link active)
- Files: `install-gateway-docker.sh` (lines 408, 450, 458, 472)
- Trigger: `netplan apply` renames interfaces and reconfigures network; if SSH is routed through LAN port, session dies
- Workaround: Script warns users and tells them to reconnect; `NETWORK_MARKER` prevents re-running network setup
- Root cause: Network reconfiguration is inherently disruptive; no way to avoid without complex network isolation

**Marker File Orphaning on Script Crash:**

- Symptoms: If script crashes after writing `NETWORK_MARKER` but before completing dnsmasq setup, subsequent runs skip network setup even though it's incomplete
- Files: `install-gateway-docker.sh` (lines 17, 456-457, 866-875)
- Trigger: SIGTERM/SIGKILL during `configure_dnsmasq()` or later
- Workaround: Manual deletion of `${STATE_DIR}/network-configured` marker
- Fix approach: Move marker write to end of network setup or use atomic multi-step checks

**Subscription URL Not Validated Before Rendering:**

- Symptoms: Invalid subscription URLs accepted during setup if curl check passes but URL later fails to load in Mihomo
- Files: `install-gateway-docker.sh` (lines 714-718)
- Trigger: Subscription URL that is reachable during install (ping succeeds) but becomes unavailable later, or URL redirects to error page
- Workaround: Users must manually re-enter subscription via settings menu
- Fix approach: Parse subscription response for validity (e.g., check for valid YAML proxy lists) not just HTTP status

---

## Security Considerations

**Secrets Stored in Plaintext Files:**

- Risk: `CLASH_SECRET` and `SUBSCRIPTION_URL` stored in plaintext in `/var/lib/mihomo-gateway/gateway.env` and `/opt/mihomo-gateway/.env` with chmod 600
- Files: `install-gateway-docker.sh` (lines 8, 27, 186-196, 793-800); files created: `/var/lib/mihomo-gateway/gateway.env`, `/opt/mihomo-gateway/.env`
- Current mitigation: File permissions are 600 (user-readable only); state directory is 700
- Recommendations: 
  - Consider using systemd user secrets or overlay filesystem for sensitive values
  - No automated credential rotation mechanism
  - Secrets visible in `docker inspect` and process listings during container startup

**External Controller Exposed with CORS Allow-Private-Network:**

- Risk: Mihomo API listens on `0.0.0.0:9090` in host network mode with `allow-private-network: true` in CORS config
- Files: `mihomo/config.yaml` (lines 9, 12-15); `install-gateway-docker.sh` (line 812)
- Current mitigation: nftables rules drop port 9090 from WAN interface; internal LAN-only access
- Recommendations:
  - Document that any device on LAN can control proxy settings
  - Consider binding to `${LAN_IP}:9090` only instead of `0.0.0.0:9090`
  - No rate limiting on API endpoints

**Network Firewall Rules Incomplete:**

- Risk: nftables only drops ports 80, 7890, 9090 from WAN; no validation that processes are actually bound to those ports; forward chain allows all LAN→WAN traffic without stateful filtering
- Files: `install-gateway-docker.sh` (lines 551-563)
- Current mitigation: `ct state established,related accept` handles return traffic
- Recommendations:
  - Validate that Mihomo proxy (7890) isn't accidentally exposed to WAN
  - Add explicit deny for LAN→WAN access to privileged ports (e.g., 22, 23, 111)
  - Consider adding DNS query logging for audit purposes

**Root Execution with Broad Blast Radius:**

- Risk: Script requires root and modifies system-wide configs: Netplan, nftables, sysctl, systemd services, Docker Engine; any bug in install or uninstall can render system unreachable
- Files: `install-gateway-docker.sh` (line 106, 1134-1206)
- Current mitigation: Backups taken to `/var/lib/mihomo-gateway/original/`; rollback mechanism exists
- Recommendations:
  - Consider splitting into unprivileged (Docker config) and privileged (network) phases
  - Test rollback path in CI/CD

---

## Performance Bottlenecks

**Docker Image Pull Synchronous:**

- Problem: `docker compose pull` (line 1025) runs synchronously during install; can timeout on slow connections or if registries are overloaded
- Files: `install-gateway-docker.sh` (lines 1024-1025)
- Cause: Network I/O dependency; 20-second timeout on template download (line 732) may be insufficient for large images
- Improvement path: Run pulls asynchronously or cache images; allow operator to pre-pull or use local tarball

**No Resource Limits on Containers:**

- Problem: Mihomo and Zashboard containers have no CPU/memory limits defined; a runaway proxy process could consume entire system
- Files: `install-gateway-docker.sh` (lines 805-840, compose.yaml template)
- Cause: Compose file has no `resources:` section
- Improvement path: Add memory limit (e.g., 512M for Mihomo, 256M for Zashboard) and CPU quota

**Subscription Update Interval Hardcoded to 1 Hour:**

- Problem: `proxy-providers.interval: 3600` (line 22 in config.yaml) is not user-configurable
- Files: `mihomo/config.yaml` (line 22)
- Cause: Template embeds interval; users cannot tune for their subscription provider
- Improvement path: Make interval a template variable like other settings

---

## Fragile Areas

**Interface MAC-Based Matching in Netplan:**

- Files: `install-gateway-docker.sh` (lines 362-370)
- Why fragile: Netplan matches interfaces by MAC address; if user clones VM or MAC changes, renaming fails silently
- Safe modification: Always detect current state before applying changes; add validation that `ip link show lan` exists post-apply
- Test coverage: No automated tests for Netplan generation

**Sed-Based Template Rendering with Special Characters:**

- Files: `install-gateway-docker.sh` (lines 757-771)
- Why fragile: Uses sed with `|` delimiter and manual escaping of `&`, `\`, `|`; URLs or secrets with these chars could break rendering
- Safe modification: Use a safer template engine (e.g., envsubst for simple cases, or jq for YAML); validate rendered output against JSON schema
- Test coverage: No tests for subscription URLs or secrets with special characters

**Marker Files as State Machine:**

- Files: `install-gateway-docker.sh` (lines 14-17, 332-347, 456-457, 866-875)
- Why fragile: Three separate marker files (`BACKUP_MARKER`, `NETWORK_MARKER`, `CONFIG_FILE`) represent state; inconsistencies can leave system in half-configured state
- Safe modification: Use a single state file with version and checksums; implement atomic writes with temp files and mv
- Test coverage: No tests for state recovery after crash

**Recursive Sed Replacements:**

- Problem: Multiple sed invocations on same file (lines 767-770) could accumulate or conflict if placeholders aren't unique
- Fix: Validate that all placeholders were replaced (line 773-776 does this) but could be more robust with dedicated parser

---

## Scaling Limits

**Hardcoded /24 Subnet:**

- Current capacity: Supports 254 DHCP clients (192.168.100.0/24 default)
- Limit: Operator cannot change subnet size; larger LAN networks (e.g., 10.0.0.0/16) would require script modification
- Scaling path: Make subnet mask configurable; validate against DHCP range
- Affected: `install-gateway-docker.sh` (lines 41-43, 169, 538, 759, 1300)

**No Clustering or HA:**

- Current: Single machine installation only
- Limit: No failover if gateway crashes; no multi-node setup
- Scaling path: This is a single-host installer, not designed for clustering

---

## Dependencies at Risk

**Upstream Image Registries (GitHub Container Registry, Docker Hub):**

- Risk: Both `metacubex/mihomo` and `ghcr.io/zephyruso/zashboard` could disappear or have breaking changes
- Impact: Future installs fail; no offline-first option
- Migration plan: Maintain local mirror of images or include tarball in releases; implement fallback registry

**GitHub Network Dependency:**

- Risk: Config template fetch from `raw.githubusercontent.com` (line 39)
- Impact: Installation impossible without internet access
- Migration plan: Bundle template in repository; test offline installation path

**Ubuntu/Debian Package Availability:**

- Risk: nftables, dnsmasq, or Docker packages might be removed or change significantly in future Ubuntu versions
- Impact: Installation on future Ubuntu (e.g., 26.04+) might fail
- Migration plan: Version pin key packages or provide build-from-source fallbacks

---

## Missing Critical Features

**No Automated Backup of Subscription/Configuration:**

- Problem: User data (subscription URL, API secret, proxy configs) only exists in container volumes and state files
- Blocks: Cannot easily migrate gateway to new hardware or backup user settings
- Recommendation: Implement export/import of configuration

**No Health Check Monitoring:**

- Problem: Script does `quick_status()` checks but no automatic recovery if services die
- Blocks: Unattended operation; no alerting mechanism
- Recommendation: Add systemd service with restart policies or Docker healthchecks

**No Update Mechanism for Gateway Components:**

- Problem: Script versions are tracked, but no automated update path for the installer itself
- Blocks: Security patches not automatically applied
- Recommendation: Implement update checker or automatic pull from repository

**No Support for Multiple Subnets/VLAN:**

- Problem: Single LAN subnet (192.168.100.0/24 default)
- Blocks: Cannot support multi-VLAN deployments
- Recommendation: Design for multi-interface support (future major version)

---

## Test Coverage Gaps

**No Automated Tests for Netplan Generation:**

- What's not tested: Interface naming, MAC matching, YAML syntax validation, carrier detection
- Files: `install-gateway-docker.sh` (lines 350-398, 441-443)
- Risk: Netplan syntax errors or malformed configs only detected at runtime
- Priority: High

**No Tests for Template Rendering:**

- What's not tested: Sed escaping with special characters, placeholder replacement completeness, Clash config validity
- Files: `install-gateway-docker.sh` (lines 741-783)
- Risk: Malformed Mihomo configs prevent startup; users only discover this after install completes
- Priority: High

**No Integration Tests for Full Install Flow:**

- What's not tested: Full `install_stack()` → `main_menu()` → settings changes → removal flow
- Files: `install-gateway-docker.sh` (lines 1009-1062, 1134-1206)
- Risk: Regressions not caught until user reports; no CI/CD coverage
- Priority: Medium

**No Tests for Rollback/Recovery:**

- What's not tested: Marker file recovery after crash, restoration from backup files, cleanup after failed operations
- Files: `install-gateway-docker.sh` (lines 1099-1132)
- Risk: Partial configurations left on system after failures
- Priority: Medium

**No Tests for Edge Cases:**

- What's not tested: Non-standard Ubuntu versions, missing required commands, pre-existing Docker installations, interface renaming conflicts
- Files: `install-gateway-docker.sh` (lines 1509-1517, 228-239)
- Risk: Script fails silently or leaves system in inconsistent state on non-standard environments
- Priority: Low

---

## Root Causes Summary

| Issue | Category | Root Cause |
|-------|----------|-----------|
| SSH drops during netplan apply | Architecture | Network reconfiguration cannot be atomic over SSH |
| Marker file orphaning | State management | Single marker files don't represent full state |
| Container image updates unpredictable | Dependency | Using `latest` tags without version control |
| Secrets in plaintext | Security | No secrets management integration |
| No test coverage | Process | Script is 1536 lines of bash with no unit/integration tests |
| Template download timeout | Resilience | Synchronous I/O without retry or fallback |
| Password too weak | Security | 8-character minimum is outdated for API keys |

---

*Concerns audit: 2026-09-16*
