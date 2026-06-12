#!/bin/bash
# DietPi (Debian ARM) — nftables правила для Xray Transparent Gateway
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
#   КОНФИГУРАЦИЯ
# ============================================
XRAY_GID=990
TPROXY_PORT=12345
TPROXY_MARK=1
BYPASS_MARK=2
TABLE_NAME="inet xray"

# Порты локальных сервисов на шлюзе, доступных клиентам (TorrServer и др.)
# Трафик на эти порты шлюза не будет перехватываться TProxy
LOCAL_TCP_PORTS="8090"

# DoH/DNS серверы (должны совпадать с hosts в xray-generate-config.py)
# Используются для:
#   - bypass не-DNS трафика к этим IP (PREROUTING)
#   - разрешения DoH-запросов от встроенного DNS Xray (OUTPUT)
DNS_IPS="77.88.8.8 77.88.8.1 1.1.1.1 1.0.0.1 45.90.28.0 45.90.30.0"

# ============================================
#   АВТООПРЕДЕЛЕНИЕ LAN
# ============================================
if ip link show eth0 >/dev/null 2>&1; then
	LAN_IF="eth0"
elif ip link show enp1s0 >/dev/null 2>&1; then
	LAN_IF="enp1s0"
elif ip link show end0 >/dev/null 2>&1; then
	LAN_IF="end0"
else
	LAN_IF=$(ip -4 addr show | grep -v 'lo\|docker\|virbr\|wg\|tun\|veth' | grep 'inet ' | head -1 | awk '{print $NF}')
fi

if [ -z "$LAN_IF" ]; then
	echo "[X] Не удалось определить LAN интерфейс" >&2
	exit 1
fi

# Получаем IP шлюза на LAN интерфейсе (нужен для точечного bypass)
GW_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 2>/dev/null || echo "")

echo "→ LAN интерфейс: $LAN_IF"
echo "→ IP шлюза: ${GW_IP:-не определён}"
echo "→ Xray GID: $XRAY_GID"

# ============================================
#   ОЧИСТКА ПРАВИЛ
# ============================================
cleanup_rules() {
	echo "→ Очистка правил Xray nftables..."

	# Удаляем таблицу xray целиком (все цепочки, set-ы и правила внутри)
	nft delete table "$TABLE_NAME" 2>/dev/null || true

	# Убираем policy routing
	while ip rule del fwmark "$TPROXY_MARK" table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null

	# Сбрасываем IPv6 route localnet если был установлен
	sysctl -w net.ipv6.conf.all.route_localnet=0 2>/dev/null || true

	echo "✓ Правила очищены"
}

# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================
setup_network() {
	echo "→ Настройка policy routing..."

	# Очищаем предыдущие правила
	while ip rule del fwmark "$TPROXY_MARK" table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null

	# Policy routing: пакеты с mark=1 → table 100 → lo (для TProxy)
	ip rule add fwmark "$TPROXY_MARK" table 100
	ip route add local 0.0.0.0/0 dev lo table 100

	# Включаем route_localnet для IPv4 (нужно для TProxy на lo)
	sysctl -w net.ipv4.conf.all.route_localnet=1 2>/dev/null
	sysctl -w net.ipv4.conf.lo.route_localnet=1 2>/dev/null

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
	nft add element "$TABLE_NAME" reserved_v4 { 172.16.0.0/12 }
	nft add element "$TABLE_NAME" reserved_v4 { 192.168.0.0/16 }
	nft add element "$TABLE_NAME" reserved_v4 { 169.254.0.0/16 }
	nft add element "$TABLE_NAME" reserved_v4 { 224.0.0.0/4 }
	nft add element "$TABLE_NAME" reserved_v4 { 255.255.255.255 }

	# ============================================
	#   ЦЕПОЧКА tproxy (PREROUTING)
	#   Перехватывает трафик от клиентов LAN
	# ============================================
	nft add chain "$TABLE_NAME" tproxy { type filter hook prerouting priority mangle \; policy accept \; }

	# 1. Пропускаем уже установленные/связанные соединения (оптимизация)
	#    Это аналог DIVERT из iptables — не перехватываем пакеты
	#    существующих соединений повторно.
	nft add rule "$TABLE_NAME" tproxy ct state { established, related } accept

	# 2. Bypass по mark: трафик самого Xray (sockopt.mark=2)
	nft add rule "$TABLE_NAME" tproxy meta mark "$BYPASS_MARK" return

	# 3. DHCP — не трогаем
	nft add rule "$TABLE_NAME" tproxy udp dport { 67, 68 } return

	# 4. Локальные сервисы шлюза (TorrServer, dnsmasq, etc.)
	#    ВСЕ пакеты, адресованные локальным IP шлюза — bypass
	nft add rule "$TABLE_NAME" tproxy fib daddr type local return

	# 5. ЯВНЫЙ bypass портов локальных сервисов (защита от краевых случаев)
	if [ -n "$LOCAL_TCP_PORTS" ]; then
		for port in $LOCAL_TCP_PORTS; do
			nft add rule "$TABLE_NAME" tproxy tcp dport "$port" return
		done
	fi

	# 6. Приватные/мультикаст/бродкаст адреса — не трогаем
	nft add rule "$TABLE_NAME" tproxy ip daddr @reserved_v4 return

	# 7. Публичные DNS (не-DNS трафик к этим IP) — bypass
	#    Например, если клиент по ошибке ломится на 8.8.8.8:443
	nft add rule "$TABLE_NAME" tproxy ip daddr @dns_v4 tcp dport != 53 return
	nft add rule "$TABLE_NAME" tproxy ip daddr @dns_v4 udp dport != 53 return

	# 8. Блокировка QUIC (UDP/443) — на входе, ДО TProxy
	#    Вынуждает браузеры использовать TCP/HTTPS
	nft add rule "$TABLE_NAME" tproxy iifname "$LAN_IF" udp dport 443 drop

	# 9. Отбрасываем IPv6 трафик от клиентов (шлюз — IPv4-only)
	#    Предотвращает утечки IPv6 в обход прокси
	nft add rule "$TABLE_NAME" tproxy meta nfproto ipv6 drop

	# 10. TProxy: трафик с LAN → Xray (порт 12345)
	#     mark=1 нужен для policy routing (таблица 100 → lo)
	nft add rule "$TABLE_NAME" tproxy iifname "$LAN_IF" meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_MARK" accept

	# 11. TProxy: собственный трафик шлюза (приходит на lo после policy routing)
	#     Шлюз сам ходит в интернет через Xray.
	#     Исключения (Xray, DNS, локальные сервисы) уже отсеяны в правилах 1-9.
	nft add rule "$TABLE_NAME" tproxy iifname "lo" meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_MARK" accept

	# ============================================
	#   ЦЕПОЧКА input_filter — защита TProxy порта
	# ============================================
	nft add chain "$TABLE_NAME" input_filter { type filter hook input priority filter \; policy accept \; }

	# Блокируем прямой доступ к порту TProxy извне
	nft add rule "$TABLE_NAME" input_filter iifname "$LAN_IF" meta l4proto { tcp, udp } th dport "$TPROXY_PORT" drop

	# ============================================
	#   ЦЕПОЧКА output_mark — маркировка
	#   Маркирует исходящий трафик Xray для bypass в tproxy
	# ============================================
	nft add chain "$TABLE_NAME" output_mark { type filter hook output priority mangle \; policy accept \; }

	# 1. Трафик процессов группы xray → mark=BYPASS_MARK
	#    Это основной механизм защиты от петель.
	#    Xray должен запускаться с SupplementaryGroups=xray (gid 990).
	if getent group "$XRAY_GID" >/dev/null 2>&1 || getent group xray >/dev/null 2>&1; then
		nft add rule "$TABLE_NAME" output_mark meta skgid "$XRAY_GID" meta mark set "$BYPASS_MARK" accept
		echo "  ✓ GID-bypass активен (skgid $XRAY_GID)"
	else
		echo "  [!] Группа xray (gid $XRAY_GID) не найдена — GID-bypass отключён"
		echo "  [!] Создайте группу: groupadd -r -g $XRAY_GID xray"
	fi

	# 2. Bypass по уже установленному mark (defense in depth)
	nft add rule "$TABLE_NAME" output_mark meta mark "$BYPASS_MARK" return

	# 3. Пропускаем локальный трафик
	nft add rule "$TABLE_NAME" output_mark fib daddr type local return
	nft add rule "$TABLE_NAME" output_mark ip daddr @reserved_v4 return

	# 4. ЯВНЫЙ bypass DoH/DNS запросов от встроенного DNS Xray
	#    (на случай если mark ещё не установлен на первом пакете)
	nft add rule "$TABLE_NAME" output_mark ip daddr @dns_v4 return

	# 5. NTP (порт 123) — не трогаем
	nft add rule "$TABLE_NAME" output_mark udp dport 123 return

	# 6. Отбрасываем IPv6 исходящий (шлюз — IPv4-only)
	nft add rule "$TABLE_NAME" output_mark meta nfproto ipv6 drop

	# 7. Выход в интернет: шлюз проксирует СОБСТВЕННЫЙ трафик через Xray
	#     mark=TPROXY_MARK → policy routing (таблица 100 → lo) → PREROUTING → TProxy
	#     Исключения (Xray, DNS, NTP, локальное, IPv6) уже отсеяны в правилах 1-6.
	#     Чтобы отключить проксирование шлюза — закомментируйте строку ниже.
	nft add rule "$TABLE_NAME" output_mark meta mark set "$TPROXY_MARK" accept

	echo "✓ nftables правила применены (таблица $TABLE_NAME)"
}

# ============================================
#   ТОЧКА ВХОДА
# ============================================
if [ "$1" = "--cleanup" ]; then
	cleanup_rules
else
	setup_network
fi
