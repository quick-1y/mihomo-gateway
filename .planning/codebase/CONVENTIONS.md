---
last_mapped_commit: 97de2a317b9228e391394b4f67a798f5af5505eb
last_mapped_at: 2026-09-16
---
# Coding Conventions

**Analysis Date:** 2026-09-16

## Naming Patterns

**Files:**

- Shell scripts: lowercase with hyphens (`install-gateway-docker.sh`)
- Configuration files: lowercase with extension (e.g., `config.yaml`)

**Functions:**

- Lowercase with underscores: `configure_network_first`, `validate_dhcp_range`, `detect_interfaces`
- Prefixes indicate purpose: `is_ipv4`, `validate_*`, `configure_*`, `write_*`, `run_timed`
- Menu functions use `_menu` suffix: `main_menu`, `settings_menu`, `services_menu`
- Short helper functions: `pad`, `die`, `info`, `success`, `warn`, `error`

**Variables:**

- Global constants: `UPPERCASE_WITH_UNDERSCORES` and marked `readonly`
- Global mutable variables: `UPPERCASE` (e.g., `LAN_IFACE`, `DNS1`, `SUBSCRIPTION_URL`)
- Local variables: `lowercase_with_underscores` (e.g., `local log rc elapsed`)
- Loop counters: Single letters acceptable in short contexts (e.g., `for i in`, `for p in`, `for _l in`)
- Temporary iteration variables: Underscore prefix when not used (`_o`, `_l`) for clarity

**Types/Constants:**

- Directories: `readonly STATE_DIR="/var/lib/mihomo-gateway"`
- File paths: `readonly CONFIG_FILE="${STATE_DIR}/gateway.env"`
- Network defaults: `readonly LAN_DEFAULT="192.168.100.1"`
- Container names: `readonly MIHOMO_CONTAINER="mihomo"`
- Image references: `readonly MIHOMO_IMAGE="metacubex/mihomo:latest"`

## Code Style

**Shebang and Error Handling:**

- Line 1: `#!/usr/bin/env bash`
- Line 3: `set -Eeuo pipefail` — Mandatory for all scripts
  - `-E`: Inherit ERR trap in functions
  - `-e`: Exit on error (unless in `|| return`/`|| true` patterns)
  - `-u`: Error on undefined variables
  - `-o pipefail`: Fail on any command in a pipeline
- See `install-gateway-docker.sh:1-3`

**Formatting:**

- **Tab/Space:** Use spaces (not detected in script, follows bash convention)
- **Line length:** No strict limit observed; descriptive names preferred over brevity
- **Quoting:** Always quote variables in expansions: `"$var"`, `"${var}"`, `"$@"`
- **Braces:** Use `${var}` for clarity in complex expansions; `$var` acceptable in simple cases

**Error Handling:**

- Use `trap` for cleanup and error capture:
  ```bash
  cleanup(){ [[ -n "$TEMPLATE_CACHE" && -f "$TEMPLATE_CACHE" ]] && rm -f "$TEMPLATE_CACHE"; return 0; }
  trap cleanup EXIT
  
  on_error(){
      local rc=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]}
      error "Ошибка (код ${rc}) в строке ${line}: ${cmd}"
      exit "$rc"
  }
  trap on_error ERR
  ```
  See `install-gateway-docker.sh:108-116`

- Inline error handling with `|| return` or `|| die`:
  ```bash
  is_ipv4 "$start" || { error "Некорректный начальный адрес DHCP."; return 1; }
  ```
  See `install-gateway-docker.sh:167`

- Use `set -e` with explicit error contexts; avoid bare `set +e` unless essential

**Linting:**

- No formal linter configured; follow conventional bash practices
- Implicit conventions from script: avoid `eval` except for safe config parsing
- Prefer `[[ ]]` over `[ ]` for all conditional tests (POSIX not required)

## Import Organization

**Not applicable to bash scripts.** Variable declarations and sourcing:

- Constants declared at top with `readonly` keyword
- All configuration keys listed in `CONFIG_KEYS` string for validation
- No source files; single-script architecture

**Relative paths in script:**

```bash
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MIHOMO_TEMPLATE_LOCAL="${SCRIPT_DIR}/mihomo/config.yaml"
```

See `install-gateway-docker.sh:37-39`

## Error Handling

**Patterns:**

- **Fatal errors:** Use `die` function (calls `error` then `exit 1`)
  ```bash
  die "Запустите с правами root: sudo bash $0"
  ```
  See `install-gateway-docker.sh:106`

- **Non-fatal errors:** Return error code, let caller decide
  ```bash
  is_ipv4 "$ip" || return 1
  ```
  See `install-gateway-docker.sh:151-160`

- **Error with context:** Print before exit
  ```bash
  [[ -f /etc/os-release ]] || die "Не найден /etc/os-release"
  ```
  See `install-gateway-docker.sh:229`

