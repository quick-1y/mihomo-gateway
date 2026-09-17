#!/usr/bin/env bash
# Ubuntu Gateway + Mihomo + Zashboard installer / manager
set -Eeuo pipefail

readonly SCRIPT_VERSION="2.0"

readonly STATE_DIR="/var/lib/mihomo-gateway"
readonly CONFIG_FILE="${STATE_DIR}/gateway.env"
readonly ORIGINAL_DIR="${STATE_DIR}/original"
readonly ORIGINAL_NETPLAN_DIR="${ORIGINAL_DIR}/netplan"
readonly ORIGINAL_DNSMASQ="${ORIGINAL_DIR}/dnsmasq.conf"
readonly ORIGINAL_NFT="${ORIGINAL_DIR}/nftables.conf"
readonly ORIGINAL_SYSCTL="${ORIGINAL_DIR}/99-router.conf"
readonly BACKUP_MARKER="${ORIGINAL_DIR}/BACKUP_DONE"
# Set as soon as the initial netplan is applied, so a dropped SSH session
# during "netplan apply" cannot make the next run redo the setup.
readonly NETWORK_MARKER="${STATE_DIR}/network-configured"

readonly NETPLAN_FILE="/etc/netplan/01-gateway.yaml"
readonly DNSMASQ_FILE="/etc/dnsmasq.conf"
readonly DNSMASQ_OVERRIDE="/etc/systemd/system/dnsmasq.service.d/override.conf"
readonly NFT_FILE="/etc/nftables.conf"
readonly PORTFWD_FILE="${STATE_DIR}/portforward.list"
# Legacy block-list (pre-refactor). Kept only as a read-only reference
# during migration to the allow-list model below — never written again.
readonly WANACCESS_FILE="${STATE_DIR}/wan-block.list"
readonly WAN_ALLOW_FILE="${STATE_DIR}/wan-allow.list"
readonly LAN_ALLOW_FILE="${STATE_DIR}/lan-allow.list"
readonly NFT_TABLE="gateway"
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly ORIGINAL_DOCKER_DAEMON="${ORIGINAL_DIR}/daemon.json"
readonly NFT_CONFIRM_BACKUP="${STATE_DIR}/nftables.conf.pre-confirm"
readonly NFT_CONFIRM_SECONDS=300
# Names of the systemd-timer-based confirm mechanism from an earlier
# revision of this script. No longer created (see nft_confirm_or_rollback);
# kept only so full_remove() can clean up leftovers from that revision.
readonly NFT_CONFIRM_TIMER_NAME="gateway-fw-confirm.timer"
readonly NFT_CONFIRM_SERVICE_NAME="gateway-fw-confirm.service"

# PPPoE
readonly PPPOE_PEER_NAME="mihomo-gateway"
readonly PPPOE_PEER_FILE="/etc/ppp/peers/mihomo-gateway"
readonly PAP_SECRETS="/etc/ppp/pap-secrets"
readonly CHAP_SECRETS="/etc/ppp/chap-secrets"
readonly SECRETS_BEGIN="# BEGIN mihomo-gateway"
readonly SECRETS_END="# END mihomo-gateway"
readonly PPPOE_IFACE="ppp0"
readonly PPPOE_SERVICE="mihomo-gateway-pppoe.service"
readonly PPPOE_WATCHDOG="mihomo-gateway-pppoe-watchdog"
readonly PPPOE_UNIT_DIR="/etc/systemd/system"
readonly PPPOE_HELPER_DIR="/usr/local/lib/mihomo-gateway"
readonly PPPOE_STATE_DIR="${STATE_DIR}/pppoe"
readonly PPPOE_PKG_FILE="${PPPOE_STATE_DIR}/installed-packages"
readonly PPPOE_FAIL_FILE="${PPPOE_STATE_DIR}/fail-count"
readonly NETPLAN_SAVE_DIR="${STATE_DIR}/netplan"
readonly NETPLAN_DHCP_SAVE="${NETPLAN_SAVE_DIR}/wan-dhcp.yaml"
readonly NETPLAN_PPPOE_SAVE="${NETPLAN_SAVE_DIR}/wan-pppoe.yaml"
readonly SYSCTL_FILE="/etc/sysctl.d/99-router.conf"

readonly PROJECT_DIR="/opt/mihomo-gateway"
readonly COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly MIHOMO_CONFIG_DIR="${PROJECT_DIR}/config"
readonly MIHOMO_CONFIG="${MIHOMO_CONFIG_DIR}/config.yaml"

readonly MIHOMO_IMAGE="metacubex/mihomo:latest"
readonly ZASHBOARD_IMAGE="ghcr.io/zephyruso/zashboard:latest"
readonly MIHOMO_CONTAINER="mihomo"
readonly ZASHBOARD_CONTAINER="zashboard"

# Mihomo configuration template stored separately in the repository.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MIHOMO_TEMPLATE_LOCAL="${SCRIPT_DIR}/mihomo/config.yaml"
readonly MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/quick-1y/mihomo-gateway/main/mihomo/config.yaml"

readonly LAN_DEFAULT="192.168.100.1"
readonly DHCP_START_DEFAULT="192.168.100.100"
readonly DHCP_END_DEFAULT="192.168.100.250"
readonly DNS1_DEFAULT="1.1.1.1"
readonly DNS2_DEFAULT="8.8.8.8"

# A UTF-8 locale is required: otherwise ${#str} counts bytes and the
# Cyrillic menu loses its alignment.
if ! locale charmap 2>/dev/null | grep -qi 'utf-\?8'; then
    for _l in C.UTF-8 C.utf8 en_US.UTF-8 ru_RU.UTF-8; do
        if locale -a 2>/dev/null | grep -qix "$_l"; then export LC_ALL="$_l"; break; fi
    done
    unset _l
fi

# Colors are real escape sequences ($'...'), so they work with both echo and printf.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'
    DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi
readonly RED GREEN YELLOW BLUE CYAN BOLD DIM NC

readonly LINE="══════════════════════════════════════════════════════════════"

# Keys allowed in the state file.
# PPPOE_PASSWORD is intentionally absent: it lives only in /etc/ppp/*-secrets (0600).
readonly CONFIG_KEYS="LAN_IP DHCP_START DHCP_END DNS1 DNS2 LAN_IFACE WAN_IFACE LAN_MAC WAN_MAC NAT_ENABLED SUBSCRIPTION_URL CLASH_SECRET WAN_MODE PPPOE_USER PPPOE_INITIALIZED PPPOE_AUTO_ROLLBACK PPPOE_ATTEMPTS PPPOE_FAIL_THRESHOLD"

LAN_IFACE=""; WAN_IFACE=""; LAN_MAC=""; WAN_MAC=""
LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"
DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; CLASH_SECRET=""; SUBSCRIPTION_URL=""
NAT_ENABLED="1"
WAN_MODE="dhcp"; PPPOE_USER=""; PPPOE_INITIALIZED="0"
PPPOE_AUTO_ROLLBACK="0"; PPPOE_ATTEMPTS="10"; PPPOE_FAIL_THRESHOLD="5"

TEMPLATE_CACHE=""

# ─────────────────────────────── вывод ───────────────────────────────
# All diagnostics go to stderr so functions can safely return values on stdout.
info(){    echo -e "${BLUE}[i]${NC} $*" >&2; }
success(){ echo -e "${GREEN}[✓]${NC} $*" >&2; }
warn(){    echo -e "${YELLOW}[!]${NC} $*" >&2; }
error(){   echo -e "${RED}[✗]${NC} $*" >&2; }
die(){     error "$*"; exit 1; }

# Pads by characters (printf %-Ns would pad by bytes and break Cyrillic columns).
pad(){
    local s="$1" w="$2" len=${#1}
    if (( len < w )); then printf '%s%*s' "$s" $((w - len)) ''; else printf '%s' "$s"; fi
}

header(){
    clear
    echo
    echo -e "${BOLD}${CYAN}${LINE}${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}${LINE}${NC}"
    echo
}

confirm(){
    local a
    read -rp "$(echo -e "${YELLOW}${1:-Продолжить?} [y/N]: ${NC}")" a || return 1
    [[ "$a" =~ ^([Yy]([Ee][Ss])?|[Дд]([Аа])?)$ ]]
}
press_enter(){ echo; read -rp "Нажмите Enter для продолжения..." _ || true; }
need_root(){ [[ $EUID -eq 0 ]] || die "Запустите с правами root: sudo bash $0"; }

cleanup(){ [[ -n "$TEMPLATE_CACHE" && -f "$TEMPLATE_CACHE" ]] && rm -f "$TEMPLATE_CACHE"; return 0; }
trap cleanup EXIT

on_error(){
    local rc=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]}
    error "Ошибка (код ${rc}) в строке ${line}: ${cmd}"
    exit "$rc"
}
trap on_error ERR

# ─────────────────────────── вспомогательное ─────────────────────────
run_timed(){
    local label="$1"; shift
    local log start pid rc elapsed
    log=$(mktemp /tmp/mgw-run.XXXXXX)
    start=$SECONDS

    if [[ -t 1 ]]; then
        "$@" >"$log" 2>&1 </dev/null &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            elapsed=$((SECONDS - start))
            printf '\r%s⏳%s %-48s %3ss' "$YELLOW" "$NC" "$label" "$elapsed" >&2
            sleep 1
        done
        rc=0; wait "$pid" || rc=$?
        printf '\r\033[2K' >&2
    else
        rc=0; "$@" >"$log" 2>&1 </dev/null || rc=$?
    fi

    elapsed=$((SECONDS - start))
    if (( rc == 0 )); then
        success "$label — ${elapsed} с"
    else
        error "$label — ошибка (код ${rc}, ${elapsed} с)"
        tail -n 30 "$log" >&2 || true
    fi
    rm -f "$log"
    return "$rc"
}

# ── валидация ────────────────────────────────────────────────────────
is_ipv4(){
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra o <<<"$ip"
    for _o in "${o[@]}"; do
        [[ "$_o" =~ ^[0-9]+$ ]] || return 1
        (( _o >= 0 && _o <= 255 )) || return 1
    done
    return 0
}
last_octet(){ echo "${1##*.}"; }
subnet_of(){ echo "${1%.*}"; }
same_subnet(){ [[ "$(subnet_of "$1")" == "$(subnet_of "$2")" ]]; }

validate_dhcp_range(){
    local start="$1" end="$2" lan="$3"
    is_ipv4 "$start" || { error "Некорректный начальный адрес DHCP."; return 1; }
    is_ipv4 "$end"   || { error "Некорректный конечный адрес DHCP."; return 1; }
    same_subnet "$start" "$lan" || { error "Начало пула не в подсети $(subnet_of "$lan").0/24"; return 1; }
    same_subnet "$end"   "$lan" || { error "Конец пула не в подсети $(subnet_of "$lan").0/24"; return 1; }
    (( $(last_octet "$start") <= $(last_octet "$end") )) || { error "Начало пула больше конца."; return 1; }
    local lo; lo=$(last_octet "$lan")
    if (( lo >= $(last_octet "$start") && lo <= $(last_octet "$end") )); then
        error "Адрес шлюза ${lan} попадает внутрь DHCP-пула."
        return 1
    fi
    return 0
}

