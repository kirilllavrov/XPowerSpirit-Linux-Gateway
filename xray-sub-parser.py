#!/usr/bin/env python3
"""
Xray Subscription Parser — DietPi (Debian ARM)
Поддерживает два входных формата:
  1. Base64 VLESS (традиционный) — без --ua или с любым неизвестным User-Agent
  2. JSON (Happ/Sing-box/Karing) — с --ua happ/singbox/sfa/sfi/sfm/sft/karing

Унифицированный режим (с --ua):
  Определяет формат по User-Agent, парсит, проверяет hole,
  выводит {"hole": bool, "outbounds": [...]}

Совместимость:
  Без --ua — поведение не меняется (Base64 VLESS, вывод JSON-массива outbounds).
"""
import sys
import base64
import json
import urllib.parse as urlparse
import urllib.request
import re
import argparse
import logging

# Настраиваем логирование
logging.basicConfig(
    level=logging.INFO,
    format='%(message)s',
    stream=sys.stderr
)
log = logging.getLogger("xray-parser")


# -----------------------------
# ЛОГИРОВАНИЕ ОШИБОК
# -----------------------------
def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr (также попадает в journald)"""
    print(msg, file=sys.stderr)


# -----------------------------
# НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def normalize_tag(tag: str) -> str:
    tag = urlparse.unquote(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание (без эмодзи во избежание re.error)
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


# -----------------------------
# ЗАГРУЗКА URL
# -----------------------------
def try_download(data: str) -> tuple:
    """
    Загружает данные по URL, если передан HTTP/HTTPS URL.
    Возвращает (содержимое, успех).
    """
    if not (data.startswith("http://") or data.startswith("https://")):
        return data, True

    try:
        with urllib.request.urlopen(data, timeout=10) as r:
            content = r.read()

            # Проверяем, что это не HTML ошибка
            content_lower = content.lower()
            if b"<html" in content_lower or b"<!doctype" in content_lower:
                log_error(f"Subscription returned HTML, not valid data: {data}")
                return "", False

            return content.decode("utf-8", errors="replace"), True
    except Exception as e:
        log_error(f"Failed to download subscription: {e}")
        return "", False


# -----------------------------
# УМНОЕ BASE64 (с поддержкой URL-safe)
# -----------------------------
def try_base64_decode(data: str) -> tuple:
    """Декодирует Base64, если это возможно. Возвращает (результат, успех)."""
    data = data.strip()

    # Если уже содержит vless:// — не трогаем
    if "vless://" in data:
        return data, True

    # Конвертируем URL-safe → стандартный Base64
    b64 = data.replace('-', '+').replace('_', '/')

    # Пробуем с padding и без
    for s in (b64, b64 + '=' * (-len(b64) % 4)):
        try:
            decoded = base64.b64decode(s).decode("utf-8", errors="replace")
            if "vless://" in decoded:
                return decoded, True
        except Exception:
            continue

    return data, False


# -----------------------------
# SAFE JSON PARSER FOR extra=
# -----------------------------
def parse_extra_json(extra_raw: str):
    if not extra_raw:
        return None
    try:
        decoded = urlparse.unquote(extra_raw)
        return json.loads(decoded)
    except Exception:
        return None


# -----------------------------
# ПРОВЕРКА HOLE
# -----------------------------
def _check_hole(ob: dict) -> bool:
    """Проверяет, является ли outbound сигналом 'hole' (окончание подписки)"""
    try:
        return ob.get("settings", {}).get("vnext", [{}])[0].get("address", "") == "hole"
    except Exception:
        return False


# -----------------------------
# ПАРСЕР VLESS
# -----------------------------
def parse_vless_uri(uri: str, idx: int):
    parsed = urlparse.urlparse(uri)

    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port if parsed.port is not None else 443

    # ТЕГ
    fragment = parsed.fragment or ""
    tag = normalize_tag(fragment) if fragment else f"proxy-vless-{idx}"

    # QUERY
    q = urlparse.parse_qs(parsed.query)

    def get_param(key, default=None):
        v = q.get(key)
        return v[0] if v else default

    # БАЗОВЫЕ ПОЛЯ
    uuid = user
    encryption = get_param("encryption", "none")
    flow = get_param("flow", None)

    # ТРАНСПОРТ
    network = get_param("type", "tcp").lower()
    if network in ("h2", "http2"):
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        network = "tcp"

    # SECURITY
    security = get_param("security", "none").lower()
    if security in ("tls", "xtls"):
        security_mode = "tls"
    elif security == "reality":
        security_mode = "reality"
    else:
        security_mode = "none"

    sni = get_param("sni", None)
    fp = get_param("fp", None)
    alpn_raw = get_param("alpn", None)
    alpn = [x.strip() for x in alpn_raw.split(",")] if alpn_raw else None
    allow_insecure = get_param("allowInsecure", "0") in ("1", "true", "yes")

    # REALITY
    pbk = get_param("pbk", None)
    sid = get_param("sid", None)
    spx = get_param("spx", None)

    # WS / HTTP / XHTTP / gRPC
    path = get_param("path", "/")
    host_header = get_param("host", None)
    grpc_service = get_param("serviceName", None) or get_param("grpc-service-name", None)
    xhttp_mode = get_param("mode", None)
    extra_raw = get_param("extra", None)

    # SETTINGS
    user_obj = {"id": uuid, "encryption": encryption}
    if flow:
        user_obj["flow"] = flow

    settings = {
        "vnext": [
            {
                "address": host,
                "port": port,
                "users": [user_obj]
            }
        ]
    }

    # STREAM SETTINGS
    stream = {"network": network}

    # TLS / REALITY
    if security_mode == "tls":
        stream["security"] = "tls"
        tls = {}
        if sni:
            tls["serverName"] = sni
        if alpn:
            tls["alpn"] = alpn
        if fp:
            tls["fingerprint"] = fp
        if allow_insecure:
            tls["allowInsecure"] = True
        if tls:
            stream["tlsSettings"] = tls

    elif security_mode == "reality":
        stream["security"] = "reality"
        reality = {}
        if sni:
            reality["serverName"] = sni
        if pbk:
            reality["publicKey"] = pbk
        if sid:
            reality["shortId"] = sid
        if spx:
            reality["spiderX"] = spx
        if fp:
            reality["fingerprint"] = fp
        stream["realitySettings"] = reality

    # NETWORK-SPECIFIC
    if network == "ws":
        ws = {"path": path}
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws

    elif network == "grpc":
        grpc = {}
        if grpc_service:
            grpc["serviceName"] = grpc_service
        stream["grpcSettings"] = grpc

    elif network == "http":
        http = {"path": path}
        if host_header:
            http["host"] = [host_header]
        stream["httpSettings"] = http

    elif network == "xhttp":
        xhttp = {"path": path}
        if host_header:
            xhttp["host"] = [host_header]
        if xhttp_mode:
            xhttp["mode"] = xhttp_mode

        extra_obj = parse_extra_json(extra_raw)
        if extra_obj:
            xhttp["extra"] = extra_obj

        stream["xhttpSettings"] = xhttp

    return {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream
    }


# -----------------------------
# ПАРСЕР VLESS-СТРОК
# -----------------------------
def _parse_vless_lines(data: str) -> tuple:
    """Парсит все vless:// URI из текста. Возвращает (outbounds, hole)."""
    lines = [l.strip() for l in data.splitlines() if l.strip()]
    outbounds = []
    hole = False
    idx = 0

    for line in lines:
        if line.startswith("vless://"):
            ob = parse_vless_uri(line, idx)
            if ob:
                if _check_hole(ob):
                    hole = True
                outbounds.append(ob)
                idx += 1

    return outbounds, hole


