#!/bin/bash
# DietPi (Debian ARM) — nftables правила для Xray Transparent Gateway
#
# Режим: прозрачный шлюз (не основной роутер)
# Только клиентский трафик с LAN проксируется через Xray TProxy.
# Использует отдельную таблицу inet xray (не пересекается с системной).

set -e

CONF="/etc/xray/config.json"
TABLE_NAME="inet xray"

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

echo "→ LAN интерфейс: $LAN_IF"

# ============================================
#   ИЗВЛЕЧЕНИЕ IP ПРОКСИ-СЕРВЕРОВ ИЗ config.json
# ============================================
extract_server_ips() {
	python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr and addr not in ("hole", "0.0.0.0", "127.0.0.1"):
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

# ============================================
#   ОЧИСТКА ПРАВИЛ
# ============================================
cleanup_rules() {
	echo "→ Очистка правил Xray nftables..."

	# Удаляем таблицу xray целиком (все цепочки и правила внутри)
	nft delete table "$TABLE_NAME" 2>/dev/null || true

	# Убираем policy routing
	while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null

	echo "✓ Правила очищены"
}

# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================
setup_network() {
	echo "→ Настройка policy routing..."

	# Очищаем предыдущие правила
	while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null

	# Policy routing: пакеты с mark=1 → table 100 → lo (для TProxy)
	ip rule add fwmark 1 table 100
	ip route add local 0.0.0.0/0 dev lo table 100

	echo "→ Настройка nftables..."

	# Создаём таблицу xray (отдельно от системной)
	nft delete table "$TABLE_NAME" 2>/dev/null || true
	nft add table "$TABLE_NAME"

	# ============================================
	#   ЦЕПОЧКА PREROUTING (tproxy)
	# ============================================
	nft add chain "$TABLE_NAME" tproxy { type filter hook prerouting priority mangle \; policy accept \; }

	# 1. Защита от петель: трафик Xray (mark=2) — не трогаем
	nft add rule "$TABLE_NAME" tproxy meta mark 2 return

	# 2. DHCP — не трогаем
	nft add rule "$TABLE_NAME" tproxy udp dport { 67, 68 } return

	# 3. Публичные DNS (не-DNS трафик к этим IP) — bypass
	nft add rule "$TABLE_NAME" tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return

	# 4. Прокси-серверы (VPS) — bypass (чтобы Xray мог к ним подключиться без повторного проксирования)
	for ip in $(extract_server_ips); do
		if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
			nft add rule "$TABLE_NAME" tproxy ip daddr $ip return
		fi
	done

	# 5. Локальные/приватные/мультикаст адреса — не трогаем
	nft add rule "$TABLE_NAME" tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4 } return

	# 6. Блокировка QUIC (UDP/443) на входе — ДО TProxy
	nft add rule "$TABLE_NAME" tproxy iifname "$LAN_IF" udp dport 443 drop

	# 7. TProxy: весь остальной трафик с LAN → Xray (порт 12345)
	#    mark=1 нужен для policy routing (таблица 100 → lo)
	nft add rule "$TABLE_NAME" tproxy iifname "$LAN_IF" meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

	# ============================================
	#   ЦЕПОЧКА INPUT — защита от постороннего доступа к TProxy
	# ============================================
	nft add chain "$TABLE_NAME" input { type filter hook input priority filter \; policy accept \; }

	# Блокируем прямой доступ к порту TProxy извне
	nft add rule "$TABLE_NAME" input iifname "$LAN_IF" meta l4proto { tcp, udp } th dport 12345 drop

	# ============================================
	#   ЦЕПОЧКА OUTPUT — заглушка (шлюз не проксирует собственный трафик)
	# ============================================
	nft add chain "$TABLE_NAME" output { type filter hook output priority filter \; policy accept \; }
	nft add rule "$TABLE_NAME" output return

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
