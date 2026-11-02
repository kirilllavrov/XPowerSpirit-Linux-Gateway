# XPowerSpirit-Linux-Gateway

Прозрачный шлюз Xray на DietPi (Debian ARM). Устройство работает за основным роутером (Keenetic), принимает трафик клиентов локальной сети и обрабатывает его через Xray TProxy.

```text
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
- Права root (установка, nftables, TProxy)
- Свободные порты `53` (dnsmasq) и `12345` (TProxy); меняются в `settings.json`

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

```text
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
| --- | --- |
| `--sub=URL` | URL подписки |
| `--ip=X.X.X.X` | Статический IP шлюза (пропускает диалог) |
| `--mask=X.X.X.X` | Маска подсети (по умолчанию 255.255.255.0) |
| `--gw=X.X.X.X` | IP основного роутера |
| `--sub-ua=UA` | User-Agent для запроса подписки |
| `--remarks=FILTER` | Какой профиль взять из JSON-подписки (подстрока `remarks`, регистр не важен) |
| `--no-dns` | Не настраивать DNS (dnsmasq, resolv.conf, systemd-resolved) |

### Зависимости

Скрипт сам установит недостающие пакеты через `apt`:

- `curl` — загрузка файлов
- `python3` — парсер подписок и генератор конфига
- `unzip` — распаковка Xray
- `nftables` — правила TProxy
- `iproute2` — policy routing (`ip rule`/`ip route`)
- `jq` — работа с `settings.json`
- `cron` — ежедневное автообновление
- `dnsmasq` — DNS-фронтенд (если DNS не отключён через `--no-dns`)
- `coreutils` — `sha256sum`

### После установки

Проверьте состояние шлюза:

```sh
xpower status     # сервис, nftables, DNS, режим подписки, трафик
xpower test       # интернет, DNS, TProxy, выход через прокси
```

### Настройка основного роутера (Keenetic)

После установки настройте DHCP на Keenetic:

- **Шлюз по умолчанию** = IP Xray-устройства
- **DNS-сервер** = IP Xray-устройства

## Состав проекта

| Файл | Роль |
| --- | --- |
| `install-xray-gateway.sh` | Установщик (интерактивный + аргументы) |
| `update-xray.sh` | Автообновление Xray, geo, подписки, конфига (cron + systemd) |
| `update-nft.sh` | Применение правил nftables TProxy |
| `xray-sub-parser.py` | Парсер JSON-подписки: выбор профиля, отбор прокси-серверов |
| `xray-generate-config.py` | Генератор config.json: DNS, routing, балансировка |
| `xpower` | CLI управления шлюзом (статус, трафик, профиль, логи) |

## Настройки

Единственный источник настроек — `/etc/xray/settings.json` (создаётся из `settings.default.json` при установке). Скрипты и генератор **не содержат собственных значений** — всё берётся из этого файла. Если файл повреждён, генератор завершается с ошибкой, а не подставляет молча другие значения; если файла нет — используются встроенные умолчания с предупреждением в лог.