# ============================================
#   УНИФИЦИРОВАННЫЙ РЕЖИМ (--ua)
# ============================================

def _is_json_format(user_agent: str) -> bool:
    """Определяет, является ли User-Agent признаком JSON-подписки"""
    ua_lower = user_agent.lower()
    json_markers = ["xpower", "happ", "singbox", "sfa", "sfi", "sfm", "sft", "karing"]
    return any(m in ua_lower for m in json_markers)


def parse_json_subscription(raw_data: str, remarks_filter: str = '') -> dict:
    """
    Парсит JSON-подписку (Happ/Sing-box формат).
    Возвращает {"hole": bool, "outbounds": [сырые outbounds из подписки]}.
    """
    try:
        data = json.loads(raw_data)
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return {"hole": False, "outbounds": []}

    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        log_error("Unexpected JSON structure (expected list or dict)")
        return {"hole": False, "outbounds": []}

    # Проверка hole
    hole = False
    for config in data:
        for ob in config.get("outbounds", []):
            if _check_hole(ob):
                hole = True
                break

    # Извлечение outbounds
    all_outbounds = []
    seen_tags = set()
    found_profile = False

    for config in data:
        config_remarks = config.get("remarks", "")

        # Фильтрация по remarks
        if remarks_filter:
            if remarks_filter.lower() not in config_remarks.lower():
                print(f"  → Пропускаем профиль: {config_remarks}", file=sys.stderr)
                continue

        found_profile = True
        print(f"  → Используем профиль: {config_remarks}", file=sys.stderr)

        for ob in config.get("outbounds", []):
            protocol = ob.get("protocol", "")
            # Пропускаем служебные outbounds
            if protocol in ("freedom", "blackhole", "dns"):
                continue

            # Нормализуем тег (минимально)
            tag = ob.get("tag", "") or "proxy"
            tag = normalize_tag(tag)
            counter = 2
            base_tag = tag
            while tag in seen_tags:
                tag = normalize_tag(f"{base_tag}-{counter}")
                counter += 1
            ob["tag"] = tag
            seen_tags.add(tag)

            all_outbounds.append(ob)

    if remarks_filter and not found_profile:
        print(f"  [X] Профиль с remarks '{remarks_filter}' не найден!", file=sys.stderr)
        print(f"  → Доступные профили:", file=sys.stderr)
        for config in data:
            print(f"      - {config.get('remarks', '')}", file=sys.stderr)

    return {"hole": hole, "outbounds": all_outbounds}


