#!/usr/bin/env python3
"""
Xray Config Generator for DietPi (Debian ARM) TProxy

Вход — унифицированный JSON от xray-sub-parser.py:
  {"hole": bool, "remarks": str, "reason": str, "outbounds": [...]}

DIRECT-режим:
  Если подписка истекла ("hole") или в профиле не осталось рабочих серверов
  (пустой outbounds — например, исчерпан лимит устройств), генерируется
  DIRECT-конфиг: весь трафик идёт напрямую, прокси отключены.

Балансировка:
  Используется стратегия leastLoad с burstObservatory для выбора наиболее стабильного прокси.
"""

import json
import os
import sys
import argparse

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# Переопределяется переменной окружения XRAY_SETTINGS_PATH (используется в тестах)
SETTINGS_PATH = os.environ.get("XRAY_SETTINGS_PATH", "/etc/xray/settings.json")

# settings.json — единственный источник настроек.
# Значения по умолчанию ниже нужны только для settings.json от старых версий,
# где соответствующих ключей ещё нет.
DEFAULT_TCP_KEEPALIVE_INTERVAL = 30
DEFAULT_DNS_SERVERS = [
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
        "address": "https+local://juuri.hagezi.org/dns-query",
        "skipFallback": False
    }
]
DEFAULT_DNS_HOSTS = {
    "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
    "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
    "juuri.hagezi.org": ["95.217.163.17"]
}

_settings_cache = None


def load_settings() -> dict:
    """Загружает settings.json (единственный источник настроек)"""
    global _settings_cache
    if _settings_cache is None:
        try:
            with open(SETTINGS_PATH, encoding="utf-8") as f:
                _settings_cache = json.load(f)
        except FileNotFoundError:
            print(f"  [!] {SETTINGS_PATH} не найден — используются значения по умолчанию",
                  file=sys.stderr)
            _settings_cache = {}
        except Exception as e:
            # Настройки — источник истины: битый файл нельзя молча игнорировать
            print(f"  [X] Не удалось прочитать {SETTINGS_PATH}: {e}", file=sys.stderr)
            sys.exit(1)

        if not isinstance(_settings_cache, dict):
            print(f"  [X] {SETTINGS_PATH}: ожидался JSON-объект", file=sys.stderr)
            sys.exit(1)
    return _settings_cache


def setting(path: str, default=None):
    """Читает значение по пути вида "xray.bypass_mark"; default — если ключа нет"""
    node = load_settings()
    for key in path.split("."):
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return default if node is None else node


def load_routing() -> dict:
    """Загружает routing-категории из settings.json"""
    return setting("routing", {})