| Ключ | Что задаёт |
| --- | --- |
| `subscription.url`, `.user_agent`, `.remarks` | подписка, User-Agent и выбранный профиль |
| `hwid`, `device_model`, `device_os`, `ver_os` | заголовки запроса подписки: `x-hwid`, `X-Device-Model`, `X-Device-Os`, `X-Ver-Os` (уходят и при установке, и при каждом обновлении; пустые значения не отправляются) |
| `network.interface` | LAN-интерфейс: приоритетнее автоопределения. Если пуст или такого интерфейса нет — берётся первый с IPv4, **кроме** интерфейса default route (аплинка). На машине с двумя NIC задавайте явно |
| `network.ip`, `.mask`, `.gateway` | сетевые параметры шлюза (заполняет установщик) |
| `xray.gid` | GID группы `xray` (bypass в nftables) |
| `xray.tproxy_port` | порт TProxy-инбаунда (`tunnel`) |
| `xray.dns_in_port` | порт DNS-инбаунда, куда форвардит dnsmasq |
| `xray.tproxy_mark` / `xray.bypass_mark` | метки TProxy и bypass в nftables и `sockopt.mark` |
| `xray.tcp_keepalive_interval` | `sockopt.tcpKeepAliveInterval` у outbound'ов |
| `xray.direct_domain_strategy` | `sockopt.domainStrategy` у выхода `direct` |
| `log.loglevel`, `.access`, `.error` | логи Xray |
| `api.enabled`, `api.listen_port` | gRPC API для статистики (`stats`, `api`, `policy` в конфиге) |
| `dns.query_strategy`, `.serve_expired_ttl`, `.dnsmasq_fallback` | параметры DNS |
| `dns.disable_cache`, `.serve_stale`, `.disable_fallback`, `.disable_fallback_if_match`, `.enable_parallel_query` | флаги DNS Xray |
| `dns.hosts` | статические IP DoH-серверов (они же bypass-адреса в nftables). DoH-сервер, заданный доменом без IP здесь, отвергается генератором: `https+local://` резолвит домен через систему и получается петля |
| `dns.block_domains` | доменные паттерны, которые отвергаются на уровне DNS (по умолчанию `geosite:category-ads`). У старых `settings.json` без этого ключа источником остаётся `routing.block.domains` |
| `dns.block_via_dns` | включить DNS-блокировку `dns.block_domains` (по умолчанию `true`) |
| `dns.block_rcode` | код отказа для DNS-блокировки: `3` (по умолчанию) — NXDOMAIN, `0` — NOERROR с пустым ответом |
| `dns.servers` | список DNS-серверов встроенного DNS Xray. У Yandex DoH в `domains` перечислены `domain:ru`, `domain:su`, `domain:xn--p1ai`, `domain:рф` и `geosite:category-ru`: российские домены целиком уходят к нему, `expectedIPs: geoip:ru` отсекает ответы с зарубежными адресами, `skipFallback` не даёт переключиться на зарубежный резолвер |
| `balancer.expected`, `.max_rtt`, `.baselines`, `.fallback_tag` | основной пул `leastLoad` (по нагрузке) |
| `balancer.streaming.enabled`, `.strategy` | отдельный пул `balancer-stream` для доменов из `routing.proxy.domains` (игры, стриминг): по умолчанию включён со стратегией `leastPing` — там решает задержка, а не загрузка узла |
| `observatory.destination`, `.interval`, `.sampling`, `.timeout`, `.http_method` | `burstObservatory` |
| `routing.domain_strategy` | `routing.domainStrategy` |
| `routing.direct` / `.block` / `.proxy` / `.doh_bypass` | категории маршрутизации |
| `routing.direct.bittorrent` | `true` — незашифрованный BitTorrent идёт напрямую, `false` — по общим правилам (в прокси). Требует `sniffing` на инбаунде (включён в генерируемом конфиге) |
| `geodata.dir`, `.geoip_url`, `.geosite_url` | откуда и куда качать geo-файлы. По умолчанию — зеркало в Yandex Object Storage (`xpower/GEO/`), то же, что использует XPowerSpirit-OpenWRT: раздача из РФ без обращений к raw.githubusercontent |

Значения по умолчанию для отсутствующих ключей оставлены в коде только ради совместимости с `settings.json` от старых версий.

## Как работает

### Обработка трафика

Клиенты отправляют весь трафик на Xray-шлюз (прописано в DHCP основного роутера). nftables перехватывает трафик в цепочке PREROUTING и направляет в Xray через TProxy. Xray маршрутизирует: российские сайты — напрямую, зарубежные — через прокси, реклама — в блокировку.

