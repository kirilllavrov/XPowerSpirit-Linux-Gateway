#!/bin/bash
# Ubuntu/Debian ARM — Xray Transparent Gateway (IPv4-only)
#
# Прозрачный шлюз: устройство НЕ основной роутер.
# Основной роутер (Роутер) раздаёт DHCP, NAT, интернет.
# Xray-шлюз получает статический IP, принимает трафик клиентов,
# обрабатывает через Xray TProxy и отправляет через основной роутер в интернет.
#
# Топология:
#   Internet → Роутер (192.168.1.1) → Xray GW (192.168.1.2) → Клиенты
#   Клиенты: gateway=192.168.1.2, dns=192.168.1.2
#
# Параметры (все опциональны, недостающие запрашиваются интерактивно):
#   --sub=URL        URL подписки
#   --ip=X.X.X.X     Статический IP шлюза
#   --mask=X.X.X.X   Маска подсети (по умолчанию 255.255.255.0)
#   --gw=X.X.X.X     IP основного роутера
#   --sub-ua=UA      User-Agent для подписки
#   --remarks=FILTER Фильтр remarks в JSON-подписке
#   --dwl=DOMAIN     Приоритетный домен для VLESS (Base64) подписок
#   --no-dns          Не настраивать DNS (dnsmasq, resolv.conf, systemd-resolved)

set -e

# Логирование
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Установка Xray Transparent Gateway          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

[ "$(id -u)" != "0" ] && {
	echo "[X] Запускать нужно от root"
	exit 1
}

# ============================================
#   ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ============================================
echo "=== Проверка зависимостей ==="

# Проверяем и устанавливаем необходимые пакеты
REQUIRED_PACKAGES="curl python3 unzip nftables iproute2 jq"
MISSING=""

for pkg in $REQUIRED_PACKAGES; do
	if ! dpkg -s "$pkg" >/dev/null 2>&1; then
		MISSING="$MISSING $pkg"
	fi
done

if [ -n "$MISSING" ]; then
	echo "→ Устанавливаю недостающие пакеты:$MISSING"
	apt-get update -qq
	apt-get install -y -qq $MISSING
fi

# Проверяем sha256sum
if ! command -v sha256sum >/dev/null 2>&1; then
	echo "→ Устанавливаю coreutils..."
	apt-get install -y -qq coreutils
fi

echo "[+] Все зависимости установлены"

# ============================================
#   TIMEZONE + NTP
# ============================================
echo "=== Синхронизация времени ==="

# Установка timezone: пробуем timedatectl, fallback — прямой symlink
TZ_SET=0
if timedatectl set-timezone Europe/Moscow 2>/dev/null; then
	TZ_SET=1
else
	# D-Bus недоступен (контейнер/minimal) — ставим symlink напрямую
	if [ -f /usr/share/zoneinfo/Europe/Moscow ]; then
		ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
		TZ_SET=1
		echo "  → Timezone установлен через /etc/localtime"
	fi
fi
[ "$TZ_SET" = "1" ] && echo "  ✓ Timezone: Europe/Moscow"

# Синхронизация времени
if command -v timedatectl >/dev/null 2>&1 && timedatectl status >/dev/null 2>&1; then
	# systemd-timesyncd с D-Bus
	timedatectl set-ntp true 2>/dev/null || true
	for i in $(seq 1 5); do
		if timedatectl status | grep -q "synchronized: yes"; then
			break
		fi
		echo "  → Ожидание синхронизации времени... ($i)"
		sleep 2
	done
else
	# Fallback: ntpdate (без D-Bus)
	apt-get install -y -qq ntpdate 2>/dev/null || true
	if ntpdate -u ru.pool.ntp.org 2>/dev/null ||
		ntpdate -u time.google.com 2>/dev/null; then
		echo "  ✓ Время синхронизировано (ntpdate)"
	else
		echo "  [!] Синхронизация времени не удалась, продолжаем..."
	fi
fi
echo ""

# ============================================
#   ПЕРЕМЕННЫЕ
# ============================================
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-Linux-Gateway/main"
GENERATOR="/usr/local/share/xray/xray-generate-config.py"
PARSER="/usr/local/share/xray/xray-sub-parser.py"
UPDATER="/usr/local/share/xray/update-xray.sh"
NFT_UPDATER="/usr/local/share/xray/update-nft.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/local/share/xray"
STATE_DIR="/etc/xray/state"
SUB_USER_AGENT="XPower/1.0"

# ============================================
#   HELPER: чтение/запись settings.json
# ============================================
settings_get() {
	jq -r "${1} // empty" "$SETTINGS_JSON" 2>/dev/null
}