# ── конфигурация состояния ───────────────────────────────────────────
cfg_quote(){ local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

write_config(){
    local key val tmp
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    tmp=$(mktemp "${STATE_DIR}/.gateway.env.XXXXXX")
    {
        echo "# mihomo-gateway state (v${SCRIPT_VERSION}) — не редактировать вручную"
        for key in $CONFIG_KEYS; do
            val="${!key-}"
            printf '%s=%s\n' "$key" "$(cfg_quote "$val")"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# Parses the state file instead of sourcing it: only known keys, quoted values.
load_config(){
    [[ -f "$CONFIG_FILE" ]] || return 1
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z0-9_]+)=(\'.*\')$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        [[ " $CONFIG_KEYS " == *" $key "* ]] || continue
        eval "$key=$val"
    done <"$CONFIG_FILE"

    LAN_IP="${LAN_IP:-$LAN_DEFAULT}"
    DHCP_START="${DHCP_START:-$DHCP_START_DEFAULT}"
    DHCP_END="${DHCP_END:-$DHCP_END_DEFAULT}"
    DNS1="${DNS1:-$DNS1_DEFAULT}"; DNS2="${DNS2:-$DNS2_DEFAULT}"
    NAT_ENABLED="${NAT_ENABLED:-1}"
    SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-}"; CLASH_SECRET="${CLASH_SECRET:-}"
    LAN_IFACE="${LAN_IFACE:-}"; WAN_IFACE="${WAN_IFACE:-}"
    LAN_MAC="${LAN_MAC:-}"; WAN_MAC="${WAN_MAC:-}"
    WAN_MODE="${WAN_MODE:-dhcp}"
    [[ "$WAN_MODE" == pppoe || "$WAN_MODE" == dhcp ]] || WAN_MODE="dhcp"
    PPPOE_USER="${PPPOE_USER:-}"
    PPPOE_INITIALIZED="${PPPOE_INITIALIZED:-0}"
    PPPOE_AUTO_ROLLBACK="${PPPOE_AUTO_ROLLBACK:-0}"
    [[ "${PPPOE_ATTEMPTS:-}" =~ ^[0-9]+$ ]] || PPPOE_ATTEMPTS="10"
    [[ "${PPPOE_FAIL_THRESHOLD:-}" =~ ^[0-9]+$ ]] || PPPOE_FAIL_THRESHOLD="5"
    return 0
}

# ─────────────────────────────── ОС / apt ────────────────────────────
get_os_release_value(){
    local key="$1" value
    value=$(grep -E "^[[:space:]]*${key}=" /etc/os-release 2>/dev/null | head -n1 | sed -E 's/^[^=]+=//' || true)
    value="${value#[\"\']}"; value="${value%[\"\']}"
    printf '%s' "$value"
}

check_os(){
    [[ -f /etc/os-release ]] || die "Не найден /etc/os-release"
    local os_id os_id_like os_pretty
    os_id="$(get_os_release_value ID)"
    os_id_like="$(get_os_release_value ID_LIKE)"
    os_pretty="$(get_os_release_value PRETTY_NAME)"
    info "ОС: ${os_pretty:-unknown}"
    if [[ "$os_id" != "ubuntu" && "$os_id_like" != *ubuntu* && "$os_id_like" != *debian* ]]; then
        warn "Скрипт рассчитан на Ubuntu/Debian."
        confirm "Продолжить?" || exit 1
    fi
}

pkg_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

apt_update_safe(){
    local log rc=0
    log=$(mktemp /tmp/mgw-apt.XXXXXX)
    apt-get update -qq >"$log" 2>&1 || rc=$?
    if (( rc != 0 )); then
        warn "apt update завершился с предупреждениями/ошибкой."
        tail -n 12 "$log" >&2 || true
    fi
    rm -f "$log"
    return 0
}

apt_install(){
    local packages=("$@") missing=() p
    for p in "${packages[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then
        success "Пакеты уже установлены: ${packages[*]}"
        return 0
    fi
    apt_update_safe
    run_timed "Установка пакетов: ${missing[*]}" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# ────────────────────────────── интерфейсы ───────────────────────────
detect_interfaces(){
    local p i
    for p in /sys/class/net/*; do
        i=$(basename "$p")
        [[ "$i" == lo ]] && continue
        [[ -d "$p/device" || -d "$p/wireless" ]] || continue
        echo "$i"
    done
}

mac_of(){ cat "/sys/class/net/$1/address" 2>/dev/null || echo ""; }
carrier_of(){ [[ "$(cat "/sys/class/net/$1/carrier" 2>/dev/null || echo 0)" == 1 ]]; }
state_of(){ cat "/sys/class/net/$1/operstate" 2>/dev/null || echo unknown; }
speed_of(){
    local s; s=$(cat "/sys/class/net/$1/speed" 2>/dev/null || echo 0)
    if [[ "$s" =~ ^[1-9][0-9]*$ ]]; then echo "$s Мбит/с"; else echo "—"; fi
}

print_iface(){
    local i="$1" mac state speed link
    mac=$(mac_of "$i"); state=$(state_of "$i"); speed=$(speed_of "$i")
    if carrier_of "$i"; then link="${GREEN}connected${NC}"; else link="${DIM}disconnected${NC}"; fi
    printf '%s MAC: %-17s  Статус: %s  Линк: %b  Скорость: %s' \
        "$(pad "$i" 8)" "$mac" "$(pad "$state" 8)" "$link" "$speed"
}

choose_iface_manual(){
    local prompt="$1" exclude="${2:-}"
    local arr=() shown=() i n chosen
    mapfile -t arr < <(detect_interfaces)

    for i in "${arr[@]}"; do
        [[ "$i" == "$exclude" ]] && continue
        shown+=("$i")
    done
    (( ${#shown[@]} > 0 )) || { error "Нет доступных интерфейсов."; return 1; }

    {
        echo
        echo -e "${BOLD}Найденные физические интерфейсы:${NC}"
        echo
        n=1
        for i in "${shown[@]}"; do
            printf '  %d) ' "$n"; print_iface "$i"; printf '\n'
            n=$((n + 1))
        done
        echo
    } >&2

    while true; do
        read -rp "$(echo -e "${BOLD}${prompt} [1-${#shown[@]}]: ${NC}")" n || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#shown[@]} )); then
            chosen="${shown[n-1]}"
            echo "$chosen"
            return 0
        fi
        warn "Введите номер от 1 до ${#shown[@]}."
    done
}

# ──────────────────────────────── бэкап ──────────────────────────────
backup_once(){
    mkdir -p "$ORIGINAL_NETPLAN_DIR"
    chmod 700 "$ORIGINAL_DIR"
    [[ -f "$BACKUP_MARKER" ]] && return 0

    local f base
    shopt -s nullglob
    for f in /etc/netplan/*.yaml; do
        base=$(basename "$f")
        cp -a "$f" "${ORIGINAL_NETPLAN_DIR}/${base}"
        mv "$f" "${f}.gateway-disabled"
    done
    shopt -u nullglob
    [[ -f "$DNSMASQ_FILE" ]] && cp -a "$DNSMASQ_FILE" "$ORIGINAL_DNSMASQ"
    [[ -f "$NFT_FILE" ]]     && cp -a "$NFT_FILE" "$ORIGINAL_NFT"
    [[ -f "$SYSCTL_FILE" ]]  && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL"
    echo "NETWORK_BACKUP_DONE=1" > "$BACKUP_MARKER"
    success "Исходные конфигурации сохранены в ${ORIGINAL_DIR}"
    return 0
}

# ─────────────────────────────── netplan ─────────────────────────────
# ignore-carrier keeps the LAN address configured even with the cable unplugged,
# so 192.168.100.1 exists for dnsmasq and for the zashboard port binding.
netplan_body(){
    local extra="" wan_cfg
    [[ "$1" == 1 ]] && extra=$'\n      ignore-carrier: true'
    # In PPPoE mode netplan owns the link only; pppd owns the session and the
    # default route. LAN stanza is byte-identical in both modes.
    if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
        wan_cfg=$'      dhcp4: false\n      dhcp6: false\n      accept-ra: false'
    else
        wan_cfg='      dhcp4: true'
    fi
    cat > "$NETPLAN_FILE" <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    lan:
      match:
        macaddress: ${LAN_MAC}
      set-name: lan
      optional: true${extra}
      addresses:
        - ${LAN_IP}/24
    wan:
      match:
        macaddress: ${WAN_MAC}
      set-name: wan
      optional: true
${wan_cfg}
EOF2
    chmod 600 "$NETPLAN_FILE"
}

write_netplan(){
    [[ -n "$LAN_MAC" && -n "$WAN_MAC" ]] || { error "Не определены MAC-адреса LAN/WAN."; return 1; }
    mkdir -p /etc/netplan
    netplan_body 1
    if ! netplan generate >/dev/null 2>&1; then
        warn "Эта версия netplan не поддерживает ignore-carrier."
        warn "LAN-адрес будет подниматься только при подключённом кабеле."
        netplan_body 0
        netplan generate >/dev/null 2>&1 || { error "Ошибка конфигурации Netplan."; return 1; }
    fi
    save_wan_rollback "${WAN_MODE:-dhcp}"
    return 0
}

apply_netplan_checked(){
    netplan generate || return 1
    netplan apply    || return 1
    sleep 3
    ip link show lan >/dev/null 2>&1 || return 1
    ip link show wan >/dev/null 2>&1 || return 1
    return 0
}

configure_network_first(){
    header "ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА СЕТИ"
    echo "Будут настроены:"
    echo
    echo "  LAN  → ${LAN_DEFAULT}/24"
    echo "  WAN  → DHCP"
    echo "  DHCP → ${DHCP_START_DEFAULT}–${DHCP_END_DEFAULT}"
    echo
    warn "После применения Netplan SSH может быть разорван."
    confirm "Начать сетевую настройку?" || exit 0

    header "СЕТЕВОЙ ЭТАП · ВЫБОР LAN / WAN"
    local ifaces=()
    mapfile -t ifaces < <(detect_interfaces)
    (( ${#ifaces[@]} >= 2 )) || die "Нужно минимум два физических интерфейса."

    LAN_IFACE=$(choose_iface_manual "Выберите LAN (локальная сеть)" "") || exit 1
    success "LAN: ${LAN_IFACE}"
    WAN_IFACE=$(choose_iface_manual "Выберите WAN (интернет / провайдер)" "$LAN_IFACE") || exit 1
    success "WAN: ${WAN_IFACE}"
    LAN_MAC=$(mac_of "$LAN_IFACE"); WAN_MAC=$(mac_of "$WAN_IFACE")

    if ! carrier_of "$WAN_IFACE"; then
        warn "На ${WAN_IFACE} не обнаружен линк (carrier)."
        confirm "Всё равно использовать как WAN?" || exit 0
    fi

    echo
    echo -e "${BOLD}Назначение:${NC}"
    echo "  LAN:    ${LAN_IFACE}  ${LAN_MAC}"
    echo "  WAN:    ${WAN_IFACE}  ${WAN_MAC}"
    echo "  LAN IP: ${LAN_DEFAULT}/24"
    echo
    confirm "Применить?" || exit 0

    backup_once
    LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"
    DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; NAT_ENABLED=1
    SUBSCRIPTION_URL=""; CLASH_SECRET=""
    write_config

    header "СЕТЕВОЙ ЭТАП · NETPLAN"
    write_netplan
    info "Проверяю Netplan..."; netplan generate; success "netplan generate — OK"

    echo
    warn "Сейчас будет применён Netplan. Интерфейсы будут переименованы:"
    echo "  ${LAN_IFACE} → lan   (${LAN_IP}/24)"
    echo "  ${WAN_IFACE} → wan   (DHCP)"
    echo
    warn "После применения Netplan SSH может быть разорван."
    echo "Затем найдите устройство по новому адресу и запустите скрипт снова."
    echo
    confirm "Применить Netplan сейчас?" || { warn "Отменено. Netplan не применён."; exit 0; }

    # Written before the apply: SSH (and this script) may die mid-apply.
    echo "NETWORK_CONFIGURED=1" > "$NETWORK_MARKER"

    if ! run_timed "Применение Netplan" apply_netplan_checked; then
        rm -f "$NETWORK_MARKER"
        error "Netplan не применился. Проверьте:"
        echo "  ip -br addr"
        echo "  networkctl status"
        echo "  journalctl -u systemd-networkd -n 50"
        exit 1
    fi
    success "LAN → ${LAN_IP}/24 (optional)"
    success "WAN → интерфейс ${WAN_IFACE}"

    configure_dnsmasq

    if carrier_of "$LAN_IFACE"; then
        warn "На LAN-порту есть линк. Если SSH идёт через него — соединение оборвётся."
        echo "Переподключитесь по новому адресу и запустите скрипт снова:"
        echo -e "  ${CYAN}ssh user@${LAN_IP}${NC}"
        exit 0
    fi

    info "LAN-порт не подключён — это нормально."
    info "DHCP (bind-dynamic) подхватит LAN автоматически при подключении кабеля."
    info "Продолжаю установку..."
}

# ─────────────────────────────── dnsmasq ─────────────────────────────
configure_dnsmasq(){
    header "НАСТРОЙКА · DHCP / DNSMASQ"
    validate_dhcp_range "$DHCP_START" "$DHCP_END" "$LAN_IP" || return 1
    [[ -f "$DNSMASQ_FILE" && ! -f "$ORIGINAL_DNSMASQ" ]] && cp -a "$DNSMASQ_FILE" "$ORIGINAL_DNSMASQ"
    apt_install dnsmasq

    cat > "$DNSMASQ_FILE" <<EOF2
interface=lan
bind-dynamic

dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h
dhcp-authoritative

dhcp-option=3,${LAN_IP}
dhcp-option=6,${LAN_IP}

domain-needed
bogus-priv

server=${DNS1}
server=${DNS2}
EOF2

    mkdir -p "$(dirname "$DNSMASQ_OVERRIDE")"
    cat > "$DNSMASQ_OVERRIDE" <<'EOF2'
[Unit]
Wants=network-online.target
After=network-online.target nftables.service

[Service]
Restart=always
RestartSec=5
EOF2

    systemctl daemon-reload
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    if ! run_timed "Запуск dnsmasq" systemctl restart dnsmasq; then
        journalctl -u dnsmasq -n 40 --no-pager >&2 || true
        return 1
    fi
    systemctl is-active --quiet dnsmasq || { error "dnsmasq не active."; return 1; }
    success "DHCP → ${DHCP_START}–${DHCP_END} (bind-dynamic)"
    success "Шлюз/DNS → ${LAN_IP}"
}

# ─────────────────────────────── nftables ────────────────────────────
# Single authoritative firewall/NAT owner: one table ("inet gateway") holds
# filtering (input/forward/output) AND NAT (postrouting/prerouting). Docker
# never touches iptables/nftables (daemon.json: "iptables": false, see
# configure_docker_daemon()), so this table is the only place that decides
# what is reachable from LAN, from WAN, and what gets forwarded/NATed.
#
# Structural layer (chains, hooks, policies, set/map *definitions*) is
# rendered by write_nft_structural() and changes rarely (install, LAN IP
# change, NAT on/off). Data layer (which ports are open, which forwards
# exist) lives in nftables sets/maps and is mutated with single
# `nft add/delete element` calls (nft_add_port, nft_add_portfwd, ...) so a
# menu edit is atomic and never reloads the whole ruleset. The on-disk
# ${NFT_FILE} is kept in sync on every change (write_nft_structural is cheap
# — it only writes a file) so a reboot or `systemctl restart nftables`
# always reproduces the exact live state with no separate "restore" step.
#
# WAN is referenced everywhere as the dynamic set @wan_if (holds "wan" in
# DHCP mode or "ppp0" in PPPoE mode) instead of being hardcoded into rule
# text — switching WAN mode is a single `nft flush/add element` call
# (see nft_set_wan_if), never a firewall reload.

nft_lan_subnet(){ printf '%s.0/24' "$(subnet_of "$LAN_IP")"; }

# elements= list for a simple port set, built from a "<tcp|udp> <port> <label>" file.
nft_port_elements(){
    local proto="$1" file="$2" ports=() p port _rest
    [[ -f "$file" ]] || { printf ''; return 0; }
    while read -r p port _rest; do
        [[ "$p" == "$proto" ]] || continue
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        ports+=("$port")
    done < "$file"
    (( ${#ports[@]} > 0 )) && (IFS=,; printf '%s' "${ports[*]}")
    return 0
}

# elements= list for the portfwd map, built from PORTFWD_FILE
# ("<tcp|udp> <wan_port> <lan_ip> <lan_port>" lines).
nft_portfwd_elements(){
    local proto="$1" out=() p wport lip lport
    [[ -f "$PORTFWD_FILE" ]] || { printf ''; return 0; }
    while read -r p wport lip lport; do
        [[ "$p" == "$proto" ]] || continue
        [[ -n "$wport" && -n "$lip" && -n "$lport" ]] || continue
        out+=("${wport} : ${lip} . ${lport}")
    done < "$PORTFWD_FILE"
    (( ${#out[@]} > 0 )) && (IFS=,; printf '%s' "${out[*]}")
    return 0
}

# nft rejects an empty "elements = {  }" clause — this must be omitted
# entirely (not just left blank) when there is no data yet.
nft_elements_clause(){
    [[ -n "$1" ]] && printf '        elements = { %s }\n' "$1"
    return 0
}

# Renders the complete /etc/nftables.conf (structure + current data) from
# the state files. Pure function of state — always safe to call, never
# touches the live kernel ruleset by itself.
write_nft_structural(){
    local wan_if lan_net lan_tcp lan_udp wan_tcp wan_udp pf_tcp pf_udp nat_rule=""
    wan_if="$(wan_out_iface)"
    lan_net="$(nft_lan_subnet)"
    lan_tcp="$(nft_port_elements tcp "$LAN_ALLOW_FILE")"
    lan_udp="$(nft_port_elements udp "$LAN_ALLOW_FILE")"
    wan_tcp="$(nft_port_elements tcp "$WAN_ALLOW_FILE")"
    wan_udp="$(nft_port_elements udp "$WAN_ALLOW_FILE")"
    pf_tcp="$(nft_portfwd_elements tcp)"
    pf_udp="$(nft_portfwd_elements udp)"
    [[ "$NAT_ENABLED" == "1" ]] && nat_rule="        ip saddr ${lan_net} oifname @wan_if masquerade"

    cat > "$NFT_FILE" <<EOF2
#!/usr/sbin/nft -f
flush ruleset

table inet ${NFT_TABLE} {
    set wan_if {
        type ifname
        elements = { "${wan_if}" }
    }

    set lan_allow_tcp {
        type inet_service
$(nft_elements_clause "$lan_tcp")
    }
    set lan_allow_udp {
        type inet_service
$(nft_elements_clause "$lan_udp")
    }
    set wan_allow_tcp {
        type inet_service
$(nft_elements_clause "$wan_tcp")
    }
    set wan_allow_udp {
        type inet_service
$(nft_elements_clause "$wan_udp")
    }

    map portfwd_tcp {
        type inet_service : ipv4_addr . inet_service
$(nft_elements_clause "$pf_tcp")
    }
    map portfwd_udp {
        type inet_service : ipv4_addr . inet_service
$(nft_elements_clause "$pf_udp")
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        iif "lo" accept
        ct state established,related accept
        # Mihomo's own auto-redirect table (table inet mihomo) intercepts
        # LAN traffic with a plain nftables "redirect to :<port>" rule — a
        # DNAT-to-local operation. That reclassifies the packet as
        # locally-destined, so it traverses this INPUT hook instead of
        # FORWARD, hitting a destination port internal to mihomo (not
        # fixed, not known to this firewall) that would otherwise fall
        # through to the default-drop policy below. Confirmed on real
        # hardware: mihomo's redirect/dnat rules never set any packet or
        # connection mark, so matching on the mark this refactor originally
        # tried (meta mark) never fires — ct status dnat is the one fact
        # that's actually true of this traffic, and is the same signal the
        # forward chain below already uses for WAN->LAN port-forwarding.
        ct status dnat accept
        iifname "lan" icmp type echo-request accept
        iifname "lan" tcp dport @lan_allow_tcp accept
        iifname "lan" udp dport @lan_allow_udp accept
        iifname @wan_if tcp dport @wan_allow_tcp accept
        iifname @wan_if udp dport @wan_allow_udp accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        # MSS clamping MUST run before the terminal "accept" statements below:
        # once a packet hits "iifname lan accept" its chain evaluation stops
        # (accept is a terminal verdict), so a clamp rule placed after it
        # would never execute for any LAN-forwarded packet. This ordering
        # bug existed in the pre-refactor ruleset too (inherited, not new).
        iifname @wan_if tcp flags syn tcp option maxseg size set rt mtu
        oifname @wan_if tcp flags syn tcp option maxseg size set rt mtu
        iifname "lan" accept
        ct status dnat accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
${nat_rule}
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname @wan_if dnat ip to tcp dport map @portfwd_tcp
        iifname @wan_if dnat ip to udp dport map @portfwd_udp
    }
}
EOF2
    chmod 644 "$NFT_FILE"
}

# ── atomic runtime element mutation (no reload, no rules-disappear window) ─
nft_add_port(){ nft add element inet "$NFT_TABLE" "$1" "{ $2 }" 2>/dev/null; }
nft_del_port(){ nft delete element inet "$NFT_TABLE" "$1" "{ $2 }" 2>/dev/null; }
nft_add_portfwd(){ nft add element inet "$NFT_TABLE" "$1" "{ $2 : $3 . $4 }" 2>/dev/null; }
nft_del_portfwd(){ nft delete element inet "$NFT_TABLE" "$1" "{ $2 : $3 . $4 }" 2>/dev/null; }

# Called whenever WAN mode switches (DHCP<->PPPoE): one atomic set update,
# never a firewall reload. Safe to call even if nftables isn't loaded yet
# (fresh install) — write_nft_structural() will pick up the right value
# regardless the next time the structural file is (re)rendered.
nft_set_wan_if(){
    local iface="$1"
    nft flush set inet "$NFT_TABLE" wan_if 2>/dev/null || return 1
    nft add element inet "$NFT_TABLE" wan_if "{ \"${iface}\" }" 2>/dev/null || return 1
    return 0
}

# ── inline, synchronous confirm-or-rollback (no separate menu/CLI step) ───
# Snapshot the ACTUAL live ruleset (ground truth, not just a copy of a state
# file that may already have been edited) before a risky change is made.
# Call this BEFORE performing the change; nft_confirm_or_rollback() restores
# this snapshot if the change isn't confirmed.
nft_snapshot(){
    rm -f "$NFT_CONFIRM_BACKUP"
    if systemctl is-active --quiet nftables 2>/dev/null; then
        nft -s list ruleset > "$NFT_CONFIRM_BACKUP" 2>/dev/null || true
    fi
    return 0
}

# Call AFTER a risky nftables change is already live. Blocks with a visible
# countdown; 'y' confirms and keeps the change, 'n' or timeout restores the
# ruleset captured by the most recent nft_snapshot(). This is the ONLY
# confirm mechanism — automatic, inline, no separate menu item or CLI arg,
# used identically during install and during normal menu-driven changes.
# Restores the live kernel ruleset only; the caller is responsible for
# reverting its own state file / in-memory variable and re-running
# write_nft_structural() on a rollback (mirrors the existing pattern for
# NAT on/off — see firewall_menu()).
nft_confirm_or_rollback(){
    echo
    warn "Правила firewall изменены и требуют подтверждения."
    warn "Проверьте SSH / Zashboard / Mihomo API с другого устройства, не закрывая эту сессию."
    echo

    local remaining=$NFT_CONFIRM_SECONDS key answer=""
    while (( remaining > 0 )); do
        printf '\r%s[?]%s Подтвердить изменения? [y/N]  (откат через %02d:%02d) ' \
            "$YELLOW" "$NC" $(( remaining / 60 )) $(( remaining % 60 ))
        if read -rsn1 -t 1 key 2>/dev/null; then
            case "$key" in
                y|Y) answer=y; break ;;
                n|N) answer=n; break ;;
                *) : ;;
            esac
        fi
        remaining=$((remaining - 1))
    done
    printf '\r\033[2K'

    if [[ "$answer" == y ]]; then
        success "Изменения firewall подтверждены."
        rm -f "$NFT_CONFIRM_BACKUP"
        return 0
    fi

    [[ "$answer" == n ]] && warn "Изменения отклонены — откат к предыдущей конфигурации." \
                         || warn "Время ожидания истекло — откат к предыдущей конфигурации."
    if [[ -s "$NFT_CONFIRM_BACKUP" ]]; then
        if { echo "flush ruleset"; cat "$NFT_CONFIRM_BACKUP"; } | nft -f -; then
            success "Предыдущая конфигурация firewall восстановлена."
        else
            error "ОТКАТ НЕ УДАЛСЯ — проверьте вручную: nft list ruleset"
        fi
    else
        nft flush ruleset 2>/dev/null || true
        warn "До этого изменения firewall не был настроен — правила очищены."
    fi
    rm -f "$NFT_CONFIRM_BACKUP"
    return 1
}

# Convenience wrapper for the common case: snapshot already taken by the
# caller, $NFT_FILE already re-rendered by write_nft_structural() — this
# just does the syntax check, the atomic load, and the confirm-or-rollback.
# Returns 0 only if the admin actually confirmed the change.
nft_apply_with_confirm(){
    nft -c -f "$NFT_FILE" || { error "Ошибка синтаксиса nftables — правила не применены."; rm -f "$NFT_CONFIRM_BACKUP"; return 1; }
    if ! nft -f "$NFT_FILE"; then
        error "Не удалось загрузить новые правила nftables."
        rm -f "$NFT_CONFIRM_BACKUP"
        return 1
    fi
    systemctl enable nftables >/dev/null 2>&1 || true
    nft_confirm_or_rollback
}

# ── WAN allow-list (default-deny, explicit allow) ──────────────────────
wanaccess_seed_defaults(){
    [[ -f "$WAN_ALLOW_FILE" ]] && return 0
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    if [[ -f "$WANACCESS_FILE" ]]; then
        info "Обнаружен старый список блокировок WAN (${WANACCESS_FILE})."
        info "Модель изменилась на allow-list (default-deny) — старый файл не переносится автоматически."
        info "По умолчанию с WAN будут доступны SSH (22), Zashboard (80) и Mihomo API (9090)."
    fi
    cat > "$WAN_ALLOW_FILE" <<'EOF2'
tcp 22 SSH
tcp 80 Zashboard
tcp 9090 Mihomo-API
EOF2
    chmod 600 "$WAN_ALLOW_FILE"
}

wanaccess_count(){ wanaccess_seed_defaults; [[ -s "$WAN_ALLOW_FILE" ]] && grep -c . "$WAN_ALLOW_FILE" || echo 0; }

wanaccess_print_table(){
    wanaccess_seed_defaults
    if [[ ! -s "$WAN_ALLOW_FILE" ]]; then
        echo "  Разрешённых портов нет — gateway полностью недоступен с WAN."
        return 0
    fi
    local i=0 proto port label
    while read -r proto port label; do
        [[ -z "$proto" ]] && continue
        i=$((i+1))
        printf '  %s) %-4s порт %-6s разрешён — %s\n' "$i" "${proto^^}" "$port" "${label:-без описания}"
    done < "$WAN_ALLOW_FILE"
}

# ── LAN allow-list (default-deny, explicit allow — same model as WAN) ───
lan_allow_seed_defaults(){
    if [[ -f "$LAN_ALLOW_FILE" ]]; then
        # Self-heal: udp/67 (DHCP server) was missing from the very first
        # cut of this default-deny LAN policy — without it, the gateway's
        # own firewall blocks LAN clients' DHCP requests before dnsmasq
        # ever sees them. Backfill it into any file that predates this fix.
        grep -qE '^udp 67 ' "$LAN_ALLOW_FILE" 2>/dev/null || {
            printf 'udp 67 DHCP\n' >> "$LAN_ALLOW_FILE"
            chmod 600 "$LAN_ALLOW_FILE"
        }
        return 0
    fi
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$LAN_ALLOW_FILE" <<'EOF2'
tcp 22 SSH
tcp 80 Zashboard
tcp 7890 Mihomo-proxy
udp 7890 Mihomo-proxy
tcp 9090 Mihomo-API
tcp 53 DNS
udp 53 DNS
udp 67 DHCP
EOF2
    chmod 600 "$LAN_ALLOW_FILE"
}

lan_allow_count(){ lan_allow_seed_defaults; [[ -s "$LAN_ALLOW_FILE" ]] && grep -c . "$LAN_ALLOW_FILE" || echo 0; }

lan_allow_print_table(){
    lan_allow_seed_defaults
    if [[ ! -s "$LAN_ALLOW_FILE" ]]; then
        echo "  Разрешённых портов нет — gateway полностью недоступен из LAN."
        return 0
    fi
    local i=0 proto port label
    while read -r proto port label; do
        [[ -z "$proto" ]] && continue
        i=$((i+1))
        printf '  %s) %-4s порт %-6s разрешён — %s\n' "$i" "${proto^^}" "$port" "${label:-без описания}"
    done < "$LAN_ALLOW_FILE"
}

# ── port forwarding (WAN → LAN device, DNAT via nft map) ────────────────
portfwd_count(){ [[ -s "$PORTFWD_FILE" ]] && grep -c . "$PORTFWD_FILE" || echo 0; }

portfwd_print_table(){
    if [[ ! -s "$PORTFWD_FILE" ]]; then
        echo "  Правил нет."
        return 0
    fi
    local wan_ip; wan_ip="$(iface_ipv4 "$(wan_out_iface)")"; wan_ip="${wan_ip:-<WAN-IP>}"
    local i=0 proto wport lip lport
    while read -r proto wport lip lport; do
        [[ -z "$proto" ]] && continue
        i=$((i+1))
        printf '  %s) %-4s %s:%s → %s:%s\n' "$i" "${proto^^}" "$wan_ip" "$wport" "$lip" "$lport"
    done < "$PORTFWD_FILE"
}

configure_nftables(){
    header "УСТАНОВКА · NFTABLES / NAT / FIREWALL"
    apt_install nftables
    [[ -f "$NFT_FILE" && ! -f "$ORIGINAL_NFT" ]] && cp -a "$NFT_FILE" "$ORIGINAL_NFT"
    wanaccess_seed_defaults
    lan_allow_seed_defaults
    nft_snapshot
    write_nft_structural
    nft -c -f "$NFT_FILE" || { error "Ошибка синтаксиса nftables."; return 1; }
    success "Конфигурация nftables — OK (LAN allow-list: $(lan_allow_count) портов, WAN allow-list: $(wanaccess_count) портов)"
    # Not run through run_timed(): the confirm countdown must be interactive
    # on the terminal directly — run_timed captures stdout into a log file.
    nft_apply_with_confirm
}

configure_forwarding(){
    header "УСТАНОВКА · IPV4 FORWARDING / IPV6"
    [[ -f "$SYSCTL_FILE" && ! -f "$ORIGINAL_SYSCTL" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL"
    # IPv6 is deliberately and explicitly disabled: this gateway is IPv4-only
    # by design, not "IPv6 accidentally left half-configured".
    # ip_nonlocal_bind is intentionally NOT set here: Zashboard and Mihomo
    # both run in network_mode: host and bind 0.0.0.0, so no service needs to
    # bind an address that might not exist yet — access is controlled purely
    # by nftables, not by which address a container can bind.
    cat > "$SYSCTL_FILE" <<'EOF2'
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF2
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || { error "Не удалось включить forwarding."; return 1; }
    success "IPv4 forwarding → active"
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == 1 ]]; then
        success "IPv6 → отключён"
    else
        warn "Не удалось отключить IPv6 через sysctl."
    fi
}

# ──────────────────────────────── docker ─────────────────────────────
remove_docker_list_duplicate(){
    if [[ -f /etc/apt/sources.list.d/docker.list && -f /etc/apt/sources.list.d/docker.sources ]]; then
        rm -f /etc/apt/sources.list.d/docker.list
        success "Дубликат Docker repository удалён."
    fi
}

configure_docker_repo(){
    remove_docker_list_duplicate
    apt_install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        run_timed "Загрузка ключа Docker" \
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    local arch codename
    arch=$(dpkg --print-architecture)
    codename="$(get_os_release_value VERSION_CODENAME)"
    [[ -n "$codename" ]] || { error "Не удалось определить VERSION_CODENAME."; return 1; }
    cat > /etc/apt/sources.list.d/docker.sources <<EOF2
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF2
    apt_update_safe
}

install_docker(){
    header "УСТАНОВКА · DOCKER ENGINE + COMPOSE"
    if pkg_installed docker-ce && systemctl cat docker.service >/dev/null 2>&1; then
        success "Docker Engine уже установлен."
        remove_docker_list_duplicate
    else
        info "Docker Engine отсутствует или установлен не полностью."
        configure_docker_repo
        run_timed "Установка Docker Engine + Compose" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl daemon-reload
    systemctl enable --now docker.service >/dev/null
    systemctl is-active --quiet docker.service || {
        systemctl status docker.service --no-pager -l >&2 || true
        error "Docker не запустился."; return 1
    }
    command -v docker >/dev/null 2>&1        || { error "docker недоступен."; return 1; }
    docker compose version >/dev/null 2>&1   || { error "docker compose недоступен."; return 1; }
    docker info >/dev/null 2>&1              || { error "docker info не отвечает."; return 1; }
    success "Docker Engine → active"
    success "Docker Compose → OK"
    configure_docker_daemon || return 1
}

# Docker never manages iptables/nftables: nftables (write_nft_structural) is
# the single owner of ALL filtering/NAT. This matters because Mihomo and
# Zashboard both run in network_mode: host — there is no Docker bridge
# network left for Docker's own DOCKER/DOCKER-ISOLATION chains to apply to,
# and disabling them at the daemon level makes that a guarantee rather than
# an accident of today's container config. live-restore keeps already-
# running containers alive across a daemon restart — required here because
# THIS restart is the one that turns iptables management off; without it,
# an already-running Mihomo container would be stopped and restarted by the
# daemon restart itself (a one-time, few-second blip on upgrade — harmless
# on a fresh install where no containers exist yet).
configure_docker_daemon(){
    header "УСТАНОВКА · DOCKER · СЕТЕВАЯ МОДЕЛЬ"
    mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
    if [[ -f "$DOCKER_DAEMON_JSON" && ! -f "$ORIGINAL_DOCKER_DAEMON" ]]; then
        mkdir -p "$ORIGINAL_DIR"; chmod 700 "$ORIGINAL_DIR"
        cp -a "$DOCKER_DAEMON_JSON" "$ORIGINAL_DOCKER_DAEMON"
    fi
    cat > "$DOCKER_DAEMON_JSON" <<'EOF2'
{
    "iptables": false,
    "ip6tables": false,
    "live-restore": true
}
EOF2
    chmod 644 "$DOCKER_DAEMON_JSON"

    if systemctl is-active --quiet docker 2>/dev/null; then
        warn "Docker daemon перезапускается для применения новой сетевой модели."
        warn "Если контейнеры уже были запущены без live-restore — они перезапустятся один раз (несколько секунд)."
        run_timed "Перезапуск Docker daemon" systemctl restart docker || {
            error "Не удалось перезапустить Docker daemon с новой конфигурацией."
            return 1
        }
    else
        systemctl daemon-reload
    fi
    systemctl is-active --quiet docker 2>/dev/null \
        && success "Docker daemon: iptables отключён, live-restore включён." \
        || { error "Docker daemon не запустился после изменения конфигурации."; return 1; }

    # One-time cleanup: "iptables": false stops Docker from managing these
    # going forward, but restarting the daemon does NOT retroactively tear
    # down chains a PREVIOUS (iptables: true) daemon run already created —
    # they're left behind as orphaned, inert-but-still-registered netfilter
    # hooks. Safe to remove: identified specifically by their DOCKER/
    # DOCKER-* chain names, and nftables (table inet gateway) is now this
    # box's sole firewall/NAT owner.
    local fam name pair
    for pair in "ip nat" "ip filter" "ip6 nat" "ip6 filter"; do
        read -r fam name <<<"$pair"
        if nft list table "$fam" "$name" 2>/dev/null | grep -q 'chain DOCKER '; then
            nft delete table "$fam" "$name" 2>/dev/null \
                && info "Удалена устаревшая таблица Docker: ${fam} ${name}"
        fi
    done
}

compose(){ ( cd "$PROJECT_DIR" && docker compose "$@" ); }

# ──────────────────────────────── mihomo ─────────────────────────────
random_secret(){
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    fi
}

prompt_secret(){
    header "ПАРОЛЬ MIHOMO API"
    echo "Допустимы: A-Z a-z 0-9 @ . _ -   (минимум 8 символов)"
    echo "Пустой ввод — сгенерировать случайный пароль."
    echo
    local a b
    while true; do
        read -rsp "Введите пароль API: " a; echo
        if [[ -z "$a" ]]; then
            a=$(random_secret)
            echo -e "Сгенерирован пароль: ${BOLD}${a}${NC}"
            confirm "Использовать его?" || continue
            CLASH_SECRET="$a"; break
        fi
        read -rsp "Повторите пароль: " b; echo
        [[ "$a" == "$b" ]]                  || { warn "Пароли не совпадают."; continue; }
        (( ${#a} >= 8 ))                    || { warn "Минимум 8 символов."; continue; }
        [[ "$a" =~ ^[A-Za-z0-9@._-]+$ ]]    || { warn "Допустимы только A-Z a-z 0-9 @ . _ -"; continue; }
        CLASH_SECRET="$a"; break
    done
    write_config
    success "Пароль Mihomo API сохранён."
}

prompt_subscription_install(){
    header "ПОДПИСКА MIHOMO"
    if [[ -n "$SUBSCRIPTION_URL" && -f "$MIHOMO_CONFIG" ]]; then
        echo "Найдена существующая подписка: ${SUBSCRIPTION_URL:0:60}..."
        echo "  1) Использовать существующую"
        echo "  2) Ввести новую"
        echo
        local c; read -rp "Выбор [1-2]: " c || c=1
        [[ "$c" != 2 ]] && { success "Существующая подписка сохранена."; return 0; }
    fi
    local url
    while true; do
        read -rp "Ссылка на подписку: " url || return 1
        [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || { warn "Нужна корректная ссылка http:// или https://"; continue; }
        if curl -fsSL --max-time 10 -o /dev/null "$url"; then
            SUBSCRIPTION_URL="$url"; success "Ссылка доступна."; break
        fi
        warn "Ссылка не прошла проверку."
        if confirm "Использовать её всё равно?"; then SUBSCRIPTION_URL="$url"; break; fi
    done
    write_config
}

fetch_template(){
    if [[ -f "$MIHOMO_TEMPLATE_LOCAL" ]]; then
        printf '%s' "$MIHOMO_TEMPLATE_LOCAL"
        return 0
    fi
    # Supports both a cloned repository and a single-file curl install.
    info "Шаблон Mihomo не найден локально. Загружаю из GitHub..."
    TEMPLATE_CACHE=$(mktemp /tmp/mgw-template.XXXXXX.yaml)
    if ! run_timed "Загрузка шаблона Mihomo" \
        curl -fsSL --max-time 20 -o "$TEMPLATE_CACHE" "$MIHOMO_TEMPLATE_URL"; then
        error "Не удалось загрузить mihomo/config.yaml."
        error "Для запуска из клонированного репозитория файл должен быть здесь: $MIHOMO_TEMPLATE_LOCAL"
        rm -f "$TEMPLATE_CACHE"; TEMPLATE_CACHE=""
        return 1
    fi
    printf '%s' "$TEMPLATE_CACHE"
}

render_mihomo_config(){
    [[ -n "$CLASH_SECRET" ]]     || { error "Не задан пароль Mihomo API."; return 1; }
    [[ -n "$SUBSCRIPTION_URL" ]] || { error "Не задана подписка."; return 1; }

    local template marker tmp
    template=$(fetch_template) || return 1

    for marker in __LAN_IP__ __LAN_NETWORK__ __CLASH_SECRET__ __SUBSCRIPTION_URL__; do
        grep -Fq "$marker" "$template" || {
            error "В шаблоне Mihomo отсутствует обязательный placeholder: ${marker}"
            return 1
        }
    done

    mkdir -p "$MIHOMO_CONFIG_DIR/ruleset" "$MIHOMO_CONFIG_DIR/proxy_providers"

    # Escaped for sed with '|' as delimiter: handles &, \, |, slashes and URL chars.
    local lan_network esc_ip esc_net esc_secret esc_url
    lan_network="$(subnet_of "$LAN_IP").0/24"
    esc_ip=$(printf '%s' "$LAN_IP"           | sed 's/[\\&|]/\\&/g')
    esc_net=$(printf '%s' "$lan_network"     | sed 's/[\\&|]/\\&/g')
    esc_secret=$(printf '%s' "$CLASH_SECRET" | sed 's/[\\&|]/\\&/g')
    esc_url=$(printf '%s' "$SUBSCRIPTION_URL"| sed 's/[\\&|]/\\&/g')

    # Render to a temp file first so a failure never leaves a broken config.
    tmp=$(mktemp "${MIHOMO_CONFIG_DIR}/.config.yaml.XXXXXX")
    sed -e "s|__LAN_IP__|${esc_ip}|g" \
        -e "s|__LAN_NETWORK__|${esc_net}|g" \
        -e "s|__CLASH_SECRET__|${esc_secret}|g" \
        -e "s|__SUBSCRIPTION_URL__|${esc_url}|g" \
        "$template" > "$tmp" || { rm -f "$tmp"; error "Ошибка генерации config.yaml"; return 1; }

    if grep -Eq '__[A-Z0-9_]+__' "$tmp"; then
        rm -f "$tmp"
        error "В сгенерированном config.yaml остались незаменённые placeholders."
        return 1
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$MIHOMO_CONFIG"
    cleanup
    success "Конфигурация Mihomo сгенерирована."
}

create_env(){
    mkdir -p "$PROJECT_DIR"
    local tz="Europe/Moscow"
    if [[ -f "$ENV_FILE" ]] && grep -q '^TZ=' "$ENV_FILE"; then
        tz=$(sed -n 's/^TZ=//p' "$ENV_FILE" | head -n1)
    elif command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "$tz")
    fi
    # LAN_IP must live here: compose interpolates it for the zashboard port binding.
    cat > "$ENV_FILE" <<EOF2
TZ=${tz:-Europe/Moscow}
LAN_IP=${LAN_IP}
MIHOMO_IMAGE=${MIHOMO_IMAGE}
ZASHBOARD_IMAGE=${ZASHBOARD_IMAGE}
EOF2
    chmod 600 "$ENV_FILE"
}

create_compose(){
    mkdir -p "$PROJECT_DIR"
    cat > "$COMPOSE_FILE" <<'EOF2'
services:
  mihomo:
    image: ${MIHOMO_IMAGE}
    container_name: mihomo
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./config:/root/.config/mihomo
    environment:
      TZ: ${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  zashboard:
    image: ${ZASHBOARD_IMAGE}
    container_name: zashboard
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: ${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF2
    success "Создан compose.yaml"
}

validate_config(){
    header "ПРОВЕРКА · MIHOMO"
    run_timed "Проверка конфигурации Mihomo" \
        docker run --rm --network host --cap-add NET_ADMIN \
        --device /dev/net/tun:/dev/net/tun \
        -v "${MIHOMO_CONFIG_DIR}:/root/.config/mihomo" \
        "$MIHOMO_IMAGE" -d /root/.config/mihomo -t
}

# ═══════════════════════════════ PPPoE ═══════════════════════════════
# WAN has two modes and only ever one netplan file:
#   dhcp  — wan: dhcp4: true                      (existing behaviour)
#   pppoe — wan: link only, no address; the session is owned by pppd via
#           mihomo-gateway-pppoe.service, ppp0 carries the default route.
# Mode switches rewrite ONLY the wan stanza and are applied with
# `networkctl reconfigure wan`, never `netplan apply`, so lan/SSH is untouched.

wan_out_iface(){ [[ "${WAN_MODE:-dhcp}" == pppoe ]] && echo "$PPPOE_IFACE" || echo "wan"; }
mask_secret(){
    local s="${1:-}"
    [[ -z "$s" ]] && { echo "—"; return 0; }
    (( ${#s} <= 2 )) && { echo "***"; return 0; }
    printf '%s***%s\n' "${s:0:2}" "${s: -1}"
}

iface_ipv4(){ ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
default_gw_via(){ ip -4 route show default 2>/dev/null | awk -v d="$1" '$0 ~ ("dev "d)  {print $3; exit}'; }
default_dev(){ ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

internet_ok(){
    ping -c1 -W2 -n 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c1 -W2 -n 8.8.8.8 >/dev/null 2>&1 && return 0
    curl -fsS --max-time 4 -o /dev/null http://connectivitycheck.gstatic.com/generate_204 2>/dev/null
}

pppoe_service_active(){ systemctl is-active --quiet "$PPPOE_SERVICE" 2>/dev/null; }

# Real network state, deliberately independent of the systemd unit state.
pppoe_link_ok(){
    ip link show "$PPPOE_IFACE" >/dev/null 2>&1 || return 1
    [[ -n "$(iface_ipv4 "$PPPOE_IFACE")" ]]     || return 1
    ip -4 route show default 2>/dev/null | grep -q "dev ${PPPOE_IFACE}" || return 1
    return 0
}
pppoe_session_ok(){ pppoe_link_ok && internet_ok; }

wan_link_ok(){
    [[ -n "$(iface_ipv4 wan)" ]] || return 1
    ip -4 route show default 2>/dev/null | grep -q "dev wan" || return 1
    return 0
}

# ── пакеты ───────────────────────────────────────────────────────────
pppoe_install_packages(){
    header "PPPoE · УСТАНОВКА ПАКЕТОВ"
    info "Пакеты ставятся, пока WAN ещё работает по DHCP."
    mkdir -p "$PPPOE_STATE_DIR"; chmod 700 "$PPPOE_STATE_DIR"

    local p newly=()
    for p in ppp pppoe; do
        pkg_installed "$p" || newly+=("$p")
    done

    if ! pkg_installed ppp; then
        apt_install ppp || { error "Не удалось установить пакет ppp."; return 1; }
    fi
    # pppoe(8) is optional: the rp-pppoe.so plugin ships with ppp itself.
    if ! pkg_installed pppoe; then
        apt_install pppoe || warn "Пакет pppoe не установлен — используется плагин rp-pppoe.so из ppp."
    fi

    # Remember only what WE installed, so full removal never purges
    # packages that were present before the gateway.
    for p in "${newly[@]}"; do
        pkg_installed "$p" && ! grep -qx "$p" "$PPPOE_PKG_FILE" 2>/dev/null && echo "$p" >> "$PPPOE_PKG_FILE"
    done
    [[ -f "$PPPOE_PKG_FILE" ]] && chmod 600 "$PPPOE_PKG_FILE"

    command -v pppd >/dev/null 2>&1 || { error "pppd не найден после установки."; return 1; }
    local plugin
    plugin=$(find /usr/lib/pppd -name 'rp-pppoe.so' 2>/dev/null | head -n1)
    [[ -n "$plugin" ]] || { error "Плагин rp-pppoe.so не найден. PPPoE недоступен."; return 1; }
    success "pppd и плагин rp-pppoe.so готовы."
}

# ── учётные данные ───────────────────────────────────────────────────
# The password is never stored in gateway.env, never passed as an argv
# argument and never printed: it goes straight into the 0600 secrets files.
pppoe_prompt_credentials(){
    header "PPPoE · УЧЁТНЫЕ ДАННЫЕ ПРОВАЙДЕРА"
    local u p1 p2
    while true; do
        read -rp "Логин PPPoE${PPPOE_USER:+ [$(mask_secret "$PPPOE_USER")]}: " u || return 1
        [[ -z "$u" && -n "$PPPOE_USER" ]] && u="$PPPOE_USER"
        [[ -n "$u" ]] || { warn "Логин не может быть пустым."; continue; }
        [[ "$u" != *'"'* && "$u" != *'\'* ]] || { warn "Символы \" и \\ недопустимы."; continue; }
        break
    done
    while true; do
        read -rsp "Пароль PPPoE: " p1; echo
        [[ -n "$p1" ]] || { warn "Пароль не может быть пустым."; continue; }
        [[ "$p1" != *'"'* && "$p1" != *'\'* ]] || { warn "Символы \" и \\ недопустимы."; continue; }
        read -rsp "Повторите пароль: " p2; echo
        [[ "$p1" == "$p2" ]] || { warn "Пароли не совпадают."; continue; }
        break
    done
    PPPOE_USER="$u"
    pppoe_write_secrets "$u" "$p1" || return 1
    unset p1 p2
    write_config
    success "Учётные данные сохранены (файлы 0600, доступны только root)."
}

pppoe_write_secrets(){
    local user="$1" pass="$2" f tmp base
    for f in "$PAP_SECRETS" "$CHAP_SECRETS"; do
        [[ -f "$f" ]] || { install -m 600 /dev/null "$f"; }
        base=$(basename "$f")
        [[ -f "${ORIGINAL_DIR}/${base}" ]] || cp -a "$f" "${ORIGINAL_DIR}/${base}" 2>/dev/null || true
        tmp=$(mktemp); chmod 600 "$tmp"
        sed "/^${SECRETS_BEGIN}\$/,/^${SECRETS_END}\$/d" "$f" > "$tmp" 2>/dev/null || true
        {
            echo "$SECRETS_BEGIN"
            printf '"%s" * "%s" *\n' "$user" "$pass"
            echo "$SECRETS_END"
        } >> "$tmp"
        cat "$tmp" > "$f"
        rm -f "$tmp"
        chmod 600 "$f"; chown root:root "$f" 2>/dev/null || true
    done
    return 0
}

pppoe_have_credentials(){
    [[ -n "${PPPOE_USER:-}" ]] || return 1
    grep -q "^${SECRETS_BEGIN}$" "$PAP_SECRETS" 2>/dev/null || return 1
    return 0
}

pppoe_write_peer(){
    mkdir -p /etc/ppp/peers
    cat > "$PPPOE_PEER_FILE" <<EOF2
# mihomo-gateway PPPoE peer — генерируется автоматически
plugin rp-pppoe.so
wan
user "${PPPOE_USER}"
ifname ${PPPOE_IFACE}
linkname ${PPPOE_PEER_NAME}
noipdefault
defaultroute
replacedefaultroute
noauth
hide-password
persist
maxfail 0
holdoff 5
lcp-echo-interval 20
lcp-echo-failure 3
mtu 1492
mru 1492
noaccomp
nodeflate
nobsdcomp
EOF2
    chmod 600 "$PPPOE_PEER_FILE"
}

pppoe_write_units(){
    cat > "${PPPOE_UNIT_DIR}/${PPPOE_SERVICE}" <<EOF2
[Unit]
Description=Mihomo Gateway PPPoE link (WAN)
Documentation=man:pppd(8)
After=network.target sys-subsystem-net-devices-wan.device
BindsTo=sys-subsystem-net-devices-wan.device

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call ${PPPOE_PEER_NAME} nodetach
ExecStopPost=-/usr/bin/env true
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF2
    chmod 644 "${PPPOE_UNIT_DIR}/${PPPOE_SERVICE}"
    pppoe_write_watchdog
    systemctl daemon-reload
}

# ── watchdog (только при включённом авто-откате) ─────────────────────
pppoe_write_watchdog(){
    mkdir -p "$PPPOE_HELPER_DIR"
    cat > "${PPPOE_HELPER_DIR}/pppoe-watchdog.sh" <<EOF2
#!/usr/bin/env bash
# mihomo-gateway PPPoE watchdog — генерируется автоматически.
# Откатывает WAN на DHCP только если пользователь включил авто-откат
# И сессия PPPoE не поднимается подряд N проверок.
set -uo pipefail
CONFIG_FILE="${CONFIG_FILE}"
FAIL_FILE="${PPPOE_FAIL_FILE}"
NETPLAN_FILE="${NETPLAN_FILE}"
NETPLAN_DHCP_SAVE="${NETPLAN_DHCP_SAVE}"
PPPOE_IFACE="${PPPOE_IFACE}"
PPPOE_SERVICE="${PPPOE_SERVICE}"
WATCHDOG_TIMER="${PPPOE_WATCHDOG}.timer"
EOF2
    cat >> "${PPPOE_HELPER_DIR}/pppoe-watchdog.sh" <<'EOF2'

cfg(){ sed -n "s/^$1='\(.*\)'\$/\1/p" "$CONFIG_FILE" 2>/dev/null | tail -n1; }

[[ -f "$CONFIG_FILE" ]] || exit 0
[[ "$(cfg WAN_MODE)" == pppoe ]] || exit 0
[[ "$(cfg PPPOE_AUTO_ROLLBACK)" == 1 ]] || exit 0

threshold=$(cfg PPPOE_FAIL_THRESHOLD); [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=5
(( threshold >= 1 )) || threshold=5

session_ok(){
    ip link show "$PPPOE_IFACE" >/dev/null 2>&1 || return 1
    ip -4 -o addr show "$PPPOE_IFACE" 2>/dev/null | grep -q inet || return 1
    ip -4 route show default 2>/dev/null | grep -q "dev ${PPPOE_IFACE}" || return 1
    ping -c1 -W2 -n 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 -n 8.8.8.8 >/dev/null 2>&1
}

if session_ok; then
    echo 0 > "$FAIL_FILE"
    exit 0
fi

n=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
[[ "$n" =~ ^[0-9]+$ ]] || n=0
n=$((n + 1))
echo "$n" > "$FAIL_FILE"
logger -t mihomo-gateway-pppoe "PPPoE session down (${n}/${threshold})"
(( n >= threshold )) || exit 0

logger -t mihomo-gateway-pppoe "PPPoE failed ${n} times — rolling back WAN to DHCP"
systemctl stop "$PPPOE_SERVICE" 2>/dev/null || true
systemctl disable "$PPPOE_SERVICE" 2>/dev/null || true

if [[ -f "$NETPLAN_DHCP_SAVE" ]]; then
    cp -a "$NETPLAN_DHCP_SAVE" "$NETPLAN_FILE"
    netplan generate 2>/dev/null || true
    # Only the WAN link is reconfigured: LAN and SSH stay up.
    networkctl reload >/dev/null 2>&1 || true
    networkctl reconfigure wan >/dev/null 2>&1 || true
fi
sed -i "s/^WAN_MODE=.*/WAN_MODE='dhcp'/" "$CONFIG_FILE" 2>/dev/null || true
echo 0 > "$FAIL_FILE"
systemctl disable --now "$WATCHDOG_TIMER" 2>/dev/null || true
logger -t mihomo-gateway-pppoe "Rollback to DHCP finished"
EOF2
    chmod 700 "${PPPOE_HELPER_DIR}/pppoe-watchdog.sh"

    cat > "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.service" <<EOF2
[Unit]
Description=Mihomo Gateway PPPoE watchdog

[Service]
Type=oneshot
ExecStart=${PPPOE_HELPER_DIR}/pppoe-watchdog.sh
EOF2
    cat > "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.timer" <<EOF2
[Unit]
Description=Mihomo Gateway PPPoE watchdog timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF2
    chmod 644 "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.service" "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.timer"
}

pppoe_sync_watchdog(){
    systemctl daemon-reload
    mkdir -p "$PPPOE_STATE_DIR"; echo 0 > "$PPPOE_FAIL_FILE"
    if [[ "${PPPOE_AUTO_ROLLBACK:-0}" == 1 && "${WAN_MODE:-dhcp}" == pppoe ]]; then
        systemctl enable --now "${PPPOE_WATCHDOG}.timer" >/dev/null 2>&1 \
            && success "Авто-откат включён (порог: ${PPPOE_FAIL_THRESHOLD} проверок)." \
            || warn "Не удалось включить таймер авто-отката."
    else
        systemctl disable --now "${PPPOE_WATCHDOG}.timer" >/dev/null 2>&1 || true
    fi
}

# ── переключение режима WAN (LAN не трогаем) ─────────────────────────
save_wan_rollback(){
    mkdir -p "$NETPLAN_SAVE_DIR"; chmod 700 "$NETPLAN_SAVE_DIR"
    case "${1:-}" in
        dhcp)  cp -a "$NETPLAN_FILE" "$NETPLAN_DHCP_SAVE" ;;
        pppoe) cp -a "$NETPLAN_FILE" "$NETPLAN_PPPOE_SAVE" ;;
    esac
}