def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def _migrate_ws_host(ob: dict) -> None:
    """
    Подписка иногда кладёт Host в устаревший wsSettings.headers.Host.
    По документации приоритет wsSettings: host > headers > address,
    поэтому переносим значение в host и убираем опустевший headers.
    """
    ws = ob.get("streamSettings", {}).get("wsSettings")
    if not isinstance(ws, dict):
        return

    headers = ws.get("headers")
    if not isinstance(headers, dict):
        return

    host = headers.pop("Host", None) or headers.pop("host", None)
    if host and not ws.get("host"):
        ws["host"] = host
    if not headers:
        ws.pop("headers", None)


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}

    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}

    ob["streamSettings"]["sockopt"]["mark"] = setting("xray.bypass_mark", 2)
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = setting(
        "xray.tcp_keepalive_interval", DEFAULT_TCP_KEEPALIVE_INTERVAL)

    _migrate_ws_host(ob)

    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False

    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS (параметры — из settings.json)"""
    tproxy_port = setting("xray.tproxy_port", 12345)
    dns_in_port = setting("xray.dns_in_port", 5353)

    return {
        "log": {
            "loglevel": setting("log.loglevel", "none"),
            "access": setting("log.access", "/var/log/xray-access.log"),
            "error": setting("log.error", "/var/log/xray-error.log")
        },
        "dns": {
            "tag": "dns-inbuilt",
            "queryStrategy": setting("dns.query_strategy", "UseIPv4"),
            "disableCache": setting("dns.disable_cache", False),
            "serveStale": setting("dns.serve_stale", True),
            "serveExpiredTTL": setting("dns.serve_expired_ttl", 1800),
            "disableFallback": setting("dns.disable_fallback", False),
            "disableFallbackIfMatch": setting("dns.disable_fallback_if_match", True),
            "enableParallelQuery": setting("dns.enable_parallel_query", True),
            "hosts": setting("dns.hosts", DEFAULT_DNS_HOSTS),
            "servers": setting("dns.servers", DEFAULT_DNS_SERVERS)
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": tproxy_port,
                "protocol": "tunnel",
                "settings": {
                    "allowedNetwork": "tcp,udp",
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
                "port": dns_in_port,
                "protocol": "tunnel",
                "settings": {
                    "allowedNetwork": "tcp,udp"
                }
            }
        ]
    }


def build_direct_config() -> dict:
    """Создаёт DIRECT-конфиг (без прокси) для режима 'hole'"""
    cfg = base_config()
    cfg["outbounds"] = [
        _default_direct_outbound(),
        _default_block_outbound(),
        build_dns_outbound()
    ]
    rt = load_routing()
    doh = rt.get("doh_bypass", [])
    block_domains = rt.get("block", {}).get("domains", [])
    direct_ips = rt.get("direct", {}).get("ips", [])
    direct_domains = rt.get("direct", {}).get("domains", [])

    cfg["routing"] = {
        "domainStrategy": setting("routing.domain_strategy", "IPOnDemand"),
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
                "domain": doh,
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": block_domains,
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": direct_ips,
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": direct_domains,
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
                    "qType": "1,28"
                }
            ]
        }
    }


def build_rules(proxy_outbounds: list) -> list:
    """
    Строит правила маршрутизации.
    Если proxy_outbounds пуст — все правила ведут на direct.
    Если несколько прокси — использует балансировщик.
    """
    rt = load_routing()
    doh = rt.get("doh_bypass", [])
    block_domains = rt.get("block", {}).get("domains", [])
    direct_ips = rt.get("direct", {}).get("ips", [])
    direct_domains = rt.get("direct", {}).get("domains", [])
    proxy_domains = rt.get("proxy", {}).get("domains", [])

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
            "domain": doh,
            "outboundTag": "direct"
        },
        # Блокировка рекламы
        {
            "type": "field",
            "domain": block_domains,
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
            "ip": direct_ips,
            "outboundTag": "direct"
        },
        # Локальные и российские домены — напрямую
        {
            "type": "field",
            "domain": direct_domains,
            "outboundTag": "direct"
        },
    ]

    if proxy_outbounds:
        use_balancer = len(proxy_outbounds) > 1
        target = "balancer" if use_balancer else proxy_outbounds[0]["tag"]
        route_key = "balancerTag" if use_balancer else "outboundTag"

        # Стриминг и игры — через прокси
        rules.append({
            "type": "field",
            "domain": proxy_domains,
            route_key: target
        })

        # Весь остальной трафик
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            route_key: target
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
    Создаёт конфигурацию балансировщика (leastLoad) по параметрам из settings.json:
      balancer.expected      — сколько лучших серверов использовать
      balancer.max_rtt       — отсечка по максимальному RTT
      balancer.baselines     — допустимое стандартное отклонение RTT (джиттер)
      balancer.fallback_tag  — outbound, если недоступны все
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    # expected не может превышать число серверов
    expected = setting("balancer.expected", 2)
    settings_block = {
        "expected": min(int(expected), len(proxy_outbounds)),
        "maxRTT": setting("balancer.max_rtt", "800ms"),
        "baselines": setting("balancer.baselines", ["200ms"]),
    }

    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": {
            "type": "leastLoad",
            "settings": settings_block,
        },
        "fallbackTag": setting("balancer.fallback_tag", "direct"),
    }


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт burstObservatory по параметрам из settings.json (секция observatory).
    Используется со стратегией leastLoad.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": setting("observatory.destination",
                                       "https://connectivitycheck.gstatic.com/generate_204"),
                "interval": setting("observatory.interval", "1m"),
                "sampling": setting("observatory.sampling", 10),
                "timeout": setting("observatory.timeout", "15s"),
                "httpMethod": setting("observatory.http_method", "GET"),
            }
        }
    }


# ============================================
#   СБОРКА КОНФИГА
# ============================================

def _default_direct_outbound() -> dict:
    return {
        "protocol": "freedom",
        "tag": "direct",
        "streamSettings": {
            "sockopt": {
                "mark": setting("xray.bypass_mark", 2),
                "tcpKeepAliveInterval": setting(
                    "xray.tcp_keepalive_interval", DEFAULT_TCP_KEEPALIVE_INTERVAL),
                "domainStrategy": setting("xray.direct_domain_strategy", "UseIPv4"),
            }
        }
    }

def _default_block_outbound() -> dict:
    return {
        "protocol": "blackhole",
        "tag": "block",
        "settings": {"response": {"type": "http"}}
    }

def write_config(cfg: dict, output_path: str) -> None:
    """Записывает config.json на диск"""
    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def assemble_config(proxy_outbounds: list, output_path: str):
    """Собирает полный конфиг Xray из списка прокси-серверов и сохраняет."""
    if not proxy_outbounds:
        print("  [!] Нет прокси-серверов — DIRECT-режим", file=sys.stderr)

    cfg = base_config()
    cfg["outbounds"] = proxy_outbounds + [
        _default_direct_outbound(),
        _default_block_outbound(),
        build_dns_outbound()
    ]

    if len(proxy_outbounds) > 1:
        cfg.update(build_burst_observatory(proxy_outbounds))

    routing = {
        "domainStrategy": setting("routing.domain_strategy", "IPOnDemand"),
        "rules": build_rules(proxy_outbounds),
    }

    if len(proxy_outbounds) > 1:
        routing["balancers"] = [build_balancer(proxy_outbounds)]

    cfg["routing"] = routing

    print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
    if len(proxy_outbounds) > 1:
        print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)

    write_config(cfg, output_path)
    print(f"  ✓ Конфиг сохранён: {output_path}", file=sys.stderr)


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for DietPi TProxy')
    parser.add_argument('--output', required=True, help='Куда записать config.json')
    parser.add_argument('--format', choices=['unified'], default='unified',
                        help='Формат входа. Поддерживается только unified '
                             '(вывод xray-sub-parser.py); опция оставлена для совместимости')
    return parser.parse_args()


def main():
    args = parse_args()

    try:
        data = json.load(sys.stdin)
    except Exception as e:
        log_error(f"[X] Не удалось разобрать входной JSON: {e}")
        sys.exit(1)

    if not isinstance(data, dict):
        log_error('[X] Ожидался объект {"hole": bool, "outbounds": [...]} '
                  'от xray-sub-parser.py')
        sys.exit(1)

    if data.get("remarks"):
        print(f"  → Профиль подписки: {data['remarks']}", file=sys.stderr)

    hole = bool(data.get("hole", False))
    proxy_outbounds = [normalize_outbound(ob) for ob in data.get("outbounds") or []]

    if hole or not proxy_outbounds:
        if hole:
            print("  [!] Подписка истекла (сервер 'hole').", file=sys.stderr)
        else:
            print("  [!] В профиле нет рабочих серверов "
                  "(лимит устройств или заглушки).", file=sys.stderr)
        print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
        write_config(build_direct_config(), args.output)
        print(f"  ✓ DIRECT-конфиг сохранён: {args.output}", file=sys.stderr)
        return

    assemble_config(proxy_outbounds, args.output)


if __name__ == "__main__":
    main()
