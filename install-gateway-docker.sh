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
readonly CONFIG_KEYS="LAN_IP DHCP_START DHCP_END DNS1 DNS2 LAN_IFACE WAN_IFACE LAN_MAC WAN_MAC NAT_ENABLED SUBSCRIPTION_URL CLASH_SECRET"

LAN_IFACE=""; WAN_IFACE=""; LAN_MAC=""; WAN_MAC=""
LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"
DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; CLASH_SECRET=""; SUBSCRIPTION_URL=""
NAT_ENABLED="1"

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
    local extra=""
    [[ "$1" == 1 ]] && extra=$'\n      ignore-carrier: true'
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
      dhcp4: true
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
After=network-online.target

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
write_nftables(){
    local nat_block=""
    if [[ "$NAT_ENABLED" == "1" ]]; then
        nat_block=$(cat <<EOF2

table ip gateway_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wan" ip saddr $(subnet_of "$LAN_IP").0/24 masquerade
  }
}
EOF2
        )
    fi

    cat > "$NFT_FILE" <<EOF2
#!/usr/sbin/nft -f

table inet gateway_filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "wan" tcp dport { 80, 7890, 9090 } drop
    iifname "wan" udp dport { 53, 7890 } drop
    iifname "wan" tcp dport 53 drop
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
$( [[ "$NAT_ENABLED" == "1" ]] && cat <<'EOF3'
    iifname "lan" oifname "wan" accept
    iifname "wan" oifname "lan" ct state established,related accept
EOF3
)
  }
}
${nat_block}
EOF2
    chmod 644 "$NFT_FILE"
}

reload_nftables(){
    nft -c -f "$NFT_FILE" || { error "Ошибка синтаксиса nftables."; return 1; }
    # Old tables must go, otherwise disabled NAT rules would survive the reload.
    nft delete table ip gateway_nat 2>/dev/null || true
    nft -f "$NFT_FILE" || return 1
    return 0
}

configure_nftables(){
    header "УСТАНОВКА · NFTABLES / NAT"
    apt_install nftables
    [[ -f "$NFT_FILE" && ! -f "$ORIGINAL_NFT" ]] && cp -a "$NFT_FILE" "$ORIGINAL_NFT"
    write_nftables
    nft -c -f "$NFT_FILE" || { error "Ошибка синтаксиса nftables."; return 1; }
    success "Конфигурация nftables — OK"
    systemctl enable nftables >/dev/null 2>&1 || true
    run_timed "Применение nftables" systemctl restart nftables
}

