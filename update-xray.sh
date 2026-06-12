#!/bin/bash
# DietPi (Debian ARM) — обновление Xray, geoip, geosite, подписки и config.json
# Работает в режиме прозрачного шлюза
# Поддерживает два формата подписки:
#   - Base64 (VLESS URI)
#   - JSON (Happ/Sing-box)

set -e

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# Блокировка от одновременного запуска
LOCK_FILE="/var/lock/xray-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
	echo "Другой экземпляр уже запущен" >&2
	exit 1
fi

LOG="/var/log/xray-update.log"
mkdir -p "$(dirname "$LOG")"

die() {
	echo "[X] $1" | tee -a "$LOG"
	exit 1
}

# Единая функция загрузки (curl) — с авто-заголовками из settings.json
fetch_url() {
	local url="$1"
	local dst="$2"

	# Системные заголовки из settings.json
	local _ua _ver _model _os
	_ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "XPower/1.0")
	_ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
	_model=$(settings_get ".device_model" 2>/dev/null || echo "")
	_os=$(settings_get ".device_os" 2>/dev/null || echo "")

	# Cache-buster для raw.githubusercontent.com
	case "$url" in
	*raw.githubusercontent.com*) url="${url}?_t=$(date +%s)" ;;
	esac

	curl -s -L --max-time 15 \
		-H "User-Agent: $_ua" \
		${_ver:+-H "X-Ver-Os: $_ver"} \
		${_model:+-H "X-Device-Model: $_model"} \
		${_os:+-H "X-Device-Os: $_os"} \
		-o "$dst" "$url"
	local rc=$?

	if [ $rc -eq 0 ] && [ -s "$dst" ]; then
		if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
			rm -f "$dst"
			return 1
		fi
		return 0
	fi

	return 1
}

CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"

# ============================================
#   HELPER: чтение settings.json
# ============================================
settings_get() {
	python3 -c "import json; cfg=json.load(open('$SETTINGS_JSON')); print(cfg${1} if ${1} else '')" 2>/dev/null || true
}

STATE_DIR="/etc/xray/state"
TMP_DIR="/tmp/xray_update"

XRAY_BIN="/usr/local/bin/xray"
GENERATOR="/usr/local/share/xray/xray-generate-config.py"
PARSER="/usr/local/share/xray/xray-sub-parser.py"
NFT_UPDATER="/usr/local/share/xray/update-nft.sh"
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-Linux-Gateway/main"

# Геоданные — из settings.json (с умолчаниями)
GEO_DIR="$(settings_get '.geodata.dir')"
[ -z "$GEO_DIR" ] && GEO_DIR="/usr/local/share/xray"
GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="$(settings_get '.geodata.geoip_url')"
[ -z "$GEOIP_URL" ] && GEOIP_URL="https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat"
GEOSITE_URL="$(settings_get '.geodata.geosite_url')"
[ -z "$GEOSITE_URL" ] && GEOSITE_URL="https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"

mkdir -p "$STATE_DIR" "$TMP_DIR"

echo "===== $(date) =====" >>"$LOG"

extract_sha256() {
	awk -F '= ' '/^SHA2-256/{print $2}' "$1" | tr -d ' \n'
}

# =============================================
#   Очистка/ротация логов
# =============================================
rotate_log() {
	local log="$1"
	local max_size="${2:-1048576}" # по умолчанию 1MB
	[ -f "$log" ] || return
	local size=$(stat -c%s "$log" 2>/dev/null || wc -c <"$log")
	if [ "$size" -gt "$max_size" ]; then
		: >"$log"
		echo "[*] Лог очищен: $log" >>"$LOG"
	fi
}
rotate_log "/var/log/xray-access.log" 524288
rotate_log "/var/log/xray-error.log" 262144
rotate_log "$LOG" 262144

