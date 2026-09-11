#!/usr/bin/env bash
#
# Ubuntu Gateway + Mihomo — Docker Manager v3.0
#
# HOST:
#   Netplan
#   dnsmasq
#   nftables
#   IPv4 forwarding
#   Docker Engine
#
# DOCKER:
#   Mihomo          host network, TUN
#   MetaCubeXD      host network, port 80
#
# IMPORTANT:
#   Normal removal does NOT touch the host network.
#   Full removal restores the original Netplan and removes the host network stack.
#
# First launch on an unconfigured machine:
#   1) Configure LAN/WAN + DHCP
#   2) STOP
#   3) Reconnect over LAN using 192.168.100.1
#   4) Run again
#
# ============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.0.0"
readonly STATE_DIR="/var/lib/mihomo-gateway"
readonly CONFIG_FILE="${STATE_DIR}/gateway.env"
readonly ORIGINAL_DIR="${STATE_DIR}/original"
readonly ORIGINAL_NETPLAN_DIR="${ORIGINAL_DIR}/netplan"
readonly ORIGINAL_DNSMASQ="${ORIGINAL_DIR}/dnsmasq.conf"
readonly ORIGINAL_NFT="${ORIGINAL_DIR}/nftables.conf"
readonly ORIGINAL_SYSCTL="${ORIGINAL_DIR}/99-router.conf"
readonly NETPLAN_FILE="/etc/netplan/01-gateway.yaml"
readonly DNSMASQ_FILE="/etc/dnsmasq.conf"
readonly DNSMASQ_OVERRIDE="/etc/systemd/system/dnsmasq.service.d/override.conf"
readonly NFT_FILE="/etc/nftables.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-router.conf"
readonly PROJECT_DIR="/opt/mihomo-gateway"
readonly COMPOSE_FILE="${PROJECT_DIR}/compose.yaml"
readonly MIHOMO_CONFIG_DIR="${PROJECT_DIR}/config"
readonly MIHOMO_CONFIG="${MIHOMO_CONFIG_DIR}/config.yaml"
readonly ENV_FILE="${PROJECT_DIR}/.env"
readonly LAN_DEFAULT="192.168.100.1"
readonly DHCP_START_DEFAULT="192.168.100.100"
readonly DHCP_END_DEFAULT="192.168.100.250"
readonly DNS1_DEFAULT="1.1.1.1"
readonly DNS2_DEFAULT="8.8.8.8"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

LAN_IFACE=""; WAN_IFACE=""; LAN_MAC=""; WAN_MAC=""
LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"
DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; CLASH_SECRET=""; SUBSCRIPTION_URL=""
NAT_ENABLED="1"

info(){ echo -e "${BLUE}[i]${NC} $*"; }
success(){ echo -e "${GREEN}[✓]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
error(){ echo -e "${RED}[✗]${NC} $*" >&2; }
header(){ echo; echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"; printf "${BOLD}${CYAN}║ %-60s ║${NC}\n" "$1"; echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"; echo; }
confirm(){ local a; read -rp "$(echo -e "${YELLOW}${1:-Продолжить?} [y/N]: ${NC}")" a; [[ "$a" =~ ^[YyДд]$ ]]; }
press_enter(){ read -rp "Нажмите Enter..." _ || true; }
need_root(){ [[ $EUID -eq 0 ]] || { error "Запустите: sudo bash $0"; exit 1; }; }

on_error(){
    local rc=$?
    error "Скрипт остановился с ошибкой (код ${rc})."
    error "При необходимости выберите 'Полная диагностика / статусы'."
    exit "$rc"
}
trap on_error ERR

# ----------------------------------------------------------------------------
# Timed command runner
# ----------------------------------------------------------------------------
run_timed(){
    local label="$1"; shift
    local log
    log=$(mktemp /tmp/mgw-run.XXXXXX)
    local start=$SECONDS pid rc elapsed
    "$@" >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS-start))
        printf '\r%s⏳%s %-48s %3ss' "$YELLOW" "$NC" "$label" "$elapsed"
        sleep 1
    done
    wait "$pid"; rc=$?
    elapsed=$((SECONDS-start))
    printf '\r\033[2K'
    if (( rc == 0 )); then
        success "$label — ${elapsed} с"
    else
        error "$label — ошибка (код ${rc}, ${elapsed} с)"
        tail -n 30 "$log" >&2 || true
    fi
    rm -f "$log"
    return "$rc"
}