settings_set() {
	local key="$1" val="$2" tmp="${SETTINGS_JSON}.tmp"
	jq --arg v "$val" "${key} = \$v" "$SETTINGS_JSON" > "$tmp" 2>/dev/null && mv "$tmp" "$SETTINGS_JSON"
}

# Сетевые параметры
LAN_IF=""
LAN_IP=""
LAN_MASK="255.255.255.0"
GATEWAY_IP=""
SUB_URL=""
REMARKS_FILTER=""
DWL_DOMAIN=""
SKIP_DNS=0

# ============================================
#   АВТООПРЕДЕЛЕНИЕ СЕТИ
# ============================================
detect_network() {
	echo "  [1/3] Определяю сетевой интерфейс..."

	# ip -o даёт по одной строке на адрес: <idx>: <ifname>    inet <cidr> ...
	# Имя интерфейса ВСЕГДА во втором поле.
	# Фильтруем по началу имени: lo, docker*, virbr*, wg*, tun*, veth*, br-*
	LAN_IF=$(ip -o -4 addr show 2>/dev/null | \
		awk '{print $2}' | \
		grep -vE '^(lo|docker|virbr|wg|tun|veth|br-)' | \
		head -1)

	[ -z "$LAN_IF" ] && {
		echo "[X] Не удалось определить сетевой интерфейс"
		echo "    Вывод ip -4 addr show:"
		ip -4 addr show 2>&1 || true
		echo "    Проверьте наличие активного Ethernet-интерфейса."
		exit 1
	}
	echo "    Интерфейс: $LAN_IF"

	# Определяем текущий IP
	LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	if [ -z "$LAN_IP" ]; then
		echo "    Запрашиваю IP по DHCP..."
		# Пробуем dhclient (isc-dhcp-client), если нет — dhcpcd (DietPi по умолчанию)
		if command -v dhclient >/dev/null 2>&1; then
			dhclient -v "$LAN_IF" 2>/dev/null || true
		elif command -v dhcpcd >/dev/null 2>&1; then
			dhcpcd -4 "$LAN_IF" 2>/dev/null || true
		fi
		sleep 3
		LAN_IP=$(ip -4 addr show "$LAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
	fi

	[ -z "$LAN_IP" ] && {
		echo "[X] Не удалось получить IP. Проверьте кабель."
		exit 1
	}

	# Определяем шлюз по умолчанию
	GATEWAY_IP=$(ip route | grep '^default' | awk '{print $3}')
	if [ -z "$GATEWAY_IP" ]; then
		SUBNET=$(echo "$LAN_IP" | cut -d'.' -f1-3)
		GATEWAY_IP="${SUBNET}.1"
	fi
}

# ============================================
#   ИНТЕРАКТИВНЫЙ ВЫБОР IP
# ============================================
configure_network() {
	echo ""
	echo "  [2/3] Настройка IP-адреса шлюза"
	echo "  ─────────────────────────────────────────────"
	echo "  Обнаружена сеть:"
	echo "    Интерфейс : $LAN_IF"
	echo "    Текущий IP: $LAN_IP"
	echo "    Маска     : $LAN_MASK"
	echo "    Роутер    : $GATEWAY_IP"
	echo ""

	# Если все параметры уже заданы через аргументы — не спрашиваем
	if [ -n "$ARG_IP" ] && [ -n "$ARG_GW" ]; then
		LAN_IP="$ARG_IP"
		GATEWAY_IP="$ARG_GW"
		[ -n "$ARG_MASK" ] && LAN_MASK="$ARG_MASK"
		echo "    → Использую параметры командной строки"
		echo "    IP: $LAN_IP, маска: $LAN_MASK, роутер: $GATEWAY_IP"
		return
	fi

	# Если IP задан аргументом, но GW нет — используем IP из аргумента, GW авто
	if [ -n "$ARG_IP" ]; then
		LAN_IP="$ARG_IP"
		[ -n "$ARG_MASK" ] && LAN_MASK="$ARG_MASK"
		[ -n "$ARG_GW" ] && GATEWAY_IP="$ARG_GW"
		echo "    → IP задан аргументом: $LAN_IP"
		echo "    Роутер (авто): $GATEWAY_IP"
	fi

	echo "  Выберите действие:"
	echo "    [1] Оставить обнаруженный IP ($LAN_IP)"
	echo "    [2] Ввести другой IP вручную"
	echo "    [3] Оставить DHCP (не рекомендуется)"
	echo ""
	printf "  Ваш выбор [1]: "
	read -r CHOICE
	CHOICE="${CHOICE:-1}"

	case "$CHOICE" in
	1)
		echo "    → Оставляю: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	2)
		echo ""
		printf "    IP адрес шлюза [${LAN_IP}]: "
		read -r NEW_IP
		[ -n "$NEW_IP" ] && LAN_IP="$NEW_IP"

		printf "    Маска подсети [${LAN_MASK}]: "
		read -r NEW_MASK
		[ -n "$NEW_MASK" ] && LAN_MASK="$NEW_MASK"

		printf "    IP основного роутера [${GATEWAY_IP}]: "
		read -r NEW_GW
		[ -n "$NEW_GW" ] && GATEWAY_IP="$NEW_GW"

		echo "    → Настройки: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	3)
		echo "    → Оставляю DHCP (IP может меняться)"
		echo "    [!] ВНИМАНИЕ: Роутер должен всегда выдавать один и тот же IP!"
		USE_DHCP=1
		;;
	*)
		echo "    → Оставляю: $LAN_IP / $LAN_MASK, роутер $GATEWAY_IP"
		;;
	esac
}