Реклама блокируется на уровне DNS. Домены из `dns.block_domains` попадают в `dns.hosts` со значением `#3`, и DNS-ответ приходит пустым с NXDOMAIN: `hosts` проверяется **до** резолверов, поэтому заблокированный домен не тратит запрос к DoH, а клиент получает отказ за миллисекунды вместо TLS-таймаута. Отключается ключом `dns.block_via_dns: false`, код отказа меняется через `dns.block_rcode` (`3` — NXDOMAIN, `0` — NOERROR с пустым ответом).

Правило маршрутизации в `blackhole` (`routing.block.domains`) по умолчанию **пустое**: DNS-слой отрабатывает раньше и дешевле, а само правило тянет за собой огромный список доменов в матчере маршрутизации. Если нужен второй слой (например, для клиентов с собственным DoH, минующих шлюз), допишите паттерны в `routing.block.domains` — тогда генератор снова создаст правило `block`.

Незашифрованный BitTorrent распознаётся через `sniffing` и уходит напрямую (`routing.direct.bittorrent`). Это осознанный компромисс: BT не нагружает прокси, но пиры и DHT видят реальный IP шлюза. Для зашифрованного/обфусцированного BT (MSE, uTP) распознавание не работает — такой трафик идёт по общим правилам, то есть через прокси.

### DNS без утечек

```text
Клиенты → dnsmasq :53 → Xray :15353 → dns-out (hijack) → dns-inbuilt (DoH)
                                                       ├─ зоны .ru/.su/.рф и geosite:category-ru → DoH Yandex
                                                       └─ остальные → DoH Cloudflare / unfiltered AdGuard / ffmuc.net

Собственный DNS шлюза → 127.0.0.1:53 (тот же dnsmasq) → Xray
```

`systemd-resolved` отключается при установке чтобы освободить порт 53 для dnsmasq, `/etc/resolv.conf` указывает на `127.0.0.1`.

Порт DNS-инбаунда Xray — `15353`, а не `5353`: `5353` зарегистрирован за mDNS, и его занимают сторонние сервисы (TorrServer/Bonjour, avahi, браузеры). Порт задаётся в `xray.dns_in_port`, установщик подставляет его же в `/etc/dnsmasq.conf`. DHCP не раздаётся — этим занимается основной роутер (Keenetic).

Если Xray остановлен, dnsmasq отвечает через `dns.dnsmasq_fallback` (`77.88.8.8`) — клиенты не остаются без DNS.

Формат `domains` у DNS-сервера — тот же, что у `domain` в правилах маршрутизации, поэтому здесь работают и префикс `domain:`, и категории `geosite:`. Без префикса домен считается полным (`full:`) — так задаются имена самих DoH-серверов в `dns.hosts`.

Запросы к DoH-серверам идут через `https+local://` — режим DOHL, то есть **мимо** routing и прокси, напрямую. Имена DoH-серверов при этом должны разрешаться без обращения к внешнему DNS, поэтому их IP указаны в `dns.hosts`: на шлюзе системный резолвер сам ходит через Xray, и без этих записей получился бы цикл `Xray → DoH → DNS → Xray`.

### Балансировка прокси

При нескольких серверах в подписке:

- **leastLoad** — автоматический выбор самых стабильных серверов
- **burstObservatory** — пинг `connectivitycheck.gstatic.com/generate_204` (URL, интервал, число замеров — в `observatory`)
- Сколько серверов использовать, отсечка по RTT и джиттеру — `balancer.expected`, `max_rtt`, `baselines`
- При падении всех — переход на прямой трафик (`balancer.fallback_tag` → direct)
- Игры и стриминг идут через второй пул `balancer-stream` с `leastPing`: он выбирает узел с наименьшей задержкой, тогда как основной `balancer` — с наименьшей загрузкой. Пул создаётся только при нескольких серверах и отключается ключом `balancer.streaming.enabled`
- **Режим DIRECT**: если подписка истекла или в профиле не осталось рабочих серверов
  (например, исчерпан лимит устройств) — весь трафик идёт напрямую

### Защита от петель

Собственный трафик Xray не должен снова попасть в TProxy:

