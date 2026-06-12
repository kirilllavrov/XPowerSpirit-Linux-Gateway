#!/usr/bin/env python3
"""
Xray Config Generator for DietPi (Debian ARM) TProxy
Поддерживает три входных формата:
  --format unified - унифицированный JSON из xray-sub-parser.py (рекомендуемый)
  --format vless   - старый режим: VLESS outbounds из xray-sub-parser.py
  --format json    - старый режим: сырая JSON-подписка Happ/Sing-box

Специальная обработка "hole":
  Если в подписке обнаружен outbound с address="hole", генерируется DIRECT-конфиг
  (весь трафик идёт напрямую, прокси отключены). Это сигнал об окончании срока подписки.

Балансировка:
  Используется стратегия leastLoad с burstObservatory для выбора наиболее стабильного прокси.
"""

import json
import sys
import re
import argparse

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

SETTINGS_PATH = "/etc/xray/settings.json"

def load_settings() -> dict:
    """Загружает settings.json или возвращает умолчания"""
    try:
        with open(SETTINGS_PATH) as f:
            return json.load(f)
    except Exception:
        return {}

def _load_domain_whitelist() -> list:
    """Загружает whitelist из settings.json (dns.dwl_domain)"""
    whitelist = []
    s = load_settings()
    dwl = s.get("dns", {}).get("dwl_domain", "")
    if dwl:
        whitelist.append(dwl)
    return whitelist

DOMAIN_WHITELIST = _load_domain_whitelist()


def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def normalize_tag(tag: str) -> str:
    """Нормализует тег для использования в Xray"""
    if not tag:
        return "proxy"
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpNoDelay, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}

    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}

    ob["streamSettings"]["sockopt"]["mark"] = 2
    ob["streamSettings"]["sockopt"]["tcpNoDelay"] = True
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30

    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False

    return ob


# ============================================
#   ФУНКЦИИ ДЛЯ JSON ФОРМАТА (Happ/Sing-box)
# ============================================

def load_json_subscription() -> list:
    """Загружает JSON-подписку из stdin (формат Happ/Sing-box)"""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, list):
            return data
        return [data]
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return []


def has_hole_in_subscription(sub_data: list) -> bool:
    """
    Проверяет, есть ли в подписке outbound с адресом 'hole'.
    Это сигнал об окончании срока подписки.
    """
    for config in sub_data:
        if "outbounds" not in config:
            continue
        for ob in config["outbounds"]:
            try:
                addr = ob.get("settings", {}).get("vnext", [{}])[0].get("address", "")
                if addr == "hole":
                    return True
            except Exception:
                pass
    return False


def extract_outbounds_from_subscription(sub_data: list, remarks_filter: str = '') -> list:
    """
    Извлекает все outbounds из JSON-подписки.
    Пропускает служебные outbounds (freedom, blackhole, dns).
    Нормализует теги и добавляет недостающие поля.
    Если указан remarks_filter, выбирает только профиль с этим remarks.
    """
    all_outbounds = []
    seen_tags = set()
    found_profile = False

    for config in sub_data:
        config_remarks = config.get("remarks", "")

        # Фильтрация по remarks
        if remarks_filter:
            if remarks_filter.lower() not in config_remarks.lower():
                print(f"  → Пропускаем профиль: {config_remarks}", file=sys.stderr)
                continue

        found_profile = True
        print(f"  → Используем профиль: {config_remarks}", file=sys.stderr)

        if "outbounds" not in config:
            continue

        for ob in config["outbounds"]:
            # Пропускаем служебные outbounds
            protocol = ob.get("protocol", "")
            if protocol in ["freedom", "blackhole", "dns"]:
                continue

            # Нормализуем тег
            if "tag" not in ob or not ob["tag"]:
                ob["tag"] = "proxy"

            # Дедупликация тегов
            original_tag = ob["tag"]
            tag = normalize_tag(original_tag)
            counter = 2
            while tag in seen_tags:
                tag = f"{original_tag}-{counter}"
                tag = normalize_tag(tag)
                counter += 1
            ob["tag"] = tag
            seen_tags.add(tag)

            # Добавляем недостающие поля (sockopt, mux)
            ob = normalize_outbound(ob)

            all_outbounds.append(ob)
            print(f"  → Outbound: {tag} ({protocol})", file=sys.stderr)

    if remarks_filter and not found_profile:
        print(f"  [X] Профиль с remarks '{remarks_filter}' не найден!", file=sys.stderr)
        print(f"  → Доступные профили:", file=sys.stderr)
        for config in sub_data:
            config_remarks = config.get("remarks", "")
            print(f"      - {config_remarks}", file=sys.stderr)

    return all_outbounds