- **Command failure:** Capture and report
  ```bash
  log=$(mktemp /tmp/mgw-run.XXXXXX)
  if (( rc == 0 )); then
      success "$label — ${elapsed} с"
  else
      error "$label — ошибка (код ${rc}, ${elapsed} с)"
      tail -n 30 "$log" >&2 || true
  fi
  ```
  See `install-gateway-docker.sh:140-145`

- **Safe operations:** Use `|| true` to suppress non-fatal failures
  ```bash
  systemctl enable dnsmasq >/dev/null 2>&1 || true
  ```
  See `install-gateway-docker.sh:519`

## Logging

**Framework:** `bash` builtin `echo` and custom wrapper functions

**Functions:**

- `info()` — Informational messages (BLUE `[i]`)
- `success()` — Success confirmations (GREEN `[✓]`)
- `warn()` — Warnings (YELLOW `[!]`)
- `error()` — Error messages (RED `[✗]`)
- `die()` — Fatal errors (calls `error`, exits 1)
- `header()` — Section headers (BOLD CYAN with line decorators)

**See `install-gateway-docker.sh:78-98`**

**Patterns:**

- **All diagnostics to stderr:** Functions write `>&2` to keep stdout clean for command output
  ```bash
  info(){ echo -e "${BLUE}[i]${NC} $*" >&2; }
  ```
  See `install-gateway-docker.sh:80`

- **Colored output:** Conditional; only if connected to terminal
  ```bash
  if [[ -t 1 ]]; then
      RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
      ...
  else
      RED=''; GREEN=''
  fi
  readonly RED GREEN ...
  ```
  See `install-gateway-docker.sh:57-64`

- **Informational with timing:**
  ```bash
  run_timed "Установка пакетов: ${missing[*]}" \
      env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  ```
  See `install-gateway-docker.sh:119-148`

## Comments

**When to Comment:**

- Section headers: Descriptive text in Russian using box drawing characters
  ```bash
  # ─────────────────────────────── вывод ───────────────────────────────
  # All diagnostics go to stderr so functions can safely return values on stdout.
  ```
  See `install-gateway-docker.sh:78-79`

- Non-obvious logic: Explain WHY not WHAT
  ```bash
  # A UTF-8 locale is required: otherwise ${#str} counts bytes and the
  # Cyrillic menu loses its alignment.
  ```
  See `install-gateway-docker.sh:47-48`

- State machine notes: Explain next steps
  ```bash
  # Set as soon as the initial netplan is applied, so a dropped SSH session
  # during "netplan apply" cannot make the next run redo the setup.
  ```
  See `install-gateway-docker.sh:15-16`

**Style:**

- English for technical comments (see `install-gateway-docker.sh:79`)
- Russian for user-facing messages and explanations
- Line-prefix comments with `#`, no inline comments except in data
- Multi-line comments: Preceding lines, not inline

**JSDoc/TSDoc:**

- Not applicable (bash script); no formal documentation attributes

## Function Design

**Size:**

- Small single-purpose functions: 5–30 lines typical
- Example `is_ipv4`: 8 lines (validation only)
- Example `run_timed`: 30 lines (includes display and error handling)
- Complex functions like `main_menu`: 40+ lines (intentional for menu UX)

**Parameters:**

- Pass arguments explicitly; avoid reading globals inside functions
  ```bash
  validate_dhcp_range(){
      local start="$1" end="$2" lan="$3"
      ...
  }
  ```
  See `install-gateway-docker.sh:165-178`

- First parameter often labeled (`prompt="$1"`, `label="$1"`)
- Remaining parameters shifted or indexed (`"$2"`, `"${@:2}"`)
- Use `local` for all function variables

**Return Values:**

- Functions return exit codes (0=success, non-zero=failure)
- Output to stdout only when function returns values (e.g., `detect_interfaces` echoes interface names)
- All logging to stderr (`>&2`)
  ```bash
  detect_interfaces(){
      ...
      echo "$i"  # stdout: return value
  done
  ```
  See `install-gateway-docker.sh:268-276`

## Module Design

**Not applicable to single-script architecture.** 

**Structure in `install-gateway-docker.sh`:**

- Constants (lines 5–75): All readonly globals and defaults
- Configuration functions (lines 180–217): Config file I/O
- Validation functions (lines 150–178): Helper validators
- Feature groups: Network setup, DNS/DHCP, nftables, Docker, Mihomo, diagnostics
- Menu functions (lines 1300+): Interactive user interface
- Main entry point (lines 1519–1536): `main()` function and call at EOF

**Pattern:**

- Sections marked with box-drawing header comments
- Related functions grouped together
- Menu structure isolates UI from logic

---

*Convention analysis: 2026-09-16*