configure_forwarding(){
    header "УСТАНОВКА · IPV4 FORWARDING"
    [[ -f "$SYSCTL_FILE" && ! -f "$ORIGINAL_SYSCTL" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL"
    cat > "$SYSCTL_FILE" <<'EOF2'
net.ipv4.ip_forward=1
# Lets services bind the LAN address before the LAN link is up
# (zashboard publishes on ${LAN_IP}:80).
net.ipv4.ip_nonlocal_bind=1
EOF2
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || { error "Не удалось включить forwarding."; return 1; }
    success "IPv4 forwarding → active"
    if [[ "$(sysctl -n net.ipv4.ip_nonlocal_bind 2>/dev/null || echo 0)" == 1 ]]; then
        success "Привязка к LAN-адресу без линка → разрешена"
    else
        warn "Не удалось включить ip_nonlocal_bind — панель поднимется только с линком на LAN."
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
    ports:
      - "${LAN_IP}:80:80"
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
    elif network_link_ok; then
        status_row "Сеть" ok
    else
        status_row "Сеть" off "LAN-адрес ${LAN_IP} не поднят"
    fi
    systemctl is-active --quiet dnsmasq 2>/dev/null && status_row "DHCP" ok || status_row "DHCP" fail

    if nft list table ip gateway_nat >/dev/null 2>&1; then
        status_row "NAT" ok "$(subnet_of "$LAN_IP").0/24 → wan"
    else
        status_row "NAT" off
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
    echo "  LAN интерфейс: ${LAN_IFACE:-неизвестно}"
    echo "  LAN адрес:     ${LAN_IP}/24"
    echo "  WAN интерфейс: ${WAN_IFACE:-неизвестно}"
    echo "  DHCP:          ${DHCP_START}–${DHCP_END}"
    echo "  DNS upstream:  ${DNS1}, ${DNS2}"
    echo
    ip -br addr show lan 2>/dev/null || true
    ip -br addr show wan 2>/dev/null || true
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
    echo -e "${BOLD}NAT${NC}"
    if [[ "$NAT_ENABLED" == 1 ]]; then
        echo -e "  Состояние:  ${GREEN}включён${NC}"
    else
        echo -e "  Состояние:  ${YELLOW}выключен${NC}"
    fi
    echo "  LAN → WAN:  $(subnet_of "$LAN_IP").0/24 → ${WAN_IFACE:-wan}"
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
    write_nftables
    reload_nftables          || return 1
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
    # Zashboard may fail to bind ${LAN_IP}:80 while the LAN link is down,
    # so a non-zero exit here is not fatal — Mihomo is checked separately below.
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

    if ! check_container "$ZASHBOARD_CONTAINER"; then
        docker start "$ZASHBOARD_CONTAINER" >/dev/null 2>&1 || true
        sleep 2
    fi
    if check_container "$ZASHBOARD_CONTAINER"; then
        success "Zashboard → running"
    else
        warn "Zashboard пока не запущен (обычно — нет линка на LAN)."
        docker logs --tail 20 "$ZASHBOARD_CONTAINER" >&2 || true
        warn "Панель поднимется сама после подключения кабеля (restart: unless-stopped)."
    fi

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
    echo "  • Docker Engine и связанные пакеты"
    echo "  • nftables, IPv4 forwarding"
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

    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    pkg_installed dnsmasq && { run_timed "Удаление dnsmasq" \
        env DEBIAN_FRONTEND=noninteractive apt-get purge -y dnsmasq || true; }
    rm -rf /etc/systemd/system/dnsmasq.service.d
    systemctl daemon-reload

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet gateway_filter 2>/dev/null || true
        nft delete table ip gateway_nat 2>/dev/null || true
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

nat_menu(){
    while true; do
        header "НАСТРОЙКИ · NAT"
        echo "LAN: $(subnet_of "$LAN_IP").0/24 → WAN: ${WAN_IFACE:-wan}"
        if [[ "$NAT_ENABLED" == 1 ]]; then
            echo -e "Состояние: ${GREEN}ВКЛЮЧЁН${NC}"
        else
            echo -e "Состояние: ${YELLOW}ВЫКЛЮЧЕН${NC}"
        fi
        echo
        echo "  1) Включить NAT"
        echo "  2) Выключить NAT"
        echo "  3) Пересоздать правила"
        echo "  0) Назад"
        echo
        local c old="$NAT_ENABLED"
        read -rp "Выбор [0-3]: " c || return 0
        case "$c" in
            1|2)
                [[ "$c" == 1 ]] && NAT_ENABLED=1 || NAT_ENABLED=0
                write_nftables
                if reload_nftables; then
                    write_config
                    [[ "$NAT_ENABLED" == 1 ]] && success "NAT включён." || success "NAT выключен."
                else
                    NAT_ENABLED="$old"; write_nftables; reload_nftables || true
                    error "Не удалось изменить NAT."
                fi ;;
            3)  write_nftables
                reload_nftables && success "Правила NAT пересозданы." || error "Ошибка правил NAT." ;;
            0)  return 0 ;;
            *)  warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

interfaces_menu(){
    header "НАСТРОЙКИ · ИНТЕРФЕЙСЫ"
    echo "Текущие: LAN=${LAN_IFACE:-—} (${LAN_MAC:-—}), WAN=${WAN_IFACE:-—} (${WAN_MAC:-—})"
    echo
    echo "  1) Изменить LAN интерфейс"
    echo "  2) Изменить WAN интерфейс"
    echo "  0) Назад"
    echo
    local c new
    read -rp "Выбор [0-2]: " c || return 0
    case "$c" in
        1) new=$(choose_iface_manual "Выберите новый LAN" "$WAN_IFACE") || return 0
           LAN_IFACE="$new"; LAN_MAC=$(mac_of "$new")
           if confirm "Применить? SSH может оборваться."; then
               apply_generated || { warn "Не применено."; load_config || true; }
           else load_config || true; fi ;;
        2) new=$(choose_iface_manual "Выберите новый WAN" "$LAN_IFACE") || return 0
           WAN_IFACE="$new"; WAN_MAC=$(mac_of "$new")
           if confirm "Применить?"; then
               apply_generated || { warn "Не применено."; load_config || true; }
           else load_config || true; fi ;;
        0) return 0 ;;
        *) warn "Неверный выбор." ;;
    esac
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

