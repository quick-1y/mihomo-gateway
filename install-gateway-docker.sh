#!/usr/bin/env bash
set -Eeuo pipefail

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

# Mihomo configuration template stored separately in the repository.
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly MIHOMO_TEMPLATE_LOCAL="${SCRIPT_DIR}/mihomo/config.yaml"
readonly MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/quick-1y/mihomo-gateway/main/mihomo/config.yaml"
readonly MIHOMO_TEMPLATE_CACHE="/tmp/mihomo-gateway-config.yaml"
readonly LAN_DEFAULT="192.168.100.1"
readonly DHCP_START_DEFAULT="192.168.100.100"
readonly DHCP_END_DEFAULT="192.168.100.250"
readonly DNS1_DEFAULT="1.1.1.1"
readonly DNS2_DEFAULT="8.8.8.8"
readonly PPPOE_SERVICE="mihomo-gateway-pppoe.service"
readonly PPPOE_PEER="/etc/ppp/peers/mihomo-gateway"
readonly PPPOE_CHAP="/etc/ppp/chap-secrets"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

LAN_IFACE=""; WAN_IFACE=""; LAN_MAC=""; WAN_MAC=""
LAN_IP="$LAN_DEFAULT"; DHCP_START="$DHCP_START_DEFAULT"; DHCP_END="$DHCP_END_DEFAULT"
DNS1="$DNS1_DEFAULT"; DNS2="$DNS2_DEFAULT"; CLASH_SECRET=""; SUBSCRIPTION_URL=""
NAT_ENABLED="1"
WAN_MODE="dhcp"
PPPOE_USERNAME=""
PPPOE_PASSWORD=""