# ============================================
#   ВВОД ПОДПИСКИ
# ============================================
configure_subscription() {
	echo ""
	echo "  [3/3] Настройка подписки"
	echo "  ─────────────────────────────────────────────"

	if [ -n "$SUB_URL" ]; then
		echo "    URL подписки: $SUB_URL"
		return
	fi

	echo "  Введите URL подписки (или укажите --sub=URL при запуске):"
	printf "  > "
	read -r SUB_URL

	while [ -z "$SUB_URL" ]; do
		echo "  [!] URL обязателен. Введите URL подписки:"
		printf "  > "
		read -r SUB_URL
	done

	echo "    URL: $SUB_URL"
}

# ============================================
#   ПАРСЕР АРГУМЕНТОВ
# ============================================
ARG_IP=""
ARG_MASK=""
ARG_GW=""
for arg in "$@"; do
	case $arg in
	--sub=*) SUB_URL="${arg#*=}" ;;
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	--ip=*) ARG_IP="${arg#*=}" ;;
	--mask=*) ARG_MASK="${arg#*=}" ;;
	--gw=*) ARG_GW="${arg#*=}" ;;
	--no-dns) SKIP_DNS=1 ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# ============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# ============================================

# Универсальная загрузка файла (с авто-заголовками из settings.json + до 3 кастомных)
# Автоматически повторяет при неудаче: 3 попытки с растущей задержкой
# Использование:
#   download_file "URL" "DEST" ["HEADER1" "HEADER2" "HEADER3"]
download_file() {
	local url="$1"
	local dst="$2"
	shift 2
	local max_retries=3
	local retry=1
	local delay=2

	# Системные заголовки из settings.json (могут быть пустыми при первом запуске)
	local _ua _ver _model _os
	_ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "XPower/1.0")
	_ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
	_model=$(settings_get ".device_model" 2>/dev/null || echo "")
	_os=$(settings_get ".device_os" 2>/dev/null || echo "")

	# Cache-buster для GitHub raw
	local cache_buster="_t=$(date +%s)_r=$RANDOM"
	case "$url" in
	*raw.githubusercontent.com*) url="${url}?${cache_buster}" ;;
	esac

	while [ $retry -le $max_retries ]; do
		curl -s -L --max-time 15 \
			-H "User-Agent: $_ua" \
			${_ver:+-H "X-Ver-Os: $_ver"} \
			${_model:+-H "X-Device-Model: $_model"} \
			${_os:+-H "X-Device-Os: $_os"} \
			${1:+-H "$1"} \
			${2:+-H "$2"} \
			${3:+-H "$3"} \
			-o "$dst" "$url"
		local rc=$?

		if [ $rc -eq 0 ] && [ -s "$dst" ]; then
			if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
				rm -f "$dst"
			else
				return 0
			fi
		fi

		if [ $retry -lt $max_retries ]; then
			echo "     → Попытка $retry не удалась, повтор через ${delay}с..." >&2
			sleep "$delay"
			delay=$((delay * 2)) # 2с → 4с → 8с
		fi
		retry=$((retry + 1))
	done

	return 1
}

download_script() {
	local url="$1"
	local dst="$2"
	if download_file "$url" "$dst"; then
		chmod +x "$dst"
		echo "  → $dst"
	else
		echo "  [X] Ошибка: не удалось скачать $dst"
		exit 1
	fi
}

extract_sha256() {
	awk -F '= ' '/^SHA2-256/{print $2}' "$1" | tr -d ' \n'
}

