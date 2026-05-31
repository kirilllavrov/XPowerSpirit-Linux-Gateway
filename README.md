# XPowerSpirit-Linux-Gateway

Прозрачный шлюз Xray на DietPi (Debian ARM). Устройство работает за основным роутером (Keenetic), принимает трафик клиентов локальной сети и обрабатывает его через Xray TProxy.

> **Отличие от OpenWRT-версии:** адаптирован под DietPi / Debian ARM. Использует systemd, `/etc/network/interfaces`, apt, dnsmasq как DNS-фронтенд, отдельную таблицу nftables.

```
Internet
   │
Keenetic (основной роутер: NAT, DHCP, DNS fallback)
   │ 192.168.1.1
   ├── Xray GW (статический IP 192.168.1.2)
   │      └── TProxy :12345 → routing → proxy/direct/block
   │
   └── Клиенты (gateway=192.168.1.2, dns=192.168.1.2)
```

## Поддерживаемые платформы

- **DietPi** (рекомендуется) — Raspberry Pi, Odroid, Orange Pi, NanoPi и др.
- **Debian ARM** (arm64, armv7, armv6)
- **Debian/Ubuntu x86_64**

## Требования

- DietPi или Debian-based система
- Доступ в интернет
- Статический IP (рекомендуется) или DHCP-резервация на основном роутере

## Установка

Скрипт сам определит текущую сеть и предложит вариант IP-адреса. Можно принять автоопределение или ввести вручную.

```sh
curl -sSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-Linux-Gateway/main/install-xray-gateway.sh | bash -s -- --sub=https://your-subscription.url
```

Либо скачать и запустить:

```sh
wget https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-Linux-Gateway/main/install-xray-gateway.sh
bash install-xray-gateway.sh --sub=https://your-subscription.url
```

### Интерактивный режим

Без аргументов скрипт задаст вопросы:

```
╔══════════════════════════════════════════════════════╗
║  Xray Transparent Gateway — установка на DietPi ARM  ║
╚══════════════════════════════════════════════════════╝

=== Шаг 1: Настройка сети и подписки ===

  [1/3] Определяю сетевой интерфейс...
    Интерфейс: eth0

  [2/3] Настройка IP-адреса шлюза
  ─────────────────────────────────────────────
  Обнаружена сеть:
    Интерфейс : eth0
    Текущий IP: 192.168.1.2
    Маска     : 255.255.255.0
    Роутер    : 192.168.1.1

  Выберите действие:
    [1] Оставить обнаруженный IP (192.168.1.2)
    [2] Ввести другой IP вручную
    [3] Оставить DHCP (не рекомендуется)

  Ваш выбор [1]:

  [3/3] Настройка подписки
  ─────────────────────────────────────────────
  Введите URL подписки (или укажите --sub=URL при запуске):
  >
```

### Аргументы командной строки

| Аргумент | Назначение |
|---|---|
| `--sub=URL` | URL подписки |
| `--ip=X.X.X.X` | Статический IP шлюза (пропускает диалог) |
| `--mask=X.X.X.X` | Маска подсети (по умолчанию 255.255.255.0) |
| `--gw=X.X.X.X` | IP основного роутера |
| `--sub-ua=UA` | User-Agent для запроса подписки |
| `--remarks=FILTER` | Фильтр по имени профиля в JSON-подписке |
| `--dwl=DOMAIN` | Приоритетный домен для **Base64 VLESS** подписок |

### Зависимости

Скрипт сам установит необходимые пакеты через `apt`:
- `curl` — загрузка файлов
- `python3` — парсер подписок и генератор конфига
- `unzip` — распаковка Xray
- `dnsmasq` — DNS-фронтенд
- `coreutils` — sha256sum

### Настройка основного роутера (Keenetic)

После установки настройте DHCP на Keenetic:
- **Шлюз по умолчанию** = IP Xray-устройства
- **DNS-сервер** = IP Xray-устройства

## Состав проекта

| Файл | Роль |
|---|---|
| `install-xray-gateway.sh` | Установщик (интерактивный + аргументы) |
| `update-xray.sh` | Автообновление Xray, geo, подписки, конфига (cron + systemd) |
| `update-nft.sh` | Применение правил nftables TProxy |
| `xray-sub-parser.py` | Парсер подписок: Base64 VLESS + JSON Happ/Sing-box |
| `xray-generate-config.py` | Генератор config.json: DNS, routing, балансировка |
| `setup-led-status.sh` | LED-индикация Xray и интернета (GPIO/sysfs) |

## Как работает

### Обработка трафика

