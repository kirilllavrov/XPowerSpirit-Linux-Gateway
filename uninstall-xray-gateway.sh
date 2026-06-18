#!/bin/bash
# Полное удаление Xray Transparent Gateway
# Возвращает систему в исходное состояние

set -e

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       Удаление Xray Transparent Gateway             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

[ "$(id -u)" != "0" ] && { echo "[X] Запускать нужно от root"; exit 1; }

# ============================================
#   1. Остановка служб
# ============================================
echo "=== Шаг 1: Остановка служб ==="

SERVICES="xray.service dnsmasq xray-network-update.path xray-network-update.service"
for svc in $SERVICES; do
	if systemctl is-active --quiet "$svc" 2>/dev/null; then
		systemctl stop "$svc" 2>/dev/null || true
		echo "  → $svc остановлен"
	fi
	if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
		systemctl disable "$svc" 2>/dev/null || true
		echo "  → $svc отключён"
	fi
done

# ============================================
#   2. Удаление systemd-юнитов
# ============================================
echo "=== Шаг 2: Удаление systemd-юнитов ==="

UNITS="xray.service xray-network-update.service xray-network-update.path"
for unit in $UNITS; do
	rm -f "/etc/systemd/system/$unit"
	echo "  → $unit удалён"
done
systemctl daemon-reload 2>/dev/null || true

# ============================================
#   3. Очистка nftables
# ============================================
echo "=== Шаг 3: Очистка nftables ==="

if [ -x /usr/local/share/xray/update-nft.sh ]; then
	/usr/local/share/xray/update-nft.sh --cleanup 2>/dev/null || true
else
	# Ручная очистка если скрипт уже удалён
	nft delete table "inet xray" 2>/dev/null || true
	while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null || true
fi
echo "  ✓ Правила nftables и policy routing удалены"

# ============================================
#   4. Удаление sysctl
# ============================================
echo "=== Шаг 4: Удаление sysctl ==="

rm -f /etc/sysctl.d/99-xray.conf
# Перезагружаем sysctl без xray-настроек
sysctl --system >/dev/null 2>&1 || true
echo "  ✓ /etc/sysctl.d/99-xray.conf удалён"

# ============================================
#   5. Удаление cron
# ============================================
echo "=== Шаг 5: Удаление cron ==="

TMP_CRON="/tmp/crontab.$$"
crontab -l 2>/dev/null >"$TMP_CRON" || true
if grep -q "update-xray.sh" "$TMP_CRON" 2>/dev/null; then
	grep -v "update-xray.sh" "$TMP_CRON" | crontab - 2>/dev/null || true
	echo "  → Запись cron удалена"
else
	echo "  - Запись cron не найдена"
fi
rm -f "$TMP_CRON"

# ============================================
#   6. Восстановление DNS
# ============================================
echo "=== Шаг 6: Восстановление DNS ==="

# Останавливаем dnsmasq если запущен
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true

# Восстанавливаем systemd-resolved если был отключён
if [ -f /lib/systemd/system/systemd-resolved.service ] || [ -f /usr/lib/systemd/system/systemd-resolved.service ]; then
	systemctl enable systemd-resolved 2>/dev/null || true
	systemctl start systemd-resolved 2>/dev/null || true
	# Восстанавливаем симлинк resolv.conf на stub-resolv
	rm -f /etc/resolv.conf
	ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || \
		ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || \
		echo "nameserver 1.1.1.1" >/etc/resolv.conf
	echo "  → systemd-resolved восстановлен"
else
	# Нет systemd-resolved — прописываем публичный DNS
	echo "nameserver 1.1.1.1" >/etc/resolv.conf
	echo "  → resolv.conf: 1.1.1.1"
fi

# Восстанавливаем networkd / NetworkManager
if [ -f /lib/systemd/system/systemd-networkd.service ] || [ -f /usr/lib/systemd/system/systemd-networkd.service ]; then
	systemctl enable systemd-networkd 2>/dev/null || true
	echo "  → systemd-networkd включён"
fi
if [ -f /lib/systemd/system/NetworkManager.service ] || [ -f /usr/lib/systemd/system/NetworkManager.service ]; then
	systemctl enable NetworkManager 2>/dev/null || true
	echo "  → NetworkManager включён"
fi

# Восстанавливаем interfaces из бекапа если есть
BACKUP=$(ls -t /etc/network/interfaces.bak.* 2>/dev/null | head -1)
if [ -n "$BACKUP" ]; then
	cp "$BACKUP" /etc/network/interfaces
	echo "  → /etc/network/interfaces восстановлен из $BACKUP"
fi

echo "  ✓ DNS восстановлен в исходное состояние"

# ============================================
#   7. Удаление routing table
# ============================================
echo "=== Шаг 7: Удаление routing table ==="

if [ -f /etc/iproute2/rt_tables ]; then
	sed -i '/^100[[:space:]]\+xray$/d' /etc/iproute2/rt_tables 2>/dev/null || true
	echo "  → Таблица 100 xray удалена из rt_tables"
fi

# ============================================
#   8. Удаление группы xray
# ============================================
echo "=== Шаг 8: Удаление группы xray ==="

if getent group xray >/dev/null 2>&1; then
	groupdel xray 2>/dev/null || true
	echo "  → Группа xray удалена"
else
	echo "  - Группа xray не найдена"
fi

# ============================================
#   9. Удаление файлов
# ============================================
echo "=== Шаг 9: Удаление файлов ==="

# Конфиги
rm -rf /etc/xray
echo "  → /etc/xray удалён"

# Скрипты
rm -rf /usr/local/share/xray
echo "  → /usr/local/share/xray удалён"

# Бинарник
rm -f /usr/local/bin/xray
echo "  → /usr/local/bin/xray удалён"

# Логи
rm -f /var/log/xray-update.log
rm -f /var/log/xray-access.log
rm -f /var/log/xray-error.log
rm -f /tmp/xray_install.log
echo "  → Логи удалены"

# Блокировка
rm -f /var/lock/xray-update.lock

# Временные файлы
rm -rf /tmp/xray_update /tmp/xray_install

# ============================================
#   10. Удаление dhcpcd (DietPi) если был установлен только для нас
# ============================================
echo "=== Шаг 10: Очистка пакетов ==="

# Не удаляем пакеты принудительно — могли быть установлены до нас.
# Выводим информацию.
echo "  [!] Пакеты НЕ удаляются автоматически (могли быть установлены ранее)."
echo "      Если хотите удалить — выполните вручную:"
echo "        apt-get remove --purge dnsmasq ntpdate"
echo "      Или оставьте — они не мешают."

# ============================================
echo ""
echo "============================================"
echo "  Удаление завершено."
echo ""
echo "  [!] ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА для применения"
echo "      сетевых настроек (DNS, interfaces)."
echo ""
echo "  Выполните: reboot"
echo "============================================"