update_geo() {
	local URL="$1"
	local DEST="$2"
	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → $BASE"
	download_file "${URL}.sha256sum" "$TMP_SHA" || {
		echo "  [X] Не удалось получить SHA256 для $BASE"
		exit 1
	}
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Пустой SHA256 для $BASE"
		exit 1
	}

	# Проверяем, не тот же ли уже файл
	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
		echo "  ✓ $BASE не изменился"
		rm -f "$TMP_SHA"
		return
	fi

	download_file "$URL" "$TMP" || {
		echo "  [X] Не удалось скачать $BASE"
		exit 1
	}
	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает для $BASE"
		rm -f "$TMP" "$TMP_SHA"
		exit 1
	fi
	mv "$TMP" "$DEST"
	echo "$REMOTE_SHA" >"$SHA_FILE"
	echo "  ✓ $BASE готов"
}

# ============================================
#   СОЗДАНИЕ ДИРЕКТОРИЙ
# ============================================
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR" "/tmp/log"

# ============================================
#   1. Определение сети + выбор IP + подписка
# ============================================
echo "=== Шаг 1: Настройка сети и подписки ==="

detect_network
configure_network
configure_subscription

echo ""
echo "  Итоговые настройки:"
echo "    Интерфейс : $LAN_IF"
if [ "$USE_DHCP" = "1" ]; then
	echo "    IP адрес  : DHCP (динамический)"
else
	echo "    IP адрес  : $LAN_IP / $LAN_MASK (статический)"
fi
echo "    Роутер    : $GATEWAY_IP"
echo "    Подписка  : $SUB_URL"
echo ""

# ============================================
#   2. Сохраняем настройки в settings.json
# ============================================
echo "=== Шаг 2: Сохранение настроек ==="

# Скачиваем settings.default.json как основу
echo "  → Загружаю settings.default.json..."
if [ ! -f "$SETTINGS_JSON" ]; then
	download_file "$REPO/settings.default.json" "$SETTINGS_JSON" || {
		echo ""
		echo "  ╔══════════════════════════════════════════════════╗"
		echo "  ║  [X] Не удалось загрузить settings.default.json  ║"
		echo "  ║                                                  ║"
		echo "  ║  Проверьте:                                      ║"
		echo "  ║  1. Доступ в интернет                            ║"
		echo "  ║  2. GitHub не заблокирован                       ║"
		echo "  ║  3. Репозиторий $REPO существует                 ║"
		echo "  ╚══════════════════════════════════════════════════╝"
		echo ""
		exit 1
	}
fi

settings_set '.subscription.url' "$SUB_URL"
echo "[+] URL подписки сохранён"

settings_set '.subscription.user_agent' "$SUB_USER_AGENT"
echo "[+] User-Agent: $SUB_USER_AGENT"

if [ -n "$REMARKS_FILTER" ]; then
	settings_set '.subscription.remarks' "$REMARKS_FILTER"
	echo "[+] Фильтр remarks: $REMARKS_FILTER"
else
	settings_set '.subscription.remarks' ''
fi

# Определяем и сохраняем информацию об устройстве
DEVICE_MODEL=""
VER_OS=""
DEVICE_OS="$(lsb_release -is 2>/dev/null || grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
[ -z "$DEVICE_OS" ] && DEVICE_OS="Debian"

if [ -f /boot/dietpi/.hw_model ]; then
	source /boot/dietpi/.hw_model
	DEVICE_MODEL="${G_HW_MODEL_NAME:-}"
	VER_OS="${G_DISTRO_NAME:-}"
	DEVICE_OS="DietPi"
fi
[ -z "$DEVICE_MODEL" ] && DEVICE_MODEL="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || cat /sys/class/dmi/id/product_name 2>/dev/null || uname -m)"
[ -z "$VER_OS" ] && VER_OS="$(cat /etc/debian_version 2>/dev/null || lsb_release -rs 2>/dev/null)"

settings_set '.device_model' "$DEVICE_MODEL"
settings_set '.device_os' "$DEVICE_OS"
settings_set '.ver_os' "$VER_OS"
echo "[+] Устройство: $DEVICE_MODEL / $DEVICE_OS $VER_OS"

# Сохраняем сетевые параметры
settings_set '.network.interface' "$LAN_IF"
settings_set '.network.ip' "$LAN_IP"
settings_set '.network.mask' "$LAN_MASK"
settings_set '.network.gateway' "$GATEWAY_IP"
echo "[+] Сетевые параметры сохранены"

# Сохраняем приоритетный домен
if [ -n "$DWL_DOMAIN" ]; then
	settings_set '.subscription.dwl_domain' "$DWL_DOMAIN"
	echo "[+] Приоритетный домен: $DWL_DOMAIN"
else
	settings_set '.subscription.dwl_domain' ''