# ============================================
#   ФУНКЦИИ ДЛЯ VLESS ФОРМАТА (через парсер)
# ============================================

def load_vless_outbounds() -> list:
    """Загружает outbounds из stdin (формат от xray-sub-parser.py)"""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            return data
    except Exception:
        return []
    return []


def extract_address(ob):
    try:
        return ob["settings"]["vnext"][0]["address"]
    except Exception:
        return None


def extract_id(ob):
    try:
        return ob["settings"]["vnext"][0]["users"][0]["id"]
    except Exception:
        return None


def is_placeholder(ob):
    addr = extract_address(ob)
    uid = extract_id(ob)
    port = None
    try:
        port = ob["settings"]["vnext"][0]["port"]
    except Exception:
        pass
    return (
        uid == "00000000-0000-0000-0000-000000000000"
        or addr in ["0.0.0.0", "127.0.0.1", "hole"]
        or str(port) == "1"
    )


def has_hole(servers):
    for ob in servers:
        if extract_address(ob) == "hole":
            return True
    return False


def choose_best_server(servers):
    if not servers:
        return None
    servers = [s for s in servers if not is_placeholder(s)]
    if not servers:
        return None
    if DOMAIN_WHITELIST:
        for ob in servers:
            addr = extract_address(ob)
            if addr in DOMAIN_WHITELIST:
                return ob
    return servers[0]


def normalize_vless_outbound(ob: dict, chosen_tag: str) -> dict:
    """Нормализует outbound из VLESS формата"""
    if "tag" not in ob:
        ob["tag"] = chosen_tag

    ss = ob.setdefault("streamSettings", {})
    sockopt = ss.setdefault("sockopt", {})
    sockopt["mark"] = 2
    sockopt["tcpKeepAliveInterval"] = 30
    sockopt["tcpNoDelay"] = True
    ob.setdefault("mux", {"enabled": False})

    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    s = load_settings()
    tproxy_port = s.get("xray", {}).get("tproxy_port", 12345)

    return {
        "log": {
            "loglevel": "none",
            "access": "/var/log/xray-access.log",
            "error": "/var/log/xray-error.log"
        },
        "dns": {
            "tag": "dns-inbuilt",
            "queryStrategy": "UseIPv4",
            "disableCache": False,
            "serveStale": True,
            "serveExpiredTTL": 1800,
            "disableFallback": False,
            "disableFallbackIfMatch": True,
            "enableParallelQuery": True,
            "hosts": {
                "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
                "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"]
            },
            "servers": [
                {
                    "address": "https+local://common.dot.dns.yandex.net/dns-query",
                    "domains": ["geosite:category-ru"],
                    "expectedIPs": ["geoip:ru"],
                    "skipFallback": True
                },
                {
                    "address": "https+local://cloudflare-dns.com/dns-query",
                    "skipFallback": False
                },
                {
                    "address": "https+local://dns.nextdns.io",
                    "skipFallback": False
                }
            ]
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": tproxy_port,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": True
                }
            },
            {
                "tag": "dns-in",
                "listen": "127.0.0.1",
                "port": 5353,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp"
                }
            }
        ]
    }


