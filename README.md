# 🌐 Ubuntu Gateway + Mihomo

Интерактивный установщик шлюза на **Ubuntu/Debian**, превращающий мини-ПК с двумя сетевыми портами в полноценный gateway с **Mihomo** ⚡

---

## 🗺 Схема работы

```mermaid
flowchart LR
    I(["🌍 Интернет"]):::wan

    subgraph GW["Ubuntu Gateway"]
        direction TB
        N["nftables · NAT"]:::svc
        D["dnsmasq · DHCP"]:::svc
        subgraph DOCK["Docker"]
            M1["Mihomo"]:::svc
            M2["MetaCubeX 🎛"]:::svc
            M1 --> M2
        end
        N --> D --> DOCK
    end

    SW["🔀 Switch / AP"]:::lan
    PC["💻 PC"]:::lan
    PH["📱 Phone"]:::lan
    SRV["🖥️ Server"]:::lan

    I ==>|WAN eth0/enp1s0| GW
    GW ==>|LAN eth1/enp2s0| SW
    SW --> PC
    SW --> PH
    SW --> SRV

    classDef wan fill:#111827,stroke:#f59e0b,color:#fde68a;
    classDef svc fill:#1f2937,stroke:#60a5fa,color:#e5e7eb;
    classDef lan fill:#0b1220,stroke:#34d399,color:#a7f3d0;
```

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
├── README.md
└── LICENSE
```

---

## 🛠 Что делает установщик

- 🔌 Определяет **WAN/LAN** интерфейсы
- ⚙️ Настраивает **Netplan**, **dnsmasq**, forwarding и **nftables**
- 🐳 Ставит **Docker**
- ▶️ Запускает и управляет **Mihomo** + **MetaCubeXD**
- 📊 Даёт меню: диагностика, настройки, удаление, восстановление сети

---

## 📦 Файлы конфигурации

- `gateway.conf` — основные параметры шлюза
- `mihomo.yaml.template` — шаблон конфига Mihomo
- `compose.yaml.template` — шаблон Docker Compose

---

## 📄 Лицензия

См. [LICENSE](LICENSE)