fi

# ============================================
#   3. Настройка IP (статический или DHCP)
# ============================================
echo "=== Шаг 3: Настройка IP-адреса ==="

# Запоминаем текущий IP до изменений
OLD_IP="$LAN_IP"

# Создаём конфигурацию /etc/network/interfaces для DietPi
INTERFACES_FILE="/etc/network/interfaces"
BACKUP_FILE="/etc/network/interfaces.bak.$$"

# Бекапим оригинал
cp "$INTERFACES_FILE" "$BACKUP_FILE" 2>/dev/null || true

# Оставляем только loopback и наш LAN интерфейс
cat >"$INTERFACES_FILE" <<EOF
# Xray Transparent Gateway — конфигурация сети
# Исходный конфиг сохранён в $BACKUP_FILE

auto lo
iface lo inet loopback

EOF

if [ "$USE_DHCP" = "1" ]; then
	cat >>"$INTERFACES_FILE" <<EOF
auto $LAN_IF
iface $LAN_IF inet dhcp
EOF
	echo "  → Режим DHCP"
else
	cat >>"$INTERFACES_FILE" <<EOF
auto $LAN_IF
iface $LAN_IF inet static
    address $LAN_IP
    netmask $LAN_MASK
    gateway $GATEWAY_IP
    dns-nameservers 1.0.0.1
EOF
	echo "  → Статический IP: $LAN_IP / $LAN_MASK, шлюз: $GATEWAY_IP"
fi

# Отключаем systemd-networkd и NetworkManager (только disable, не stop — чтобы не рвать SSH)
# Они будут отключены после перезагрузки; текущая сессия продолжает работать
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
	systemctl disable systemd-networkd 2>/dev/null || true
	echo "  → systemd-networkd будет отключён после перезагрузки"
fi
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
	systemctl disable NetworkManager 2>/dev/null || true
	echo "  → NetworkManager будет отключён после перезагрузки"
fi

if [ "$SKIP_DNS" = "1" ]; then
	echo "  → DNS не настраивается (--no-dns)"
else
# Настраиваем dnsmasq как DNS-фронтенд (без DHCP)
echo "=== Установка dnsmasq ==="
apt-get install -y -qq dnsmasq 2>/dev/null || true

# Конфигурация dnsmasq: DNS-фронтенд, без DHCP
cat >/etc/dnsmasq.conf <<'DNSMASQ_EOF'
# Xray Transparent Gateway — DNS-фронтенд
# Принимает запросы клиентов на :53, форвардит в Xray dns-in на :5353

# Не использовать /etc/resolv.conf
no-resolv

# Слушать на LAN интерфейсе и localhost
interface=LAN_IF_PLACEHOLDER
bind-interfaces

# Не раздавать DHCP
no-dhcp-interface=LAN_IF_PLACEHOLDER

# DNS-серверы: сначала Xray (:5353), потом fallback
server=127.0.0.1#5353
server=77.88.8.8

# Кеш
cache-size=1000
min-cache-ttl=300
max-cache-ttl=1800

# Локальный домен
domain=lan
local=/lan/

# Безопасность
stop-dns-rebind
DNSMASQ_EOF

# Подставляем реальный интерфейс
sed -i "s/LAN_IF_PLACEHOLDER/$LAN_IF/g" /etc/dnsmasq.conf

# Перезапускаем dnsmasq с новым конфигом — ДО того как сломаем systemd-resolved
systemctl restart dnsmasq 2>/dev/null || true
echo "  → dnsmasq запущен на :53 → :5353"

# Отключаем systemd-resolved чтобы освободить порт 53
# ВАЖНО: dnsmasq УЖЕ слушает :53, поэтому переключение resolv.conf безопасно
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
	systemctl stop systemd-resolved 2>/dev/null || true
	systemctl disable systemd-resolved 2>/dev/null || true
	# Удаляем симлинк /etc/resolv.conf → systemd-resolved stub
	rm -f /etc/resolv.conf
	echo "nameserver 127.0.0.1" >/etc/resolv.conf
	echo "  → systemd-resolved отключён, DNS через dnsmasq (127.0.0.1:53)"
else
	# На всякий случай: если resolv.conf внешний DNS — переключаем на локальный
	if ! grep -q "^nameserver 127.0.0.1" /etc/resolv.conf 2>/dev/null; then
		echo "nameserver 127.0.0.1" >/etc/resolv.conf
		echo "  → resolv.conf переключён на 127.0.0.1"
	fi
fi
fi  # SKIP_DNS

echo "[+] Сетевая конфигурация сохранена (применится при перезагрузке)"

