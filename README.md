# 🌐 Ubuntu Gateway + Mihomo

Интерактивный установщик шлюза на **Ubuntu/Debian**, превращающий мини-ПК с двумя сетевыми портами в полноценный gateway с **Mihomo** ⚡

---

## 🗺 Схема работы

```text
        Интернет 🌍
            │
            │  WAN (eth0 / enp1s0)
            ▼
   ┌─────────────────────────┐
   │   Ubuntu Gateway Box    │
   │  ┌───────────────────┐  │
   │  │  nftables (NAT)   │  │
   │  │  dnsmasq (DHCP)   │  │
   │  └─────────┬─────────┘  │
   │            │            │
   │     ┌──────▼──────┐     │
   │     │   Docker    │     │
   │     │  ┌───────┐  │     │
   │     │  │Mihomo │  │     │
   │     │  └───┬───┘  │     │
   │     │  ┌───▼────┐ │     │
   │     │  │MetaCube│ │     │
   │     │  │  XD 🎛 │ │     │
   │     │  └────────┘ │     │
   │     └─────────────┘     │
   └────────────┬────────────┘
                │  LAN (eth1 / enp2s0)
                ▼
        ┌───────────────┐
        │  Switch / AP  │
        └───────┬───────┘
                │
      ┌─────────┼─────────┐
      ▼         ▼         ▼
   💻 PC     📱 Phone   🖥 Server
```

---

## 🚀 Быстрый старт

```bash
git clone https://github.com/quick-1y/mihomo-gateway.git
cd mihomo-gateway
sudo bash install-gateway-docker.sh
```

Всё остальное — интерактивно 🎛

---

## 📁 Структура проекта

```text
mihomo-gateway/
├── install-gateway-docker.sh
├── gateway.conf
├── mihomo.yaml.template
├── compose.yaml.template
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
