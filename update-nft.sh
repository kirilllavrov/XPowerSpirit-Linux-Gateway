#!/bin/bash
# Ubuntu/Debian ARM — nftables правила для Xray Transparent Gateway
#
# Режим: прозрачный шлюз (не основной роутер).
# Трафик клиентов с LAN + собственный трафик шлюза проксируются через Xray TProxy.
# Локальные сервисы (TorrServer, dnsmasq, SSH) и трафик самого Xray — bypass.
#
# Защита от петель:
#   1. mark=2 — bypass (sockopt.mark в Xray outbounds)
#   2. skgid xray — bypass исходящего трафика процессов группы xray
#   3. fib daddr type local — bypass всех локальных сервисов (TorrServer, dnsmasq, etc.)
#
# Использует отдельную таблицу inet xray (не пересекается с системной).

set -e

# ============================================
#   КОНФИГУРАЦИЯ (умолчания)
# ============================================
XRAY_GID=990
TPROXY_PORT=12345
TPROXY_MARK=1
BYPASS_MARK=2
# Блокировка QUIC (UDP/443): по умолчанию выключена — HTTP/3 проксируется.
# Переопределяется ключом routing.block_quic в settings.json
BLOCK_QUIC=false
TABLE_NAME="inet xray"
SETTINGS_JSON="/etc/xray/settings.json"
CONFIG_JSON="/etc/xray/config.json"

# Узлы подписки: их адреса живут в именованном наборе @nodes, а трафик к ним
# обходит TProxy одним правилом вместо десятка адресов в самом правиле.
NODES_SET="nodes"
# Список адресов всех профилей подписки; пишет update-xray.sh.
# XRAY_NODES_FILE — для проверок без root и без установленного шлюза.
NODES_FILE="${XRAY_NODES_FILE:-/etc/xray/state/subscription-nodes.txt}"
SERVER_IPS=""
NODES_SET_READY=0

# Порты локальных сервисов на шлюзе (TorrServer и др.) — bypass TProxy
# Пример с несколькими портами: LOCAL_TCP_PORTS="8090 8091 8443"
LOCAL_TCP_PORTS="8090"

# IP DoH-серверов заполняются ниже из settings.json (dns.hosts) —
# это те же адреса, что генератор кладёт в hosts встроенного DNS
DNS_IPS=""

# ============================================
#   HELPER: чтение settings.json
# ============================================
settings_get() {
	jq -r "${1} // empty" "$SETTINGS_JSON" 2>/dev/null
}

# Читаем настройки из settings.json (если есть), иначе умолчания
if [ -f "$SETTINGS_JSON" ]; then
	_gid=$(settings_get '.xray.gid')
	[ -n "$_gid" ] && XRAY_GID="$_gid"

	_tport=$(settings_get '.xray.tproxy_port')
	[ -n "$_tport" ] && TPROXY_PORT="$_tport"

	_tmark=$(settings_get '.xray.tproxy_mark')
	[ -n "$_tmark" ] && TPROXY_MARK="$_tmark"

	_bmark=$(settings_get '.xray.bypass_mark')
	[ -n "$_bmark" ] && BYPASS_MARK="$_bmark"

	# QUIC (UDP/443). По умолчанию не блокируется: HTTP/3 проходит через прокси
	_block_quic=$(settings_get '.routing.block_quic')
	[ -n "$_block_quic" ] && BLOCK_QUIC="$_block_quic"
fi

# IP DoH-серверов — из settings.json (dns.hosts), чтобы не дублировать их в коде
if [ -f "$SETTINGS_JSON" ]; then
	DNS_IPS=$(jq -r '.dns.hosts // {} | .[] | .[]' "$SETTINGS_JSON" 2>/dev/null | sort -u | tr '\n' ' ')
fi
if [ -z "${DNS_IPS// /}" ]; then
	echo "[!] settings.json: dns.hosts пуст — DoH-bypass в nftables отключён" >&2
fi

# ============================================
#   АДРЕСА УЗЛОВ ПОДПИСКИ (набор @nodes)
# ============================================
# Трафик к серверам прокси заворачивать в TProxy нельзя: соединение с сервером
# ушло бы само в себя. Адреса берутся из двух источников:
#   1. outbound'ы текущего config.json — то, через что шлюз работает сейчас;
#   2. subscription-nodes.txt (пишет update-xray.sh) — адреса ВСЕХ профилей
#      подписки: клиент в LAN может запустить свой Xray с этой же подпиской и
#      другим профилем, и его трафик к узлу проксировался бы второй раз.
# В подписках адрес часто задан доменом, поэтому имена резолвятся. Не удалось
# разрешить — работаем без них: правила TProxy от этого не перестают быть верными.