def build_direct_config() -> dict:
    """Создаёт DIRECT-конфиг (без прокси) для режима 'hole'"""
    cfg = base_config()
    cfg["outbounds"] = [
        {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
        {"protocol": "blackhole", "tag": "block", "settings": {"response": {"type": "http"}}},
        {
            "protocol": "dns",
            "tag": "dns-out",
            "settings": {
                "rules": [
                    {
                        "action": "hijack",
                        "qtype": "1,28"
                    }
                ]
            }
        }
    ]
    cfg["routing"] = {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {
                "type": "field",
                "inboundTag": ["dns-in"],
                "outboundTag": "dns-out"
            },
            {
                "type": "field",
                "inboundTag": ["tproxy-in"],
                "port": "53",
                "outboundTag": "dns-out"
            },
            {
                "type": "field",
                "domain": [
                    "common.dot.dns.yandex.net",
                    "cloudflare-dns.com",
                    "dns.google",
                    "dns.quad9.net",
                    "doh.opendns.com",
                    "dns.nextdns.io"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": ["geosite:category-ads"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": ["geoip:ru", "geoip:private"],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [
                    "geosite:private",
                    "geosite:category-browser",
                    "geosite:category-cdn-ru",
                    "geosite:category-mobile",
                    "geosite:category-ru"
                ],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "direct"
            }
        ]
    }
    return cfg


def build_dns_outbound() -> dict:
    """Создаёт outbound 'dns-out' с hijack во встроенный DNS"""
    return {
        "protocol": "dns",
        "tag": "dns-out",
        "settings": {
            "rules": [
                {
                    "action": "hijack",
                    "qtype": "1,28"
                }
            ]
        }
    }


def build_rules(proxy_outbounds: list, direct_mode: bool = False) -> list:
    """
    Строит правила маршрутизации.
    Если несколько прокси, использует балансировщик.
    Если один прокси, использует прямой outboundTag.
    """
    rules = [
        # DNS inbound (принимает на IP шлюза:53) → dns-out (hijack → dns-inbuilt)
        {
            "type": "field",
            "inboundTag": ["dns-in"],
            "outboundTag": "dns-out"
        },
        # Клиентский DNS (порт 53 через TProxy) → dns-out (hijack → dns-inbuilt)
        {
            "type": "field",
            "inboundTag": ["tproxy-in"],
            "port": "53",
            "outboundTag": "dns-out"
        },
        # Ловим прямой DoH от браузеров — отправляем напрямую (уже зашифрован)
        {
            "type": "field",
            "domain": [
                "common.dot.dns.yandex.net",
                "cloudflare-dns.com",
                "dns.google",
                "dns.quad9.net",
                "doh.opendns.com",
                "dns.nextdns.io"
            ],
            "outboundTag": "direct"
        },
        # Блокировка рекламы
        {
            "type": "field",
            "domain": ["geosite:category-ads"],
            "outboundTag": "block"
        },
        # NTP (порт 123) — напрямую
        {
            "type": "field",
            "port": "123",
            "network": "udp",
            "outboundTag": "direct"
        },
        # QUIC (UDP/443) — блокируем на уровне Xray
        {
            "type": "field",
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
        },
        # Локальные и российские IP — напрямую
        {
            "type": "field",
            "ip": ["geoip:ru", "geoip:private"],
            "outboundTag": "direct"
        },
        # Локальные и российские домены — напрямую
        {
            "type": "field",
            "domain": [
                "geosite:private",
                "geosite:category-browser",
                "geosite:category-cdn-ru",
                "geosite:category-mobile",
                "geosite:category-ru"
            ],
            "outboundTag": "direct"
        },
    ]

    if not direct_mode and proxy_outbounds:
        target = "balancer" if len(proxy_outbounds) > 1 else proxy_outbounds[0]["tag"]

        # Стриминг и игры — через прокси
        rules.append({
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "balancerTag" if len(proxy_outbounds) > 1 else "outboundTag": target
        })

        # Весь остальной трафик
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "balancerTag" if len(proxy_outbounds) > 1 else "outboundTag": target
        })
    else:
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "direct"
        })

    return rules


