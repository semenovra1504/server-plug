#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/semenovra1504/server-plug/main"

TEMPLATES=(
  "01-kroshka.html"
  "03-otrezok.html"
  "04-spektr.html"
  "05-access_restricted.html"
)

log() {
  printf '\n\033[1;32m%s\033[0m\n' "$1"
}

error() {
  printf '\n\033[1;31mОшибка:\033[0m %s\n' "$1" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  error "Скрипт нужно запускать от root. Используй: curl -fsSL ${BASE_URL}/setup.sh | sudo bash"
fi

if [[ ! -r /dev/tty ]]; then
  error "Нет доступа к /dev/tty. Запусти скрипт из обычного интерактивного терминала."
fi

# -----------------------------------------------------------------------------
# 1. Домен
# -----------------------------------------------------------------------------

DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  printf 'Укажи домен (например ads.zenvoras.net): ' > /dev/tty
  IFS= read -r DOMAIN < /dev/tty
fi

# Убираем пробелы/переводы строк по краям без запуска внешних команд.
DOMAIN="${DOMAIN#"${DOMAIN%%[![:space:]]*}"}"
DOMAIN="${DOMAIN%"${DOMAIN##*[![:space:]]}"}"

# Нижний регистр средствами bash.
DOMAIN="${DOMAIN,,}"

[[ -n "$DOMAIN" ]] || error "Домен не указан."

# Проверяем только безопасный формат домена.
if [[ "$DOMAIN" == *".."* ]] || \
   [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || \
   [[ "$DOMAIN" != *.* ]]; then
  error "Некорректный домен: $DOMAIN"
fi

printf '\nДомен принят: %s\n' "$DOMAIN" > /dev/tty

# -----------------------------------------------------------------------------
# 2. Выбор заглушки
# -----------------------------------------------------------------------------

CHOICE="${2:-}"

if [[ -z "$CHOICE" ]]; then
  printf '\nВыбери заглушку:\n' > /dev/tty

  for i in "${!TEMPLATES[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${TEMPLATES[$i]}" > /dev/tty
  done

  printf '\nВведи номер [1-4]: ' > /dev/tty
  IFS= read -r CHOICE < /dev/tty
fi

# На всякий случай убираем пробелы по краям.
CHOICE="${CHOICE#"${CHOICE%%[![:space:]]*}"}"
CHOICE="${CHOICE%"${CHOICE##*[![:space:]]}"}"

case "$CHOICE" in
  1) TEMPLATE="${TEMPLATES[0]}" ;;
  2) TEMPLATE="${TEMPLATES[1]}" ;;
  3) TEMPLATE="${TEMPLATES[2]}" ;;
  4) TEMPLATE="${TEMPLATES[3]}" ;;
  *) error "Нужно выбрать вариант от 1 до 4." ;;
esac

WEB_ROOT="/var/www/${DOMAIN}"
NGINX_AVAILABLE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

CERT_DIR="/root/cert/${DOMAIN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

TEMPLATE_URL="${BASE_URL}/${TEMPLATE}"

printf '\n'
printf 'Домен:     %s\n' "$DOMAIN"
printf 'Заглушка:  %s\n' "$TEMPLATE"
printf 'Web root:  %s\n' "$WEB_ROOT"
printf 'SSL:       %s\n' "$CERT_DIR"

# -----------------------------------------------------------------------------
# 3. Проверяем SSL
# -----------------------------------------------------------------------------

log "Проверяю SSL-сертификаты..."

[[ -f "$FULLCHAIN" ]] || error "Не найден SSL-сертификат: $FULLCHAIN"
[[ -f "$PRIVKEY" ]] || error "Не найден SSL-ключ: $PRIVKEY"

# -----------------------------------------------------------------------------
# 4. Устанавливаем nginx/curl при необходимости
# -----------------------------------------------------------------------------

if ! command -v nginx >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log "Устанавливаю nginx и curl..."

  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y nginx curl
else
  log "nginx и curl уже установлены."
fi

log "Запускаю nginx..."
systemctl enable --now nginx

log "Версия nginx:"
nginx -v

# -----------------------------------------------------------------------------
# 5. Создаём папку сайта
# -----------------------------------------------------------------------------

log "Создаю каталог сайта..."
install -d -m 755 "$WEB_ROOT"

# -----------------------------------------------------------------------------
# 6. Скачиваем выбранную заглушку
# -----------------------------------------------------------------------------

log "Скачиваю ${TEMPLATE}..."

TMP_HTML="${WEB_ROOT}/.index.html.tmp"

# Удаляем временный файл при аварийном завершении.
cleanup() {
  rm -f "$TMP_HTML"
}
trap cleanup EXIT

curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --connect-timeout 15 \
  --max-time 60 \
  "$TEMPLATE_URL" \
  -o "$TMP_HTML"

[[ -s "$TMP_HTML" ]] || error "Скачанный HTML-файл пуст."

chmod 644 "$TMP_HTML"
mv -f "$TMP_HTML" "${WEB_ROOT}/index.html"

# После успешного mv временного файла уже нет.
trap - EXIT

# -----------------------------------------------------------------------------
# 7. Создаём nginx-конфиг
# -----------------------------------------------------------------------------

log "Создаю nginx-конфиг..."

cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name ${DOMAIN};

    ssl_certificate     ${FULLCHAIN};
    ssl_certificate_key ${PRIVKEY};

    root ${WEB_ROOT};
    index index.html;

    location / {
        try_files /index.html =404;
    }
}
EOF

# -----------------------------------------------------------------------------
# 8. Активируем сайт
# -----------------------------------------------------------------------------

log "Активирую сайт..."
ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"

# -----------------------------------------------------------------------------
# 9. Проверяем конфигурацию
# -----------------------------------------------------------------------------

log "Проверяю конфигурацию nginx..."
nginx -t

# -----------------------------------------------------------------------------
# 10. Применяем конфигурацию
# -----------------------------------------------------------------------------

log "Перезагружаю nginx..."
systemctl reload nginx

printf '\n\033[1;32mГотово.\033[0m\n'
printf 'Сайт:      https://%s\n' "$DOMAIN"
printf 'Заглушка:  %s\n' "$TEMPLATE"
printf 'HTML:      %s/index.html\n' "$WEB_ROOT"
printf 'Nginx:     %s\n\n' "$NGINX_AVAILABLE"
