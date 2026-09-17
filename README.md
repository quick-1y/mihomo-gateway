# 🌐 Ubuntu Gateway + Mihomo

Интерактивный установщик шлюза на **Ubuntu/Debian**, превращающий мини-ПК с двумя сетевыми портами в полноценный gateway с **Mihomo** ⚡

---

## 🗺 Схема работы

```mermaid
flowchart LR
    ISP(["🌍 Интернет / провайдер"])
    DEV["💻📱 Устройства LAN"]
    SW["🔀 Switch / AP"]

    subgraph GW["🖥️ Ubuntu Gateway"]
        direction LR
        WANIF(["wan · DHCP или PPPoE"])
        LANIF(["lan · 192.168.100.1/24"])
        DNSMASQ["dnsmasq — DHCP + DNS"]
        NFT["nftables — firewall · DNAT · NAT (masquerade)"]
        TUN["Mihomo TUN (Meta) · auto-route + auto-redirect"]
        MIHOMO["Mihomo — PROXY / DIRECT"]
        ZASH["Zashboard · веб-панель :80"]
    end

    ISP <--> WANIF
    DEV <--> SW
    SW <--> LANIF

    LANIF --- DNSMASQ
    DEV -.->|"DHCP-аренда, DNS-запросы"| DNSMASQ

    LANIF -->|"1 · запрос LAN-устройства"| NFT
    NFT -->|"2 · перехват LAN-трафика"| TUN
    TUN --> MIHOMO
    MIHOMO -->|"3 · новое соединение, PROXY или DIRECT"| NFT
    NFT -->|"4 · masquerade → WAN"| WANIF

    ZASH <-->|"API :9090"| MIHOMO

    classDef box fill:#1f2937,stroke:#60a5fa,color:#e5e7eb;
    classDef net fill:#0f172a,stroke:#34d399,color:#e5e7eb;
    class GW,WANIF,LANIF,DNSMASQ,NFT,TUN,MIHOMO,ZASH,SW,DEV box;
    class ISP net;
```

Цифры 1–4 — путь обычного веб-запроса от устройства LAN до интернета:

1. Устройство LAN отправляет запрос на `lan` — nftables фильтрует по default-deny allow-list и решает, форвардить ли пакет дальше.
2. Собственная таблица nftables Mihomo перехватывает LAN-трафик (`redirect` в TUN); чтобы это перехваченное соединение не попало под default-deny основной таблицы gateway, там есть отдельное правило `ct status dnat accept`.
3. Mihomo разбирает трафик и либо проксирует его (`PROXY`), либо открывает прямое соединение (`DIRECT`) — в обоих случаях это уже новое, локально инициированное Mihomo соединение.
4. Это исходящее соединение выходит через `wan`, где nftables делает `masquerade` (NAT) и отправляет пакет провайдеру.

DHCP и DNS для LAN обслуживает `dnsmasq` напрямую на адресе `lan`, отдельно от основного пути запроса. Zashboard — веб-панель, которая обращается к API Mihomo (`:9090`) и не участвует в передаче трафика.

---

## 🚀 Быстрый старт

```bash
curl -fsSL -o install-gateway-docker.sh https://raw.githubusercontent.com/quick-1y/mihomo-gateway/main/install-gateway-docker.sh
chmod +x install-gateway-docker.sh
sudo ./install-gateway-docker.sh
```

Всё остальное — интерактивно 🎛

---

## 📁 Структура проекта

```text
mihomo-gateway/
├── install-gateway-docker.sh
└── mihomo/
    └── config.yaml
```

---

## 🛠 Что делает установщик

- 🔌 Определяет **WAN/LAN** интерфейсы
- ⚙️ Настраивает **Netplan**, **dnsmasq**, forwarding и **nftables**
- 🐳 Ставит **Docker**
- ▶️ Запускает и управляет **Mihomo** + **Zashboard**
- 📊 Даёт меню: диагностика, настройки, удаление, восстановление сети

---

## 📦 Файлы конфигурации

- `mihomo/config.yaml` — шаблон конфига Mihomo

---

## 📄 Лицензия

[LICENSE](LICENSE)