services_menu(){
    while true; do
        header "СЕРВИСЫ И КОНТЕЙНЕРЫ"
        if stack_present; then
            echo "  1) Перезапустить стек (up -d)"
            echo "  2) Остановить контейнеры"
            echo "  3) Обновить образы (pull + up -d)"
            echo "  4) Логи Mihomo (последние 100)"
            echo "  5) Логи Zashboard (последние 100)"
            echo "  6) Перезапустить dnsmasq / nftables"
        else
            warn "Стек не установлен — доступен только пункт 6."
            echo "  6) Перезапустить dnsmasq / nftables"
        fi
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-6]: " c || return 0
        case "$c" in
            1) stack_present && restart_stack || error "Стек не установлен." ;;
            2) stack_present && { compose stop && success "Контейнеры остановлены."; } || error "Стек не установлен." ;;
            3) if stack_present; then
                   run_timed "Обновление образов" bash -c "cd '$PROJECT_DIR' && docker compose pull" \
                       && restart_stack
               else error "Стек не установлен."; fi ;;
            4) docker logs --tail 100 "$MIHOMO_CONTAINER" 2>&1 | less -R || true ;;
            5) docker logs --tail 100 "$ZASHBOARD_CONTAINER" 2>&1 | less -R || true ;;
            6) systemctl restart dnsmasq && success "dnsmasq перезапущен." || error "Ошибка dnsmasq."
               systemctl restart nftables && success "nftables перезапущен." || error "Ошибка nftables." ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        press_enter
    done
}

setting_row(){ printf "  ${BOLD}%s)${NC} %s ${DIM}%s${NC}\n" "$1" "$(pad "$2" 26)" "${3:-—}"; }

settings_menu(){
    while true; do
        header "НАСТРОЙКИ"
        setting_row 1 "Подписка Mihomo"      "${SUBSCRIPTION_URL:+задана}"
        setting_row 2 "Пароль Mihomo API"    "${CLASH_SECRET:+задан}"
        setting_row 3 "LAN / адрес шлюза"    "${LAN_IP}/24"
        setting_row 4 "DHCP / пул адресов"   "${DHCP_START}–${DHCP_END}"
        setting_row 5 "NAT"                  "$([[ "$NAT_ENABLED" == 1 ]] && echo включён || echo выключен)"
        setting_row 6 "Интерфейсы LAN / WAN" "${LAN_IFACE:-—} / ${WAN_IFACE:-—}"
        setting_row 7 "DNS upstream"         "${DNS1}, ${DNS2}"
        echo "  0) Назад"
        echo
        local c; read -rp "Выбор [0-7]: " c || return 0
        case "$c" in
            1) subscription_menu ;;
            2) password_menu ;;
            3) if ! lan_menu; then warn "Операция прервана."; fi; press_enter ;;
            4) if ! dhcp_menu; then warn "Операция прервана."; fi; press_enter ;;
            5) nat_menu ;;
            6) if ! interfaces_menu; then warn "Операция прервана."; fi; press_enter ;;
            7) if ! dns_menu; then warn "Операция прервана."; fi; press_enter ;;
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
        menu_item 1 "Установить / переустановить Gateway" "полный цикл"
        menu_item 2 "Сервисы и контейнеры"                "перезапуск, логи, обновление"
        menu_item 3 "Настройки"                           "подписка, LAN, DHCP, NAT, DNS"
        menu_item 4 "Диагностика и статусы"               "подробный отчёт"
        menu_item 5 "Удалить Gateway"                     "сеть оставить"
        menu_item 6 "Полное удаление"                     "сброс сети"
        menu_item 0 "Выход"                               ""
        echo -e "${BOLD}${CYAN}${LINE}${NC}"
        echo -e "  ${DIM}Панель: http://${LAN_IP}/     API: http://${LAN_IP}:9090${NC}"
        echo

        read -rp "$(echo -e "${BOLD}Выбор [0-6]: ${NC}")" c || exit 0
        case "$c" in
            1) if ! install_stack; then error "Установка завершилась с ошибкой."; fi; press_enter ;;
            2) services_menu ;;
            3) settings_menu ;;
            4) clear; if ! full_diagnostics; then error "Ошибка диагностики."; fi; press_enter ;;
            5) if ! remove_stack; then error "Удаление завершилось с ошибкой."; fi; press_enter ;;
            6) if ! full_remove; then error "Удаление завершилось с ошибкой."; fi; press_enter ;;
            0|q|Q|й|Й) echo; exit 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

self_test(){
    local missing=() cmd
    for cmd in grep sed awk ip systemctl curl netplan mktemp; do
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
