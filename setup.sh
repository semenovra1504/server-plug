#!/usr/bin/env bash
set -Eeuo pipefail

# Репозиторий, где лежат setup.sh и HTML-заглушки.
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

# При запуске через:
# curl -fsSL .../setup.sh | sudo bash
# stdin занят самим скриптом, поэтому интерактивные ответы читаем из /dev/tty.
ask() {
  local prompt="$1"
  local value

  if [[ ! -r /dev/tty ]]; then
    error "Нет интерактивного терминала. Запусти скрипт из обычного терминала."
  fi

  printf "%s" "$prompt" > /dev/tty
  IFS= read -r value < /dev/tty
  printf "%s" "$value"
}

if [[ "${EUID}" -ne 0 ]]; then
  error "Скрипт нужно запускать от root. Используй: curl -fsSL ${BASE_URL}/setup.sh | sudo bash"
fi

# -----------------------------------------------------------------------------
# 1. Домен
# -----------------------------------------------------------------------------

DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(ask "Укажи домен (например ads.zenvoras.net): ")"
fi

# Убираем пробелы по краям и приводим домен к нижнему регистру.
DOMAIN="$(printf '%s' "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')"

[[ -n "$DOMAIN" ]] || error "Домен не указан."

# Простая безопасная проверка домена, чтобы его нельзя было использовать
# для подстановки путей или shell-команд.
if [[ "$DOMAIN" == *".."* ]] || \
   [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || \
   [[ "$DOMAIN" != *.* ]]; then
  error "Некорректный домен: $DOMAIN"
fi

# -----------------------------------------------------------------------------
# 2. Выбор заглушки
# -----------------------------------------------------------------------------

CHOICE="${2:-}"

if [[ -z "$CHOICE" ]]; then
  printf '\nВыбери заглушку:\n' > /dev/tty

  for i in "${!TEMPLATES[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${TEMPLATES[$i]}" > /dev/tty
  done

  CHOICE="$(ask $'\nВведи номер [1-4]: ')"
fi

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
# 3. Проверяем SSL до изменения nginx-конфига
# -----------------------------------------------------------------------------

[[ -f "$FULLCHAIN" ]] || error "Не найден SSL-сертификат: $FULLCHAIN"
[[ -f "$PRIVKEY" ]] || error "Не найден SSL-ключ: $PRIVKEY"

# -----------------------------------------------------------------------------
# 4. Устанавливаем nginx/curl, если чего-то нет
# -----------------------------------------------------------------------------

if ! command -v nginx >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log "Устанавливаю nginx и curl..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y nginx curl
else
  log "nginx и curl уже установлены."
fi

systemctl enable --now nginx

log "Версия nginx:"
nginx -v

# -----------------------------------------------------------------------------
# 5. Создаём папку сайта и скачиваем выбранную заглушку
# -----------------------------------------------------------------------------

log "Создаю каталог сайта..."
install -d -m 755 "$WEB_ROOT"

log "Скачиваю ${TEMPLATE}..."
TMP_HTML="${WEB_ROOT}/.index.html.tmp"

curl -fsSL "$TEMPLATE_URL" -o "$TMP_HTML"
chmod 644 "$TMP_HTML"
mv -f "$TMP_HTML" "${WEB_ROOT}/index.html"

# -----------------------------------------------------------------------------
# 6. Создаём nginx-конфиг
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
# 7. Активируем сайт
# -----------------------------------------------------------------------------

log "Активирую сайт..."
ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"

# -----------------------------------------------------------------------------
# 8. Проверяем конфигурацию и применяем её
# -----------------------------------------------------------------------------

log "Проверяю конфигурацию nginx..."
nginx -t

log "Перезагружаю nginx..."
systemctl reload nginx

printf '\n\033[1;32mГотово.\033[0m\n'
printf 'Сайт: https://%s\n' "$DOMAIN"
printf 'Заглушка: %s\n' "$TEMPLATE"
printf 'HTML: %s/index.html\n' "$WEB_ROOT"
printf 'Nginx: %s\n\n' "$NGINX_AVAILABLE"