is_ipv4() {
	[[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	# 0.0.0.0 — заглушка «нет сервера»: ядро такой элемент набора не примет,
	# а add_nodes_rule из-за него вернул бы ошибку и откатил все правила
	[ "$1" != "0.0.0.0" ] || return 1
	local octet
	for octet in "${BASH_REMATCH[@]:1}"; do
		[ "$octet" -le 255 ] || return 1
	done
	return 0
}

resolve_ipv4() {
	command -v getent >/dev/null 2>&1 || return 0
	local ip
	for ip in $(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u); do
		# getent отдаёт и литеральные адреса (например, 0.0.0.0 из заглушки)
		if is_ipv4 "$ip"; then
			printf '%s\n' "$ip"
		fi
	done
	return 0
}

collect_servers() {
	local candidates addr resolved
	local unresolved=""

	candidates=$(
		{
			if [ -f "$CONFIG_JSON" ]; then
				jq -r '.outbounds[]?
					| select(.protocol != "freedom" and .protocol != "blackhole"
						and .protocol != "dns" and .protocol != "loopback")
					| .settings.vnext[]?.address, .settings.servers[]?.address,
					  .settings.address
					| select(. != null)' "$CONFIG_JSON" 2>/dev/null || true
			fi
			if [ -f "$NODES_FILE" ]; then
				grep -vE '^[[:space:]]*(#|$)' "$NODES_FILE" 2>/dev/null || true
			fi
		} | tr -d '\r' | sort -u
	)

	for addr in $candidates; do
		if is_ipv4 "$addr"; then
			SERVER_IPS="$SERVER_IPS $addr"
			continue
		fi
		# Заглушка «нет сервера» — не ошибка резолвинга, просто пропускаем
		if [ "$addr" = "0.0.0.0" ]; then
			continue
		fi
		resolved=$(resolve_ipv4 "$addr")
		if [ -n "$resolved" ]; then
			SERVER_IPS="$SERVER_IPS $(printf '%s\n' "$resolved" | tr '\n' ' ')"
		else
			unresolved="$unresolved $addr"
		fi
	done

	SERVER_IPS=$(printf '%s\n' $SERVER_IPS | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')

	if [ -n "$unresolved" ]; then
		echo "[!] Не удалось определить IP серверов прокси:$unresolved — их трафик пойдёт через TProxy" >&2
	fi
}

collect_servers

# ============================================
#   ОПРЕДЕЛЕНИЕ LAN-ИНТЕРФЕЙСА
# ============================================
# Порядок:
#   1. network.interface из settings.json — если задан и интерфейс существует;
#   2. автоопределение с ИСКЛЮЧЕНИЕМ интерфейса аплинка (тот, через который идёт
#      default route).
# Раньше брался просто первый попавшийся интерфейс, и на машине с двумя NIC
# (eth0 = аплинк, eth1 = LAN) TProxy вешался на аплинк: клиентский трафик не
# проксировался, а правила применялись к входящему из интернета.

iface_has_ipv4() {
	[ -n "$1" ] && ip -4 addr show "$1" 2>/dev/null | grep -q 'inet '
}

WAN_IF=$(ip route show default 2>/dev/null |
	awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')

LAN_IF_CFG=""
SINGLE_NIC=0
[ -f "$SETTINGS_JSON" ] && LAN_IF_CFG=$(settings_get '.network.interface')

if [ -n "$LAN_IF_CFG" ]; then
	if iface_has_ipv4 "$LAN_IF_CFG"; then
		LAN_IF="$LAN_IF_CFG"
		echo "→ LAN интерфейс: $LAN_IF (из settings.json → network.interface)"
	else
		echo "[!] network.interface=\"$LAN_IF_CFG\" не найден — определяю автоматически" >&2
		LAN_IF=""
	fi
fi

if [ -z "$LAN_IF" ]; then
	# Кандидаты: все с IPv4, кроме виртуальных и кроме интерфейса аплинка
	# `|| true` обязателен: под set -e пустой результат grep (нет совпадений)
	# завершает скрипт молча — так и было на шлюзе с одним интерфейсом
	ALL_IFS=$(ip -o -4 addr show 2>/dev/null |
		awk '{print $2}' |
		grep -vE '^(lo|docker|virbr|wg|tun|veth|br-)' || true)
	CANDIDATES=$(printf '%s\n' "$ALL_IFS" | grep -vx "${WAN_IF:-__none__}" || true)

	# Шлюз с одним интерфейсом (основной сценарий: устройство за главным
	# роутером) — аплинк и LAN совпадают, исключать аплинк не из чего
	if [ -z "$CANDIDATES" ] && [ -n "$WAN_IF" ]; then
		CANDIDATES="$WAN_IF"
		SINGLE_NIC=1
	fi

	LAN_IF=$(printf '%s\n' "$CANDIDATES" | grep . | head -1 || true)
	ALL=$(printf '%s\n' "$ALL_IFS" | tr '\n' ' ')
	COUNT=$(printf '%s\n' "$CANDIDATES" | grep -c . || true)

	if [ -n "$LAN_IF" ] && [ "$SINGLE_NIC" != "1" ]; then
		echo "→ LAN интерфейс: $LAN_IF (автоопределение, аплинк ${WAN_IF:-не найден} исключён)"
		if [ "$COUNT" -gt 1 ]; then
			echo "  [!] Подходят несколько интерфейсов: $ALL — выбран $LAN_IF" >&2
			echo "      Задайте нужный: settings.json → network.interface" >&2
		fi
	fi
fi

if [ -z "$LAN_IF" ]; then
	echo "[X] Не удалось определить LAN интерфейс" >&2
	echo "    Доступные интерфейсы: $(ip -o -4 addr show 2>/dev/null | awk '{print $2}' | tr '\n' ' ')" >&2
	echo "    Аплинк (default route): ${WAN_IF:-не найден}" >&2
	echo "    Задайте вручную: settings.json → network.interface" >&2
	exit 1
fi

if [ -n "$WAN_IF" ] && [ "$LAN_IF" = "$WAN_IF" ]; then
	echo "[!] LAN и аплинк совпали ($LAN_IF) — похоже, шлюз с одним интерфейсом" >&2
fi

# Получаем IP шлюза на LAN интерфейсе (нужен для точечного bypass)
GW_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 2>/dev/null || echo "")

echo "→ LAN интерфейс: $LAN_IF"
echo "→ IP шлюза: ${GW_IP:-не определён}"
echo "→ Xray GID: $XRAY_GID"
if [ -n "${SERVER_IPS// /}" ]; then
	echo "→ Узлы для bypass (@$NODES_SET): $(printf '%s\n' $SERVER_IPS | grep -c .) адресов"
else
	echo "[!] Адреса узлов подписки не определены — bypass узлов отключён" >&2
fi

# ============================================
#   ОЧИСТКА ПРАВИЛ
# ============================================
cleanup_rules() {
	echo "→ Очистка правил Xray nftables..."

	# Удаляем таблицу xray целиком (все цепочки, set-ы и правила внутри)
	nft delete table "$TABLE_NAME" 2>/dev/null || true

	# Убираем policy routing
	while ip rule del fwmark "$TPROXY_MARK" table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null || true

	# Сбрасываем IPv6 route localnet если был установлен
	sysctl -w net.ipv6.conf.all.route_localnet=0 2>/dev/null || true

	echo "✓ Правила очищены"
}

# Снятие всего, что успели применить, при ошибке на середине.
# Скрипт работает под `set -e` и без отката оставлял полупостроенную таблицу:
# часть правил есть, часть нет — трафик уходил мимо прокси, а `nftables правила
# применены` так и не печаталось, и понять это было нечем.
ROLLBACK_NEEDED=0

rollback_rules() {
	[ "$ROLLBACK_NEEDED" = "1" ] || return 0
	ROLLBACK_NEEDED=0
	echo "[X] Применение правил прервано — откат" >&2
	cleanup_rules >&2 || true
	echo "[X] Правила сняты полностью, трафик идёт напрямую" >&2
}

# ============================================
#   ПРОВЕРКА ПРИМЕНЁННЫХ ПРАВИЛ
# ============================================
# Читаем таблицу обратно: `nft add rule` может отработать без ошибки, но
# правило не встанет на место (например, при конфликте с уже существующим).
verify_rules() {
	local dump missing=""
	dump=$(nft list table "$TABLE_NAME" 2>/dev/null) || {
		echo "[X] Таблица $TABLE_NAME не читается после применения" >&2
		return 1
	}

	printf '%s\n' "$dump" | grep -qF "tproxy ip to 127.0.0.1:$TPROXY_PORT" ||
		missing="$missing tproxy-правило"

	printf '%s\n' "$dump" | grep -q "type filter hook prerouting priority mangle" ||
		missing="$missing хук-prerouting"

	printf '%s\n' "$dump" | grep -q "type route hook output priority mangle" ||
		missing="$missing хук-output"

	printf '%s\n' "$dump" | grep -qE "meta mark (0x0*$(printf '%x' "$BYPASS_MARK")|$BYPASS_MARK)([[:space:]]|$)" ||
		missing="$missing bypass-метка-$BYPASS_MARK"

	if [ "$BLOCK_QUIC" = "true" ]; then
		printf '%s\n' "$dump" | grep -qF "udp dport 443 drop" ||
			missing="$missing блокировка-quic"
	else
		printf '%s\n' "$dump" | grep -qF "udp dport 443 drop" &&
			missing="$missing лишняя-блокировка-quic"
	fi

	# nft печатает имя интерфейса в кавычках, но старые версии — без
	printf '%s\n' "$dump" | grep -qE "iifname \"?$LAN_IF\"?([[:space:]]|$)" ||
		missing="$missing правила-для-$LAN_IF"

	# Адреса узлов подписки живут в именованном наборе @nodes: правило обязано
	# быть в обеих цепочках — в PREROUTING (трафик клиентов) и в OUTPUT
	if [ -n "${SERVER_IPS// /}" ]; then
		local chain_tproxy chain_output
		chain_tproxy=$(nft list chain "$TABLE_NAME" xray_tproxy 2>/dev/null)
		chain_output=$(nft list chain "$TABLE_NAME" xray_output 2>/dev/null)
		printf '%s\n' "$chain_tproxy" | grep -qF "ip daddr @$NODES_SET" ||
			missing="$missing bypass-узлов-xray_tproxy"
		printf '%s\n' "$chain_output" | grep -qF "ip daddr @$NODES_SET" ||
			missing="$missing bypass-узлов-xray_output"
	fi

	if [ -n "$missing" ]; then
		echo "[X] После применения не найдено:$missing" >&2
		return 1
	fi

	# Ядро могло не принять часть элементов набора — тогда bypass неполный
	if [ -n "${SERVER_IPS// /}" ]; then
		local listed ip
		listed=$(nft list set "$TABLE_NAME" "$NODES_SET" 2>/dev/null)
		for ip in $SERVER_IPS; do
			printf '%s\n' "$listed" | grep -qF "$ip" ||
				{
					echo "[X] В наборе @$NODES_SET нет адреса узла $ip" >&2
					return 1
				}
		done
	fi

	# Policy routing: без него трафик шлюза после mark уйдёт не в lo
	ip rule show 2>/dev/null |
		grep -qE "fwmark 0x0*$(printf '%x' "$TPROXY_MARK")[[:space:]]+lookup (100|xray)" ||
		{
			echo "[X] Нет ip rule fwmark $TPROXY_MARK → table 100" >&2
			return 1
		}
	# Ядро печатает `local default dev lo`, а не `local 0.0.0.0/0`
	ip route show table 100 2>/dev/null |
		grep -qE "local (default|0\.0\.0\.0/0) dev lo" ||
		{
			echo "[X] В таблице 100 нет local default dev lo" >&2
			return 1
		}

	return 0
}

# ============================================
#   НАБОР АДРЕСОВ УЗЛОВ + ПРАВИЛО BYPASS
# ============================================
# Набор создаётся один раз на таблицу, правила — в каждой цепочке своё.
# Возвращает 1, если адресов нет: пустой набор сделал бы правило бесполезным.
add_nodes_rule() {
	local chain="$1" ip list=""

	[ -n "${SERVER_IPS// /}" ] || return 1

	if [ "$NODES_SET_READY" != "1" ]; then
		nft add set "$TABLE_NAME" "$NODES_SET" "{ type ipv4_addr ; }" || return 1
		for ip in $SERVER_IPS; do
			list="$list${list:+, }$ip"
		done
		nft add element "$TABLE_NAME" "$NODES_SET" "{ $list }" || return 1
		NODES_SET_READY=1
	fi

	nft add rule "$TABLE_NAME" "$chain" ip daddr "@$NODES_SET" return || return 1
	return 0
}

# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================
setup_network() {
	# Всё, что ниже, меняет состояние системы: при ошибке на середине
	# откатываем, иначе останутся policy routing без правил или полутаблица.
	ROLLBACK_NEEDED=1

	echo "→ Настройка policy routing..."

	# Очищаем предыдущие правила
	while ip rule del fwmark "$TPROXY_MARK" table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null || true

	# Policy routing: пакеты с mark=1 → table 100 → lo (для TProxy)
	ip rule add fwmark "$TPROXY_MARK" table 100
	ip route add local 0.0.0.0/0 dev lo table 100

	# Включаем route_localnet для IPv4 (нужно для TProxy на lo).
	# `|| true` обязателен: в контейнерах и на read-only /proc/sys sysctl
	# возвращает ошибку, а под `set -e` это обрывало скрипт уже после того,
	# как policy routing был изменён.
	sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.lo.route_localnet=1 >/dev/null 2>&1 || true

	echo "→ Настройка nftables..."

	# Удаляем предыдущую таблицу
	nft delete table "$TABLE_NAME" 2>/dev/null || true
	nft add table "$TABLE_NAME"

	# ============================================
	#   SET-ы (именованные списки)
	# ============================================

	# DNS-серверы (IPv4)
	nft add set "$TABLE_NAME" dns_v4 { type ipv4_addr \; }
	for ip in $DNS_IPS; do
		nft add element "$TABLE_NAME" dns_v4 { $ip }
	done

	# Приватные сети (IPv4) — никогда не проксируются
	nft add set "$TABLE_NAME" reserved_v4 { type ipv4_addr \; flags interval \; }
	nft add element "$TABLE_NAME" reserved_v4 { 127.0.0.0/8 }
	nft add element "$TABLE_NAME" reserved_v4 { 10.0.0.0/8 }
	nft add element "$TABLE_NAME" reserved_v4 { 100.64.0.0/10 }
	nft add element "$TABLE_NAME" reserved_v4 { 172.16.0.0/12 }
	nft add element "$TABLE_NAME" reserved_v4 { 192.168.0.0/16 }
	nft add element "$TABLE_NAME" reserved_v4 { 192.0.0.0/24 }
	nft add element "$TABLE_NAME" reserved_v4 { 169.254.0.0/16 }
	nft add element "$TABLE_NAME" reserved_v4 { 224.0.0.0/4 }
	nft add element "$TABLE_NAME" reserved_v4 { 240.0.0.0/4 }

	# ============================================
	#   ЦЕПОЧКА tproxy (PREROUTING)
	#   Перехватывает трафик от клиентов LAN
	# ============================================
	nft add chain "$TABLE_NAME" xray_tproxy { type filter hook prerouting priority mangle \; policy accept \; }

	# 1. Bypass по mark: трафик самого Xray (sockopt.mark=2)
	nft add rule "$TABLE_NAME" xray_tproxy meta mark "$BYPASS_MARK" return

	# 2. DHCP — не трогаем
	nft add rule "$TABLE_NAME" xray_tproxy udp dport { 67, 68 } return

	# 3. Локальные сервисы шлюза (TorrServer, dnsmasq, etc.)
	#    ВСЕ пакеты, адресованные локальным IP шлюза — bypass
	nft add rule "$TABLE_NAME" xray_tproxy fib daddr type local return

	# 4. ЯВНЫЙ bypass портов локальных сервисов (защита от краевых случаев)
	if [ -n "$LOCAL_TCP_PORTS" ]; then
		for port in $LOCAL_TCP_PORTS; do
			nft add rule "$TABLE_NAME" xray_tproxy tcp dport "$port" return
		done
	fi

	# 5. Приватные/мультикаст/бродкаст адреса — не трогаем
	nft add rule "$TABLE_NAME" xray_tproxy ip daddr @reserved_v4 return

	# 5.1. Узлы подписки: клиент в LAN может держать собственный Xray с этой же
	#      подпиской — трафик к узлам не должен заворачиваться в TProxy повторно
	if add_nodes_rule xray_tproxy; then
		echo "  ✓ bypass узлов подписки (@$NODES_SET)"
	fi

	# 6. Публичные DNS (не-DNS трафик к этим IP) — bypass
	nft add rule "$TABLE_NAME" xray_tproxy ip daddr @dns_v4 tcp dport != 53 return
	nft add rule "$TABLE_NAME" xray_tproxy ip daddr @dns_v4 udp dport != 53 return

	# 7. Блокировка QUIC (UDP/443) — на входе, ДО TProxy.
	# Тот же ключ routing.block_quic управляет правилом в Xray
	if [ "$BLOCK_QUIC" = "true" ]; then
		nft add rule "$TABLE_NAME" xray_tproxy iifname "$LAN_IF" udp dport 443 drop
	fi

	# 8. Отбрасываем IPv6 трафик от клиентов (шлюз — IPv4-only)
	nft add rule "$TABLE_NAME" xray_tproxy meta nfproto ipv6 drop

	# 9. TProxy: трафик с LAN → Xray (порт 12345)
	nft add rule "$TABLE_NAME" xray_tproxy iifname "$LAN_IF" meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_MARK" accept

	# 10. TProxy: собственный трафик шлюза (приходит на lo после policy routing)
	nft add rule "$TABLE_NAME" xray_tproxy iifname "lo" meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_MARK" accept

	# ============================================
	#   ЦЕПОЧКА input_filter — защита TProxy порта
	# ============================================
	nft add chain "$TABLE_NAME" xray_input { type filter hook input priority filter \; policy accept \; }

	# Блокируем прямой доступ к порту TProxy извне
	nft add rule "$TABLE_NAME" xray_input iifname "$LAN_IF" meta l4proto { tcp, udp } th dport "$TPROXY_PORT" drop

	# ============================================
	#   ЦЕПОЧКА output_mark — маркировка
	#   Маркирует исходящий трафик Xray для bypass в tproxy
	# ============================================
	nft add chain "$TABLE_NAME" xray_output { type route hook output priority mangle \; policy accept \; }

	# 1. Трафик процессов группы xray → mark=BYPASS_MARK
	#    Это основной механизм защиты от петель.
	#    Xray должен запускаться с SupplementaryGroups=xray (gid 990).
	if getent group "$XRAY_GID" >/dev/null 2>&1 || getent group xray >/dev/null 2>&1; then
		nft add rule "$TABLE_NAME" xray_output meta skgid "$XRAY_GID" meta mark set "$BYPASS_MARK" return
		echo "  ✓ GID-bypass активен (skgid $XRAY_GID)"
	else
		echo "  [!] Группа xray (gid $XRAY_GID) не найдена — GID-bypass отключён"
		echo "  [!] Создайте группу: groupadd -r -g $XRAY_GID xray"
	fi

	# 2. Bypass по уже установленному mark (defense in depth)
	nft add rule "$TABLE_NAME" xray_output meta mark "$BYPASS_MARK" return

	# 3. Пропускаем локальный трафик
	nft add rule "$TABLE_NAME" xray_output fib daddr type local return
	nft add rule "$TABLE_NAME" xray_output ip daddr @reserved_v4 return

	# 3.1. Узлы подписки — то же, что в PREROUTING: собственный трафик шлюза к
	#      узлам не маркируется. Набор уже создан выше; если правило не встанет,
	#      проверка применённых правил откатит изменения
	add_nodes_rule xray_output || true

	# 4. ЯВНЫЙ bypass DoH/DNS запросов от встроенного DNS Xray
	#    (на случай если mark ещё не установлен на первом пакете)
	nft add rule "$TABLE_NAME" xray_output ip daddr @dns_v4 return

	# 5. NTP (порт 123) — не трогаем
	nft add rule "$TABLE_NAME" xray_output udp dport 123 return

	# 5.1. ICMP — Xray его не проксирует (TProxy в prerouting ловит только tcp/udp),
	#      поэтому с меткой TPROXY_MARK пакет уходит в lo и теряется.
	#      Без этого правила ping/traceroute с самого шлюза не работают.
	nft add rule "$TABLE_NAME" xray_output meta l4proto icmp return

	# 6. Отбрасываем IPv6 исходящий (шлюз — IPv4-only)
	nft add rule "$TABLE_NAME" xray_output meta nfproto ipv6 drop

	# 7. Выход в интернет: шлюз проксирует СОБСТВЕННЫЙ трафик через Xray
	#     mark=TPROXY_MARK → policy routing (таблица 100 → lo) → PREROUTING → TProxy
	#     Исключения (Xray, DNS, NTP, ICMP, локальное, IPv6) уже отсеяны в правилах 1-6.
	#     Чтобы отключить проксирование шлюза — закомментируйте строку ниже.
	nft add rule "$TABLE_NAME" xray_output meta mark set "$TPROXY_MARK" accept

	# Читаем обратно: правило могло не встать, и молча
	if ! verify_rules; then
		rollback_rules
		exit 1
	fi

	ROLLBACK_NEEDED=0
	echo "✓ nftables правила применены и проверены (таблица $TABLE_NAME)"
}

# ============================================
#   ТОЧКА ВХОДА
# ============================================
if [ "$1" = "--cleanup" ]; then
	cleanup_rules
else
	trap 'rollback_rules' EXIT
	setup_network
	trap - EXIT
fi