# Reconfigures the wan link only. `netplan apply` would restart networkd
# and can blip LAN/SSH, so it is the fallback of last resort.
apply_wan_only(){
    netplan generate || { error "netplan generate: ошибка конфигурации."; return 1; }
    if command -v networkctl >/dev/null 2>&1; then
        networkctl reload >/dev/null 2>&1 || true
        networkctl reconfigure wan >/dev/null 2>&1 || warn "networkctl reconfigure wan вернул ошибку."
    else
        warn "networkctl недоступен — применяю netplan apply (LAN может моргнуть)."
        netplan apply || return 1
    fi
    sleep 2
    return 0
}

# Writes the netplan for the requested WAN mode and applies it to wan only.
switch_wan_mode(){
    local mode="$1" prev="${WAN_MODE:-dhcp}"
    WAN_MODE="$mode"
    if ! write_netplan; then
        WAN_MODE="$prev"; write_netplan || true
        error "Не удалось сгенерировать Netplan для режима ${mode}."
        return 1
    fi
    save_wan_rollback "$mode"
    if ! apply_wan_only; then
        error "Не удалось применить сетевую конфигурацию WAN."
        return 1
    fi
    if [[ "$mode" == pppoe ]]; then
        # The DHCP lease must not linger on wan while pppd owns the link.
        ip -4 addr flush dev wan 2>/dev/null || true
    fi
    # Atomic set update — never a firewall reload. Safe even if nftables
    # isn't loaded yet: write_nft_structural() re-derives wan_if from
    # wan_out_iface() independently the next time it runs.
    nft_set_wan_if "$(wan_out_iface)" 2>/dev/null || true
    return 0
}