def unified_main():
    """
    Унифицированный режим: определяет формат по --ua, парсит подписку,
    выводит {"hole": bool, "outbounds": [...]}.
    """
    parser = argparse.ArgumentParser(description='Xray subscription parser (unified) - DietPi')
    parser.add_argument('--ua', required=True, help='User-Agent used for subscription request')
    parser.add_argument('--remarks', default='', help='Filter by remarks (JSON format only)')
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        log_error("Empty input")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    # Загружаем по URL, если нужно
    data, success = try_download(raw)
    if not success or not data:
        log_error("Failed to download subscription")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    if _is_json_format(args.ua):
        # --- JSON формат (Happ/Sing-box) ---
        print("  → Определён JSON формат подписки (Happ/Sing-box)", file=sys.stderr)
        result = parse_json_subscription(data, args.remarks)
    else:
        # --- Base64 VLESS формат ---
        print("  → Определён Base64 VLESS формат подписки", file=sys.stderr)

        data, decoded = try_base64_decode(data)
        if not decoded:
            log_error("Failed to decode Base64 (no vless:// found)")
            print(json.dumps({"hole": False, "outbounds": []}))
            sys.exit(1)

        outbounds, hole = _parse_vless_lines(data)
        if not outbounds:
            log_error("No valid vless:// URIs parsed")

        result = {"hole": hole, "outbounds": outbounds}

    print(json.dumps(result, indent=2, ensure_ascii=False))


# ================================================
#   СТАРЫЙ РЕЖИМ (без --ua) — обратная совместимость
# ================================================
def main():
    raw = sys.stdin.read().strip()
    if not raw:
        log_error("Empty input")
        print("[]")
        sys.exit(1)

    # Загружаем по URL, если нужно
    data, success = try_download(raw)
    if not success or not data:
        log_error("Failed to download subscription")
        print("[]")
        sys.exit(1)

    # Пробуем декодировать Base64
    data, decoded = try_base64_decode(data)
    if not decoded:
        log_error("Failed to decode Base64 (no vless:// found after decoding)")
        print("[]")
        sys.exit(1)

    # Проверяем, что в данных есть vless://
    if "vless://" not in data:
        log_error("No vless:// URIs found in subscription")
        print("[]")
        sys.exit(1)

    outbounds, _ = _parse_vless_lines(data)

    if not outbounds:
        log_error("No valid vless:// URIs parsed")
        print("[]")
        sys.exit(1)

    print(json.dumps(outbounds, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    # Если передан --ua → унифицированный режим
    if "--ua" in sys.argv:
        unified_main()
    else:
        main()