run_capture(){
    local label="$1"; shift
    local log; log=$(mktemp /tmp/mgw-run.XXXXXX)
    local start=$SECONDS pid rc elapsed
    "$@" >"$log" 2>&1 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        elapsed=$((SECONDS-start))
        printf '\r%s⏳%s %-48s %3ss' "$YELLOW" "$NC" "$label" "$elapsed"
        sleep 1
    done
    wait "$pid"; rc=$?
    elapsed=$((SECONDS-start)); printf '\r\033[2K'
    if (( rc == 0 )); then success "$label — ${elapsed} с"; else error "$label — ошибка"; tail -n 40 "$log" >&2 || true; fi
    cat "$log" >/tmp/mgw-last.log
    rm -f "$log"
    return "$rc"
}

# ----------------------------------------------------------------------------
# OS / packages
# ----------------------------------------------------------------------------
check_os(){
    [[ -f /etc/os-release ]] || { error "Не найден /etc/os-release"; exit 1; }
    . /etc/os-release
    info "ОС: ${PRETTY_NAME:-unknown}"
    if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* && "${ID_LIKE:-}" != *debian* ]]; then
        warn "Скрипт рассчитан на Ubuntu/Debian."
        confirm "Продолжить?" || exit 1
    fi
}

apt_update_safe(){
    local log rc
    log=$(mktemp /tmp/mgw-apt.XXXXXX)
    apt-get update -qq >"$log" 2>&1 || rc=$? || true
    rc=${rc:-0}
    if (( rc != 0 )); then
        warn "apt update завершился с предупреждениями/ошибкой. Продолжаю, если нужные пакеты доступны."
        tail -n 12 "$log" >&2 || true
    fi
    cat "$log" >/tmp/mgw-apt-last.log
    rm -f "$log"
    return 0
}

apt_install(){
    local packages=("$@")
    apt_update_safe
    run_timed "Установка пакетов: ${packages[*]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

# ----------------------------------------------------------------------------
# Persistent config
# ----------------------------------------------------------------------------
write_config(){
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$CONFIG_FILE" <<EOF2
LAN_IP=${LAN_IP}
DHCP_START=${DHCP_START}
DHCP_END=${DHCP_END}
DNS1=${DNS1}
DNS2=${DNS2}
LAN_IFACE=${LAN_IFACE}
WAN_IFACE=${WAN_IFACE}
LAN_MAC=${LAN_MAC}
WAN_MAC=${WAN_MAC}
NAT_ENABLED=${NAT_ENABLED}
SUBSCRIPTION_URL=${SUBSCRIPTION_URL}
CLASH_SECRET=${CLASH_SECRET}
EOF2
    chmod 600 "$CONFIG_FILE"
}

load_config(){
    [[ -f "$CONFIG_FILE" ]] || return 1
    . "$CONFIG_FILE"
    LAN_IP="${LAN_IP:-$LAN_DEFAULT}"; DHCP_START="${DHCP_START:-$DHCP_START_DEFAULT}"; DHCP_END="${DHCP_END:-$DHCP_END_DEFAULT}"
    DNS1="${DNS1:-$DNS1_DEFAULT}"; DNS2="${DNS2:-$DNS2_DEFAULT}"; NAT_ENABLED="${NAT_ENABLED:-1}"
    SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-}"; CLASH_SECRET="${CLASH_SECRET:-}"
    LAN_IFACE="${LAN_IFACE:-}"; WAN_IFACE="${WAN_IFACE:-}"; LAN_MAC="${LAN_MAC:-}"; WAN_MAC="${WAN_MAC:-}"
    return 0
}

# ----------------------------------------------------------------------------
# Interfaces
# ----------------------------------------------------------------------------
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
speed_of(){ local s; s=$(cat "/sys/class/net/$1/speed" 2>/dev/null || echo 0); [[ "$s" =~ ^[0-9]+$ && "$s" != 0 ]] && echo "$s Мбит/с" || echo "—"; }
state_of(){ cat "/sys/class/net/$1/operstate" 2>/dev/null || echo unknown; }