- все outbound'ы помечаются `sockopt.mark` = `xray.bypass_mark` (по умолчанию 2);
- в `PREROUTING` правило `meta mark 2 return` пропускает такие пакеты мимо TProxy;
- в `OUTPUT` дополнительно работает `meta skgid <xray.gid>` — трафик процессов группы `xray` помечается bypass-меткой (работает даже если `sockopt.mark` не применился);
- к локальным адресам (`fib daddr type local`), приватным сетям, DoH-серверам, NTP, ICMP и DHCP правила не применяются вовсе.
- ICMP исключён намеренно: TProxy в `PREROUTING` перехватывает только `tcp`/`udp`, поэтому помеченный ICMP-пакет уходит на `lo` и теряется — без этого исключения `ping`/`traceroute` с самого шлюза не работают. ICMP от клиентов идёт как обычный форвардинг и через прокси не проходит.

### Выбор профиля подписки

Подписка — это JSON-массив профилей (например: Автовыбор, Европа, Франция, LTE…). Каждый профиль содержит свой набор серверов, поэтому берётся ровно один:

- без аргументов — **первый профиль** в подписке (в лог пишется, какой именно);
- с `--remarks=ФРАГМЕНТ` — первый профиль, в чьём `remarks` встречается фрагмент (регистр не важен).

Поведение сохраняется в `/etc/xray/settings.json` → `subscription.remarks`, поэтому автообновление использует тот же профиль. Посмотреть доступные имена можно в логе генерации:

```sh
grep 'Доступные профили' /var/log/xray-update.log
```

### Блокировка QUIC

QUIC (UDP/443) блокируется чтобы браузеры использовали TCP/HTTPS (VLESS+XTLS не поддерживает UDP).

## CLI: `xpower`

Устанавливается в `/usr/local/bin/xpower`. Команды без `status`/`test`/`traffic`/`config`/`proxy-list`/`profile` требуют root.

```sh
xpower status            # состояние шлюза: сервис, nftables, policy routing,
                         # DNS, профиль подписки, балансировщик, трафик
xpower test              # интернет, DNS (dnsmasq :53 и Xray), TProxy,
                         # выход в интернет, bypass-метка, валидность config.json
xpower traffic           # трафик по серверам (через API Xray)
xpower proxy-list        # прокси-серверы из config.json (адрес, сеть, TLS, mark)
xpower profile           # какой профиль подписки выбран и какой использован
xpower profile "LTE 1"   # переключить профиль (применить: xpower update)
xpower start|stop|restart|toggle
xpower update            # обновить Xray, geo, подписку и config.json
xpower logs              # journalctl -u xray -f
xpower config            # показать config.json
xpower setup             # переприменить правила nftables
xpower version
```

Для `status`/`traffic` в конфиг добавляются `stats`, `api` и `policy`
(`api.enabled`, `api.listen_port` в `settings.json`; по умолчанию
`127.0.0.1:10085`) — по ним Xray отдаёт счётчики
`outbound>>>tag>>>traffic>>>uplink|downlink`. Генератор также пишет
`/etc/xray/state/status.json` с режимом (proxy/direct), причиной DIRECT-режима,
числом серверов и профилем — его читает `xpower status`.

## Управление сервисом

Удобнее через `xpower` (см. раздел CLI):

```sh
xpower status      # состояние шлюза
xpower restart     # перезапуск
xpower test        # проверка DNS, TProxy и выхода в интернет
```

Напрямую через systemd:

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

```text
Cron (2:30) / systemd network hook
        │
        ▼
  update-xray.sh
        ├─► Xray (GitHub Releases, SHA-верификация)
        ├─► geoip.dat + geosite.dat (SHA-верификация)
        ├─► Подписка → парсер → генератор → config.json
        ├─► xray run -test (валидация)
        ├─► update-nft.sh (nftables): при сбое правила снимаются целиком,
        │   а update-xray.sh завершается с кодом 1 — проксирование не работает
        └─► Перезапуск Xray (systemctl)
```