if [ "$USE_DHCP" != "1" ] && [ "$LAN_IP" != "$OLD_IP" ]; then
	echo ""
	echo "  ╔══════════════════════════════════════════════════╗"
	echo "  ║  [!] IP изменится при перезагрузке:              ║"
	echo "  ║      Было : $OLD_IP"                             ║"
	echo "  ║ Стало: $LAN_IP"                                  ║"
	echo "  ║                                                  ║"
	echo "  ║  После перезагрузки подключайтесь к $LAN_IP      ║"
	echo "  ╚══════════════════════════════════════════════════╝"
	echo ""
fi

# ============================================
#   4. Установка Xray
# ============================================
echo "=== Шаг 4: Установка Xray ==="

# Ждём доступности GitHub API
for i in $(seq 1 10); do
	if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание GitHub... ($i)"
	sleep 2
done

LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && {
	echo "  [X] Не удалось получить версию Xray"
	exit 1
}

LATEST_VER_NUM="${LATEST_VERSION#v}"

CURRENT_VERSION=""
if [ -x /usr/local/bin/xray ]; then
	CURRENT_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
fi

if [ "$CURRENT_VERSION" = "$LATEST_VER_NUM" ]; then
	echo "  ✓ Xray уже актуальной версии $LATEST_VERSION, пропускаем"
