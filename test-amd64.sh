#!/bin/bash
# Самопроверка XPowerSpirit-Linux-Gateway (amd64 / ubuntu:24.04).
#
# Запуск: bash test-amd64.sh [--no-xray]
#
# Проверяет:
#   1. синтаксис shell-скриптов и Python-модулей;
#   2. валидность settings.default.json;
#   3. парсер подписок (Base64 VLESS + JSON Happ/Sing-box, режим "hole", фильтр remarks);
#   4. генератор config.json (балансировщик, DIRECT-режим, выбор сервера по dwl_domain);
#   5. что каждый сгенерированный config.json принимается настоящим Xray (xray run -test).
#
# --no-xray  пропустить загрузку Xray и проверки через "xray run -test".
#
# Требует: curl, unzip, jq, python3.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PARSER="$ROOT/xray-sub-parser.py"
GENERATOR="$ROOT/xray-generate-config.py"
XRAY_BIN="$WORK/xray"
XRAY_MACHINE="${XRAY_MACHINE:-64}"
XRAY_VERSION=""

USE_XRAY=1
[ "${1:-}" = "--no-xray" ] && USE_XRAY=0

PASS=0
FAIL=0
SKIP=0

ok()      { echo "  [ok]   $*"; PASS=$((PASS + 1)); }
bad()     { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip()    { echo "  [skip] $*"; SKIP=$((SKIP + 1)); }
section() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------
#   ВСПОМОГАТЕЛЬНОЕ
# ---------------------------------------------------------------

# Проверяет выражение jq на файле конфига
jq_is() {
	local expr="$1" file="$2" want="$3" desc="$4"
	local got
	got=$(jq -c "$expr" "$file" 2>/dev/null)
	if [ "$got" = "$want" ]; then
		ok "$desc"
	else
		bad "$desc (ожидалось: $want, получено: ${got:-<ошибка jq>})"
	fi
}

# Запускает "xray run -test" на конфиге
xray_test() {
	local file="$1" desc="$2"
	if [ ! -x "$XRAY_BIN" ]; then
		skip "$desc (нет бинарника Xray)"
		return
	fi
	if XRAY_LOCATION_ASSET="$WORK" "$XRAY_BIN" run -test -config "$file" >"$WORK/xray-test.log" 2>&1; then
		if grep -q "deprecated" "$WORK/xray-test.log"; then
			ok "$desc (с предупреждениями об устаревших полях)"
		else
			ok "$desc"
		fi
	else
		bad "$desc"
		grep -E "Failed|invalid|illegal|cannot" "$WORK/xray-test.log" | tail -3 | sed 's/^/         /'
	fi
}

# ---------------------------------------------------------------
#   ЗАГРУЗКА XRAY
# ---------------------------------------------------------------

download_xray() {
	echo "  → Определяю последнюю версию Xray..."
	XRAY_VERSION=$(curl -s --max-time 15 \
		https://api.github.com/repos/XTLS/Xray-core/releases/latest |
		sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
	if [ -z "$XRAY_VERSION" ]; then
		bad "не удалось получить версию Xray (GitHub API)"
		return 1
	fi

	local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_MACHINE}.zip"

	if ! curl -sL --max-time 30 -o "$WORK/xray.zip.dgst" "${url}.dgst"; then
		bad "не удалось скачать $XRAY_VERSION .dgst"
		return 1
	fi
	local remote_sha
	remote_sha=$(awk -F '= ' '/^SHA2-256/{print $2}' "$WORK/xray.zip.dgst" | tr -d ' \n')
	if [ -z "$remote_sha" ]; then
		bad "не удалось извлечь SHA2-256 из .dgst"
		return 1
	fi

	if ! curl -sL --max-time 180 -o "$WORK/xray.zip" "$url"; then
		bad "не удалось скачать $XRAY_VERSION zip"
		return 1
	fi

	local local_sha
	local_sha=$(sha256sum "$WORK/xray.zip" | awk '{print $1}')
	if [ "$local_sha" != "$remote_sha" ]; then
		bad "SHA256 не совпадает для $XRAY_VERSION"
		return 1
	fi
	ok "Xray $XRAY_VERSION скачан, SHA256 совпадает"

	if ! unzip -o -q "$WORK/xray.zip" xray geoip.dat geosite.dat -d "$WORK"; then
		bad "не удалось распаковать архив Xray"
		return 1
	fi
	chmod 755 "$XRAY_BIN"
	ok "geoip.dat + geosite.dat распакованы (используются в run -test)"
}

# ---------------------------------------------------------------
#   ФИКСТУРЫ ПОДПИСОК
# ---------------------------------------------------------------

make_fixtures() {
	# Base64 VLESS: два узла — WS+TLS и TCP+REALITY
	printf '%s\n' \
		'vless://11111111-2222-3333-4444-555555555555@a.example.com:443?encryption=none&security=tls&sni=a.example.com&type=ws&path=%2Fws&host=a.example.com#Node_A' \
		'vless://66666666-7777-8888-9999-000000000000@b.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&type=tcp#Node_B' |
		base64 -w0 >"$WORK/sub64.txt"

	# JSON-подписка Happ/Sing-box: два профиля, служебные outbounds внутри
	jq -n '[
		{"remarks": "Profile-A", "outbounds": [
			{"tag": "direct", "protocol": "freedom"},
			{"tag": "block", "protocol": "blackhole"},
			{"tag": "dns-out", "protocol": "dns"},
			{"tag": "Proxy One", "protocol": "vless",
			 "settings": {"vnext": [{"address": "c.example.com", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none"}]}]},
			 "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "c.example.com"}}},
			{"tag": "Proxy Two", "protocol": "trojan",
			 "settings": {"servers": [{"address": "d.example.com", "port": 443, "password": "secret"}]},
			 "streamSettings": {"network": "grpc", "security": "tls", "grpcSettings": {"serviceName": "grpc"}}}
		]},
		{"remarks": "Profile-B", "outbounds": [
			{"tag": "Proxy Three", "protocol": "vless",
			 "settings": {"vnext": [{"address": "e.example.com", "port": 443, "users": [{"id": "77777777-8888-9999-0000-111111111111", "encryption": "none"}]}]},
			 "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "e.example.com"}}}
		]}
	]' >"$WORK/sub.json"

	# Подписка с истёкшим сроком (сервер "hole")
	jq -n '[{"remarks": "Expired", "outbounds": [
		{"tag": "hole", "protocol": "vless",
		 "settings": {"vnext": [{"address": "hole", "port": 1, "users": [{"id": "00000000-0000-0000-0000-000000000000", "encryption": "none"}]}]}}
	]}]' >"$WORK/sub_hole.json"

	# settings.json на основе штатного, но с категориями geosite из официального набора
	# (кастомные категории проекта лежат в geoip-builder/geosite-builder и не нужны для теста логики)
	jq '.routing.direct.domains = ["geosite:private"]
		| .routing.direct.ips = ["geoip:private"]
		| .routing.block.domains = ["geosite:category-ads"]
		| .routing.proxy.domains = ["geosite:google"]' \
		"$ROOT/settings.default.json" >"$WORK/settings.test.json"
}

# ---------------------------------------------------------------
#   1. СТАТИЧЕСКИЕ ПРОВЕРКИ
# ---------------------------------------------------------------

test_static() {
	section "Синтаксис и структура"

	local f
	for f in "$ROOT"/*.sh; do
		if bash -n "$f" 2>"$WORK/bashn.log"; then
			ok "bash -n $(basename "$f")"
		else
			bad "bash -n $(basename "$f")"
			sed 's/^/         /' "$WORK/bashn.log"
		fi
	done

	for f in "$ROOT"/*.py; do
		if python3 -m py_compile "$f" 2>"$WORK/py.log"; then
			ok "py_compile $(basename "$f")"
		else
			bad "py_compile $(basename "$f")"
			sed 's/^/         /' "$WORK/py.log"
		fi
	done

	if jq empty "$ROOT/settings.default.json" 2>/dev/null; then
		ok "settings.default.json — валидный JSON"
	else
		bad "settings.default.json — невалидный JSON"
	fi
}

# ---------------------------------------------------------------
#   2. ПАРСЕР ПОДПИСОК
# ---------------------------------------------------------------

test_parser() {
	section "Парсер подписок (xray-sub-parser.py)"

	# Base64 VLESS → унифицированный формат
	if python3 "$PARSER" --ua "Test/1.0" <"$WORK/sub64.txt" >"$WORK/parsed_vless.json" 2>/dev/null; then
		ok "Base64 VLESS → unified JSON"
		jq_is '.hole' "$WORK/parsed_vless.json" "false" "hole=false для действующей подписки"
		jq_is '.outbounds | length' "$WORK/parsed_vless.json" "2" "разобраны оба vless:// узла"
		jq_is '[.outbounds[].streamSettings.network] | sort' "$WORK/parsed_vless.json" '["tcp","ws"]' "транспорты ws/tcp распознаны"
		jq_is '[.outbounds[].streamSettings.security] | sort' "$WORK/parsed_vless.json" '["reality","tls"]' "security tls/reality распознаны"
		jq_is '.outbounds[1].settings.vnext[0].users[0].flow' "$WORK/parsed_vless.json" '"xtls-rprx-vision"' "flow xtls-rprx-vision сохранён"
		jq_is '.outbounds[1].streamSettings.realitySettings.publicKey | length' "$WORK/parsed_vless.json" "43" "reality publicKey сохранён"
		jq_is '.outbounds[0].streamSettings.wsSettings.host' "$WORK/parsed_vless.json" '"a.example.com"' "WS host → wsSettings.host"
		jq_is '.outbounds[0].streamSettings.wsSettings.headers' "$WORK/parsed_vless.json" "null" "устаревший headers.Host не используется"
	else
		bad "Base64 VLESS → unified JSON"
	fi

	# JSON-подписка (Happ/Sing-box)
	if python3 "$PARSER" --ua "Happ/2.0" <"$WORK/sub.json" >"$WORK/parsed_json.json" 2>/dev/null; then
		ok "JSON-подписка → unified JSON"
		jq_is '.outbounds | length' "$WORK/parsed_json.json" "3" "служебные freedom/blackhole/dns отброшены"
		jq_is '[.outbounds[].protocol] | sort' "$WORK/parsed_json.json" '["trojan","vless","vless"]' "протоколы из подписки сохранены"
		jq_is '[.outbounds[].tag] | unique | length' "$WORK/parsed_json.json" "3" "теги нормализованы и уникальны"
		jq_is '[.outbounds[].tag] | map(select(test(" "))) | length' "$WORK/parsed_json.json" "0" "пробелы из тегов убраны"
	else
		bad "JSON-подписка → unified JSON"
	fi

	# Фильтр по remarks
	if python3 "$PARSER" --ua "Happ/2.0" --remarks "profile-b" <"$WORK/sub.json" >"$WORK/parsed_remarks.json" 2>/dev/null; then
		ok "фильтр --remarks"
		jq_is '.outbounds | length' "$WORK/parsed_remarks.json" "1" "--remarks оставил только Profile-B (регистр не важен)"
	else
		bad "фильтр --remarks"
	fi

	# Режим "hole"
	if python3 "$PARSER" --ua "Happ/2.0" <"$WORK/sub_hole.json" >"$WORK/parsed_hole.json" 2>/dev/null; then
		ok "подписка с истёкшим сроком → unified JSON"
		jq_is '.hole' "$WORK/parsed_hole.json" "true" "сервер 'hole' обнаружен"
	else
		bad "подписка с истёкшим сроком → unified JSON"
	fi

	# Старый режим (без --ua) — обратная совместимость
	if python3 "$PARSER" <"$WORK/sub64.txt" >"$WORK/parsed_legacy.json" 2>/dev/null; then
		ok "старый режим (без --ua) → массив outbounds"
		jq_is 'type' "$WORK/parsed_legacy.json" '"array"' "на выходе JSON-массив"
		jq_is 'length' "$WORK/parsed_legacy.json" "2" "оба узла на месте"
	else
		bad "старый режим (без --ua) → массив outbounds"
	fi

	# Битый вход не должен ронять парсер с трейсбеком
	if python3 "$PARSER" --ua "Test/1.0" </dev/null >"$WORK/parsed_empty.json" 2>/dev/null; then
		jq_is '.outbounds | length' "$WORK/parsed_empty.json" "0" "пустой ввод → пустой список (без падения)"
	else
		ok "пустой ввод → код возврата 1 (без падения)"
	fi
}

# ---------------------------------------------------------------
#   3. ГЕНЕРАТОР КОНФИГА
# ---------------------------------------------------------------

test_generator() {
	section "Генератор config.json (xray-generate-config.py)"
	export XRAY_SETTINGS_PATH="$WORK/settings.test.json"

	# --- Два прокси: балансировщик + наблюдение ---
	if python3 "$GENERATOR" --format unified --output "$WORK/cfg_balance.json" \
		<"$WORK/parsed_vless.json" 2>/dev/null; then
		ok "два прокси → config.json создан"
		jq_is '.routing.balancers[0].tag' "$WORK/cfg_balance.json" '"balancer"' "балансировщик добавлен"
		jq_is '.routing.balancers[0].strategy.type' "$WORK/cfg_balance.json" '"leastLoad"' "стратегия leastLoad"
		jq_is '.routing.balancers[0].fallbackTag' "$WORK/cfg_balance.json" '"direct"' "fallbackTag = direct"
		jq_is '.routing.balancers[0].selector | length' "$WORK/cfg_balance.json" "2" "в selector оба прокси"
		jq_is '.burstObservatory.pingConfig.sampling' "$WORK/cfg_balance.json" "10" "burstObservatory настроен"
		jq_is '[.routing.rules[] | select(.balancerTag)] | length' "$WORK/cfg_balance.json" "2" "правила маршрутизации → balancerTag"
		jq_is '.inbounds[0].streamSettings.sockopt.tproxy' "$WORK/cfg_balance.json" '"tproxy"' "TProxy включён на инбаунде"
		jq_is '.inbounds[0].settings.followRedirect' "$WORK/cfg_balance.json" "true" "followRedirect включён"
		jq_is '.inbounds[0].protocol' "$WORK/cfg_balance.json" '"tunnel"' "tproxy-in: protocol tunnel"
		jq_is '.inbounds[0].settings.allowedNetwork' "$WORK/cfg_balance.json" '"tcp,udp"' "tproxy-in: allowedNetwork"
		jq_is '.inbounds[1].settings.allowedNetwork' "$WORK/cfg_balance.json" '"tcp,udp"' "dns-in: allowedNetwork"
		jq_is '[.inbounds[].settings.network] | map(select(. != null)) | length' "$WORK/cfg_balance.json" "0" "устаревшее поле settings.network не используется"
		jq_is '.inbounds[0].sniffing.routeOnly' "$WORK/cfg_balance.json" "true" "sniffing.routeOnly включён"
		jq_is '[.. | objects | select(has("tcpNoDelay"))] | length' "$WORK/cfg_balance.json" "0" "нет недокументированного sockopt.tcpNoDelay"
		jq_is '[.outbounds[] | select(.settings.domainStrategy != null)] | length' "$WORK/cfg_balance.json" "0" "нет устаревшего freedom.settings.domainStrategy"
		jq_is '[.outbounds[] | select(.tag == "direct")][0].streamSettings.sockopt.domainStrategy' \
			"$WORK/cfg_balance.json" '"UseIPv4"' "direct: sockopt.domainStrategy = UseIPv4"
		jq_is '[.outbounds[] | select(.protocol == "dns")][0].settings.rules[0].qType' "$WORK/cfg_balance.json" '"1,28"' "DNS-правило использует qType"
		jq_is '[.outbounds[] | select(.protocol == "dns")][0].settings.rules[0].qtype' "$WORK/cfg_balance.json" "null" "нижний регистр qtype не используется"
		jq_is '.burstObservatory.pingConfig.destination | startswith("https://")' "$WORK/cfg_balance.json" "true" "пинг балансировщика по https"
		jq_is '[.outbounds[] | select(.protocol != "freedom" and .protocol != "blackhole" and .protocol != "dns") | .streamSettings.sockopt.mark] | unique' \
			"$WORK/cfg_balance.json" "[2]" "все прокси помечены mark=2 (защита от петель)"
		jq_is '[.routing.rules[] | select(.outboundTag == "block")] | length' "$WORK/cfg_balance.json" "2" "правила блокировки на месте"
		jq_is '[.outbounds[] | select(.protocol == "dns")] | length' "$WORK/cfg_balance.json" "1" "DNS-инбаунд с hijack присутствует"
		xray_test "$WORK/cfg_balance.json" "config.json с балансировщиком проходит xray run -test"
	else
		bad "два прокси → config.json создан"
	fi

	# --- Один прокси: без балансировщика ---
	if python3 "$GENERATOR" --format unified --output "$WORK/cfg_single.json" \
		<"$WORK/parsed_remarks.json" 2>/dev/null; then
		ok "один прокси → config.json создан"
		jq_is '.routing.balancers' "$WORK/cfg_single.json" "null" "балансировщик не добавлен"
		jq_is '.burstObservatory' "$WORK/cfg_single.json" "null" "burstObservatory не добавлен"
		jq_is '[.routing.rules[] | select(.outboundTag == "Proxy_Three")] | length' "$WORK/cfg_single.json" "2" "трафик идёт в единственный прокси"
		xray_test "$WORK/cfg_single.json" "config.json с одним прокси проходит xray run -test"
	else
		bad "один прокси → config.json создан"
	fi

	# --- Подписка истекла: DIRECT-режим ---
	if python3 "$GENERATOR" --format unified --output "$WORK/cfg_hole.json" \
		<"$WORK/parsed_hole.json" 2>/dev/null; then
		ok "режим hole → config.json создан"
		jq_is '.routing.balancers' "$WORK/cfg_hole.json" "null" "балансировщик отсутствует"
		jq_is '[.outbounds[].tag] | sort' "$WORK/cfg_hole.json" '["block","direct","dns-out"]' "только direct/block/dns-out"
		jq_is '[.routing.rules[] | select(.balancerTag != null)] | length' "$WORK/cfg_hole.json" "0" "нет правил на балансировщик"
		jq_is '[.routing.rules[-1].outboundTag]' "$WORK/cfg_hole.json" '["direct"]' "последнее правило (весь остальной трафик) → direct"
		xray_test "$WORK/cfg_hole.json" "DIRECT-конфиг проходит xray run -test"
	else
		bad "режим hole → config.json создан"
	fi

	# --- Старый формат vless + выбор сервера по dwl_domain ---
	jq '.subscription.dwl_domain = "b.example.com"' "$WORK/settings.test.json" >"$WORK/settings.dwl.json"
	if XRAY_SETTINGS_PATH="$WORK/settings.dwl.json" python3 "$GENERATOR" --format vless \
		--output "$WORK/cfg_dwl.json" <"$WORK/parsed_legacy.json" 2>/dev/null; then
		ok "формат vless → config.json создан"
		jq_is '[.outbounds[] | select(.protocol == "vless")] | length' "$WORK/cfg_dwl.json" "1" "выбран ровно один сервер"
		jq_is '[.outbounds[] | select(.protocol == "vless")][0].settings.vnext[0].address' \
			"$WORK/cfg_dwl.json" '"b.example.com"' "dwl_domain выбрал Node_B"
		xray_test "$WORK/cfg_dwl.json" "config.json (формат vless) проходит xray run -test"
	else
		bad "формат vless → config.json создан"
	fi

	# --- Штатный settings.default.json целиком ---
	# Кастомных категорий (geosite:category-ru и т.п.) нет в официальном geosite.dat,
	# поэтому проверяем только структуру, без xray run -test.
	if XRAY_SETTINGS_PATH="$ROOT/settings.default.json" python3 "$GENERATOR" --format unified \
		--output "$WORK/cfg_default.json" <"$WORK/parsed_vless.json" 2>/dev/null; then
		ok "генерация со штатным settings.default.json"
		jq_is '[.routing.rules[] | select(.domain != null) | .domain[]] | any(. == "geosite:category-ru")' \
			"$WORK/cfg_default.json" "true" "категории direct из settings попали в правила"
		jq_is '[.routing.rules[] | select(.outboundTag == "direct") | .domain[]?] | any(. == "cloudflare-dns.com")' \
			"$WORK/cfg_default.json" "true" "DoH bypass перенесён в правила"
		jq_is '.dns.hosts["cloudflare-dns.com"] | length' "$WORK/cfg_default.json" "2" "hosts для DoH-серверов на месте"
	else
		bad "генерация со штатным settings.default.json"
	fi

	unset XRAY_SETTINGS_PATH
}

# ---------------------------------------------------------------
#   ЗАПУСК
# ---------------------------------------------------------------

echo "=== XPowerSpirit-Linux-Gateway — самопроверка ==="
echo "Каталог: $ROOT"

make_fixtures
test_static

if [ "$USE_XRAY" = "1" ]; then
	section "Загрузка Xray"
	download_xray || skip "проверки через xray run -test"
else
	section "Загрузка Xray"
	skip "проверки через xray run -test (--no-xray)"
fi

test_parser
test_generator

echo
echo "=== Итог: успешно $PASS, ошибок $FAIL, пропущено $SKIP ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
