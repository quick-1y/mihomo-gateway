# 🌐 Ubuntu Gateway + Mihomo

Интерактивный установщик шлюза на **Ubuntu/Debian**, превращающий мини-ПК с двумя сетевыми портами в полноценный gateway с **Mihomo** ⚡

---

## 🗺 Схема работы

```mermaid
flowchart TB
    Internet(["🌍 Интернет"])

    subgraph GW["🖥️ Ubuntu Gateway Box"]
        direction TB
        NFT["nftables (NAT)"]
        DNS["dnsmasq (DHCP)"]

        subgraph DK["🐳 Docker"]
            direction TB
            MH["Mihomo"]
            MC["MetaCubeX 🎛"]
            MH --> MC
        end

        NFT --> DNS
        DNS --> DK
    end

    SW["🔀 Switch / AP"]

    PC["💻 PC"]
    PH["📱 Phone"]
    SRV["🖥️ Server"]

    Internet -- "WAN (eth0 / enp1s0)" --> GW
    GW -- "LAN (eth1 / enp2s0)" --> SW
    SW --> PC
    SW --> PH
    SW --> SRV

    classDef box fill:#1f2937,stroke:#60a5fa,color:#e5e7eb;
    classDef net fill:#0f172a,stroke:#34d399,color:#e5e7eb;
    class GW,DK,NFT,DNS,MH,MC,SW,PC,PH,SRV box;
    class Internet net;
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
└── mihomo/
    └── config.yaml
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

- `mihomo/config.yaml` — шаблон конфига Mihomo

---

## 📄 Лицензия

См. [LICENSE](LICENSE)
