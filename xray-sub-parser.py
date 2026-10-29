#!/usr/bin/env python3
"""
Xray Subscription Parser — DietPi (Debian ARM)

Подписка отдаётся только в формате JSON: массив полных конфигураций Xray,
у каждой свой "remarks" и свой набор outbounds.

Парсер выбирает один профиль (по умолчанию — первый в списке, либо тот,
чей remarks совпал с --remarks), отбрасывает служебные outbounds
(freedom, blackhole, dns, loopback) и выводит унифицированный JSON
для xray-generate-config.py:

  {"hole": bool, "remarks": str, "reason": str, "outbounds": [...]}

"hole" == true   — подписка истекла (в ней есть сервер с адресом "hole").
"reason"         — "expired" | "no_proxies" | "" для понятного лога.
Пустой "outbounds" — рабочих серверов нет (например, исчерпан лимит устройств:
провайдер отдаёт заглушку 0.0.0.0:1 с нулевым UUID). Генератор в обоих
случаях собирает DIRECT-конфиг.
"""
import sys
import json
import argparse
import urllib.request

# Служебные outbounds: не являются прокси-серверами и не годятся для балансировки
SERVICE_PROTOCOLS = ("freedom", "blackhole", "dns", "loopback")

# Признаки заглушки вместо реального сервера (так провайдер сообщает
# об окончании срока подписки или исчерпании лимита устройств)
PLACEHOLDER_ADDRESSES = ("", "0.0.0.0", "127.0.0.1", "hole")
ZERO_UUID = "00000000-0000-0000-0000-000000000000"


# -----------------------------
# ЛОГИРОВАНИЕ
# -----------------------------
def log(msg: str) -> None:
    """Служебные сообщения в stderr (попадают в journald и в лог обновления)"""
    print(msg, file=sys.stderr)


# -----------------------------
# НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def normalize_tag(tag: str) -> str:
    """Оставляет в теге только буквы, цифры, дефис и подчёркивание"""
    tag = (tag or "").strip()
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    allowed = [c for c in tag if c.isalnum() or c in "_-"]
    return "".join(allowed) or "proxy"


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
        with urllib.request.urlopen(data, timeout=15) as r:
            content = r.read()
    except Exception as e:
        log(f"[X] Не удалось скачать подписку: {e}")
        return "", False

    if b"<html" in content[:1024].lower() or b"<!doctype" in content[:1024].lower():
        log("[X] Подписка вернула HTML вместо JSON")
        return "", False

    return content.decode("utf-8", errors="replace"), True


# -----------------------------
# ПРОВЕРКА "HOLE" (подписка истекла)
# -----------------------------
def _outbound_addresses(ob: dict) -> list:
    """Собирает адреса серверов из outbound: vless (vnext), hysteria, trojan (servers)"""
    settings = ob.get("settings")
    if not isinstance(settings, dict):
        return []

    addrs = []
    for key in ("vnext", "servers"):
        entries = settings.get(key)
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, dict) and entry.get("address"):
                    addrs.append(entry["address"])

    if settings.get("address"):
        addrs.append(settings["address"])

    return addrs


def has_hole(configs: list) -> bool:
    """Подписка истекла: хотя бы в одном outbound адрес сервера равен "hole" """
    for config in configs:
        outbounds = config.get("outbounds")
        if not isinstance(outbounds, list):
            continue
        for ob in outbounds:
            if not isinstance(ob, dict):
                continue
            if "hole" in _outbound_addresses(ob):
                return True
    return False


def _server_entries(settings: dict) -> list:
    """Возвращает список описаний серверов из settings любого прокси-протокола"""
    entries = []
    if isinstance(settings.get("vnext"), list):
        entries.extend(settings["vnext"])
    if isinstance(settings.get("servers"), list):
        entries.extend(settings["servers"])
    if settings.get("address"):
        entries.append(settings)
    return [e for e in entries if isinstance(e, dict)]