wait_for_dhcp_wan(){
    local i
    for i in $(seq 1 20); do
        wan_link_ok && return 0
        sleep 1
    done
    return 1
}

# ── подключение и откат ──────────────────────────────────────────────
pppoe_try_connect(){
    local attempts="${1:-10}" i j
    systemctl enable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    for (( i = 1; i <= attempts; i++ )); do
        info "Попытка подключения PPPoE ${i}/${attempts}..."
        systemctl restart "$PPPOE_SERVICE" >/dev/null 2>&1 || warn "Служба PPPoE не стартовала."
        for (( j = 0; j < 15; j++ )); do
            sleep 2
            pppoe_link_ok || continue
            if internet_ok; then
                success "PPPoE подключён: ${PPPOE_IFACE} $(iface_ipv4 "$PPPOE_IFACE")"
                return 0
            fi
        done
        if pppoe_link_ok; then
            warn "Сессия поднялась, но интернета нет (попытка ${i})."
        else
            warn "Сессия PPPoE не установлена (попытка ${i})."
        fi
        systemctl stop "$PPPOE_SERVICE" >/dev/null 2>&1 || true
        sleep 2
    done
    error "PPPoE не подключился за ${attempts} попыток."
    journalctl -u "$PPPOE_SERVICE" -n 20 --no-pager 2>/dev/null >&2 || true
    return 1
}

