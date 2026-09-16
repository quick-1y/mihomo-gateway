---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# Testing Patterns

**Analysis Date:** 2026-09-16

## Current Test Status

**No formal test suite exists in this codebase.**

This is a brownfield bash installer script (~1536 lines) with no test framework, no test files, and no CI/CD pipeline configured. The project relies on:

1. **Self-test function** in the script (basic validation)
2. **Manual testing** during development
3. **Interactive validation** built into the installer menus

## Self-Test Function

**Location:** `install-gateway-docker.sh:1509–1517`

The script includes a built-in self-check that runs before any operations:

```bash
self_test(){
    local missing=() cmd
    for cmd in grep sed awk ip systemctl curl netplan mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "Не найдены обязательные команды: ${missing[*]}"
    (( BASH_VERSINFO[0] >= 4 )) || die "Требуется bash 4 или новее."
    success "Самопроверка скрипта — OK"
}
```

**What it validates:**

- Required system commands present: `grep`, `sed`, `awk`, `ip`, `systemctl`, `curl`, `netplan`, `mktemp`
- Bash version ≥ 4

**Entry point:** Called in `main()` at line 1521, before any configuration operations.

## Test Framework

**Runner:** None configured

**Assertion Library:** None

**Run Commands:**

- No automated test runner
- Script is run manually: `sudo ./install-gateway-docker.sh`

## Test File Organization

**Not applicable.** No test files exist.

**Directory structure:**

```
mihomo-gateway/
├── install-gateway-docker.sh     (1536 lines, single monolithic script)
├── mihomo/
│   └── config.yaml               (configuration template)
├── LICENSE
└── README.md
```

No separate test directory (`tests/`, `spec/`, `__tests__/`, etc.).

## Test Structure

**Interactive validation during runtime:**

The script validates state at each step using conditional logic. Examples:

1. **Prerequisite checks** (see `install-gateway-docker.sh:1519–1533`):
   ```bash
   main(){
       need_root
       self_test
       check_os
       mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
       load_config || true
   }
   ```

2. **Configuration validation** (e.g., DHCP range check):
   ```bash
   validate_dhcp_range(){
       local start="$1" end="$2" lan="$3"
       is_ipv4 "$start" || { error "Некорректный начальный адрес DHCP."; return 1; }
       is_ipv4 "$end"   || { error "Некорректный конечный адрес DHCP."; return 1; }
       ...
   }
   ```
   See `install-gateway-docker.sh:165–178`

3. **Network state checks** (see `install-gateway-docker.sh:400–481`):
   ```bash
   if ! carrier_of "$WAN_IFACE"; then
       warn "На ${WAN_IFACE} не обнаружен линк (carrier)."
       confirm "Всё равно использовать как WAN?" || exit 0
   fi
   ```

## Mocking

**Not applicable.** No test framework = no mocking framework.

**In production code:**

- Network calls use `curl` with explicit URLs
- File I/O operations use real filesystem paths
- System commands invoked directly via `systemctl`, `nft`, `ip`, `dpkg-query`, etc.

No test doubles, stubs, or mocks are implemented.

## Fixtures and Factories

**Not applicable.** No test infrastructure.

**Configuration constants used as defaults:**

- Hardcoded defaults: `LAN_DEFAULT="192.168.100.1"`, `DHCP_START_DEFAULT="192.168.100.100"`, etc.
- See `install-gateway-docker.sh:41–45`
- These are used for menu prompts and config initialization, not test fixtures

## Coverage

**Requirements:** None enforced

**No coverage tooling:** No coverage reports, no coverage targets.

**Risk areas with minimal validation:**

- Docker image pull logic (line ~649): No test that images actually pull successfully
- Netplan generation (line ~443): Only syntax-checked via `netplan generate`, not applied
- nftables rules (line ~571): Syntax-checked via `nft -c`, not tested in real firewall
- Configuration file parsing (lines 199–217): Uses regex; no unit tests for edge cases

## Test Types

**Unit Tests:** None

**Integration Tests:** The entire script is effectively an integration test—each menu operation validates assumptions and applies changes to the system.

**E2E Tests:** None automated. Manual verification required:

- Network interfaces correctly named (`lan`/`wan`)
- DHCP pool functional
- Containers running and accessible
- Web dashboard (Zashboard) at `http://$LAN_IP`

**Manual testing strategy observed:**

1. Run installer on test VM
2. Navigate menus; validate prompts and behavior
3. Check system state (e.g., `ip -br addr`, `systemctl status dnsmasq`)
4. Verify web dashboard and API accessible
5. Test configuration changes via settings menu

## Common Patterns

**Pre-flight checks (not automated tests):**

- Root privilege check: `need_root()` at line 106
- OS detection: `check_os()` at line 228
- Package availability: `pkg_installed()` at line 241
- Command availability: `self_test()` at line 1509
- Network readiness: `network_is_ready()` (referenced in main, validates marker files)

**Inline validation:**

- IPv4 address validation: `is_ipv4()` at line 151
- Subnet validation: `same_subnet()` at line 163
- DHCP range validation: `validate_dhcp_range()` at line 165
- Docker presence check: `stack_present()` (implicitly via compose commands)

**Configuration state validation:**

- Marker files check completion: `$BACKUP_MARKER`, `$NETWORK_MARKER` (see lines 14, 17)
- Config file integrity: `load_config` uses regex to parse only known keys (line 199–207)

## Testing Best Practices Not Applied

**Identified gaps:**

1. **No bash testing framework** (e.g., `bats`, `shunit2`, `bash_unit`)
   - Would enable function unit tests and reusability

2. **No CI/CD pipeline** (no `.github/workflows/`, `.gitlab-ci.yml`, etc.)
   - Would catch syntax errors and basic validation failures automatically

3. **No ShellCheck integration**
   - No `.shellcheckrc` configuration
   - Script would benefit from `shellcheck install-gateway-docker.sh` linting

4. **No configuration schema validation**
   - YAML config template lacks comments on required/optional fields
   - Mihomo config uses placeholder variables (`__CLASH_SECRET__`, `__LAN_IP__`) with no type hints

5. **No mock/stub system for external commands**
   - Network calls to GitHub (config template URL) not cached/stubbed
   - Docker operations not testable without actual Docker

6. **No error scenario testing**
   - What happens if `netplan apply` hangs mid-operation?
   - What if `docker compose` fails partway through?
   - Error recovery not systematically tested

## Recommendations for Future Testing

**Immediate:**

1. Add ShellCheck to development workflow
2. Document manual test checklist for releases

**Short-term:**

1. Extract core validation functions into a library
2. Add `bats` tests for validation functions (`is_ipv4`, `validate_dhcp_range`, etc.)
3. Create `.github/workflows/lint.yml` for syntax validation

**Medium-term:**

1. Create integration test framework (mock system calls or container-based testing)
2. Document expected behavior for error scenarios
3. Add timeout/retry logic for network operations with tests

**Long-term:**

1. Refactor script into composable modules (functions → separate files)
2. Implement comprehensive test suite
3. Add CI/CD with test gates before release

---

*Testing analysis: 2026-09-16*