def is_placeholder(ob: dict) -> bool:
    """
    Заглушка вместо реального сервера:
    адрес 0.0.0.0 / 127.0.0.1 / "hole", порт 1 или нулевой UUID пользователя.
    """
    settings = ob.get("settings")
    if not isinstance(settings, dict):
        return True

    entries = _server_entries(settings)
    if not entries:
        return True

    for entry in entries:
        if str(entry.get("address", "")) in PLACEHOLDER_ADDRESSES:
            return True
        if str(entry.get("port", "")) == "1":
            return True
        for user in entry.get("users") or []:
            if isinstance(user, dict) and user.get("id") == ZERO_UUID:
                return True

    return False


# -----------------------------
# ВЫБОР ПРОФИЛЯ
# -----------------------------
def select_profile(configs: list, remarks_filter: str):
    """
    Возвращает выбранный профиль.
    Без фильтра берётся первый профиль подписки; с фильтром — первый,
    в чьём remarks встречается подстрока (регистр не важен).
    """
    if not remarks_filter:
        chosen = configs[0]
        log(f"  → Профиль не задан, используется первый: {chosen.get('remarks', '(без имени)')}")
        return chosen

    for config in configs:
        if remarks_filter.lower() in str(config.get("remarks", "")).lower():
            log(f"  → Выбран профиль: {config.get('remarks', '')}")
            return config

    log(f"  [X] Профиль с remarks '{remarks_filter}' не найден!")
    log("  → Доступные профили:")
    for config in configs:
        log(f"      - {config.get('remarks', '')}")
    return None


# -----------------------------
# ИЗВЛЕЧЕНИЕ ПРОКСИ
# -----------------------------
def collect_outbounds(config: dict) -> list:
    """
    Берёт из профиля только рабочие прокси-серверы:
    служебные outbounds и заглушки отбрасываются.
    """
    result = []
    seen_tags = set()

    for ob in config.get("outbounds") or []:
        if not isinstance(ob, dict):
            continue

        protocol = ob.get("protocol", "")
        if protocol in SERVICE_PROTOCOLS:
            continue

        if is_placeholder(ob):
            log(f"  → Пропускаем заглушку: {ob.get('tag', '(без тега)')} ({protocol})")
            continue

        tag = normalize_tag(ob.get("tag"))
        base_tag = tag
        counter = 2
        while tag in seen_tags:
            tag = normalize_tag(f"{base_tag}-{counter}")
            counter += 1
        ob["tag"] = tag
        seen_tags.add(tag)

        result.append(ob)
        log(f"  → Outbound: {tag} ({protocol})")

    return result


# -----------------------------
# ТОЧКА ВХОДА
# -----------------------------
def main():
    parser = argparse.ArgumentParser(description='Xray subscription parser (JSON) — DietPi')
    parser.add_argument('--remarks', default='',
                        help='Фильтр по remarks: подстрока, регистр не важен. '
                             'Без него берётся первый профиль подписки')
    parser.add_argument('--ua', default='',
                        help='Не используется (подписка всегда JSON), оставлен для совместимости')
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        log("[X] Пустой ввод")
        sys.exit(1)

    data, success = try_download(raw)
    if not success or not data:
        sys.exit(1)

    try:
        payload = json.loads(data)
    except json.JSONDecodeError as e:
        log(f"[X] Подписка не является JSON: {e}")
        sys.exit(1)

    if isinstance(payload, dict):
        configs = [payload]
    elif isinstance(payload, list):
        configs = payload
    else:
        log("[X] Неожиданная структура JSON (ожидался массив или объект)")
        sys.exit(1)

    configs = [c for c in configs if isinstance(c, dict)]
    if not configs:
        log("[X] В подписке нет ни одной конфигурации")
        sys.exit(1)

    hole = has_hole(configs)
    if hole:
        log("  [!] Обнаружен сервер 'hole' — подписка истекла")

    chosen = select_profile(configs, args.remarks)
    if chosen is None:
        sys.exit(1)

    outbounds = collect_outbounds(chosen)

    reason = ""
    if hole:
        reason = "expired"
    elif not outbounds:
        reason = "no_proxies"
        log("  [!] В профиле нет рабочих серверов (лимит устройств или заглушки)")

    log(f"  → Прокси в профиле: {len(outbounds)}")

    print(json.dumps({
        "hole": hole,
        "remarks": chosen.get("remarks", ""),
        "reason": reason,
        "outbounds": outbounds,
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