Клиенты отправляют весь трафик на Xray-шлюз (прописано в DHCP основного роутера). nftables перехватывает трафик в цепочке PREROUTING и направляет в Xray через TProxy. Xray маршрутизирует: российские сайты — напрямую, зарубежные — через прокси, реклама — в блокировку.

### DNS без утечек

```
Клиенты → dnsmasq :53 → Xray :5353 → dns-out (hijack) → dns-inbuilt (DoH)
                                                       ├─ ru-домены → DoH Yandex
                                                       └─ остальные → DoH Cloudflare / NextDNS

Шлюз (собственный DNS) → 1.0.0.1 (напрямую через основной роутер)
```

`systemd-resolved` отключается при установке чтобы освободить порт 53 для dnsmasq. DHCP не раздаётся — этим занимается основной роутер (Keenetic).

### Балансировка прокси

При нескольких серверах в подписке:
- **leastLoad** — автоматический выбор самых стабильных серверов
- **burstObservatory** — пинг `connectivitycheck.gstatic.com/generate_204` каждую минуту
- Максимум 2 сервера, RTT до 800 мс
- При падении всех — переход на прямой трафик (fallback → direct)
- **Режим hole**: если подписка истекла — весь трафик идёт напрямую

### Защита от петель

- Все outbound'ы Xray помечаются `sockopt.mark=2`
- nftables PREROUTING: `meta mark 2 return`
- IP прокси-серверов автоматически извлекаются из config.json и добавляются в bypass

### Отличия от OpenWRT-версии

| Компонент | OpenWRT | DietPi (этот проект) |
|---|---|---|
| Пакетный менеджер | opkg | apt |
| Сетевой конфиг | UCI | `/etc/network/interfaces` |
| Сервис-менеджер | procd/init.d | systemd |
| DNS | dnsmasq (UCI) | dnsmasq (`/etc/dnsmasq.conf`) |
| nftables | таблица `inet fw4` | отдельная таблица `inet xray` |
| Hotplug | `/etc/hotplug.d/` | systemd `.path` unit |
| Путь Xray | `/usr/bin/xray` | `/usr/local/bin/xray` |
| Путь скриптов | `/usr/share/xray/` | `/usr/local/share/xray/` |
| Логи Xray | `/tmp/log/` | `/var/log/` |
| LED | UCI + sysfs (Cudy WR3000S) | sysfs (автоопределение) |

### Выбор прокси-сервера — только для Base64 VLESS

Если подписка в формате **Base64 VLESS** и в ней несколько серверов, можно закрепиться за конкретным через `--dwl=DOMAIN` при установке или создав файл вручную:

```sh
echo "my-proxy.example.com" > /etc/xray/dwl_domain
```

Генератор прочитает файл и выберет сервер с указанным доменом вместо первого попавшегося. Для JSON-подписок (Happ/Sing-box) не используется — там работает балансировщик leastLoad.

### Блокировка QUIC

QUIC (UDP/443) блокируется чтобы браузеры использовали TCP/HTTPS (VLESS+XTLS не поддерживает UDP).

## Управление сервисом

```sh
# Запуск / остановка / перезапуск
systemctl start xray
systemctl stop xray
systemctl restart xray

# Статус
systemctl status xray

# Логи
journalctl -u xray -f
```

## Обновление

Автоматическое ежедневное обновление в 2:30 ночи + при поднятии сети:

```
Cron (2:30) / systemd network hook
        │
        ▼
  update-xray.sh
        ├─► Xray (GitHub Releases, SHA-верификация)
        ├─► geoip.dat + geosite.dat (SHA-верификация)
        ├─► Подписка → парсер → генератор → config.json
        ├─► xray run -test (валидация)
        ├─► update-nft.sh (nftables)
        └─► Перезапуск Xray (systemctl)
```

## Ручное обновление

```sh
/usr/local/share/xray/update-xray.sh
```

## Структура файлов после установки

```
/usr/local/bin/xray                     # Исполняемый файл Xray
/usr/local/share/xray/                  # Скрипты и geo-файлы
├── xray-generate-config.py
├── xray-sub-parser.py
├── update-xray.sh
├── update-nft.sh
├── net-check.sh
├── geoip.dat
└── geosite.dat
/etc/xray/                              # Конфигурация Xray
├── config.json
├── subscription.url
├── hwid
├── gateway_ip
├── dwl_domain          (опционально)
├── sub_user_agent      (опционально)
├── sub_remarks         (опционально)
└── state/              (SHA-кеш для инкрементальных обновлений)
/etc/systemd/system/
├── xray.service
├── xray-network-update.service
└── xray-network-update.path
/var/log/
├── xray-access.log
├── xray-error.log
└── xray-update.log
```

## Лицензия

MIT License — см. [LICENSE](LICENSE)