info(){ echo -e "${BLUE}[i]${NC} $*"; }
success(){ echo -e "${GREEN}[✓]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
error(){ echo -e "${RED}[✗]${NC} $*" >&2; }

header(){
    echo
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo
}

confirm(){ local a; read -rp "$(echo -e "${YELLOW}${1:-Продолжить?} [y/N]: ${NC}")" a; [[ "$a" =~ ^[YyДд]$ ]]; }
press_enter(){ read -rp "Нажмите Enter..." _ || true; }
need_root(){ [[ $EUID -eq 0 ]] || { error "Запустите: sudo bash $0"; exit 1; }; }

on_error(){
    local rc=$?
    error "Скрипт остановился с ошибкой (код ${rc})."
    exit "$rc"
}
trap on_error ERR

run_timed(){
    local label="$1"; shift
    local log; log=$(mktemp /tmp/mgw-run.XXXXXX)
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

get_os_release_value(){
    local key="$1"
    local value
    value=$(grep -E "^[[:space:]]*${key}=" /etc/os-release 2>/dev/null | head -n1 | sed -E 's/^[^=]+=//' || true)
    value="${value#\"}"
    value="${value%\"}"
    printf '%s' "$value"
}

check_os(){
    [[ -f /etc/os-release ]] || { error "Не найден /etc/os-release"; exit 1; }
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
    local packages=("$@")
    apt_update_safe
    run_timed "Установка пакетов: ${packages[*]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

write_config(){
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    {
        printf 'LAN_IP=%q\n' "$LAN_IP"
        printf 'DHCP_START=%q\n' "$DHCP_START"
        printf 'DHCP_END=%q\n' "$DHCP_END"
        printf 'DNS1=%q\n' "$DNS1"
        printf 'DNS2=%q\n' "$DNS2"
        printf 'LAN_IFACE=%q\n' "$LAN_IFACE"
        printf 'WAN_IFACE=%q\n' "$WAN_IFACE"
        printf 'LAN_MAC=%q\n' "$LAN_MAC"
        printf 'WAN_MAC=%q\n' "$WAN_MAC"
        printf 'NAT_ENABLED=%q\n' "$NAT_ENABLED"
        printf 'WAN_MODE=%q\n' "$WAN_MODE"
        printf 'PPPOE_USERNAME=%q\n' "$PPPOE_USERNAME"
        printf 'PPPOE_PASSWORD=%q\n' "$PPPOE_PASSWORD"
        printf 'SUBSCRIPTION_URL=%q\n' "$SUBSCRIPTION_URL"
        printf 'CLASH_SECRET=%q\n' "$CLASH_SECRET"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}


load_config(){
    [[ -f "$CONFIG_FILE" ]] || return 1
    . "$CONFIG_FILE"
    LAN_IP="${LAN_IP:-$LAN_DEFAULT}"
    DHCP_START="${DHCP_START:-$DHCP_START_DEFAULT}"
    DHCP_END="${DHCP_END:-$DHCP_END_DEFAULT}"
    DNS1="${DNS1:-$DNS1_DEFAULT}"
    DNS2="${DNS2:-$DNS2_DEFAULT}"
    NAT_ENABLED="${NAT_ENABLED:-1}"
    WAN_MODE="${WAN_MODE:-dhcp}"
    PPPOE_USERNAME="${PPPOE_USERNAME:-}"
    PPPOE_PASSWORD="${PPPOE_PASSWORD:-}"
    SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-}"
    CLASH_SECRET="${CLASH_SECRET:-}"
    LAN_IFACE="${LAN_IFACE:-}"
    WAN_IFACE="${WAN_IFACE:-}"
    LAN_MAC="${LAN_MAC:-}"
    WAN_MAC="${WAN_MAC:-}"
    [[ "$WAN_MODE" == "pppoe" || "$WAN_MODE" == "dhcp" ]] || WAN_MODE="dhcp"
    return 0
}


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
    local i="$1"
    local mac state speed link
    mac=$(mac_of "$i")
    state=$(state_of "$i")
    speed=$(speed_of "$i")
    if carrier_of "$i"; then link="connected"; else link="disconnected"; fi
    printf '%s  MAC: %s  State: %s  Link: %s  Speed: %s' "$i" "$mac" "$state" "$link" "$speed"
}

choose_iface_manual(){
    local prompt="$1" exclude="${2:-}"
    local arr=() i n idx j chosen
    mapfile -t arr < <(detect_interfaces)

    {
        echo
        echo -e "${BOLD}Найдены физические интерфейсы:${NC}"
        echo
        n=1
        for i in "${arr[@]}"; do
            [[ "$i" == "$exclude" ]] && continue
            printf '  %d) ' "$n"
            print_iface "$i"
            printf '\n'
            n=$((n+1))
        done
        echo
    } >&2

    while true; do
        read -rp "$(echo -e "${BOLD}${prompt}: ${NC}")" n
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "Введите номер."; continue; }
        idx=0; chosen=""
        for j in "${arr[@]}"; do
            [[ "$j" == "$exclude" ]] && continue
            idx=$((idx+1))
            if [[ "$idx" -eq "$n" ]]; then chosen="$j"; break; fi
        done
        if [[ -n "$chosen" ]]; then echo "$chosen"; return 0; fi
        warn "Нет такого пункта."
    done
}

backup_once(){
    mkdir -p "$ORIGINAL_NETPLAN_DIR"
    chmod 700 "$ORIGINAL_DIR"
    if [[ ! -f "${ORIGINAL_DIR}/BACKUP_DONE" ]]; then
        local f base
        shopt -s nullglob
        for f in /etc/netplan/*.yaml; do
            base=$(basename "$f")
            cp -a "$f" "${ORIGINAL_NETPLAN_DIR}/${base}"
            mv "$f" "${f}.gateway-disabled"
        done
        shopt -u nullglob
        [[ -f "$DNSMASQ_FILE" ]] && cp -a "$DNSMASQ_FILE" "$ORIGINAL_DNSMASQ" || true
        [[ -f "$NFT_FILE" ]] && cp -a "$NFT_FILE" "$ORIGINAL_NFT" || true
        [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL" || true
        echo "NETWORK_BACKUP_DONE=1" > "${ORIGINAL_DIR}/BACKUP_DONE"
        success "Исходные конфигурации сохранены."
    fi
}

write_netplan(){
    mkdir -p /etc/netplan
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        cat > "$NETPLAN_FILE" <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    lan:
      match:
        macaddress: ${LAN_MAC}
      set-name: lan
      optional: true
      addresses:
        - ${LAN_IP}/24
    wan:
      match:
        macaddress: ${WAN_MAC}
      set-name: wan
      optional: true
      dhcp4: false
EOF2
    else
        cat > "$NETPLAN_FILE" <<EOF2
network:
  version: 2
  renderer: networkd
  ethernets:
    lan:
      match:
        macaddress: ${LAN_MAC}
      set-name: lan
      optional: true
      addresses:
        - ${LAN_IP}/24
    wan:
      match:
        macaddress: ${WAN_MAC}
      set-name: wan
      optional: true
      dhcp4: true
EOF2
    fi
    chmod 600 "$NETPLAN_FILE"
}


apply_netplan_checked(){
    netplan generate || return 1
    netplan apply    || return 1
    sleep 3
    ip link show lan >/dev/null 2>&1 || return 1
    ip link show wan >/dev/null 2>&1 || return 1
    return 0
}

pppoe_configured(){
    [[ -f "$PPPOE_PEER" && -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]]
}

pppoe_stop(){
    systemctl stop "$PPPOE_SERVICE" 2>/dev/null || true
    sleep 1
    if pgrep -af 'pppd.*mihomo-gateway' >/dev/null 2>&1; then
        pkill -TERM -f 'pppd.*mihomo-gateway' 2>/dev/null || true
        sleep 1
    fi
}

pppoe_escape(){
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_pppoe_config(){
    [[ "$WAN_MODE" == "pppoe" ]] || return 0
    [[ -n "$PPPOE_USERNAME" ]] || { error "Не задан PPPoE логин."; return 1; }
    [[ -n "$PPPOE_PASSWORD" ]] || { error "Не задан PPPoE пароль."; return 1; }
    [[ -n "$WAN_IFACE" ]] || { error "Не задан WAN интерфейс."; return 1; }

    apt_install ppp pppoe
    mkdir -p /etc/ppp/peers
    chmod 700 /etc/ppp/peers

    if [[ -f "$PPPOE_CHAP" && ! -f "${ORIGINAL_DIR}/chap-secrets" ]]; then
        mkdir -p "$ORIGINAL_DIR"
        cp -a "$PPPOE_CHAP" "${ORIGINAL_DIR}/chap-secrets"
    fi

    local user_escaped pass_escaped
    user_escaped=$(pppoe_escape "$PPPOE_USERNAME")
    pass_escaped=$(pppoe_escape "$PPPOE_PASSWORD")

    touch "$PPPOE_CHAP"
    chmod 600 "$PPPOE_CHAP"
    sed -i '/^# mihomo-gateway-pppoe$/,+1d' "$PPPOE_CHAP" 2>/dev/null || true
    {
        echo '# mihomo-gateway-pppoe'
        printf '"%s" * "%s" *\n' "$user_escaped" "$pass_escaped"
    } >> "$PPPOE_CHAP"

    cat > "$PPPOE_PEER" <<EOF2
plugin rp-pppoe.so ${WAN_IFACE}
user "${user_escaped}"
persist
maxfail 0
holdoff 5
noauth
defaultroute
replacedefaultroute
usepeerdns
mtu 1492
mru 1492
lcp-echo-interval 20
lcp-echo-failure 3
noipdefault
EOF2
    chmod 600 "$PPPOE_PEER"

    cat > "/etc/systemd/system/${PPPOE_SERVICE}" <<EOF2
[Unit]
Description=Mihomo Gateway PPPoE connection
Wants=network-online.target
After=network-online.target systemd-networkd.service
BindsTo=sys-subsystem-net-devices-wan.device
After=sys-subsystem-net-devices-wan.device

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call mihomo-gateway nodetach
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=5
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload
    systemctl enable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
}

pppoe_start(){
    [[ "$WAN_MODE" == "pppoe" ]] || return 0
    write_pppoe_config || return 1
    pppoe_stop
    systemctl restart "$PPPOE_SERVICE"
    local i
    for i in {1..20}; do
        if ip link show ppp0 >/dev/null 2>&1 && ip -4 addr show dev ppp0 | grep -q 'inet '; then
            success "PPPoE → ppp0 активен ($(ip -4 -o addr show dev ppp0 | awk '{print $4}' | head -n1))"
            return 0
        fi
        sleep 1
    done
    error "PPPoE не поднялся за 20 секунд."
    journalctl -u "$PPPOE_SERVICE" -n 40 --no-pager || true
    return 1
}

configure_pppoe(){
    header "УСТАНОВКА · PPPOE"
    if [[ "$WAN_MODE" != "pppoe" ]]; then
        pppoe_stop
        systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
        return 0
    fi
    pppoe_start
}

wan_mode_menu(){
    while true; do
        header "НАСТРОЙКИ · WAN / ИНТЕРНЕТ"
        echo "Текущий режим: ${WAN_MODE^^}"
        if [[ "$WAN_MODE" == "pppoe" ]]; then
            echo "PPPoE логин: ${PPPOE_USERNAME:-не задан}"
            echo "PPPoE service: $(systemctl is-active "$PPPOE_SERVICE" 2>/dev/null || echo inactive)"
            if ip link show ppp0 >/dev/null 2>&1; then
                echo "ppp0: $(ip -4 -o addr show dev ppp0 | awk '{print $4}' | head -n1 || true)"
            fi
        fi
        echo
        echo "  1) DHCP"
        echo "  2) PPPoE"
        echo "  3) Назад"
        echo
        local c old_mode old_user old_pass user pass
        read -rp "Выбор [1-3]: " c
        case "$c" in
            1)
                old_mode="$WAN_MODE"; old_user="$PPPOE_USERNAME"; old_pass="$PPPOE_PASSWORD"
                WAN_MODE="dhcp"
                if apply_generated; then
                    success "WAN переключён на DHCP."
                else
                    WAN_MODE="$old_mode"; PPPOE_USERNAME="$old_user"; PPPOE_PASSWORD="$old_pass"; write_config
                    warn "Переключение не применено."
                fi
                press_enter
                ;;
            2)
                old_mode="$WAN_MODE"; old_user="$PPPOE_USERNAME"; old_pass="$PPPOE_PASSWORD"
                read -rp "PPPoE логин [${PPPOE_USERNAME}]: " user
                [[ -n "$user" ]] && PPPOE_USERNAME="$user"
                read -rsp "PPPoE пароль (Enter = оставить текущий): " pass; echo
                [[ -n "$pass" ]] && PPPOE_PASSWORD="$pass"
                if [[ -z "$PPPOE_USERNAME" || -z "$PPPOE_PASSWORD" ]]; then
                    error "Логин и пароль обязательны."
                    PPPOE_USERNAME="$old_user"; PPPOE_PASSWORD="$old_pass"
                    press_enter
                    continue
                fi
                WAN_MODE="pppoe"
                if apply_generated; then
                    success "WAN переключён на PPPoE."
                else
                    WAN_MODE="$old_mode"; PPPOE_USERNAME="$old_user"; PPPOE_PASSWORD="$old_pass"; write_config
                    warn "Переключение не применено."
                fi
                press_enter
                ;;
            3) return ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

pppoe_credentials_menu(){
    header "НАСТРОЙКИ · PPPOE"
    echo "Режим WAN: ${WAN_MODE^^}"
    echo "Текущий логин: ${PPPOE_USERNAME:-не задан}"
    echo
    local old_user="$PPPOE_USERNAME" old_pass="$PPPOE_PASSWORD" user pass
    read -rp "Новый PPPoE логин [${PPPOE_USERNAME}]: " user
    [[ -n "$user" ]] && PPPOE_USERNAME="$user"
    read -rsp "Новый PPPoE пароль (Enter = оставить текущий): " pass; echo
    [[ -n "$pass" ]] && PPPOE_PASSWORD="$pass"
    if [[ -z "$PPPOE_USERNAME" || -z "$PPPOE_PASSWORD" ]]; then
        PPPOE_USERNAME="$old_user"; PPPOE_PASSWORD="$old_pass"
        error "Логин и пароль должны быть заданы."
        return
    fi
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        if apply_generated; then
            success "PPPoE данные сохранены и соединение перезапущено."
        else
            PPPOE_USERNAME="$old_user"; PPPOE_PASSWORD="$old_pass"; write_config
            warn "PPPoE данные не применены."
        fi
    else
        write_config
        success "PPPoE данные сохранены."
    fi
}

configure_network_first(){
    header "ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА СЕТИ"
    echo "Будут настроены:"
    echo
    echo "  LAN  → ${LAN_DEFAULT}/24"
    echo "  DHCP → ${DHCP_START_DEFAULT}–${DHCP_END_DEFAULT}"
    echo
    warn "После применения Netplan SSH может быть разорван."
    confirm "Начать сетевую настройку?" || exit 0

    header "СЕТЕВОЙ ЭТАП · ВЫБОР LAN / WAN"
    local ifaces=()
    mapfile -t ifaces < <(detect_interfaces)
    (( ${#ifaces[@]} >= 2 )) || { error "Нужно минимум два физических интерфейса."; exit 1; }

    LAN_IFACE=$(choose_iface_manual "Выберите LAN (локальная сеть)" "")
    success "LAN: ${LAN_IFACE}"
    echo
    WAN_IFACE=$(choose_iface_manual "Выберите WAN (интернет / провайдер)" "$LAN_IFACE")
    success "WAN: ${WAN_IFACE}"
    LAN_MAC=$(mac_of "$LAN_IFACE"); WAN_MAC=$(mac_of "$WAN_IFACE")

    if ! carrier_of "$WAN_IFACE"; then
        warn "На ${WAN_IFACE} не обнаружен линк (carrier)."
        confirm "Всё равно использовать как WAN?" || exit 0
    fi

    header "СЕТЕВОЙ ЭТАП · РЕЖИМ WAN"
    echo "  1) DHCP — если провайдер выдаёт адрес автоматически"
    echo "  2) PPPoE — если провайдер требует логин и пароль"
    echo
    local mode
    while true; do
        read -rp "Выберите режим [1-2]: " mode
        case "$mode" in
            1) WAN_MODE="dhcp"; PPPOE_USERNAME=""; PPPOE_PASSWORD=""; break ;;
            2) WAN_MODE="pppoe"; break ;;
            *) warn "Введите 1 или 2." ;;
        esac
    done

    if [[ "$WAN_MODE" == "pppoe" ]]; then
        read -rp "PPPoE логин: " PPPOE_USERNAME
        read -rsp "PPPoE пароль: " PPPOE_PASSWORD; echo
        [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]] || { error "Логин и пароль обязательны."; exit 1; }
    fi

    echo
    echo -e "${BOLD}Назначение:${NC}"
    echo "  LAN: ${LAN_IFACE}  ${LAN_MAC}"
    echo "  WAN: ${WAN_IFACE}  ${WAN_MAC}"
    echo "  WAN mode: ${WAN_MODE^^}"
    [[ "$WAN_MODE" == "pppoe" ]] && echo "  PPPoE user: ${PPPOE_USERNAME}"
    echo "  LAN IP: ${LAN_DEFAULT}/24"
    echo
    confirm "Применить?" || exit 0

    backup_once
    LAN_IP="$LAN_DEFAULT"
    DHCP_START="$DHCP_START_DEFAULT"
    DHCP_END="$DHCP_END_DEFAULT"
    DNS1="$DNS1_DEFAULT"
    DNS2="$DNS2_DEFAULT"
    NAT_ENABLED=1
    SUBSCRIPTION_URL=""
    CLASH_SECRET=""
    write_config

    header "СЕТЕВОЙ ЭТАП · NETPLAN"
    write_netplan
    netplan generate
    success "netplan generate — OK"

    echo
    echo "  ${LAN_IFACE} → lan   (${LAN_IP}/24)"
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        echo "  ${WAN_IFACE} → wan   (PPPoE → ppp0)"
    else
        echo "  ${WAN_IFACE} → wan   (DHCP)"
    fi
    echo
    warn "SSH-сессия может быть разорвана."
    confirm "Применить Netplan сейчас?" || { warn "Отменено. Netplan не применён."; exit 0; }

    if ! run_timed "Применение Netplan" apply_netplan_checked; then
        error "Netplan не применился. Проверьте:"
        echo "  ip -br addr"
        echo "  networkctl status"
        echo "  journalctl -u systemd-networkd -n 50"
        exit 1
    fi

    if [[ "$WAN_MODE" == "pppoe" ]]; then
        configure_pppoe || { error "PPPoE не настроен/не подключён."; exit 1; }
    fi
    configure_dnsmasq

    if carrier_of lan; then
        warn "На LAN-порту есть линк. Если SSH идёт через него — соединение оборвётся."
        echo "Переподключитесь на новом адресе и запустите скрипт снова:"
        echo -e "  ${CYAN}ssh user@${LAN_IP}${NC}"
        exit 0
    fi

    info "LAN-порт не подключён — это нормально."
    info "DHCP (bind-dynamic) подхватит LAN автоматически, когда будет подключён кабель."
    info "Продолжаю установку..."
}


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
bind-dynamic

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

[Service]
Restart=always
RestartSec=5
EOF2

    systemctl daemon-reload
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    if ! run_timed "Запуск dnsmasq" systemctl restart dnsmasq; then
        journalctl -u dnsmasq -n 40 --no-pager || true
        return 1
    fi
    systemctl is-active --quiet dnsmasq || { error "dnsmasq не active."; return 1; }
    success "DHCP → ${DHCP_START}–${DHCP_END} (bind-dynamic)"
    success "Gateway/DNS → ${LAN_IP}"
}

write_nftables(){
    local out_if="wan"
    [[ "$WAN_MODE" == "pppoe" ]] && out_if="ppp0"
    if [[ "$NAT_ENABLED" == "1" ]]; then
        cat > "$NFT_FILE" <<EOF2
#!/usr/sbin/nft -f

table inet gateway_filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "wan" tcp dport { 80, 7890, 9090 } drop
    iifname "wan" udp dport 7890 drop
    iifname "${out_if}" tcp dport { 80, 7890, 9090 } drop
    iifname "${out_if}" udp dport 7890 drop
  }

  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "lan" oifname "${out_if}" accept
    iifname "${out_if}" oifname "lan" ct state established,related accept
  }
}

table ip gateway_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "${out_if}" ip saddr ${LAN_IP%.*}.0/24 masquerade
  }
}
EOF2
    else
        cat > "$NFT_FILE" <<EOF2
#!/usr/sbin/nft -f

table inet gateway_filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "wan" tcp dport { 80, 7890, 9090 } drop
    iifname "wan" udp dport 7890 drop
    iifname "${out_if}" tcp dport { 80, 7890, 9090 } drop
    iifname "${out_if}" udp dport 7890 drop
  }

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
    run_timed "Применение nftables" systemctl restart nftables
}

configure_forwarding(){
    header "УСТАНОВКА · IPV4 FORWARDING"
    [[ -f "$SYSCTL_FILE" && ! -f "$ORIGINAL_SYSCTL" ]] && cp -a "$SYSCTL_FILE" "$ORIGINAL_SYSCTL" || true
    echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] && success "IPv4 forwarding → active" || return 1
}

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
        run_timed "Загрузка ключа Docker" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
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
}

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

render_mihomo_config(){
    [[ -n "$CLASH_SECRET" ]] || { error "Не задан CLASH_SECRET."; return 1; }
    [[ -n "$SUBSCRIPTION_URL" ]] || { error "Не задана подписка."; return 1; }

    local template
    template="$MIHOMO_TEMPLATE_LOCAL"

    # Support both:
    #   1. running from a cloned repository;
    #   2. downloading only install-gateway-docker.sh via curl.
    if [[ ! -f "$template" ]]; then
        info "Шаблон Mihomo не найден локально. Загружаю его из GitHub..."
        run_timed "Загрузка шаблона Mihomo" curl -fsSL --max-time 20 -o "$MIHOMO_TEMPLATE_CACHE" "$MIHOMO_TEMPLATE_URL" || {
            error "Не удалось загрузить mihomo/config.yaml."
            error "Для запуска из клонированного репозитория файл должен находиться: $MIHOMO_TEMPLATE_LOCAL"
            return 1
        }
        template="$MIHOMO_TEMPLATE_CACHE"
    fi

    # Validate the template before touching the active configuration.
    local required marker
    for marker in \
        "__LAN_IP__" \
        "__LAN_NETWORK__" \
        "__CLASH_SECRET__" \
        "__SUBSCRIPTION_URL__"; do
        grep -Fq "$marker" "$template" || {
            error "В шаблоне Mihomo отсутствует обязательный placeholder: ${marker}"
            return 1
        }
    done

    mkdir -p "$MIHOMO_CONFIG_DIR/ruleset" "$MIHOMO_CONFIG_DIR/proxy_providers"

    local lan_network
    lan_network="${LAN_IP%.*}.0/24"

    # Python is intentionally not required: use awk for literal placeholder
    # replacement. Values are encoded as shell variables and escaped for awk.
    # This safely handles &, backslashes, quotes, slashes and URL characters.
    local escaped_lan_ip escaped_lan_network escaped_secret escaped_url
    escaped_lan_ip=$(printf '%s' "$LAN_IP" | sed 's/[\\&|]/\\&/g')
    escaped_lan_network=$(printf '%s' "$lan_network" | sed 's/[\\&|]/\\&/g')
    escaped_secret=$(printf '%s' "$CLASH_SECRET" | sed 's/[\\&|]/\\&/g')
    escaped_url=$(printf '%s' "$SUBSCRIPTION_URL" | sed 's/[\\&|]/\\&/g')

    sed \
        -e "s|__LAN_IP__|${escaped_lan_ip}|g" \
        -e "s|__LAN_NETWORK__|${escaped_lan_network}|g" \
        -e "s|__CLASH_SECRET__|${escaped_secret}|g" \
        -e "s|__SUBSCRIPTION_URL__|${escaped_url}|g" \
        "$template" > "$MIHOMO_CONFIG"

    chmod 600 "$MIHOMO_CONFIG"

    # Never leave a downloaded copy containing configuration placeholders/values
    # behind after rendering.
    [[ "$template" == "$MIHOMO_TEMPLATE_CACHE" ]] && rm -f "$MIHOMO_TEMPLATE_CACHE"

    # Final sanity check: no template markers may remain in the generated file.
    if grep -Eq '__[A-Z0-9_]+__' "$MIHOMO_CONFIG"; then
        error "В сгенерированном config.yaml остались не заменённые placeholders."
        return 1
    fi

    success "Конфигурация Mihomo сгенерирована из отдельного шаблона."
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

service_dot(){ local v="$1"; [[ "$v" == ok ]] && echo -e "${GREEN}●${NC} OK" || echo -e "${RED}●${NC} $v"; }

check_api(){
    [[ -n "$CLASH_SECRET" ]] || return 1
    curl -fsS --max-time 3 -H "Authorization: Bearer ${CLASH_SECRET}" "http://127.0.0.1:9090/version" >/dev/null 2>&1
}
check_ui(){ curl -fsS --max-time 3 "http://127.0.0.1/" >/dev/null 2>&1; }
check_tun(){ ip link show Meta >/dev/null 2>&1 || ip link show meta >/dev/null 2>&1; }
check_container(){ docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | grep -qx running; }

quick_status(){
    load_config || true
    echo -e "${BOLD}Состояние:${NC}"
    network_is_ready && echo -e "  Сеть          $(service_dot ok)" || echo -e "  Сеть          $(service_dot FAIL)"
    echo -e "  WAN mode      ${CYAN}${WAN_MODE^^}${NC}"
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        systemctl is-active --quiet "$PPPOE_SERVICE" 2>/dev/null && echo -e "  PPPoE         $(service_dot ok)" || echo -e "  PPPoE         $(service_dot FAIL)"
        ip -4 addr show ppp0 2>/dev/null | grep -q 'inet ' && echo -e "  ppp0          $(service_dot ok)" || echo -e "  ppp0          $(service_dot FAIL)"
    fi
    systemctl is-active --quiet dnsmasq 2>/dev/null && echo -e "  DHCP          $(service_dot ok)" || echo -e "  DHCP          $(service_dot FAIL)"
    [[ -f "$NFT_FILE" ]] && nft list table ip gateway_nat >/dev/null 2>&1 && echo -e "  NAT           $(service_dot ok)" || echo -e "  NAT           $(service_dot OFF)"
    systemctl is-active --quiet docker 2>/dev/null && echo -e "  Docker        $(service_dot ok)" || echo -e "  Docker        $(service_dot FAIL)"
    check_container mihomo && echo -e "  Mihomo        $(service_dot ok)" || echo -e "  Mihomo        $(service_dot FAIL)"
    check_container metacubexd && echo -e "  MetaCubeXD    $(service_dot ok)" || echo -e "  MetaCubeXD    $(service_dot FAIL)"
    check_api && echo -e "  API :9090     $(service_dot ok)" || echo -e "  API :9090     $(service_dot FAIL)"
    check_ui && echo -e "  Панель :80    $(service_dot ok)" || echo -e "  Панель :80    $(service_dot FAIL)"
}


network_is_ready(){
    [[ -f "$CONFIG_FILE" ]] || return 1
    [[ -f "$NETPLAN_FILE" ]] || return 1
    systemctl is-active --quiet dnsmasq 2>/dev/null || return 1
    grep -q "dhcp-range=${DHCP_START},${DHCP_END}" "$DNSMASQ_FILE" 2>/dev/null || return 1
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        [[ -f "$PPPOE_PEER" ]] || return 1
        systemctl is-enabled --quiet "$PPPOE_SERVICE" 2>/dev/null || return 1
    fi
    return 0
}


full_diagnostics(){
    header "ПОЛНАЯ ДИАГНОСТИКА / СТАТУСЫ"
    load_config || true
    echo -e "${BOLD}СЕТЬ${NC}"
    echo "  LAN интерфейс: ${LAN_IFACE:-unknown}"
    echo "  LAN адрес:     ${LAN_IP}/24"
    echo "  WAN интерфейс: ${WAN_IFACE:-unknown}"
    echo "  WAN режим:     ${WAN_MODE^^}"
    echo "  DHCP:          ${DHCP_START}–${DHCP_END}"
    echo "  DNS upstream:  ${DNS1}, ${DNS2}"
    echo
    ip -br addr show lan 2>/dev/null || true
    ip -br addr show wan 2>/dev/null || true
    if [[ "$WAN_MODE" == "pppoe" ]]; then
        ip -br addr show ppp0 2>/dev/null || true
        echo "  PPPoE service: $(systemctl is-active "$PPPOE_SERVICE" 2>/dev/null || echo inactive)"
        echo "  PPPoE user:    ${PPPOE_USERNAME:-not set}"
        echo "  Default route:"
        ip -4 route show default 2>/dev/null || true
    fi
    echo
    echo -e "${BOLD}СЕРВИСЫ ХОСТА${NC}"
    systemctl is-active --quiet dnsmasq && echo -e "  dnsmasq        ${GREEN}active${NC}" || echo -e "  dnsmasq        ${RED}inactive${NC}"
    systemctl is-active --quiet nftables && echo -e "  nftables       ${GREEN}active${NC}" || echo -e "  nftables       ${RED}inactive${NC}"
    systemctl is-active --quiet docker && echo -e "  docker         ${GREEN}active${NC}" || echo -e "  docker         ${RED}inactive${NC}"
    [[ "$WAN_MODE" == "pppoe" ]] && { systemctl is-active --quiet "$PPPOE_SERVICE" && echo -e "  pppoe          ${GREEN}active${NC}" || echo -e "  pppoe          ${RED}inactive${NC}"; }
    echo
    echo -e "${BOLD}DOCKER${NC}"
    docker --version 2>/dev/null || echo "  Engine: отсутствует"
    docker compose version 2>/dev/null || echo "  Compose: отсутствует"
    echo
    echo -e "${BOLD}КОНТЕЙНЕРЫ${NC}"
    local c st
    for c in mihomo metacubexd; do
        st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo not-found)
        echo "  ${c}: ${st}"
    done
    echo
    echo -e "${BOLD}MIHOMO${NC}"
    echo "  API:        http://${LAN_IP}:9090"
    echo "  Proxy:      ${LAN_IP}:7890"
    echo "  TUN:        $(check_tun && echo active || echo 'not found')"
    check_api && echo -e "  API check:  ${GREEN}OK${NC}" || echo -e "  API check:  ${RED}FAIL${NC}"
    echo
    echo -e "${BOLD}ПАНЕЛЬ${NC}"
    echo "  URL:        http://${LAN_IP}/"
    check_ui && echo -e "  HTTP check: ${GREEN}OK${NC}" || echo -e "  HTTP check: ${RED}FAIL${NC}"
    echo
    echo -e "${BOLD}NAT${NC}"
    if [[ "$NAT_ENABLED" == 1 ]]; then echo -e "  Состояние:  ${GREEN}включён${NC}"; else echo -e "  Состояние:  ${YELLOW}выключен${NC}"; fi
    local out_if="wan"; [[ "$WAN_MODE" == "pppoe" ]] && out_if="ppp0"
    echo "  LAN → WAN:  ${LAN_IP%.*}.0/24 → ${out_if}"
}


restart_stack(){
    ( cd "$PROJECT_DIR" && docker compose up -d --remove-orphans )
}

apply_generated(){
    pppoe_stop
    write_config
    write_netplan
    netplan generate || return 1
    run_timed "Применение Netplan" apply_netplan_checked || return 1

    if [[ "$WAN_MODE" == "pppoe" ]]; then
        configure_pppoe || return 1
    else
        systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    fi

    write_nftables
    nft -c -f "$NFT_FILE" || return 1
    run_timed "Применение nftables" systemctl restart nftables || return 1
    configure_dnsmasq || return 1
    write_config

    if [[ -f "$MIHOMO_CONFIG" && -n "$CLASH_SECRET" && -n "$SUBSCRIPTION_URL" ]]; then
        render_mihomo_config || return 1
        ( cd "$PROJECT_DIR" && docker compose up -d --remove-orphans )
    fi
}


subscription_menu(){
    while true; do
        header "НАСТРОЙКИ · ПОДПИСКА MIHOMO"
        if [[ -n "$SUBSCRIPTION_URL" ]]; then echo "Текущая: ${SUBSCRIPTION_URL:0:80}"; else echo "Текущая: не задана"; fi
        echo
        echo "  1) Добавить / изменить ссылку"
        echo "  2) Проверить доступность"
        echo "  3) Удалить подписку"
        echo "  4) Назад"
        echo
        local c; read -rp "Выбор [1-4]: " c
        case "$c" in
            1) prompt_subscription_install; [[ -n "$SUBSCRIPTION_URL" ]] && { render_mihomo_config; restart_stack; } ;;
            2) if [[ -n "$SUBSCRIPTION_URL" ]] && curl -fsSL --max-time 10 -o /dev/null "$SUBSCRIPTION_URL"; then success "Подписка доступна."; else error "Подписка недоступна."; fi ;;
            3) if confirm "Удалить ссылку подписки?"; then SUBSCRIPTION_URL=""; write_config; warn "Подписка удалена."; fi ;;
            4) return ;;
            *) warn "Неверный выбор." ;;
        esac
        press_enter
    done
}

password_menu(){
    prompt_secret
    if [[ -f "$MIHOMO_CONFIG" && -n "$SUBSCRIPTION_URL" ]]; then render_mihomo_config; ( cd "$PROJECT_DIR" && docker compose up -d mihomo ); fi
    press_enter
}

lan_menu(){
    header "НАСТРОЙКИ · LAN"
    echo "Текущий LAN: ${LAN_IP}/24"
    echo "Gateway и DNS для DHCP: ${LAN_IP}"
    echo
    warn "Изменение LAN разорвёт SSH."
    echo
    local new_ip
    read -rp "Новый LAN IP [${LAN_IP}]: " new_ip
    [[ -z "$new_ip" ]] && return
    [[ "$new_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { error "Некорректный IPv4."; return; }
    local o="$LAN_IP"; LAN_IP="$new_ip"
    if confirm "Применить новую LAN-конфигурацию?"; then
        if apply_generated; then success "LAN изменён. Переподключитесь к ssh user@${LAN_IP}"; else LAN_IP="$o"; write_config; warn "Изменение LAN не применено."; fi
    else LAN_IP="$o"; fi
}

dhcp_menu(){
    header "НАСТРОЙКИ · DHCP"
    echo "Текущий диапазон: ${DHCP_START}–${DHCP_END}"
    local a b
    read -rp "Начало DHCP [${DHCP_START}]: " a
    read -rp "Конец DHCP [${DHCP_END}]: " b
    [[ -n "$a" ]] && DHCP_START="$a"; [[ -n "$b" ]] && DHCP_END="$b"
    if configure_dnsmasq; then write_config; success "DHCP сохранён."; else error "Не удалось применить DHCP."; fi
}

nat_menu(){
    while true; do
        header "НАСТРОЙКИ · NAT"
        echo "LAN: ${LAN_IP%.*}.0/24 → WAN: ${WAN_IFACE:-wan}"
        if [[ "$NAT_ENABLED" == 1 ]]; then echo -e "Состояние: ${GREEN}ВКЛЮЧЁН${NC}"; else echo -e "Состояние: ${YELLOW}ВЫКЛЮЧЕН${NC}"; fi
        echo
        echo "  1) Включить NAT"
        echo "  2) Выключить NAT"
        echo "  3) Пересоздать правила"
        echo "  4) Назад"
        echo
        local c; read -rp "Выбор [1-4]: " c
        case "$c" in
            1) NAT_ENABLED=1; write_nftables; nft -c -f "$NFT_FILE" && nft -f "$NFT_FILE" && write_config && success "NAT включён." ;;
            2) NAT_ENABLED=0; write_nftables; nft -c -f "$NFT_FILE" && nft -f "$NFT_FILE" && write_config && success "NAT выключен." ;;
            3) write_nftables; nft -c -f "$NFT_FILE" && nft -f "$NFT_FILE" && success "Правила NAT пересозданы." ;;
            4) return ;;
            *) warn "Неверный выбор." ;;
        esac
        press_enter
    done
}

interfaces_menu(){
    header "НАСТРОЙКИ · ИНТЕРФЕЙСЫ"
    echo "Текущие: LAN=${LAN_IFACE} (${LAN_MAC}), WAN=${WAN_IFACE} (${WAN_MAC})"; echo
    echo "1) Изменить LAN интерфейс"; echo "2) Изменить WAN интерфейс"; echo "3) Назад"; echo
    local c; read -rp "Выбор [1-3]: " c
    local new
    case "$c" in
        1) new=$(choose_iface_manual "Выберите новый LAN" "$WAN_IFACE")
           LAN_IFACE="$new"; LAN_MAC=$(mac_of "$new")
           if confirm "Применить? SSH может оборваться."; then apply_generated || true; else load_config; fi ;;
        2) new=$(choose_iface_manual "Выберите новый WAN" "$LAN_IFACE")
           WAN_IFACE="$new"; WAN_MAC=$(mac_of "$new")
           if confirm "Применить?"; then apply_generated || true; else load_config; fi ;;
        3) return ;;
    esac
}

dns_menu(){
    header "НАСТРОЙКИ · DNS UPSTREAM"
    echo "Текущие: ${DNS1}, ${DNS2}"; echo
    local a b
    read -rp "DNS 1 [${DNS1}]: " a; read -rp "DNS 2 [${DNS2}]: " b
    [[ -n "$a" ]] && DNS1="$a"; [[ -n "$b" ]] && DNS2="$b"
    configure_dnsmasq && write_config && success "DNS upstream сохранён." || true
}

settings_menu(){
    while true; do
        header "НАСТРОЙКИ"
        echo "  1) Подписка Mihomo"
        echo "  2) Пароль Mihomo API"
        echo "  3) LAN / адрес шлюза"
        echo "  4) DHCP / пул адресов"
        echo "  5) NAT"
        echo "  6) Интерфейсы LAN / WAN"
        echo "  7) WAN / DHCP / PPPoE"
        echo "  8) PPPoE логин / пароль"
        echo "  9) DNS upstream"
        echo " 10) Назад"
        echo
        local c; read -rp "Выбор [1-10]: " c
        case "$c" in
            1) subscription_menu;; 2) password_menu;; 3) lan_menu;; 4) dhcp_menu;; 5) nat_menu;; 6) interfaces_menu;; 7) wan_mode_menu;; 8) pppoe_credentials_menu;; 9) dns_menu;; 10) return;; *) warn "Неверный выбор.";;
        esac
    done
}


install_stack(){
    header "УСТАНОВКА GATEWAY + MIHOMO"
    load_config || { error "Сначала выполните первоначальную настройку сети."; return 1; }
    configure_forwarding
    if [[ "$WAN_MODE" == "pppoe" ]]; then configure_pppoe; else pppoe_stop; fi
    configure_nftables
    install_docker

    mkdir -p "$PROJECT_DIR" "$MIHOMO_CONFIG_DIR/ruleset" "$MIHOMO_CONFIG_DIR/proxy_providers"

    prompt_secret
    prompt_subscription_install
    render_mihomo_config
    create_env
    create_compose

    header "ЗАГРУЗКА DOCKER-ОБРАЗОВ"
    ( cd "$PROJECT_DIR" && run_timed "Загрузка Docker-образов" docker compose pull )

    validate_config

    header "ЗАПУСК КОНТЕЙНЕРОВ"
    run_timed "Запуск Mihomo + MetaCubeXD" bash -c "cd '$PROJECT_DIR' && docker compose up -d --remove-orphans"
    sleep 5
    local _w
    for _w in 1 2 3 4 5 6; do
        check_api && break
        sleep 2
    done
    check_container mihomo && success "Mihomo → running" || { error "Mihomo не запущен."; docker logs --tail 60 mihomo || true; return 1; }
    check_container metacubexd && success "MetaCubeXD → running" || { error "MetaCubeXD не запущен."; docker logs --tail 60 metacubexd || true; return 1; }
    sleep 2
    check_api && success "Mihomo API → доступен" || warn "Mihomo API пока не отвечает."
    check_ui && success "Панель → доступна" || warn "Панель пока не отвечает."
    final_success
}


final_success(){
    echo
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}                 УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  Панель: ${CYAN}${BOLD}http://${LAN_IP}/${NC}"
    echo -e "  Mihomo API: ${CYAN}${BOLD}http://${LAN_IP}:9090${NC}"
    echo -e "  Proxy: ${CYAN}${BOLD}${LAN_IP}:7890${NC}"
    echo -e "  WAN: ${CYAN}${BOLD}${WAN_MODE^^}${NC}"
    if [[ "$WAN_MODE" == "pppoe" ]]; then echo -e "  PPPoE: ${CYAN}${BOLD}ppp0${NC}"; fi
    echo; echo "  В MetaCubeXD используйте:"; echo "    Backend URL: http://${LAN_IP}:9090"; echo "    Secret: пароль, введённый при установке"; echo
}

remove_stack(){
    header "УДАЛЕНИЕ GATEWAY + MIHOMO"
    echo "Будут удалены контейнеры и ${PROJECT_DIR}."
    echo "Будут сохранены: Netplan, dnsmasq, DHCP, nftables, forwarding, Docker Engine."
    echo
    confirm "Продолжить обычное удаление?" || return
    if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
        ( cd "$PROJECT_DIR" && docker compose down --remove-orphans --rmi local ) || true
    else
        docker rm -f mihomo metacubexd >/dev/null 2>&1 || true
    fi
    rm -rf "$PROJECT_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then sed -i '/^CLASH_SECRET=/d;/^SUBSCRIPTION_URL=/d;/^PPPOE_USERNAME=/d;/^PPPOE_PASSWORD=/d' "$CONFIG_FILE" || true; fi
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
}

restore_original_netplan(){
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
            cp -a "$f" "/etc/netplan/${base}"
        done
    fi

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
    echo "  • Mihomo / MetaCubeXD"
    echo "  • Docker Engine и связанные пакеты"
    echo "  • nftables, IPv4 forwarding"
    echo "  • dnsmasq / DHCP"
    echo "  • PPPoE service / ppp0 / credentials"
    echo "  • 01-gateway.yaml"
    echo "  • интерфейсы lan/wan будут переименованы обратно"
    echo "  • исходный Netplan будет восстановлен и применён"
    echo
    warn "SSH будет разорван. Устройство может стать недоступным."
    echo
    echo -e "Для подтверждения введите: ${BOLD}RESET-GATEWAY${NC}"
    local token; read -rp "> " token
    [[ "$token" == RESET-GATEWAY ]] || { warn "Отменено."; return; }
    echo
    confirm "Начать полное удаление?" || return

    load_config || true

    pppoe_stop
    systemctl disable "$PPPOE_SERVICE" >/dev/null 2>&1 || true
    systemctl daemon-reload
    rm -f "/etc/systemd/system/${PPPOE_SERVICE}" "$PPPOE_PEER"
    if [[ -f "${ORIGINAL_DIR}/chap-secrets" ]]; then
        cp -a "${ORIGINAL_DIR}/chap-secrets" "$PPPOE_CHAP"
        chmod 600 "$PPPOE_CHAP"
    else
        sed -i '/^# mihomo-gateway-pppoe$/,+1d' "$PPPOE_CHAP" 2>/dev/null || true
    fi
    systemctl daemon-reload

    if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then ( cd "$PROJECT_DIR" && docker compose down --remove-orphans --rmi local ) || true; fi
    docker rm -f mihomo metacubexd >/dev/null 2>&1 || true
    rm -rf "$PROJECT_DIR"

    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed' || command -v docker >/dev/null 2>&1; then
        run_timed "Удаление Docker Engine" env DEBIAN_FRONTEND=noninteractive apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    fi
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
    rm -rf /var/lib/docker /var/lib/containerd

    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    if dpkg-query -W -f='${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed'; then run_timed "Удаление dnsmasq" env DEBIAN_FRONTEND=noninteractive apt-get purge -y dnsmasq || true; fi
    rm -rf /etc/systemd/system/dnsmasq.service.d
    systemctl daemon-reload

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet gateway_filter 2>/dev/null || true
        nft delete table ip gateway_nat 2>/dev/null || true
    fi
    if dpkg-query -W -f='${Status}' nftables 2>/dev/null | grep -q 'install ok installed'; then run_timed "Удаление nftables" env DEBIAN_FRONTEND=noninteractive apt-get purge -y nftables || true; fi

    rm -f "$SYSCTL_FILE"
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
        rm -f "$NETPLAN_FILE"
        local f
        shopt -s nullglob
        for f in /etc/netplan/*.yaml.gateway-disabled; do
            mv "$f" "${f%.gateway-disabled}"
        done
        shopt -u nullglob
        if [[ -d "$ORIGINAL_NETPLAN_DIR" ]]; then
            for f in "$ORIGINAL_NETPLAN_DIR"/*.yaml; do
                [[ -f "$f" ]] || continue
                cp -a "$f" "/etc/netplan/$(basename "$f")"
            done
        fi
        rm -rf "$STATE_DIR"
        warn "Netplan восстановлен на диске, но НЕ применён."
        success "Полное удаление завершено без применения сети."
    fi
}

self_test(){
    local missing=()
    local cmd
    for cmd in bash grep sed awk ip systemctl curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        error "Не найдены обязательные команды: ${missing[*]}"
        exit 1
    fi
    success "Самопроверка скрипта — OK"
}

main_menu(){
    while true; do
        clear
        load_config || true
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}                UBUNTU GATEWAY + MIHOMO${NC}"
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN} Состояние системы${NC}"
        quick_status | sed 's/^/  /'
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}  1) Установить / переустановить Gateway${NC}"
        echo -e "${BOLD}${CYAN}  2) Удалить Gateway (сеть оставить)${NC}"
        echo -e "${BOLD}${CYAN}  3) Полное удаление + сброс сети${NC}"
        echo -e "${BOLD}${CYAN}  4) Полная диагностика / статусы${NC}"
        echo -e "${BOLD}${CYAN}  5) Настройки${NC}"
        echo -e "${BOLD}${CYAN}  6) Выход${NC}"
        echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo
        echo -e "  ${DIM}Панель: http://${LAN_IP}/${NC}"
        echo -e "  ${DIM}API:    http://${LAN_IP}:9090${NC}"
        echo
        local c; read -rp "Выбор [1-6]: " c
        case "$c" in
            1) install_stack; press_enter;;
            2) remove_stack; press_enter;;
            3) full_remove; press_enter;;
            4) clear; full_diagnostics; press_enter;;
            5) settings_menu;;
            6) exit 0;;
            *) warn "Неверный выбор."; sleep 1;;
        esac
    done
}

main(){
    need_root
    self_test
    check_os
    mkdir -p "$STATE_DIR"
    if ! network_is_ready; then
        configure_network_first
    fi
    load_config || true
    main_menu
}

main "$@"