else
	[ -n "$CURRENT_VERSION" ] && echo "  → Текущая версия: $CURRENT_VERSION, будет обновлено до $LATEST_VER_NUM"

	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64 | amd64) MACHINE="64" ;;
	aarch64) MACHINE="arm64-v8a" ;;
	armv7l) MACHINE="arm32-v7a" ;;
	armv6l) MACHINE="arm32-v6" ;;
	*) MACHINE="arm64-v8a" ;;
	esac

	ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
	ZIP_DEST="$TMP_DIR/xray.zip"
	SHA_FILE="$STATE_DIR/xray.zip.sha256sum"
	DGST_FILE="$STATE_DIR/xray.dgst"

	echo "  → Скачиваем .dgst для Xray..."
	download_file "${ZIP_URL}.dgst" "$DGST_FILE" || {
		echo "  [X] Не удалось скачать .dgst"
		exit 1
	}

	REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Не удалось извлечь SHA2-256 из .dgst"
		exit 1
	}
	echo "  → SHA2-256: ${REMOTE_SHA:0:16}..."

	FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
	if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
		echo "  [X] Недостаточно места в /tmp"
		exit 1
	fi

	echo "  → Скачиваем Xray ZIP..."
	download_file "$ZIP_URL" "$ZIP_DEST" || {
		echo "  [X] Не удалось скачать Xray ZIP"
		exit 1
	}

	LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает!"
		exit 1
	fi

	unzip -q "$ZIP_DEST" -d "$TMP_DIR"
	cp "$TMP_DIR/xray" /usr/local/bin/xray
	chmod 755 /usr/local/bin/xray
	echo "$REMOTE_SHA" >"$SHA_FILE"
	rm -rf "$TMP_DIR"/*.zip "$TMP_DIR"/xray
	echo "[+] Xray установлен версии $LATEST_VERSION"
fi

# ============================================
#   5. Загружаем скрипты из репозитория
# ============================================
echo "=== Шаг 5: Загрузка скриптов ==="

download_script "$REPO/xray-generate-config.py" "$GENERATOR"
download_script "$REPO/xray-sub-parser.py" "$PARSER"
download_script "$REPO/update-xray.sh" "$UPDATER"
download_script "$REPO/update-nft.sh" "$NFT_UPDATER"

echo "[+] Все скрипты загружены"

# ============================================
#   6. Геофайлы + HWID + config.json
# ============================================
echo "=== Шаг 6: Геофайлы, HWID, config.json ==="

GEO_DIR="$(settings_get '.geodata.dir')"
GEOIP_URL="$(settings_get '.geodata.geoip_url')"
GEOSITE_URL="$(settings_get '.geodata.geosite_url')"

update_geo "$GEOIP_URL" "$GEO_DIR/geoip.dat"
update_geo "$GEOSITE_URL" "$GEO_DIR/geosite.dat"

# HWID
echo "  → Генерируем HWID..."
HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
settings_set '.hwid' "$HWID"
echo "  ✓ HWID: $HWID"

# Генерация config.json
echo "  → Скачиваем подписку и генерируем config.json..."

if download_file "$SUB_URL" "/tmp/sub_raw.txt" "User-Agent: $SUB_USER_AGENT" "x-hwid: $HWID"; then

	if head -n 1 "/tmp/sub_raw.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
		echo "  [X] Подписка вернула HTML вместо данных"
		rm -f "/tmp/sub_raw.txt"
		exit 1
	fi

	PARSER_ARGS="python3 $PARSER --ua \"$SUB_USER_AGENT\""
	[ -n "$REMARKS_FILTER" ] && PARSER_ARGS="$PARSER_ARGS --remarks \"$REMARKS_FILTER\""

	if eval $PARSER_ARGS <"/tmp/sub_raw.txt" >"/tmp/parsed.json" 2>>"$LOG_FILE"; then
		if python3 "$GENERATOR" --format unified --output "$CONFIG_JSON" <"/tmp/parsed.json" 2>>"$LOG_FILE"; then
			echo "  ✓ config.json создан"
		else
			echo "  [X] Ошибка генератора конфига"
			exit 1
		fi
	else
		echo "  [X] Ошибка парсера подписки"
		exit 1
	fi
	rm -f "/tmp/sub_raw.txt" "/tmp/parsed.json"
else
	echo "  [X] Не удалось скачать подписку"
	exit 1
fi

if [ ! -s "$CONFIG_JSON" ]; then
	echo "  [X] config.json пуст"
	exit 1
fi

echo "[+] Геофайлы загружены, конфиг сгенерирован"

# ============================================
#   7. Проверяем config.json
# ============================================
echo "=== Шаг 7: Валидация config.json ==="
if /usr/local/bin/xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ config.json валиден"
else
	echo "  [X] config.json НЕ прошёл проверку!"
	/usr/local/bin/xray run -test -config "$CONFIG_JSON" 2>&1 | head -20
	exit 1
fi

# ============================================
#   7.5. Создаём группу xray для GID-bypass в nftables
# ============================================
echo "=== Шаг 7.5: Группа xray для GID-bypass ==="

# Создаём группу. Сначала пробуем GID 990, если занят — системный авто-gid.
if ! getent group xray >/dev/null 2>&1 && ! grep -q '^xray:' /etc/group 2>/dev/null; then
	groupadd -r -g 990 xray 2>/dev/null || groupadd -r xray 2>/dev/null || true
fi
XRAY_GID=$(getent group xray 2>/dev/null | cut -d: -f3 || grep '^xray:' /etc/group | cut -d: -f3)
if [ -n "$XRAY_GID" ]; then
	settings_set '.xray.gid' "$XRAY_GID"
	echo "  → Группа xray: gid=$XRAY_GID"
else
	echo "  [!] Не удалось создать/найти группу xray — GID-bypass будет отключён"
fi

# ============================================
#   8. Создаём systemd-сервис для Xray
# ============================================
echo "=== Шаг 8: Systemd-сервис для Xray ==="

cat >/etc/systemd/system/xray.service <<'XRAYSVC'
[Unit]
Description=Xray Transparent Gateway
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=xray
SupplementaryGroups=xray
ExecStartPre=/bin/sh -c '\
  while ! ip route | grep -q default; do sleep 2; done; \
  if command -v ntpdate >/dev/null 2>&1; then ntpdate -u ru.pool.ntp.org 2>/dev/null || true; fi; \
  /usr/local/share/xray/update-nft.sh || { echo "[X] nftables failed" >&2; exit 1; }'
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
ExecStopPost=/usr/local/share/xray/update-nft.sh --cleanup
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/xray /tmp /var/log
ReadOnlyPaths=/usr/local/share/xray /usr/local/bin/xray
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
XRAYSVC

systemctl daemon-reload
systemctl enable xray.service
echo "[+] systemd-сервис для Xray создан и включён"

# ============================================
#   9. Policy routing для TProxy
# ============================================
echo "=== Шаг 9: Policy routing ==="

mkdir -p /etc/iproute2
if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables 2>/dev/null; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing table 100 (xray) добавлена"

# ============================================
#   10. Настройка sysctl
# ============================================
echo "=== Шаг 10: Sysctl ==="

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен (ip_forward + route_localnet)"

# ============================================
#   11. Применяем nftables
# ============================================
echo "=== Шаг 11: nftables ==="
"$NFT_UPDATER" || {
	echo "  [X] Не удалось применить nftables"
	echo "  [!] Правила будут применены при запуске Xray"
}

# ============================================
#   12. Настройка cron
# ============================================
echo "=== Шаг 12: Cron ==="

CRON_ENTRY="30 2 * * * $UPDATER"
TMP_CRON="/tmp/crontab.$$"
crontab -l 2>/dev/null >"$TMP_CRON" || true
if ! grep -qF "$UPDATER" "$TMP_CRON" 2>/dev/null; then
	echo "$CRON_ENTRY" >>"$TMP_CRON"
	crontab "$TMP_CRON"
	echo "[+] Cron: автообновление в 2:30 ночи"
else
	echo "[-] Cron уже существует"
fi
rm -f "$TMP_CRON"

# Убеждаемся что cron запущен
systemctl enable cron 2>/dev/null || systemctl enable cronie 2>/dev/null || true
systemctl restart cron 2>/dev/null || systemctl restart cronie 2>/dev/null || true

# ============================================
#   13. Настройка автозапуска после поднятия сети
# ============================================
echo "=== Шаг 13: Network hook ==="

# Создаём systemd unit, запускаемый при поднятии сети
cat >/etc/systemd/system/xray-network-update.service <<'NETSVC'
[Unit]
Description=Xray auto-update on network up
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 120 && /usr/local/share/xray/update-xray.sh'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
NETSVC

cat >/etc/systemd/system/xray-network-update.path <<'NETPATH'
[Unit]
Description=Watch for network state changes
After=network.target

[Path]
PathChanged=/run/network/ifstate

[Install]
WantedBy=multi-user.target
NETPATH

# Включаем
systemctl daemon-reload
systemctl enable xray-network-update.path 2>/dev/null || true
echo "[+] Network hook: автообновление при поднятии сети"

# ============================================
#   14. Запуск служб
# ============================================
echo "=== Шаг 14: Запуск служб ==="

# Запускаем dnsmasq (если DNS не пропущен)
if [ "$SKIP_DNS" != "1" ]; then
	systemctl enable dnsmasq 2>/dev/null || true
	systemctl restart dnsmasq 2>/dev/null || true
fi

# Применяем nftables сейчас (до запуска Xray)
"$NFT_UPDATER" 2>/dev/null || true

# Запускаем Xray
systemctl start xray.service 2>/dev/null || true

echo "[+] Службы запущены"

# ============================================
#   15. Финальная проверка
# ============================================
echo "=== Шаг 15: Финал ==="

echo ""
echo "============================================"
echo "  Установка завершена!"
echo ""
if [ "$USE_DHCP" != "1" ] && [ "$LAN_IP" != "$OLD_IP" ]; then
	echo "  [!] IP изменится при следующей загрузке:"
	echo "      Было : $OLD_IP"
	echo "      Стало: $LAN_IP"
	echo ""
fi
echo "  Xray-шлюз: $LAN_IP"
echo "  Основной роутер (Роутер): $GATEWAY_IP"
echo ""
echo "  Настройте Роутер DHCP:"
echo "    Шлюз для клиентов: $LAN_IP"
echo "    DNS для клиентов:  $LAN_IP"
echo ""
if systemctl is-active --quiet xray.service 2>/dev/null; then
	echo "  Xray ЗАПУЩЕН"
else
	echo "  [!] Xray НЕ запустился — проверьте: systemctl status xray"
fi
echo "============================================"

echo ""
echo "Лог установки: $LOG_FILE"
echo ""

# ============================================
#   16. Перезагрузка
# ============================================
echo "=== Шаг 16: Перезагрузка ==="

# Проверяем, интерактивный ли терминал
if [ -t 0 ]; then
	echo ""
	echo "  ╔══════════════════════════════════════════════════╗"
	echo "  ║  Для применения сетевых настроек нужна           ║"
	echo "  ║  ПЕРЕЗАГРУЗКА.                                   ║"
	echo "  ╚══════════════════════════════════════════════════╝"
	echo ""

	if [ "$USE_DHCP" != "1" ] && [ "$LAN_IP" != "$OLD_IP" ]; then
		echo "  [!] IP изменится: $OLD_IP → $LAN_IP"
		echo "  [!] После перезагрузки подключайтесь по НОВОМУ IP!"
		echo ""
	fi

	echo "  Перезагрузить сейчас? [Y/n] (авто-перезагрузка через 30 сек)"
	printf "  > "
	read -r -t 30 REBOOT_CHOICE
	REBOOT_CHOICE="${REBOOT_CHOICE:-Y}"

	case "$REBOOT_CHOICE" in
	[Yy] | [Yy][Ee][Ss] | "")
		echo ""
		echo "  Перезагрузка через 3 секунды..."
		sleep 3
		reboot
		;;
	*)
		echo ""
		echo "  [!] Перезагрузка отложена. Не забудьте перезагрузить вручную:"
		echo "      reboot"
		;;
	esac
else
	# Неинтерактивный режим (pipe/curl | bash)
	echo "  [!] Неинтерактивный режим — перезагрузка НЕ выполняется."
	echo "  [!] Выполните reboot вручную для применения сетевых настроек."
fi