`xray-network-update.service` запускается после загрузки, ждёт реальный выход
в интернет (`wait-online.sh`, до 5 минут) и выполняет то же обновление.
Триггер по смене состояния сети (`xray-network-update.path`) ставится только
там, где есть `ifupdown`: файл `/run/network/ifstate`, за которым он следит,
создаёт только он. На Ubuntu с netplan/NetworkManager юнита не будет — вместо
молча не работающего хука установщик об этом скажет.

## Ручное обновление

```sh
xpower update                    # то же, что и по cron, но сразу
# или напрямую:
sudo /usr/local/share/xray/update-xray.sh
```

## Структура файлов после установки

```text
/usr/local/bin/
├── xray                                # исполняемый файл Xray
└── xpower                              # CLI управления шлюзом
/usr/local/share/xray/                  # скрипты и geo-файлы
├── xray-generate-config.py
├── xray-sub-parser.py
├── update-xray.sh
├── update-nft.sh
├── wait-online.sh                      # ждёт интернет перед обновлением
├── geoip.dat
└── geosite.dat
/etc/xray/
├── settings.json                       # единственный источник настроек
├── config.json                         # генерируется из подписки
└── state/
    ├── status.json                     # режим, причина DIRECT, профиль (для xpower)
    ├── xray.zip.sha256sum              # SHA-кеши для инкрементальных обновлений
    ├── geoip.dat.sha256sum
    └── geosite.dat.sha256sum
/etc/systemd/system/
├── xray.service
├── xray-network-update.service     # после загрузки: ждёт интернет и обновляет
└── xray-network-update.path        # только если установлен ifupdown
/etc/dnsmasq.conf                       # DNS-фронтенд на :53 → Xray dns-in
/etc/crontab (crontab -l)               # ежедневное обновление в 2:30
/var/log/
├── xray-access.log                 # при log.loglevel=none (по умолчанию) не ведётся
├── xray-error.log                  # то же: loglevel=none отключает и его
└── xray-update.log                 # журнал самого update-xray.sh — ведётся всегда
```

## Диагностика

Начните с `xpower status` — он показывает сервис, nftables, policy routing, DNS, режим подписки и трафик по серверам. Затем `xpower test`.

| Симптом | Что проверить |
| --- | --- |
| В `xpower status` «DIRECT — no_proxies» | Подписка вернула заглушки: исчерпан лимит устройств (адрес `0.0.0.0`, порт `1`, нулевой UUID) или список пуст. Отвяжите лишние устройства в личном кабинете провайдера и выполните `xpower update` |
| В `xpower status` «DIRECT — expired» | В подписке сервер с адресом `hole` — срок действия истёк |
| Нет интернета у клиентов, у шлюза есть | `xpower test`: если «TProxy не слушает» — `xpower restart`; если «nftables bypass: правило не найдено» — `xpower setup` |
| Не открываются сайты по именам, по IP работают | DNS: `xpower test` покажет, отвечают ли dnsmasq :53 и Xray `dns-in`. Логи Xray — `journalctl -u xray -f` с `log.loglevel: "info"` и `log.dnsLog: true` |
| После обновления не применился конфиг | Смотрите `/var/log/xray-update.log`: новый `config.json` не прошёл `xray run -test` — остался прежний рабочий конфиг |
| Клиенты ходят напрямую вместо прокси | `xpower profile` — возможно, выбран профиль без рабочих серверов; профиль задаётся `subscription.remarks` |
| Постоянные обрывы на одном сервере | `xpower proxy-list` и `xpower traffic`: балансировщик исключает узлы по RTT (`balancer.max_rtt`, `balancer.baselines`) |

Проверить конфиг вручную:

```sh
/usr/local/bin/xray run -test -config /etc/xray/config.json
```

Принудительно пересобрать всё (Xray, geo, подписка, конфиг, nftables, перезапуск):

```sh
xpower update
```

## Лицензия

MIT License — см. [LICENSE](LICENSE).