pppoe_rollback_to_dhcp(){
    header "PPPoE · АВТОМАТИЧЕСКИЙ ОТКАТ НА DHCP"
    systemctl stop "$PPPOE_SERVICE"    >/dev/null 2>&1 || true
    systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "${PPPOE_WATCHDOG}.timer" >/dev/null 2>&1 || true

    if [[ -f "$NETPLAN_DHCP_SAVE" ]]; then
        cp -a "$NETPLAN_DHCP_SAVE" "$NETPLAN_FILE"
        info "Восстановлен сохранённый рабочий Netplan (DHCP)."
    fi
    WAN_MODE="dhcp"
    write_netplan || warn "Не удалось перегенерировать Netplan, использую сохранённую копию."
    if ! apply_wan_only; then
        error "Откат: не удалось применить конфигурацию WAN."
        error "LAN не затронут. Проверьте: networkctl status wan"
        write_config
        return 1
    fi
    write_config
    write_nft_structural || warn "Не удалось обновить файл nftables."

    if wait_for_dhcp_wan; then
        success "WAN снова работает по DHCP: $(iface_ipv4 wan)"
        internet_ok && success "Интернет доступен." || warn "Адрес получен, но интернет не отвечает."
        return 0
    fi
    error "Откат выполнен, но WAN не получил адрес по DHCP."
    error "Проверьте кабель провайдера и: networkctl status wan"
    return 1
}

# ── главный сценарий включения PPPoE ─────────────────────────────────
pppoe_enable(){
    header "PPPoE · ВКЛЮЧЕНИЕ"
    [[ -n "${WAN_MAC:-}" ]] || { error "WAN-интерфейс не настроен."; return 1; }

    if [[ "${WAN_MODE:-dhcp}" == pppoe ]] && pppoe_link_ok; then
        success "PPPoE уже активен."
        return 0
    fi

    echo "Порядок действий:"
    echo "  1. Проверка текущего интернета через DHCP"
    echo "  2. Установка пакетов PPPoE (нужен работающий интернет)"
    echo "  3. Ввод учётных данных и подготовка конфигурации"
    echo "  4. Сохранение рабочего DHCP-Netplan для отката"
    echo "  5. Переключение WAN на PPPoE и до ${PPPOE_ATTEMPTS} попыток подключения"
    echo "  6. При неудаче — автоматический откат на DHCP"
    echo
    echo "LAN и SSH остаются доступными на всех шагах."
    echo
    confirm "Продолжить?" || return 0

    # 1. Internet over DHCP is needed for step 2.
    header "PPPoE · ШАГ 1/6 · ПРОВЕРКА ИНТЕРНЕТА (DHCP)"
    if internet_ok; then
        success "Интернет через DHCP доступен: $(iface_ipv4 wan)"
    else
        warn "Интернет через текущее WAN-подключение недоступен."
        warn "Пакеты PPPoE можно установить только при работающем интернете."
        if ! pkg_installed ppp; then
            error "Пакет ppp не установлен, а интернета нет. Включение PPPoE отменено."
            return 1
        fi
        confirm "Пакет ppp уже установлен. Продолжить без проверки интернета?" || return 0
    fi

    # 2. Packages first — never switch the WAN before this succeeds.
    header "PPPoE · ШАГ 2/6 · ПАКЕТЫ"
    pppoe_install_packages || return 1

    # 3. Credentials and configuration.
    header "PPPoE · ШАГ 3/6 · КОНФИГУРАЦИЯ"
    if pppoe_have_credentials; then
        info "Найдены сохранённые учётные данные (логин: $(mask_secret "$PPPOE_USER"))."
        confirm "Ввести новые?" && { pppoe_prompt_credentials || return 1; }
    else
        pppoe_prompt_credentials || return 1
    fi
    pppoe_write_peer
    pppoe_write_units
    success "Конфигурация pppd и служба созданы."

    # 4. Known-good DHCP netplan kept as the rollback target.
    header "PPPoE · ШАГ 4/6 · ТОЧКА ОТКАТА"
    local prev_mode="${WAN_MODE:-dhcp}"
    WAN_MODE="dhcp"; write_netplan || return 1
    save_wan_rollback dhcp
    WAN_MODE="$prev_mode"
    success "Рабочая DHCP-конфигурация сохранена: ${NETPLAN_DHCP_SAVE}"

    # 5. Switch WAN and connect.
    header "PPPoE · ШАГ 5/6 · ПЕРЕКЛЮЧЕНИЕ WAN"
    if ! switch_wan_mode pppoe; then
        error "Переключение не удалось — возвращаю DHCP."
        pppoe_rollback_to_dhcp || true
        return 1
    fi
    success "WAN переведён в режим PPPoE (LAN не затронут)."
    write_nft_structural || warn "Не удалось обновить файл nftables."

    header "PPPoE · ШАГ 6/6 · ПОДКЛЮЧЕНИЕ"
    if pppoe_try_connect "${PPPOE_ATTEMPTS:-10}"; then
        PPPOE_INITIALIZED=1
        WAN_MODE="pppoe"
        write_config
        save_wan_rollback pppoe
        write_nft_structural || warn "Не удалось обновить файл nftables."
        pppoe_sync_watchdog
        echo
        success "PPPoE успешно инициализирован."
        success "WAN IP: $(iface_ipv4 "$PPPOE_IFACE")  шлюз: $(default_gw_via "$PPPOE_IFACE")"
        info "Временные сбои провайдера больше не приводят к откату на DHCP."
        return 0
    fi

    # 6. All attempts failed → automatic, complete rollback.
    error "Первое подключение PPPoE не удалось (${PPPOE_ATTEMPTS} попыток)."
    error "Возможные причины: неверный логин/пароль, нет линка до провайдера, другой VLAN."
    PPPOE_INITIALIZED=0
    if pppoe_rollback_to_dhcp; then
        warn "Система откачена на DHCP и работает. PPPoE выключен."
    else
        error "Откат завершился с ошибкой — проверьте WAN вручную."
    fi
    return 1
}

pppoe_disable(){
    header "PPPoE · ВОЗВРАТ WAN НА DHCP"
    [[ "${WAN_MODE:-dhcp}" == pppoe ]] || { info "WAN уже в режиме DHCP."; return 0; }
    confirm "Вернуть WAN на DHCP? LAN и SSH не пострадают." || return 0

    systemctl stop "$PPPOE_SERVICE"    >/dev/null 2>&1 || true
    systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "${PPPOE_WATCHDOG}.timer" >/dev/null 2>&1 || true

    if ! switch_wan_mode dhcp; then
        error "Не удалось переключить WAN на DHCP."
        return 1
    fi
    write_config
    write_nft_structural || warn "Не удалось обновить файл nftables."

    if wait_for_dhcp_wan; then
        success "WAN работает по DHCP: $(iface_ipv4 wan)"
        internet_ok && success "Интернет доступен." || warn "Интернет пока не отвечает."
    else
        warn "WAN не получил адрес по DHCP. Проверьте кабель провайдера."
    fi
    info "Конфигурация и учётные данные PPPoE сохранены — можно включить снова."
}

# ── статус / диагностика ─────────────────────────────────────────────
# ${v:+x}${v:-y} would print the value twice when v is set — use this instead.
value_row(){
    local label="$1" v="${2:-}"
    if [[ -n "$v" ]]; then printf '  %s %b\n' "$(pad "$label" 14)" "${GREEN}● ${v}${NC}"
    else                   printf '  %s %b\n' "$(pad "$label" 14)" "${RED}● —${NC}"; fi
}

pppoe_status_block(){
    local ip gw
    echo -e "${BOLD}WAN${NC}"
    if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
        ip=$(iface_ipv4 "$PPPOE_IFACE"); gw=$(default_gw_via "$PPPOE_IFACE")
        printf '  %s %b\n' "$(pad "Режим WAN" 14)"     "${CYAN}● PPPoE${NC}"
        printf '  %s %b\n' "$(pad "Логин" 14)"         "${DIM}● $(mask_secret "${PPPOE_USER:-}")${NC}"
        if pppoe_service_active; then
            printf '  %s %b\n' "$(pad "Служба PPPoE" 14)" "${GREEN}● ACTIVE${NC}"
        else
            printf '  %s %b\n' "$(pad "Служба PPPoE" 14)" "${RED}● INACTIVE${NC}"
        fi
        if pppoe_link_ok; then
            printf '  %s %b\n' "$(pad "Сессия PPPoE" 14)" "${GREEN}● CONNECTED${NC}"
        else
            printf '  %s %b\n' "$(pad "Сессия PPPoE" 14)" "${RED}● DOWN${NC}"
        fi
        value_row "WAN IP" "$ip"
        value_row "Шлюз"   "$gw"
        internet_ok && printf '  %s %b\n' "$(pad "Интернет" 14)" "${GREEN}● OK${NC}" \
                    || printf '  %s %b\n' "$(pad "Интернет" 14)" "${RED}● FAIL${NC}"
        if [[ "${PPPOE_AUTO_ROLLBACK:-0}" == 1 ]]; then
            printf '  %s %b\n' "$(pad "Авто-откат" 14)" "${YELLOW}● ON (порог ${PPPOE_FAIL_THRESHOLD})${NC}"
        else
            printf '  %s %b\n' "$(pad "Авто-откат" 14)" "${DIM}● OFF${NC}"
        fi
        if [[ "${PPPOE_INITIALIZED:-0}" == 1 ]]; then
            printf '  %s %b\n' "$(pad "Инициализация" 14)" "${GREEN}● YES${NC}"
        else
            printf '  %s %b\n' "$(pad "Инициализация" 14)" "${YELLOW}● NO${NC}"
        fi
    else
        ip=$(iface_ipv4 wan); gw=$(default_gw_via wan)
        printf '  %s %b\n' "$(pad "Режим WAN" 14)" "${CYAN}● DHCP${NC}"
        value_row "WAN IP" "$ip"
        value_row "Шлюз"   "$gw"
        internet_ok && printf '  %s %b\n' "$(pad "Интернет" 14)" "${GREEN}● OK${NC}" \
                    || printf '  %s %b\n' "$(pad "Интернет" 14)" "${RED}● FAIL${NC}"
    fi
}

# ── меню ─────────────────────────────────────────────────────────────
pppoe_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · PPPoE"
        pppoe_status_block
        echo
        echo "  1) Изменить логин и пароль"
        echo "  2) Авто-откат на DHCP после инициализации"
        echo "  3) Число попыток первого подключения (${PPPOE_ATTEMPTS})"
        echo "  4) Проверить подключение сейчас"
        echo "  0) Назад"
        echo
        local c v
        read -rp "Выбор [0-4]: " c || return 0
        case "$c" in
            1) if pppoe_prompt_credentials; then
                   pppoe_write_peer
                   if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
                       confirm "Переподключить PPPoE с новыми данными?" && {
                           pppoe_try_connect "${PPPOE_ATTEMPTS:-10}" \
                               || warn "Переподключение не удалось. Режим WAN не изменён."
                       }
                   fi
               fi ;;
            2) if [[ "${PPPOE_AUTO_ROLLBACK:-0}" == 1 ]]; then
                   PPPOE_AUTO_ROLLBACK=0; write_config; pppoe_sync_watchdog
                   success "Авто-откат выключен — при сбоях система остаётся на PPPoE."
               else
                   echo
                   warn "Авто-откат вернёт WAN на DHCP, если сессия PPPoE не поднимется"
                   warn "подряд N проверок (проверка раз в минуту)."
                   read -rp "Порог неудачных проверок [${PPPOE_FAIL_THRESHOLD}]: " v || v=""
                   if [[ -n "$v" ]]; then
                       [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 60 )) \
                           && PPPOE_FAIL_THRESHOLD="$v" || { warn "Нужно число 1–60."; press_enter; continue; }
                   fi
                   PPPOE_AUTO_ROLLBACK=1; write_config
                   [[ -f "${PPPOE_HELPER_DIR}/pppoe-watchdog.sh" ]] || pppoe_write_watchdog
                   pppoe_sync_watchdog
               fi ;;
            3) read -rp "Число попыток первого подключения [${PPPOE_ATTEMPTS}]: " v || v=""
               if [[ -n "$v" ]]; then
                   if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 50 )); then
                       PPPOE_ATTEMPTS="$v"; write_config; success "Сохранено: ${PPPOE_ATTEMPTS} попыток."
                   else
                       warn "Нужно число 1–50."
                   fi
               fi ;;
            4) if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
                   pppoe_link_ok && success "Сессия PPPoE активна: $(iface_ipv4 "$PPPOE_IFACE")" \
                                 || error "Сессия PPPoE не установлена."
               else
                   wan_link_ok && success "WAN (DHCP): $(iface_ipv4 wan)" || error "WAN без адреса."
               fi
               internet_ok && success "Интернет доступен." || error "Интернета нет." ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

# ── первичная установка ──────────────────────────────────────────────
maybe_setup_pppoe(){
    header "ТИП ПОДКЛЮЧЕНИЯ WAN"
    if [[ "${WAN_MODE:-dhcp}" == pppoe && "${PPPOE_INITIALIZED:-0}" == 1 ]]; then
        info "WAN уже настроен на PPPoE."
        pppoe_link_ok || { warn "Сессия не поднята — пробую запустить службу."; \
            systemctl restart "$PPPOE_SERVICE" >/dev/null 2>&1 || true; sleep 5; }
        pppoe_link_ok && success "PPPoE активен." || warn "PPPoE пока не подключён."
        return 0
    fi
    echo "  1) DHCP  — провайдер выдаёт адрес автоматически (по умолчанию)"
    echo "  2) PPPoE — провайдер требует логин и пароль"
    echo
    local c; read -rp "Выбор [1-2]: " c || c=1
    case "$c" in
        2) pppoe_enable || warn "PPPoE не активирован, установка продолжается на DHCP." ;;
        *) WAN_MODE="dhcp"; write_config; success "WAN: DHCP." ;;
    esac
    return 0
}