def build_balancer(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию балансировщика для нескольких прокси (leastLoad).
    leastLoad выбирает наиболее стабильные серверы на основе данных burstObservatory:
      - expected=2: использовать 2 лучших сервера
      - maxRTT=800ms: серверы с пингом >800ms исключаются
      - baselines=["200ms"]: допустимое стандартное отклонение RTT (джиттер)

    Если все серверы не проходят — fallback на direct.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": {
            "type": "leastLoad",
            "settings": {
                "expected": min(2, len(proxy_outbounds)),
                "maxRTT": "800ms",
                "baselines": ["200ms"]
            }
        },
        "fallbackTag": "direct"
    }


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.
    Используется со стратегией leastLoad.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "1m",
                "sampling": 10,
                "timeout": "15s",
                "httpMethod": "GET"
            }
        }
    }


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for DietPi TProxy')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--format', choices=['json', 'vless', 'unified'], default='vless',
                        help='Input format: unified (from xray-sub-parser --ua), '
                             'json (raw Happ/Sing-box), vless (parsed VLESS outbounds)')
    parser.add_argument('--remarks', default='',
                        help='Filter outbounds by remarks (substring, case-insensitive). Only for JSON format')
    return parser.parse_args()


def main():
    args = parse_args()

    if args.format == 'unified':
        # ========================================
        # УНИФИЦИРОВАННЫЙ формат (из xray-sub-parser --ua)
        # ========================================
        print("  → Обработка унифицированной подписки", file=sys.stderr)

        try:
            data = json.load(sys.stdin)
        except Exception as e:
            log_error(f"Failed to parse unified input: {e}")
            sys.exit(1)

        hole = data.get("hole", False)
        raw_outbounds = data.get("outbounds", [])

        if hole:
            print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
            print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
            cfg = build_direct_config()
            with open(args.output, "w") as f:
                json.dump(cfg, f, indent=2, ensure_ascii=False)
            print(f"  ✓ DIRECT-конфиг сохранён: {args.output}", file=sys.stderr)
            return

        if not raw_outbounds:
            log_error("No outbounds in unified input — switching to DIRECT")
            cfg = build_direct_config()
            with open(args.output, "w") as f:
                json.dump(cfg, f, indent=2, ensure_ascii=False)
            print(f"  ✓ DIRECT-конфиг сохранён (нет серверов): {args.output}", file=sys.stderr)
            return

        # Нормализуем все outbounds (sockopt, mux — зона ответственности генератора)
        proxy_outbounds = [normalize_outbound(ob) for ob in raw_outbounds]

        cfg = base_config()

        direct_outbound = {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {"domainStrategy": "UseIPv4"},
            "streamSettings": {"sockopt": {"mark": 2, "tcpKeepAliveInterval": 30}}
        }
        block_outbound = {
            "protocol": "blackhole",
            "tag": "block",
            "settings": {"response": {"type": "http"}}
        }

        cfg["outbounds"] = proxy_outbounds + [direct_outbound, block_outbound, build_dns_outbound()]

        if len(proxy_outbounds) > 1:
            cfg.update(build_burst_observatory(proxy_outbounds))

        routing = {"domainStrategy": "IPOnDemand", "rules": build_rules(proxy_outbounds)}

        if len(proxy_outbounds) > 1:
            routing["balancers"] = [build_balancer(proxy_outbounds)]

        cfg["routing"] = routing

        print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
        if len(proxy_outbounds) > 1:
            print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)

        with open(args.output, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"  ✓ Конфиг сохранён: {args.output}", file=sys.stderr)

    elif args.format == 'json':
        # ========================================
        # JSON формат (Happ/Sing-box подписка)
        # ========================================
        print("  → Обработка JSON подписки", file=sys.stderr)

        subscription = load_json_subscription()
        if not subscription:
            log_error("Empty or invalid JSON subscription")
            sys.exit(1)

        # ПРОВЕРКА НА "hole" (окончание срока подписки)
        if has_hole_in_subscription(subscription):
            print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
            print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
            cfg = build_direct_config()
            with open(args.output, "w") as f:
                json.dump(cfg, f, indent=2, ensure_ascii=False)
            print(f"  ✓ DIRECT-конфиг сохранён: {args.output}", file=sys.stderr)
            return

        proxy_outbounds = extract_outbounds_from_subscription(subscription, args.remarks)

        if not proxy_outbounds:
            log_error("No valid outbounds found in JSON subscription")
            sys.exit(1)

        cfg = base_config()

        direct_outbound = {
            "protocol": "freedom",
            "tag": "direct",
            "settings": {"domainStrategy": "UseIPv4"},
            "streamSettings": {"sockopt": {"mark": 2, "tcpKeepAliveInterval": 30}}
        }
        block_outbound = {
            "protocol": "blackhole",
            "tag": "block",
            "settings": {"response": {"type": "http"}}
        }
        dns_outbound = build_dns_outbound()

        cfg["outbounds"] = proxy_outbounds + [direct_outbound, block_outbound, dns_outbound]

        cfg.update(build_burst_observatory(proxy_outbounds))

        routing = {"domainStrategy": "IPOnDemand", "rules": build_rules(proxy_outbounds)}

        if len(proxy_outbounds) > 1:
            routing["balancers"] = [build_balancer(proxy_outbounds)]

        cfg["routing"] = routing

        print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
        if len(proxy_outbounds) > 1:
            print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)

        with open(args.output, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"  ✓ Конфиг сохранён: {args.output}", file=sys.stderr)

    else:
        # ========================================
        # VLESS формат (через xray-sub-parser.py)
        # ========================================
        print("  → Обработка VLESS формата", file=sys.stderr)

        all_obs = load_vless_outbounds()
        cfg = base_config()

        if has_hole(all_obs):
            cfg["outbounds"] = [
                {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
                {"protocol": "blackhole", "tag": "block", "settings": {"response": {"type": "http"}}},
                build_dns_outbound()
            ]
            cfg["routing"] = {
                "domainStrategy": "IPOnDemand",
                "rules": build_rules([], direct_mode=True)
            }
            print("[!] Найден сервер 'hole'. Включён DIRECT-конфиг.", file=sys.stderr)
        else:
            chosen = choose_best_server(all_obs)

            if chosen is None:
                cfg["outbounds"] = [
                    {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
                    {"protocol": "blackhole", "tag": "block", "settings": {"response": {"type": "http"}}},
                    build_dns_outbound()
                ]
                cfg["routing"] = {
                    "domainStrategy": "IPOnDemand",
                    "rules": build_rules([], direct_mode=True)
                }
                print("[!] Нет доступных серверов (только заглушки). Создан DIRECT-конфиг.", file=sys.stderr)
            else:
                chosen_tag = chosen.get("tag") or "proxy"
                chosen_tag = re.sub(r'[^\w\-]', '_', chosen_tag)[:64] or "proxy"
                if "tag" not in chosen:
                    chosen["tag"] = chosen_tag

                chosen = normalize_vless_outbound(chosen, chosen_tag)

                direct_outbound = {
                    "protocol": "freedom",
                    "tag": "direct",
                    "settings": {"domainStrategy": "UseIPv4"},
                    "streamSettings": {"sockopt": {"mark": 2, "tcpKeepAliveInterval": 30}}
                }

                cfg["outbounds"] = [
                    chosen,
                    direct_outbound,
                    {"protocol": "blackhole", "tag": "block", "settings": {"response": {"type": "http"}}},
                    build_dns_outbound()
                ]
                cfg["routing"] = {
                    "domainStrategy": "IPOnDemand",
                    "rules": build_rules([chosen])
                }
                print(f"  ✓ Выбран сервер: {chosen_tag}", file=sys.stderr)

    # Сохраняем результат
    with open(args.output, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"  ✓ Конфиг сохранен: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