print_iface(){
    local i="$1"; local mac state speed
    mac=$(mac_of "$i"); state=$(state_of "$i"); speed=$(speed_of "$i")
    echo -e "  ${BOLD}${i}${NC}  MAC: ${mac}  State: ${state}  Link: $([[ $(carrier_of "$i") ]] && echo connected || echo disconnected)  Speed: ${speed}"
}

choose_iface_manual(){
    local title="$1" exclude="${2:-}"; shift 2 || true
    local arr=() i n
    mapfile -t arr < <(detect_interfaces)
    echo -e "${BOLD}${title}${NC}"; echo
    n=1
    for i in "${arr[@]}"; do
        [[ "$i" == "$exclude" ]] && continue
        echo "  ${n}) $(print_iface "$i")"
        echo
        ((n++))
    done
    while true; do
        read -rp "Ваш выбор: " n
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "Введите номер."; continue; }
        local idx=0 chosen=""
        for i in "${arr[@]}"; do
            [[ "$i" == "$exclude" ]] && continue
            ((idx++)); [[ "$idx" == "$n" ]] && chosen="$i" && break
        done
        [[ -n "$chosen" ]] && echo "$chosen" && return 0
        warn "Нет такого пункта."
    done
}

# ----------------------------------------------------------------------------
# Original config backup and network stage
# ----------------------------------------------------------------------------
backup_once(){
    mkdir -p "$ORIGINAL_NETPLAN_DIR"
    chmod 700 "$ORIGINAL_DIR"
    if [[ ! -f "${ORIGINAL_DIR}/BACKUP_DONE" ]]; then
        local found=0 f base
        shopt -s nullglob
        for f in /etc/netplan/*.yaml; do
            found=1; base=$(basename "$f"); cp -a "$f" "${ORIGINAL_NETPLAN_DIR}/${base}"
            mv "$f" "${f}.gateway-disabled"
        done
        shopt -u nullglob
        [[ -f "$DNSMASQ_FILE" ]] && cp -a "$DNSMASQ_FILE" "$ORIGINAL_DNSMASQ"
        [[ -f "$NFT_FILE" ]] && cp -a "$NFT_FILE" "$ORIGINAL_NFT"
        [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL"
        echo "NETWORK_BACKUP_DONE=1" > "${ORIGINAL_DIR}/BACKUP_DONE"
        success "Исходные конфигурации сохранены${found:+.}"
    fi
}

write_netplan(){
    mkdir -p /etc/netplan
    cat > "$NETPLAN_FILE" <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    lan:
      match:
        macaddress: ${LAN_MAC}
      set-name: lan
      addresses:
        - ${LAN_IP}/24
    wan:
      match:
        macaddress: ${WAN_MAC}
      set-name: wan
      dhcp4: true
EOF2
    chmod 600 "$NETPLAN_FILE"
}

apply_netplan_checked(){
    netplan generate
    netplan apply
    sleep 3
    ip -4 addr show dev lan 2>/dev/null | grep -q "inet ${LAN_IP}/24" || return 1
    ip link show wan >/dev/null 2>&1 || return 1
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
    mapfile -t ifaces < <(detect_interfaces)
    (( ${#ifaces[@]} >= 2 )) || { error "Нужно минимум два физических интерфейса."; exit 1; }
    echo -e "${BOLD}Найдены физические интерфейсы:${NC}"; echo
    local i; for i in "${ifaces[@]}"; do print_iface "$i"; done
    echo

    LAN_IFACE=$(choose_iface_manual "Выберите LAN (локальная сеть)" "")
    success "LAN: ${LAN_IFACE}"
    echo
    WAN_IFACE=$(choose_iface_manual "Выберите WAN (интернет / провайдер)" "$LAN_IFACE")
    success "WAN: ${WAN_IFACE}"
    LAN_MAC=$(mac_of "$LAN_IFACE"); WAN_MAC=$(mac_of "$WAN_IFACE")

    echo; echo -e "${BOLD}Назначение:${NC}"; echo "  LAN: ${LAN_IFACE}  ${LAN_MAC}"; echo "  WAN: ${WAN_IFACE}  ${WAN_MAC}"; echo "  LAN IP: ${LAN_DEFAULT}/24"; echo
    confirm "Применить?" || exit 0

    backup_once
    LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"; DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; NAT_ENABLED=1; SUBSCRIPTION_URL=""; CLASH_SECRET=""
    write_config

    header "СЕТЕВОЙ ЭТАП · NETPLAN"
    write_netplan
    info "Проверяю Netplan..."; netplan generate; success "netplan generate — OK"
    if ! run_timed "Применение Netplan" apply_netplan_checked; then
        error "LAN ${LAN_IP}/24 не поднялся. DHCP не устанавливаю."
        echo "Проверьте:"; echo "  ip -br addr"; echo "  networkctl status"; echo "  journalctl -u systemd-networkd -n 50"
        exit 1
    fi
    success "LAN → ${LAN_IP}/24"; success "WAN → интерфейс ${WAN_IFACE}"

    configure_dnsmasq

    echo
    echo -e "${GREEN}${BOLD}Сетевой этап завершён.${NC}"
    echo
    warn "Текущее SSH-соединение может быть разорвано."
    echo "Подключите компьютер к LAN-порту и получите адрес по DHCP."
    echo; echo -e "Подключение: ${CYAN}ssh user@${LAN_IP}${NC}"; echo
    echo "После переподключения снова запустите скрипт."
    exit 0
}

# ----------------------------------------------------------------------------
# dnsmasq
# ----------------------------------------------------------------------------
configure_dnsmasq(){
    header "УСТАНОВКА · DHCP / DNSMASQ"
    [[ -f "$DNSMASQ_FILE" && ! -f "$ORIGINAL_DNSMASQ" ]] && cp -a "$DNSMASQ_FILE" "$ORIGINAL_DNSMASQ" || true
    if ! dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed'; then
        apt_install dnsmasq
    else
        success "dnsmasq уже установлен."
    fi
    cat > "$DNSMASQ_FILE" <<EOF2
interface=lan
bind-interfaces

dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h

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
After=sys-subsystem-net-devices-lan.device
EOF2
    systemctl daemon-reload
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    if ! run_timed "Запуск dnsmasq" systemctl restart dnsmasq; then
        journalctl -u dnsmasq -n 40 --no-pager || true
        return 1
    fi
    systemctl is-active --quiet dnsmasq || { error "dnsmasq не active."; return 1; }
    success "DHCP → ${DHCP_START}–${DHCP_END}"
    success "Gateway/DNS → ${LAN_IP}"
}

# ----------------------------------------------------------------------------
# NAT / nftables
# ----------------------------------------------------------------------------
write_nftables(){
    if [[ "$NAT_ENABLED" == "1" ]]; then
        cat > "$NFT_FILE" <<EOF2
#!/usr/sbin/nft -f

table inet gateway_filter {
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "lan" oifname "wan" accept
        iifname "wan" oifname "lan" ct state established,related accept
    }
}

table ip gateway_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wan" ip saddr ${LAN_IP%.*}.0/24 masquerade
    }
}
EOF2
    else
        cat > "$NFT_FILE" <<'EOF2'
#!/usr/sbin/nft -f

table inet gateway_filter {
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
EOF2
    fi
    chmod 644 "$NFT_FILE"
}

configure_nftables(){
    header "УСТАНОВКА · NFTABLES / NAT"
    if ! command -v nft >/dev/null 2>&1; then apt_install nftables; else success "nftables уже установлен."; fi
    [[ -f "$NFT_FILE" && ! -f "$ORIGINAL_NFT" ]] && cp -a "$NFT_FILE" "$ORIGINAL_NFT" || true
    write_nftables
    nft -c -f "$NFT_FILE" || { error "Ошибка синтаксиса nftables."; return 1; }
    success "Конфигурация nftables — OK"
    systemctl enable nftables >/dev/null 2>&1 || true
    run_timed "Применение nftables" nft -f "$NFT_FILE"
}

# ----------------------------------------------------------------------------
# Forwarding
# ----------------------------------------------------------------------------
configure_forwarding(){
    header "УСТАНОВКА · IPV4 FORWARDING"
    [[ -f "$SYSCTL_FILE" && ! -f "$ORIGINAL_SYSCTL" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL" || true
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] && success "IPv4 forwarding → active" || return 1
}

# ----------------------------------------------------------------------------
# Docker repository / engine
# ----------------------------------------------------------------------------
remove_docker_list_duplicate(){
    if [[ -f /etc/apt/sources.list.d/docker.list && -f /etc/apt/sources.list.d/docker.sources ]]; then
        info "Обнаружены docker.list и docker.sources — удаляю дубликат docker.list."
        rm -f /etc/apt/sources.list.d/docker.list
        success "Дубликат Docker repository удалён."
    fi
}

configure_docker_repo(){
    remove_docker_list_duplicate
    apt_install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        run_timed "Загрузка ключа Docker" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    . /etc/os-release
    local arch codename
    arch=$(dpkg --print-architecture); codename="${VERSION_CODENAME:-}"
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
    local engine_ok=0
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed' && systemctl cat docker.service >/dev/null 2>&1; then engine_ok=1; fi
    if (( engine_ok == 0 )); then
        info "Docker Engine отсутствует или установлен не полностью."
        configure_docker_repo
        run_timed "Установка Docker Engine + Compose" env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        success "Docker Engine уже установлен."
        remove_docker_list_duplicate
    fi
    systemctl daemon-reload
    systemctl enable --now docker.service >/dev/null
    if ! systemctl is-active --quiet docker.service; then
        systemctl status docker.service --no-pager -l || true
        return 1
    fi
    command -v docker >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1
    success "Docker Engine → active"
    success "Docker Compose → OK"
    success "Docker API → доступен"
}

# ----------------------------------------------------------------------------
# Secrets / subscription
# ----------------------------------------------------------------------------
random_secret(){ openssl rand -hex 32; }

prompt_secret(){
    header "УСТАНОВКА · ПАРОЛЬ MIHOMO API"
    local a b
    while true; do
        read -rsp "Введите пароль API (минимум 8 символов): " a; echo
        read -rsp "Повторите пароль: " b; echo
        [[ "$a" == "$b" ]] || { warn "Пароли не совпадают."; continue; }
        [[ ${#a} -ge 8 ]] || { warn "Минимум 8 символов."; continue; }
        [[ "$a" =~ ^[A-Za-z0-9@._-]+$ ]] || { warn "Допустимы A-Z a-z 0-9 @ . _ -."; continue; }
        CLASH_SECRET="$a"; break
    done
    write_config
    success "Пароль Mihomo API сохранён."
}

prompt_subscription_install(){
    header "УСТАНОВКА · ПОДПИСКА MIHOMO"
    if [[ -n "$SUBSCRIPTION_URL" && -f "$MIHOMO_CONFIG" ]]; then
        echo "Найдена существующая подписка."
        echo "  1) Использовать существующую"
        echo "  2) Ввести новую"
        echo
        local c; read -rp "Выбор [1-2]: " c
        [[ "$c" != 2 ]] && { success "Существующая подписка сохранена."; return; }
    fi
    while true; do
        read -rp "Ссылка на подписку: " SUBSCRIPTION_URL
        [[ "$SUBSCRIPTION_URL" =~ ^https?:// ]] || { warn "Нужна ссылка http:// или https://"; continue; }
        if curl -fsSL --max-time 10 -o /dev/null "$SUBSCRIPTION_URL"; then success "Ссылка доступна."; break; fi
        warn "Ссылка не проверена."
        confirm "Использовать её всё равно?" && break
    done
    write_config
}

# ----------------------------------------------------------------------------
# Mihomo config / Compose
# ----------------------------------------------------------------------------
render_mihomo_config(){
    [[ -n "$CLASH_SECRET" ]] || { error "Не задан CLASH_SECRET."; return 1; }
    [[ -n "$SUBSCRIPTION_URL" ]] || { error "Не задана подписка."; return 1; }
    mkdir -p "$MIHOMO_CONFIG_DIR/ruleset" "$MIHOMO_CONFIG_DIR/proxy_providers"
    local safe
    safe="${SUBSCRIPTION_URL//\\/\\\\}"; safe="${safe//\"/\\\"}"
    cat > "$MIHOMO_CONFIG" <<EOF2
mixed-port: 7890
allow-lan: true
bind-address: ${LAN_IP}

mode: rule
log-level: info
ipv6: false

external-controller: ${LAN_IP}:9090
secret: "${CLASH_SECRET}"

external-controller-cors:
  allow-origins:
    - "http://${LAN_IP}"
  allow-private-network: true

proxy-providers:
  subscription:
    type: http
    url: "${safe}"
    path: ./proxy_providers/subscription.yaml
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      timeout: 5000
      expected-status: 204

proxy-groups:
  - name: AUTO
    type: url-test
    include-all: true
    exclude-type: direct
    exclude-filter: "(?i)автовыбор|авто|auto|automatic|auto.?select"
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 150
    empty-fallback: COMPATIBLE
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Auto.png

  - name: PROXY
    type: select
    proxies:
      - AUTO
      - DIRECT
    default-selected: AUTO
    icon: https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Global.png

tun:
  enable: true
  stack: system
  auto-route: true
  auto-redirect: false
  auto-detect-interface: true
  route-exclude-address:
    - ${LAN_IP%.*}.0/24
    - 192.168.1.0/24
    - 1.1.1.1/32
    - 8.8.8.8/32

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

rule-providers:
  youtube:
    type: http
    behavior: domain
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/youtube.mrs"
    path: ./ruleset/youtube.mrs
    interval: 86400
  discord:
    type: http
    behavior: domain
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/discord.mrs"
    path: ./ruleset/discord.mrs
    interval: 86400
  discord-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/discord-ip.mrs"
    path: ./ruleset/discord-ip.mrs
    interval: 86400
  telegram:
    type: http
    behavior: domain
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/telegram.mrs"
    path: ./ruleset/telegram.mrs
    interval: 86400
  telegram-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/telegram-ip.mrs"
    path: ./ruleset/telegram-ip.mrs
    interval: 86400
  ai:
    type: http
    behavior: domain
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/ai.mrs"
    path: ./ruleset/ai.mrs
    interval: 86400
  category-geoblock-ru:
    type: http
    behavior: domain
    format: mrs
    url: "https://cdn.jsdelivr.net/gh/mvrvntn/routing@release/mihomo/category-geoblock-ru.mrs"
    path: ./ruleset/category-geoblock-ru.mrs
    interval: 86400

rules:
  - RULE-SET,youtube,PROXY
  - RULE-SET,discord,PROXY
  - RULE-SET,discord-ip,PROXY,no-resolve
  - RULE-SET,telegram,PROXY
  - RULE-SET,telegram-ip,PROXY,no-resolve
  - RULE-SET,ai,PROXY
  - RULE-SET,category-geoblock-ru,PROXY
  - MATCH,DIRECT
EOF2
    chmod 600 "$MIHOMO_CONFIG"
}

create_compose(){
    cat > "$COMPOSE_FILE" <<'EOF2'
services:
  mihomo:
    image: metacubex/mihomo:latest
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

  metacubexd:
    image: ghcr.io/metacubex/metacubexd:latest
    container_name: metacubexd
    restart: unless-stopped
    network_mode: host
    environment:
      DEFAULT_BACKEND_URL: ${DEFAULT_BACKEND_URL}
      TZ: ${TZ}
EOF2
    success "Создан compose.yaml"
}

create_env(){
    mkdir -p "$PROJECT_DIR"
    [[ -f "$ENV_FILE" ]] || cat > "$ENV_FILE" <<EOF2
TZ=Europe/Moscow
DEFAULT_BACKEND_URL=http://${LAN_IP}:9090
EOF2
    chmod 600 "$ENV_FILE"
}

validate_config(){
    header "ПРОВЕРКА · MIHOMO"
    run_timed "Проверка конфигурации Mihomo" docker run --rm --network host --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun -v "${MIHOMO_CONFIG_DIR}:/root/.config/mihomo" metacubex/mihomo:latest -d /root/.config/mihomo -t
}

# ----------------------------------------------------------------------------
# Health / status
# ----------------------------------------------------------------------------
service_dot(){ local v="$1"; [[ "$v" == ok ]] && echo -e "${GREEN}●${NC} OK" || echo -e "${RED}●${NC} $v"; }

check_api(){
    [[ -n "$CLASH_SECRET" ]] || return 1
    curl -fsS --max-time 3 -H "Authorization: Bearer ${CLASH_SECRET}" "http://${LAN_IP}:9090/version" >/dev/null 2>&1
}
check_ui(){ curl -fsS --max-time 3 "http://${LAN_IP}/" >/dev/null 