# ── удаление ─────────────────────────────────────────────────────────
# Safe and idempotent: running it twice changes nothing and returns 0.
pppoe_purge(){
    local f p purged=0

    systemctl stop "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "${PPPOE_WATCHDOG}.timer" >/dev/null 2>&1 || true
    systemctl stop "${PPPOE_WATCHDOG}.service" >/dev/null 2>&1 || true

    # Tear the session down before the WAN config is restored.
    if ip link show "$PPPOE_IFACE" >/dev/null 2>&1; then
        pkill -f "pppd call ${PPPOE_PEER_NAME}" 2>/dev/null || true
        sleep 1
        ip link delete "$PPPOE_IFACE" 2>/dev/null || true
    fi

    for f in "${PPPOE_UNIT_DIR}/${PPPOE_SERVICE}" \
             "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.service" \
             "${PPPOE_UNIT_DIR}/${PPPOE_WATCHDOG}.timer" \
             "${PPPOE_HELPER_DIR}/pppoe-watchdog.sh" \
             "$PPPOE_PEER_FILE"; do
        [[ -e "$f" ]] && { rm -f "$f"; purged=1; }
    done
    rmdir "$PPPOE_HELPER_DIR" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # Credentials: only our own delimited block is removed.
    for f in "$PAP_SECRETS" "$CHAP_SECRETS"; do
        [[ -f "$f" ]] || continue
        if grep -q "^${SECRETS_BEGIN}$" "$f" 2>/dev/null; then
            sed -i "/^${SECRETS_BEGIN}\$/,/^${SECRETS_END}\$/d" "$f"
            chmod 600 "$f"; purged=1
        fi
    done

    # Only packages this script installed are purged.
    if [[ -f "$PPPOE_PKG_FILE" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            pkg_installed "$p" || continue
            run_timed "Удаление пакета ${p}" \
                env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" || true
        done < "$PPPOE_PKG_FILE"
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    fi

    rm -rf "$PPPOE_STATE_DIR" "$NETPLAN_SAVE_DIR"
    (( purged )) && success "Компоненты PPPoE удалены." || true
    return 0
}

# ─────────────────────────────── проверки ────────────────────────────
check_api(){
    [[ -n "$CLASH_SECRET" ]] || return 1
    curl -fsS --connect-timeout 1 --max-time 2 \
        -H "Authorization: Bearer ${CLASH_SECRET}" \
        "http://127.0.0.1:9090/version" >/dev/null 2>&1
}
check_ui(){ curl -fsS --connect-timeout 1 --max-time 2 "http://${LAN_IP}/" >/dev/null 2>&1; }
check_tun(){ ip link show Meta >/dev/null 2>&1 || ip link show meta >/dev/null 2>&1; }
check_container(){ [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true)" == running ]]; }

# "Initial setup done" must not depend on steps that run after netplan apply:
# a dropped SSH session used to kill the script before dnsmasq was configured.
network_is_ready(){
    [[ -f "$CONFIG_FILE" ]]  || return 1
    [[ -f "$NETPLAN_FILE" ]] || return 1
    [[ -n "$LAN_MAC" && -n "$WAN_MAC" ]] || return 1
    if [[ ! -f "$NETWORK_MARKER" ]]; then
        # Migration for setups made by earlier versions of this script.
        echo "NETWORK_CONFIGURED=1" > "$NETWORK_MARKER"
    fi
    return 0
}

# The LAN address is expected to exist even without a cable (ignore-carrier).
network_link_ok(){ ip -4 -br addr show lan 2>/dev/null | grep -q "${LAN_IP}/"; }

status_row(){
    local label="$1" state="$2" note="${3:-}"
    local dot
    case "$state" in
        ok)   dot="${GREEN}●${NC} OK   " ;;
        off)  dot="${YELLOW}●${NC} OFF  " ;;
        skip) dot="${DIM}○${NC} —    " ;;
        *)    dot="${RED}●${NC} FAIL " ;;
    esac
    printf '  %s %b %s\n' "$(pad "$label" 13)" "$dot" "$note"
}

# Single status pass; heavy checks are skipped when their prerequisite is down.
quick_status(){
    local docker_ok=0
    if ! network_is_ready; then
        status_row "Сеть" fail
    elif ! network_link_ok; then
        status_row "Сеть" off "LAN-адрес ${LAN_IP} не поднят"
    # ignore-carrier keeps the address configured even with the cable
    # unplugged, so the address check above can't detect that case —
    # check carrier explicitly so "no cable" doesn't look identical to "ok".
    elif ip -br link show lan 2>/dev/null | grep -q 'NO-CARRIER'; then
        status_row "Сеть" off "LAN кабель не подключён"
    else
        status_row "Сеть" ok
    fi
    systemctl is-active --quiet dnsmasq 2>/dev/null && status_row "DHCP" ok || status_row "DHCP" fail

    if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
        if pppoe_link_ok; then
            status_row "WAN" ok "PPPoE · $(iface_ipv4 "$PPPOE_IFACE")"
        else
            status_row "WAN" fail "PPPoE · сессия не установлена"
        fi
    else
        local wip; wip=$(iface_ipv4 wan)
        [[ -n "$wip" ]] && status_row "WAN" ok "DHCP · ${wip}" || status_row "WAN" off "DHCP · нет адреса"
    fi

    if [[ "$NAT_ENABLED" == "1" ]] && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        status_row "NAT" ok "$(subnet_of "$LAN_IP").0/24 → $(wan_out_iface)"
    else
        status_row "NAT" off
    fi

    local pf; pf="$(portfwd_count)"
    if (( pf > 0 )); then
        status_row "DNAT" ok "${pf} правил(о) проброса портов"
    else
        status_row "DNAT" skip
    fi

    if systemctl is-active --quiet docker 2>/dev/null; then
        docker_ok=1; status_row "Docker" ok
    else
        status_row "Docker" fail
    fi

    if (( docker_ok )); then
        check_container "$MIHOMO_CONTAINER"    && status_row "Mihomo" ok    || status_row "Mihomo" fail
        check_container "$ZASHBOARD_CONTAINER" && status_row "Zashboard" ok || status_row "Zashboard" fail
        check_api && status_row "API :9090" ok || status_row "API :9090" fail
        check_ui  && status_row "Панель :80" ok || status_row "Панель :80" fail
    else
        status_row "Mihomo" skip
        status_row "Zashboard" skip
        status_row "API :9090" skip
        status_row "Панель :80" skip
    fi
}

full_diagnostics(){
    header "ПОЛНАЯ ДИАГНОСТИКА / СТАТУСЫ"
    load_config || true
    echo -e "${BOLD}СЕТЬ${NC}"
    # LAN_IFACE/WAN_IFACE below are the ORIGINAL physical NIC names chosen
    # during setup (used only for MAC-address matching in netplan) — they
    # are NOT re-queried live and will keep showing e.g. "enp3s0" forever,
    # even after netplan successfully renames the actual device to "lan"/
    # "wan". That renamed state is what "ip -br link show lan" below
    # reports — that line, not this one, is the one to trust for "did the
    # rename actually work".
    echo "  LAN исходный интерфейс (MAC-match): ${LAN_IFACE:-неизвестно}"
    echo "  LAN адрес:     ${LAN_IP}/24"
    echo "  WAN исходный интерфейс (MAC-match): ${WAN_IFACE:-неизвестно} (режим: ${WAN_MODE:-dhcp})"
    echo "  DHCP:          ${DHCP_START}–${DHCP_END}"
    echo "  DNS upstream:  ${DNS1}, ${DNS2}"
    echo
    if ip link show lan >/dev/null 2>&1; then
        if ip -4 -o addr show lan 2>/dev/null | grep -q .; then
            success "Переименование lan → выполнено успешно"
        else
            warn "Интерфейс lan существует, но без IPv4-адреса"
        fi
        if ip -br link show lan 2>/dev/null | grep -q 'NO-CARRIER'; then
            warn "LAN: кабель НЕ подключён (NO-CARRIER) — устройства LAN не получат связь, пока кабель не воткнут"
        fi
    else
        error "Интерфейс lan не найден — переименование НЕ выполнено"
    fi
    ip -br addr show lan 2>/dev/null || true
    ip -br addr show wan 2>/dev/null || true
    [[ "${WAN_MODE:-dhcp}" == pppoe ]] && { ip -br addr show "$PPPOE_IFACE" 2>/dev/null || true; }
    echo
    pppoe_status_block
    echo
    echo -e "${BOLD}СЕРВИСЫ ХОСТА${NC}"
    local s
    for s in dnsmasq nftables docker; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            printf '  %s %b\n' "$(pad "$s" 13)" "${GREEN}active${NC}"
        else
            printf '  %s %b\n' "$(pad "$s" 13)" "${RED}inactive${NC}"
        fi
    done
    echo
    echo -e "${BOLD}DOCKER${NC}"
    docker --version 2>/dev/null || echo "  Engine: отсутствует"
    docker compose version 2>/dev/null || echo "  Compose: отсутствует"
    echo
    echo -e "${BOLD}КОНТЕЙНЕРЫ${NC}"
    local c st
    for c in "$MIHOMO_CONTAINER" "$ZASHBOARD_CONTAINER"; do
        st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "не найден")
        printf '  %s %s\n' "$(pad "$c" 13)" "$st"
    done
    echo
    echo -e "${BOLD}MIHOMO${NC}"
    echo "  API:        http://${LAN_IP}:9090"
    echo "  Proxy:      ${LAN_IP}:7890"
    echo "  TUN:        $(check_tun && echo active || echo 'не найден')"
    echo "  Подписка:   ${SUBSCRIPTION_URL:-не задана}"
    check_api && echo -e "  Проверка:   ${GREEN}OK${NC}" || echo -e "  Проверка:   ${RED}FAIL${NC}"
    echo
    echo -e "${BOLD}ПАНЕЛЬ${NC}"
    echo "  URL:        http://${LAN_IP}/"
    check_ui && echo -e "  Проверка:   ${GREEN}OK${NC}" || echo -e "  Проверка:   ${RED}FAIL${NC}"
    echo
    echo -e "${BOLD}FIREWALL / NAT (nftables — единственный владелец, таблица inet ${NFT_TABLE})${NC}"
    if [[ "$NAT_ENABLED" == 1 ]]; then
        echo -e "  NAT:                    ${GREEN}включён${NC}  $(subnet_of "$LAN_IP").0/24 → $(wan_out_iface)"
    else
        echo -e "  NAT:                    ${YELLOW}выключен${NC}"
    fi
    echo "  Доступ к gateway с LAN: $(lan_allow_count) портов разрешено (default-deny)"
    echo "  Доступ к gateway с WAN: $(wanaccess_count) портов разрешено (default-deny)"
    echo "  Проброс портов (DNAT): $(portfwd_count) правил(о)"
    echo
    echo -e "${BOLD}IPv6${NC}"
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == 1 ]]; then
        echo -e "  Состояние:  ${GREEN}отключён${NC}"
    else
        echo -e "  Состояние:  ${RED}включён${NC} (ожидалось: отключён)"
    fi
    echo
    echo -e "${BOLD}DOCKER — СЕТЕВАЯ МОДЕЛЬ${NC}"
    if [[ -f "$DOCKER_DAEMON_JSON" ]] && grep -q '"iptables": false' "$DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo -e "  iptables:   ${GREEN}отключён${NC} (nftables — единственный владелец firewall)"
    else
        echo -e "  iptables:   ${YELLOW}не подтверждено — см. ${DOCKER_DAEMON_JSON}${NC}"
    fi
}