# Проверка свободного места в /
FREE_SPACE_ROOT=$(df / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_ROOT" -lt 10240 ]; then
	die "Недостаточно места в / (нужно минимум 10MB, доступно ${FREE_SPACE_ROOT}KB)"
fi

# Проверка/создание группы xray (нужна для GID-bypass в nftables)
if ! getent group xray >/dev/null 2>&1; then
	groupadd -r -g 990 xray 2>/dev/null || true
fi

# ============================
#   HWID + подписка + настройки
# ============================

# Читаем HWID из settings.json
HWID="$(settings_get '.hwid')"
[ -z "$HWID" ] && die "Нет HWID в settings.json"

# Читаем URL подписки из settings.json
SUB_URL="$(settings_get '.subscription.url')"
[ -z "$SUB_URL" ] && die "Нет URL подписки в settings.json"

# Читаем User-Agent из settings.json
SUB_USER_AGENT="$(settings_get '.subscription.user_agent')"
[ -z "$SUB_USER_AGENT" ] && SUB_USER_AGENT="DietPi-Xray/1.0"
echo "→ User-Agent: $SUB_USER_AGENT" >>"$LOG"

# Читаем фильтр remarks из settings.json
REMARKS_FILTER="$(settings_get '.subscription.remarks')"
[ -n "$REMARKS_FILTER" ] && echo "→ Фильтр remarks: $REMARKS_FILTER" >>"$LOG"

# ============================
#   Обновление Xray
# ============================

echo "→ Проверка обновлений Xray..." >>"$LOG"

# Ожидание доступности GitHub API
for i in $(seq 1 5); do
	if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

LATEST_VERSION=$(curl -s --user-agent "DietPi-Xray/1.0" --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

if [ -z "$LATEST_VERSION" ]; then
	echo "[!] Не удалось получить версию Xray — пропускаем обновление" >>"$LOG"
else
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

	if fetch_url "${ZIP_URL}.dgst" "$STATE_DIR/xray.dgst"; then
		REMOTE_SHA=$(extract_sha256 "$STATE_DIR/xray.dgst")

		if [ -n "$REMOTE_SHA" ]; then
			FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
			if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
				echo "[!] Недостаточно места в /tmp (нужно минимум 20MB) — пропускаем" >>"$LOG"
			elif [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
				echo "✓ Xray ZIP не изменился" >>"$LOG"
			else
				echo "→ Скачиваем Xray ZIP..." >>"$LOG"
				if fetch_url "$ZIP_URL" "$ZIP_DEST"; then
					LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
					if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
						echo "$REMOTE_SHA" >"$SHA_FILE"
						unzip -q "$ZIP_DEST" -d "$TMP_DIR"
						if [ -f "$TMP_DIR/xray" ]; then
							# Останавливаем Xray перед обновлением
							systemctl stop xray.service 2>/dev/null || true
							cp "$TMP_DIR/xray" "$XRAY_BIN"
							chmod 755 "$XRAY_BIN"
							echo "[+] Xray обновлён до $LATEST_VERSION" >>"$LOG"
						else
							echo "[!] Не удалось распаковать Xray" >>"$LOG"
						fi
					else
						echo "[X] SHA не совпадает для Xray ZIP" >>"$LOG"
					fi
				else
					echo "[!] Не удалось скачать Xray ZIP" >>"$LOG"
				fi
			fi
		else
			echo "[!] Не удалось извлечь SHA из .dgst" >>"$LOG"
		fi
	else
		echo "[!] Не удалось скачать .dgst" >>"$LOG"
	fi
fi

# ============================
#   GEOIP / GEOSITE
# ============================

update_geo() {
	local URL="$1"
	local DEST="$2"
	local BASE=$(basename "$DEST")
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"
	local TMP_DEST="${TMP_DIR}/${BASE}"
	local TMP_SHA="${TMP_DIR}/${BASE}.sha256"

	echo "→ Обновление $BASE..." >>"$LOG"

	# Скачиваем SHA256
	if ! fetch_url "${URL}.sha256sum" "$TMP_SHA"; then
		echo "[!] Не удалось скачать sha256sum для $BASE — пропускаем" >>"$LOG"
		return 1
	fi

	REMOTE_SHA=$(cut -d' ' -f1 "$TMP_SHA")
	if [ -z "$REMOTE_SHA" ]; then
		echo "[!] Пустой sha256sum для $BASE — пропускаем" >>"$LOG"
		return 1
	fi

	# Проверяем, нужно ли обновлять
	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
		echo "✓ $BASE не изменился" >>"$LOG"
		return 0
	fi

	# Скачиваем сам файл
	if ! fetch_url "$URL" "$TMP_DEST"; then
		echo "[!] Не удалось скачать $BASE — пропускаем" >>"$LOG"
		return 1
	fi

	# Проверяем SHA
	LOCAL_SHA=$(sha256sum "$TMP_DEST" | awk '{print $1}')
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "[X] SHA не совпадает для $BASE" >>"$LOG"
		rm -f "$TMP_DEST"
		return 1
	fi

	# Атомарное обновление
	mv "$TMP_DEST" "$DEST"
	echo "$REMOTE_SHA" >"$SHA_FILE"
	echo "[+] $BASE обновлён" >>"$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# ============================
#   Обновление скриптов из репозитория
# ============================

echo "→ Обновление скриптов..." >>"$LOG"
for scr in xray-generate-config.py xray-sub-parser.py update-nft.sh; do
	fetch_url "$REPO/$scr" "/tmp/${scr}" && mv "/tmp/${scr}" "/usr/local/share/xray/${scr}" && chmod +x "/usr/local/share/xray/${scr}" 2>/dev/null
done

# Обновляем settings.default.json (только если settings.json отсутствует)
if [ ! -f "$SETTINGS_JSON" ]; then
	fetch_url "$REPO/settings.default.json" "$SETTINGS_JSON" 2>/dev/null || true
fi
echo "→ Скрипты обновлены" >>"$LOG"

# ============================
#   Генерация config.json (поддерживает оба формата)
# ============================

echo "→ Генерация config.json (User-Agent: $SUB_USER_AGENT)..." >>"$LOG"

# Скачиваем подписку
if curl -s -L -H "User-Agent: $SUB_USER_AGENT" -H "x-hwid: $HWID" "$SUB_URL" -o "$TMP_DIR/sub.txt"; then

	# Проверяем, что скачалось не HTML
	if head -n 1 "$TMP_DIR/sub.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
		echo "[X] Подписка вернула HTML, а не данные" >>"$LOG"
	else
		# Единый пайплайн: парсер (с автоопределением формата) → генератор
		PARSER_ARGS="python3 $PARSER --ua \"$SUB_USER_AGENT\""
		[ -n "$REMARKS_FILTER" ] && PARSER_ARGS="$PARSER_ARGS --remarks \"$REMARKS_FILTER\""

		if eval $PARSER_ARGS < "$TMP_DIR/sub.txt" > "$TMP_DIR/parsed.json" 2>>"$LOG"; then
			if python3 "$GENERATOR" --format unified --output "$TMP_DIR/config.json" < "$TMP_DIR/parsed.json" 2>>"$LOG"; then
				if $XRAY_BIN run -test -config "$TMP_DIR/config.json" >>"$LOG" 2>&1; then
					mv "$TMP_DIR/config.json" "$CONFIG_JSON"
					echo "[+] Новый config.json установлен" >>"$LOG"
				else
					echo "[X] Новый config.json невалиден" >>"$LOG"
					$XRAY_BIN run -test -config "$TMP_DIR/config.json" 2>>"$LOG"
				fi
			else
				echo "[X] Ошибка генератора конфига" >>"$LOG"
			fi
		else
			echo "[X] Ошибка парсера подписки" >>"$LOG"
		fi
	fi
else
	echo "[!] Не удалось скачать подписку" >>"$LOG"
fi

# Очистка временных файлов
rm -f "$TMP_DIR/sub.txt" "$TMP_DIR/parsed.json" "$TMP_DIR/config.json"

# ============================
#   Финальная проверка config.json
# ============================

if [ -f "$CONFIG_JSON" ]; then
	if ! $XRAY_BIN run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
		echo "[X] Итоговый config.json невалиден — отключаем Xray" >>"$LOG"
		systemctl stop xray.service 2>/dev/null || true
		exit 1
	fi
else
	echo "[X] config.json отсутствует — отключаем Xray" >>"$LOG"
	systemctl stop xray.service 2>/dev/null || true
	exit 1
fi

# ============================
#   Пересборка nftables правил
# ============================

echo "→ Обновление nftables правил..." >>"$LOG"
if /usr/local/share/xray/update-nft.sh >>"$LOG" 2>&1; then
	echo "[+] nftables правила обновлены" >>"$LOG"
else
	echo "[X] Ошибка при обновлении nftables" >>"$LOG"
fi

# ============================
#   Перезапуск Xray
# ============================

echo "→ Перезапуск Xray..." >>"$LOG"
if systemctl restart xray.service >>"$LOG" 2>&1; then
	echo "[+] Xray перезапущен успешно" >>"$LOG"
else
	echo "[!] Не удалось перезапустить Xray" >>"$LOG"
fi

echo "===== Готово =====" >>"$LOG"

# Очистка временных файлов
rm -rf "$TMP_DIR"

# Снятие блокировки
flock -u 200