# ─────────────────────────────── установка ───────────────────────────
stack_present(){ [[ -f "$COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1; }

restart_stack(){
    stack_present || { error "Стек не установлен."; return 1; }
    create_env
    run_timed "Перезапуск контейнеров" \
        bash -c "cd '$PROJECT_DIR' && docker compose up -d --remove-orphans"
}

apply_generated(){
    write_config
    write_netplan            || return 1
    netplan generate         || { error "Ошибка Netplan."; return 1; }
    nft_snapshot
    write_nft_structural
    nft_apply_with_confirm   || return 1
    run_timed "Применение Netplan" apply_netplan_checked || return 1
    configure_dnsmasq        || return 1
    if stack_present; then
        create_env
        [[ -n "$CLASH_SECRET" && -n "$SUBSCRIPTION_URL" ]] && { render_mihomo_config || return 1; }
        restart_stack || return 1
    fi
    return 0
}

install_stack(){
    header "УСТАНОВКА GATEWAY + MIHOMO"
    configure_forwarding || return 1
    maybe_setup_pppoe    || true
    configure_nftables   || return 1
    configure_dnsmasq    || return 1
    install_docker       || return 1

    mkdir -p "$PROJECT_DIR" "$MIHOMO_CONFIG_DIR/ruleset" "$MIHOMO_CONFIG_DIR/proxy_providers"

    prompt_secret
    prompt_subscription_install
    render_mihomo_config || return 1
    create_env
    create_compose

    header "ЗАГРУЗКА DOCKER-ОБРАЗОВ"
    run_timed "Загрузка Docker-образов" bash -c "cd '$PROJECT_DIR' && docker compose pull" || return 1

    validate_config || return 1

    header "ЗАПУСК КОНТЕЙНЕРОВ"
    # Both containers run in network_mode: host and bind 0.0.0.0, so neither
    # depends on the LAN link being up or an address existing yet — startup
    # here no longer has a legitimate "expected to fail" case.
    run_timed "Запуск Mihomo + Zashboard" \
        bash -c "cd '$PROJECT_DIR' && docker compose up -d --remove-orphans" \
        || warn "Не все контейнеры стартовали с первого раза."

    local i
    for i in 1 2 3 4 5 6 7 8; do
        check_api && break
        sleep 2
    done

    check_container "$MIHOMO_CONTAINER" || {
        error "Mihomo не запущен."; docker logs --tail 60 "$MIHOMO_CONTAINER" >&2 || true; return 1
    }
    success "Mihomo → running"

    check_container "$ZASHBOARD_CONTAINER" || {
        error "Zashboard не запущен."; docker logs --tail 60 "$ZASHBOARD_CONTAINER" >&2 || true; return 1
    }
    success "Zashboard → running"

    check_api && success "Mihomo API → доступен" || warn "Mihomo API пока не отвечает."
    check_ui  && success "Панель → доступна"     || warn "Панель пока не отвечает."
    final_success
}

final_success(){
    echo
    echo -e "${GREEN}${BOLD}${LINE}${NC}"
    echo -e "${GREEN}${BOLD}                     УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo -e "${GREEN}${BOLD}${LINE}${NC}"
    echo
    echo -e "  Панель:     ${CYAN}${BOLD}http://${LAN_IP}/${NC}"
    echo -e "  Mihomo API: ${CYAN}${BOLD}http://${LAN_IP}:9090${NC}"
    echo -e "  Proxy:      ${CYAN}${BOLD}${LAN_IP}:7890${NC}"
    echo
    echo "  В Zashboard укажите:"
    echo "    Backend URL: http://${LAN_IP}:9090"
    echo "    Secret:      пароль, введённый при установке"
    echo
}

# ──────────────────────────────── удаление ───────────────────────────
remove_stack(){
    header "УДАЛЕНИЕ GATEWAY + MIHOMO"
    echo "Будут удалены контейнеры и ${PROJECT_DIR}."
    echo "Будут сохранены: Netplan, dnsmasq, DHCP, nftables, forwarding, Docker Engine."
    echo
    confirm "Продолжить обычное удаление?" || return 0

    if command -v docker >/dev/null 2>&1; then
        [[ -f "$COMPOSE_FILE" ]] && compose down --remove-orphans --rmi local || true
        docker rm -f "$MIHOMO_CONTAINER" "$ZASHBOARD_CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$PROJECT_DIR"
    SUBSCRIPTION_URL=""; CLASH_SECRET=""
    [[ -f "$CONFIG_FILE" ]] && write_config
    success "Gateway + Mihomo удалены."
    echo "Сеть оставлена рабочей. Docker Engine сохранён."
}

rename_iface_back(){
    local cur="$1" orig="$2"
    [[ -z "$orig" || "$orig" == "$cur" ]] && return 0
    [[ -e "/sys/class/net/$cur" ]] || return 0
    [[ -e "/sys/class/net/$orig" ]] && return 0
    ip link set "$cur" down 2>/dev/null || true
    ip link set "$cur" name "$orig" 2>/dev/null || true
    return 0
}

restore_netplan_files(){
    rm -f "$NETPLAN_FILE"
    local sf
    for sf in pap-secrets chap-secrets; do
        [[ -f "${ORIGINAL_DIR}/${sf}" ]] && cp -a "${ORIGINAL_DIR}/${sf}" "/etc/ppp/${sf}" 2>/dev/null || true
    done
    local f base
    shopt -s nullglob
    for f in /etc/netplan/*.yaml.gateway-disabled; do
        mv "$f" "${f%.gateway-disabled}"
    done
    shopt -u nullglob
    if [[ -d "$ORIGINAL_NETPLAN_DIR" ]]; then
        for f in "$ORIGINAL_NETPLAN_DIR"/*.yaml; do
            [[ -f "$f" ]] || continue
            base=$(basename "$f")
            [[ -f "/etc/netplan/${base}" ]] || cp -a "$f" "/etc/netplan/${base}"
        done
    fi
}

restore_original_netplan(){
    restore_netplan_files
    rename_iface_back "lan" "$LAN_IFACE"
    rename_iface_back "wan" "$WAN_IFACE"
    netplan generate || true
    netplan apply || true
}

full_remove(){
    header "ПОЛНОЕ УДАЛЕНИЕ И СБРОС СЕТИ"
    echo -e "${RED}${BOLD}ВНИМАНИЕ!${NC} Это полностью удалит Gateway и сбросит сеть."
    echo
    echo "Будут удалены/сброшены:"
    echo "  • Mihomo / Zashboard"
    echo "  • Docker Engine, /etc/docker/daemon.json и связанные пакеты"
    echo "  • nftables, allow-listы LAN/WAN, проброс портов, IPv4 forwarding"
    echo "  • PPPoE: служба, watchdog, peer, учётные данные, состояние"
    echo "  • dnsmasq / DHCP"
    echo "  • 01-gateway.yaml"
    echo "  • интерфейсы lan/wan будут переименованы обратно"
    echo "  • исходный Netplan будет восстановлен и применён"
    echo
    warn "SSH будет разорван. Устройство может стать недоступным."
    echo
    echo -e "Для подтверждения введите: ${BOLD}RESET-GATEWAY${NC}"
    local token; read -rp "> " token || return 0
    [[ "$token" == RESET-GATEWAY ]] || { warn "Отменено."; return 0; }
    echo
    confirm "Начать полное удаление?" || return 0

    load_config || true

    # PPPoE goes first: the session must be down before the WAN config is
    # restored. LAN stays untouched by every step here.
    pppoe_purge || true

    if command -v docker >/dev/null 2>&1; then
        [[ -f "$COMPOSE_FILE" ]] && compose down --remove-orphans --rmi local || true
        docker rm -f "$MIHOMO_CONTAINER" "$ZASHBOARD_CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$PROJECT_DIR"

    if pkg_installed docker-ce || command -v docker >/dev/null 2>&1; then
        run_timed "Удаление Docker Engine" \
            env DEBIAN_FRONTEND=noninteractive apt-get purge -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
            docker-compose-plugin docker-ce-rootless-extras || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    fi
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
    rm -rf /var/lib/docker /var/lib/containerd

    # Docker daemon.json: restore whatever pre-existed (or remove it if the
    # gateway created it from nothing).
    if [[ -f "$ORIGINAL_DOCKER_DAEMON" ]]; then
        cp -a "$ORIGINAL_DOCKER_DAEMON" "$DOCKER_DAEMON_JSON"
    else
        rm -f "$DOCKER_DAEMON_JSON"
    fi

    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    pkg_installed dnsmasq && { run_timed "Удаление dnsmasq" \
        env DEBIAN_FRONTEND=noninteractive apt-get purge -y dnsmasq || true; }
    rm -rf /etc/systemd/system/dnsmasq.service.d
    systemctl daemon-reload

    # Cleanup for the systemd-timer-based confirm mechanism from an earlier
    # revision of this script (current revision uses an inline countdown
    # instead — see nft_confirm_or_rollback() — and creates none of this).
    systemctl disable --now "$NFT_CONFIRM_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${NFT_CONFIRM_TIMER_NAME}" "/etc/systemd/system/${NFT_CONFIRM_SERVICE_NAME}" "$NFT_CONFIRM_BACKUP"

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    fi
    pkg_installed nftables && { run_timed "Удаление nftables" \
        env DEBIAN_FRONTEND=noninteractive apt-get purge -y nftables || true; }

    rm -f "$SYSCTL_FILE"
    [[ -f "$ORIGINAL_SYSCTL" ]] && cp -a "$ORIGINAL_SYSCTL" "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || true

    echo
    echo -e "${RED}${BOLD}Сетевая конфигурация будет применена сейчас.${NC}"
    echo -e "${YELLOW}SSH может оборваться.${NC}"
    echo
    if confirm "Применить восстановленный Netplan?"; then
        restore_original_netplan
        rm -rf "$STATE_DIR"
        echo; success "Полное удаление завершено."
        echo "Если SSH оборвался — это ожидаемо."
    else
        restore_netplan_files
        rm -rf "$STATE_DIR"
        warn "Netplan восстановлен на диске, но НЕ применён."
        success "Полное удаление завершено без применения сети."
    fi
}

# ─────────────────────────────── настройки ───────────────────────────
subscription_menu(){
    while true; do
        header "НАСТРОЙКИ · ПОДПИСКА MIHOMO"
        if [[ -n "$SUBSCRIPTION_URL" ]]; then
            echo "Текущая: ${SUBSCRIPTION_URL:0:80}"
        else
            echo "Текущая: не задана"
        fi
        echo
        echo "  1) Добавить / изменить ссылку"
        echo "  2) Проверить доступность"
        echo "  3) Удалить подписку"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-3]: " c || return 0
        case "$c" in
            1) if prompt_subscription_install && [[ -n "$SUBSCRIPTION_URL" ]]; then
                   if stack_present; then
                       render_mihomo_config && restart_stack || warn "Не удалось применить подписку."
                   else
                       warn "Стек не установлен — подписка сохранена, применится при установке."
                   fi
               fi ;;
            2) if [[ -z "$SUBSCRIPTION_URL" ]]; then
                   warn "Подписка не задана."
               elif curl -fsSL --max-time 10 -o /dev/null "$SUBSCRIPTION_URL"; then
                   success "Подписка доступна."
               else
                   error "Подписка недоступна."
               fi ;;
            3) if confirm "Удалить ссылку подписки?"; then
                   SUBSCRIPTION_URL=""; write_config; warn "Подписка удалена."
               fi ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

password_menu(){
    prompt_secret
    if stack_present && [[ -f "$MIHOMO_CONFIG" && -n "$SUBSCRIPTION_URL" ]]; then
        render_mihomo_config && restart_stack || warn "Не удалось перезапустить Mihomo."
    fi
    press_enter
}

lan_menu(){
    header "НАСТРОЙКИ · LAN"
    echo "Текущий LAN:            ${LAN_IP}/24"
    echo "Шлюз и DNS для DHCP:    ${LAN_IP}"
    echo "Текущий пул DHCP:       ${DHCP_START}–${DHCP_END}"
    echo
    warn "Изменение LAN разорвёт SSH."
    echo
    local new_ip
    read -rp "Новый LAN IP [${LAN_IP}]: " new_ip || return 0
    [[ -z "$new_ip" ]] && return 0
    is_ipv4 "$new_ip" || { error "Некорректный IPv4-адрес."; return 0; }
    [[ "$new_ip" == "$LAN_IP" ]] && { info "Адрес не изменился."; return 0; }

    local o_ip="$LAN_IP" o_s="$DHCP_START" o_e="$DHCP_END"
    local new_s="$DHCP_START" new_e="$DHCP_END"
    if ! same_subnet "$new_ip" "$LAN_IP"; then
        new_s="$(subnet_of "$new_ip").$(last_octet "$DHCP_START")"
        new_e="$(subnet_of "$new_ip").$(last_octet "$DHCP_END")"
        info "Пул DHCP будет перенесён в новую подсеть: ${new_s}–${new_e}"
    fi

    LAN_IP="$new_ip"; DHCP_START="$new_s"; DHCP_END="$new_e"
    if ! validate_dhcp_range "$DHCP_START" "$DHCP_END" "$LAN_IP"; then
        LAN_IP="$o_ip"; DHCP_START="$o_s"; DHCP_END="$o_e"
        return 0
    fi

    if confirm "Применить новую LAN-конфигурацию?"; then
        if apply_generated; then
            success "LAN изменён. Переподключитесь: ssh user@${LAN_IP}"
        else
            LAN_IP="$o_ip"; DHCP_START="$o_s"; DHCP_END="$o_e"
            write_config
            warn "Изменение LAN не применено, старые значения возвращены."
        fi
    else
        LAN_IP="$o_ip"; DHCP_START="$o_s"; DHCP_END="$o_e"
    fi
}

dhcp_menu(){
    header "НАСТРОЙКИ · DHCP"
    echo "Текущий диапазон: ${DHCP_START}–${DHCP_END}  (подсеть $(subnet_of "$LAN_IP").0/24)"
    echo
    local a b o_s="$DHCP_START" o_e="$DHCP_END"
    read -rp "Начало DHCP [${DHCP_START}]: " a || return 0
    read -rp "Конец DHCP  [${DHCP_END}]: " b || return 0
    [[ -n "$a" ]] && DHCP_START="$a"
    [[ -n "$b" ]] && DHCP_END="$b"

    if ! validate_dhcp_range "$DHCP_START" "$DHCP_END" "$LAN_IP"; then
        DHCP_START="$o_s"; DHCP_END="$o_e"; return 0
    fi
    if configure_dnsmasq; then
        write_config; success "DHCP сохранён."
    else
        DHCP_START="$o_s"; DHCP_END="$o_e"
        error "Не удалось применить DHCP, значения возвращены."
    fi
}

portfwd_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ПРОБРОС ПОРТОВ"
        echo "Проброс порта с WAN на устройство в LAN (DNAT), например:"
        echo "  92.54.78.221:8265 → 192.168.1.100:8265"
        echo
        portfwd_print_table
        echo
        menu_item 1 "Добавить правило" "пробросить порт с WAN на устройство LAN"
        menu_item 2 "Удалить правило"  "убрать существующий проброс порта"
        menu_item 0 "Назад" ""
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) portfwd_add_interactive ;;
            2) portfwd_remove_interactive ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

portfwd_add_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ПРОБРОС ПОРТОВ · ДОБАВИТЬ"
    local proto wport lip lport
    read -rp "Протокол [tcp/udp/both] (tcp): " proto || return 0
    proto="${proto:-tcp}"; proto="${proto,,}"
    [[ "$proto" == tcp || "$proto" == udp || "$proto" == both ]] || { error "Протокол: tcp, udp или both."; return 0; }

    read -rp "Внешний (WAN) порт: " wport || return 0
    [[ "$wport" =~ ^[0-9]+$ ]] && (( wport >= 1 && wport <= 65535 )) || { error "Порт должен быть 1-65535."; return 0; }

    read -rp "LAN IP устройства: " lip || return 0
    is_ipv4 "$lip" || { error "Некорректный IPv4-адрес."; return 0; }
    same_subnet "$lip" "$LAN_IP" || { error "IP вне подсети LAN ($(subnet_of "$LAN_IP").0/24)."; return 0; }

    read -rp "Порт на устройстве [${wport}]: " lport || return 0
    lport="${lport:-$wport}"
    [[ "$lport" =~ ^[0-9]+$ ]] && (( lport >= 1 && lport <= 65535 )) || { error "Порт должен быть 1-65535."; return 0; }

    local protos=("$proto"); [[ "$proto" == both ]] && protos=(tcp udp)
    local p
    for p in "${protos[@]}"; do
        if grep -qE "^${p} ${wport} " "$PORTFWD_FILE" 2>/dev/null; then
            error "Внешний порт ${wport}/${p} уже занят другим правилом."
            return 0
        fi
    done

    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    for p in "${protos[@]}"; do
        printf '%s %s %s %s\n' "$p" "$wport" "$lip" "$lport" >> "$PORTFWD_FILE"
        nft_add_portfwd "portfwd_${p}" "$wport" "$lip" "$lport"
    done
    chmod 600 "$PORTFWD_FILE"
    write_nft_structural

    local wan_ip; wan_ip="$(iface_ipv4 "$(wan_out_iface)")"; wan_ip="${wan_ip:-<WAN-IP>}"
    success "Правило добавлено: ${wan_ip}:${wport} → ${lip}:${lport} (${proto})"
}

portfwd_remove_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ПРОБРОС ПОРТОВ · УДАЛИТЬ"
    portfwd_print_table
    [[ -s "$PORTFWD_FILE" ]] || return 0
    echo
    local n; read -rp "Номер правила для удаления (0 — отмена): " n || return 0
    [[ "$n" =~ ^[0-9]+$ ]] || { error "Введите число."; return 0; }
    (( n == 0 )) && return 0
    local total; total=$(portfwd_count)
    (( n >= 1 && n <= total )) || { error "Нет правила №${n}."; return 0; }

    local entry; entry=$(sed -n "${n}p" "$PORTFWD_FILE")
    local proto wport lip lport; read -r proto wport lip lport <<<"$entry"

    local tmp; tmp=$(mktemp "${STATE_DIR}/.portfwd.XXXXXX")
    sed "${n}d" "$PORTFWD_FILE" > "$tmp" && mv "$tmp" "$PORTFWD_FILE"
    chmod 600 "$PORTFWD_FILE"

    nft_del_portfwd "portfwd_${proto}" "$wport" "$lip" "$lport"
    write_nft_structural
    success "Правило №${n} удалено."
}

wanaccess_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С WAN"
        echo "Порты gateway, явно разрешённые для доступа из интернета."
        echo "Всё, чего нет в списке (включая SSH), недоступно с WAN — default-deny."
        echo
        wanaccess_print_table
        echo
        menu_item 1 "Разрешить порт"    "открыть порт gateway для доступа с WAN"
        menu_item 2 "Запретить порт"    "убрать порт из списка разрешённых для WAN"
        menu_item 0 "Назад" ""
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) wanaccess_add_interactive ;;
            2) wanaccess_remove_interactive ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

wanaccess_add_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С WAN · РАЗРЕШИТЬ ПОРТ"
    wanaccess_seed_defaults
    local proto port label
    read -rp "Протокол [tcp/udp] (tcp): " proto || return 0
    proto="${proto:-tcp}"; proto="${proto,,}"
    [[ "$proto" == tcp || "$proto" == udp ]] || { error "Протокол: tcp или udp."; return 0; }

    read -rp "Порт: " port || return 0
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { error "Порт должен быть 1-65535."; return 0; }

    if grep -qE "^${proto} ${port} " "$WAN_ALLOW_FILE" 2>/dev/null; then
        warn "Порт ${port}/${proto} уже разрешён для WAN."
        return 0
    fi

    read -rp "Название (для памяти, необязательно): " label || return 0
    label="${label:-без описания}"

    printf '%s %s %s\n' "$proto" "$port" "$label" >> "$WAN_ALLOW_FILE"
    chmod 600 "$WAN_ALLOW_FILE"

    nft_add_port "wan_allow_${proto}" "$port"
    write_nft_structural
    success "Порт ${port}/${proto} разрешён для WAN."
}

wanaccess_remove_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С WAN · ЗАПРЕТИТЬ ПОРТ"
    wanaccess_print_table
    [[ -s "$WAN_ALLOW_FILE" ]] || return 0
    echo
    local n; read -rp "Номер правила для удаления (0 — отмена): " n || return 0
    [[ "$n" =~ ^[0-9]+$ ]] || { error "Введите число."; return 0; }
    (( n == 0 )) && return 0
    local total; total=$(wanaccess_count)
    (( n >= 1 && n <= total )) || { error "Нет правила №${n}."; return 0; }

    local entry proto port; entry=$(sed -n "${n}p" "$WAN_ALLOW_FILE"); read -r proto port _ <<<"$entry"
    warn "Порт будет ЗАКРЫТ для доступа из интернета: ${entry}"
    confirm "Точно запретить этот порт для WAN?" || return 0

    # Removing WAN access can lock out remote admin (e.g. SSH) — protected
    # by the same inline confirm-or-rollback as structural firewall changes.
    nft_snapshot
    local tmp; tmp=$(mktemp "${STATE_DIR}/.wanaccess.XXXXXX")
    sed "${n}d" "$WAN_ALLOW_FILE" > "$tmp" && mv "$tmp" "$WAN_ALLOW_FILE"
    chmod 600 "$WAN_ALLOW_FILE"

    nft_del_port "wan_allow_${proto}" "$port"
    write_nft_structural

    if nft_confirm_or_rollback; then
        success "Порт запрещён для WAN."
    else
        # nft_confirm_or_rollback already restored the live ruleset — put
        # the state file (and the on-disk copy) back in sync with it.
        printf '%s\n' "$entry" >> "$WAN_ALLOW_FILE"
        chmod 600 "$WAN_ALLOW_FILE"
        write_nft_structural
        error "Изменение отменено — порт остаётся разрешён для WAN."
    fi
}

lan_allow_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С LAN"
        echo "Порты gateway, явно разрешённые для доступа из локальной сети."
        echo "Всё, чего нет в списке, недоступно из LAN — default-deny."
        echo
        lan_allow_print_table
        echo
        menu_item 1 "Разрешить порт" "открыть порт gateway для доступа из LAN"
        menu_item 2 "Запретить порт" "убрать порт из списка разрешённых для LAN"
        menu_item 0 "Назад" ""
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) lan_allow_add_interactive ;;
            2) lan_allow_remove_interactive ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

lan_allow_add_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С LAN · РАЗРЕШИТЬ ПОРТ"
    lan_allow_seed_defaults
    local proto port label
    read -rp "Протокол [tcp/udp] (tcp): " proto || return 0
    proto="${proto:-tcp}"; proto="${proto,,}"
    [[ "$proto" == tcp || "$proto" == udp ]] || { error "Протокол: tcp или udp."; return 0; }

    read -rp "Порт: " port || return 0
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { error "Порт должен быть 1-65535."; return 0; }

    if grep -qE "^${proto} ${port} " "$LAN_ALLOW_FILE" 2>/dev/null; then
        warn "Порт ${port}/${proto} уже разрешён для LAN."
        return 0
    fi

    read -rp "Название (для памяти, необязательно): " label || return 0
    label="${label:-без описания}"

    printf '%s %s %s\n' "$proto" "$port" "$label" >> "$LAN_ALLOW_FILE"
    chmod 600 "$LAN_ALLOW_FILE"

    nft_add_port "lan_allow_${proto}" "$port"
    write_nft_structural
    success "Порт ${port}/${proto} разрешён для LAN."
}

lan_allow_remove_interactive(){
    header "НАСТРОЙКИ · СЕТЬ · FIREWALL · ДОСТУП С LAN · ЗАПРЕТИТЬ ПОРТ"
    lan_allow_print_table
    [[ -s "$LAN_ALLOW_FILE" ]] || return 0
    echo
    local n; read -rp "Номер правила для удаления (0 — отмена): " n || return 0
    [[ "$n" =~ ^[0-9]+$ ]] || { error "Введите число."; return 0; }
    (( n == 0 )) && return 0
    local total; total=$(lan_allow_count)
    (( n >= 1 && n <= total )) || { error "Нет правила №${n}."; return 0; }

    local entry proto port; entry=$(sed -n "${n}p" "$LAN_ALLOW_FILE"); read -r proto port _ <<<"$entry"
    warn "Порт будет ЗАКРЫТ для доступа из LAN: ${entry}"
    confirm "Точно запретить этот порт для LAN?" || return 0

    # Removing LAN access can lock out the admin's own LAN session too —
    # protected by the same inline confirm-or-rollback.
    nft_snapshot
    local tmp; tmp=$(mktemp "${STATE_DIR}/.lanallow.XXXXXX")
    sed "${n}d" "$LAN_ALLOW_FILE" > "$tmp" && mv "$tmp" "$LAN_ALLOW_FILE"
    chmod 600 "$LAN_ALLOW_FILE"

    nft_del_port "lan_allow_${proto}" "$port"
    write_nft_structural

    if nft_confirm_or_rollback; then
        success "Порт запрещён для LAN."
    else
        printf '%s\n' "$entry" >> "$LAN_ALLOW_FILE"
        chmod 600 "$LAN_ALLOW_FILE"
        write_nft_structural
        error "Изменение отменено — порт остаётся разрешён для LAN."
    fi
}

change_lan_iface(){
    header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · LAN · ИНТЕРФЕЙС"
    echo "Текущий LAN интерфейс: ${LAN_IFACE:-—} (${LAN_MAC:-—})"
    echo
    local new
    new=$(choose_iface_manual "Выберите новый LAN" "$WAN_IFACE") || return 0
    LAN_IFACE="$new"; LAN_MAC=$(mac_of "$new")
    if confirm "Применить? SSH может оборваться."; then
        apply_generated || { warn "Не применено."; load_config || true; }
    else load_config || true; fi
}

change_wan_iface(){
    header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · WAN · ИНТЕРФЕЙС"
    echo "Текущий WAN интерфейс: ${WAN_IFACE:-—} (${WAN_MAC:-—})"
    echo
    local new
    new=$(choose_iface_manual "Выберите новый WAN" "$LAN_IFACE") || return 0
    WAN_IFACE="$new"; WAN_MAC=$(mac_of "$new")
    if confirm "Применить?"; then
        apply_generated || { warn "Не применено."; load_config || true; }
    else load_config || true; fi
}

dns_menu(){
    header "НАСТРОЙКИ · DNS UPSTREAM"
    echo "Текущие: ${DNS1}, ${DNS2}"
    echo
    local a b o1="$DNS1" o2="$DNS2"
    read -rp "DNS 1 [${DNS1}]: " a || return 0
    read -rp "DNS 2 [${DNS2}]: " b || return 0
    [[ -n "$a" ]] && DNS1="$a"
    [[ -n "$b" ]] && DNS2="$b"
    if ! is_ipv4 "$DNS1" || ! is_ipv4 "$DNS2"; then
        DNS1="$o1"; DNS2="$o2"
        error "Некорректный IPv4-адрес DNS."
        return 0
    fi
    if configure_dnsmasq; then
        write_config; success "DNS upstream сохранён."
    else
        DNS1="$o1"; DNS2="$o2"
        error "Не удалось применить DNS."
    fi
}

# ─────────────────────────── установка / удаление ─────────────────────
install_menu(){
    while true; do
        header "УСТАНОВКА / УДАЛЕНИЕ"
        echo "  1) Установить / переустановить Gateway"
        echo "  2) Удалить Gateway"
        echo "  3) Удалить полностью"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-3]: " c || return 0
        case "$c" in
            1) if ! install_stack; then error "Установка завершилась с ошибкой."; fi ;;
            2) if ! remove_stack; then error "Удаление завершилось с ошибкой."; fi ;;
            3) if ! full_remove; then error "Удаление завершилось с ошибкой."; fi ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

# ─────────────────────────── сервисы и контейнеры ──────────────────────
services_menu(){
    while true; do
        header "СЕРВИСЫ И КОНТЕЙНЕРЫ"
        if stack_present; then
            menu_item 1 "Перезапустить контейнеры"        "docker compose up -d"
            menu_item 2 "Остановить контейнеры"            "docker compose stop"
            menu_item 3 "Обновить контейнеры"               "скачать новые образы и перезапустить"
            menu_item 4 "Перезапустить dnsmasq / nftables" "пересобрать правила и перезапустить сервисы"
        else
            warn "Стек не установлен — доступен только пункт 4."
            menu_item 4 "Перезапустить dnsmasq / nftables" "пересобрать правила и перезапустить сервисы"
        fi
        menu_item 0 "Назад" ""
        echo
        local c; read -rp "Выбор [0-4]: " c || return 0
        case "$c" in
            1) stack_present && restart_stack || error "Стек не установлен." ;;
            2) stack_present && { compose stop && success "Контейнеры остановлены."; } || error "Стек не установлен." ;;
            3) if stack_present; then
                   run_timed "Обновление образов" bash -c "cd '$PROJECT_DIR' && docker compose pull" \
                       && restart_stack
               else error "Стек не установлен."; fi ;;
            4) systemctl restart dnsmasq && success "dnsmasq перезапущен." || error "Ошибка dnsmasq."
               write_nft_structural
               systemctl restart nftables && success "nftables перезапущен, правила пересозданы." || error "Ошибка nftables." ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

# ─────────────────────────────── диагностика ───────────────────────────
logs_menu(){
    while true; do
        header "ДИАГНОСТИКА · ЛОГИ"
        echo "  1) Логи Mihomo"
        echo "  2) Логи Zashboard"
        echo "  3) Логи PPPoE"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-3]: " c || return 0
        case "$c" in
            1) docker logs --tail 100 "$MIHOMO_CONTAINER" 2>&1 | less -R || true ;;
            2) docker logs --tail 100 "$ZASHBOARD_CONTAINER" 2>&1 | less -R || true ;;
            3) journalctl -u "$PPPOE_SERVICE" -n 50 --no-pager 2>/dev/null | less -R || warn "Журнал недоступен." ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

diagnostics_menu(){
    while true; do
        header "ДИАГНОСТИКА"
        echo "  1) Статусы"
        echo "  2) Логи"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) clear; if ! full_diagnostics; then error "Ошибка диагностики."; fi; press_enter ;;
            2) logs_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
    done
}

setting_row(){ printf "  ${BOLD}%s)${NC} %s ${DIM}%s${NC}\n" "$1" "$(pad "$2" 26)" "${3:-—}"; }

# ─────────────────────────────── настройки · mihomo ────────────────────
mihomo_settings_menu(){
    while true; do
        header "НАСТРОЙКИ · MIHOMO"
        setting_row 1 "Подписка" "${SUBSCRIPTION_URL:+задана}"
        setting_row 2 "Пароль"   "${CLASH_SECRET:+задан}"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) subscription_menu ;;
            2) password_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────── настройки · сеть ──────────────────────
wan_mode_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · WAN · РЕЖИМ РАБОТЫ"
        echo "Текущий режим: $([[ "${WAN_MODE:-dhcp}" == pppoe ]] && echo PPPoE || echo DHCP)"
        echo
        echo "  1) DHCP"
        echo "  2) PPPoE"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
                   pppoe_disable || warn "Не удалось вернуть DHCP."
               else
                   info "WAN уже в режиме DHCP."
               fi ;;
            2) if [[ "${WAN_MODE:-dhcp}" == pppoe ]]; then
                   info "WAN уже в режиме PPPoE."
               else
                   pppoe_enable || warn "PPPoE не включён."
               fi ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

wan_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · WAN"
        echo "Интерфейс: ${WAN_IFACE:-—} (${WAN_MAC:-—})    Режим: $([[ "${WAN_MODE:-dhcp}" == pppoe ]] && echo PPPoE || echo DHCP)"
        echo
        echo "  1) Изменить интерфейс"
        echo "  2) Режим работы"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) change_wan_iface; press_enter ;;
            2) wan_mode_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
    done
}

lan_settings_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ · LAN"
        echo "Интерфейс: ${LAN_IFACE:-—} (${LAN_MAC:-—})    Адрес: ${LAN_IP}/24    DHCP: ${DHCP_START}–${DHCP_END}"
        echo
        echo "  1) Изменить интерфейс"
        echo "  2) Изменить адрес шлюза"
        echo "  3) Пул адресов DHCP"
        echo "  4) DNS"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-4]: " c || return 0
        case "$c" in
            1) change_lan_iface; press_enter ;;
            2) if ! lan_menu; then warn "Операция прервана."; fi; press_enter ;;
            3) if ! dhcp_menu; then warn "Операция прервана."; fi; press_enter ;;
            4) if ! dns_menu; then warn "Операция прервана."; fi; press_enter ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
    done
}

interfaces_root_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · ИНТЕРФЕЙСЫ"
        echo "LAN: ${LAN_IFACE:-—}    WAN: ${WAN_IFACE:-—} ($([[ "${WAN_MODE:-dhcp}" == pppoe ]] && echo PPPoE || echo DHCP))"
        echo
        echo "  1) WAN"
        echo "  2) LAN"
        echo "  3) PPPoE"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-3]: " c || return 0
        case "$c" in
            1) wan_menu ;;
            2) lan_settings_menu ;;
            3) pppoe_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
    done
}

firewall_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ · FIREWALL"

        if systemctl is-active --quiet nftables 2>/dev/null; then
            echo -e "Firewall (nftables): ${GREEN}АКТИВЕН${NC}  (единственный владелец filter/NAT/DNAT — Docker его не трогает)"
        else
            echo -e "Firewall (nftables): ${RED}ВЫКЛЮЧЕН${NC} — фильтрация и NAT не работают"
        fi
        echo
        echo -e "${BOLD}ИСХОДЯЩИЙ ТРАФИК — LAN → интернет${NC}"
        if [[ "$NAT_ENABLED" == 1 ]]; then
            echo -e "  NAT: ${GREEN}ВКЛЮЧЕН${NC}"
        else
            echo -e "  NAT: ${YELLOW}ВЫКЛЮЧЕН${NC}"
        fi
        echo
        echo -e "${BOLD}ДОСТУП К GATEWAY — default-deny, разрешены только явно указанные порты${NC}"
        echo "  С LAN: $(lan_allow_count) портов разрешено"
        echo "  С WAN: $(wanaccess_count) портов разрешено"
        echo "  Проброс портов на LAN (DNAT): $(portfwd_count) правил(о)"
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
            echo
            echo -e "${YELLOW}Внимание: UFW тоже активен — возможен конфликт правил.${NC}"
        fi
        echo
        menu_item 1 "Включить / выключить firewall"    "полностью отключает фильтрацию и NAT"
        menu_item 2 "NAT — доступ LAN в интернет"       "включить/выключить общий доступ в сеть"
        menu_item 3 "Доступ к gateway с WAN"            "allow-list: какие порты видны снаружи"
        menu_item 4 "Доступ к gateway с LAN"            "allow-list: какие порты видны из LAN"
        menu_item 5 "Проброс портов на устройства LAN"  "сделать устройство LAN доступным из интернета"
        menu_item 0 "Назад" ""
        echo
        local c; read -rp "Выбор [0-5]: " c || return 0
        case "$c" in
            1)
                if systemctl is-active --quiet nftables 2>/dev/null; then
                    warn "Выключение firewall уберёт и фильтрацию, и NAT — LAN и WAN потеряют защиту default-deny."
                    if confirm "Выключить firewall?"; then
                        systemctl disable --now nftables >/dev/null 2>&1 \
                            && success "Firewall выключен." || error "Не удалось выключить firewall."
                    fi
                else
                    nft_snapshot
                    write_nft_structural
                    nft_apply_with_confirm || error "Не удалось включить firewall."
                fi ;;
            2)
                local old="$NAT_ENABLED"
                [[ "$NAT_ENABLED" == 1 ]] && NAT_ENABLED=0 || NAT_ENABLED=1
                nft_snapshot
                write_nft_structural
                if nft_apply_with_confirm; then
                    write_config
                    [[ "$NAT_ENABLED" == 1 ]] && success "NAT включён." || success "NAT выключен."
                else
                    NAT_ENABLED="$old"; write_nft_structural
                    error "Изменение NAT отменено."
                fi ;;
            3) wanaccess_menu; continue ;;
            4) lan_allow_menu; continue ;;
            5) portfwd_menu; continue ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

network_menu(){
    while true; do
        header "НАСТРОЙКИ · СЕТЬ"
        echo "  1) Интерфейсы"
        echo "  2) Firewall"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) interfaces_root_menu ;;
            2) firewall_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
    done
}

# ─────────────────────────────── настройки ──────────────────────────────
settings_menu(){
    while true; do
        header "НАСТРОЙКИ"
        setting_row 1 "Mihomo" "подписка, пароль"
        setting_row 2 "Сеть"   "интерфейсы, firewall"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-2]: " c || return 0
        case "$c" in
            1) mihomo_settings_menu ;;
            2) network_menu ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────── главное меню ────────────────────────
menu_item(){ printf "  ${BOLD}%s)${NC} %s ${DIM}%s${NC}\n" "$1" "$(pad "$2" 38)" "${3:-}"; }

main_menu(){
    local c
    while true; do
        load_config || true
        clear
        echo -e "${BOLD}${CYAN}${LINE}${NC}"
        echo -e "${BOLD}${CYAN}         UBUNTU GATEWAY + MIHOMO  ·  v${SCRIPT_VERSION}${NC}"
        echo -e "${BOLD}${CYAN}${LINE}${NC}"
        echo -e "${BOLD} Состояние системы${NC}"
        echo
        quick_status
        echo
        echo -e "${BOLD}${CYAN}${LINE}${NC}"
        menu_item 1 "Установка / удаление"  "установить, удалить, снести полностью"
        menu_item 2 "Сервисы и контейнеры"  "перезапуск, остановка, обновление"
        menu_item 3 "Диагностика"           "статусы, логи"
        menu_item 4 "Настройки"             "mihomo, сеть"
        menu_item 0 "Выход"                 ""
        echo -e "${BOLD}${CYAN}${LINE}${NC}"
        echo -e "  ${DIM}Панель: http://${LAN_IP}/     API: http://${LAN_IP}:9090${NC}"
        echo

        read -rp "$(echo -e "${BOLD}Выбор [0-4]: ${NC}")" c || exit 0
        case "$c" in
            1) install_menu ;;
            2) services_menu ;;
            3) diagnostics_menu ;;
            4) settings_menu ;;
            0|q|Q|й|Й) echo; exit 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

self_test(){
    local missing=() cmd
    for cmd in grep sed awk ip systemctl curl netplan mktemp ping; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "Не найдены обязательные команды: ${missing[*]}"
    (( BASH_VERSINFO[0] >= 4 )) || die "Требуется bash 4 или новее."
    success "Самопроверка скрипта — OK"
}

main(){
    need_root
    self_test
    check_os
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    load_config || true            # must run before network_is_ready
    if ! network_is_ready; then
        configure_network_first
        load_config || true
    elif ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
        # Initial setup was completed, but SSH dropped before DHCP was set up.
        info "Сеть настроена, DHCP ещё не запущен — завершаю настройку dnsmasq..."
        configure_dnsmasq || warn "Не удалось настроить DHCP. См. Настройки → DHCP."
    fi
    main_menu
}

main "$@"
