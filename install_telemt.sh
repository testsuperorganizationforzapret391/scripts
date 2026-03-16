#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# install_telemt.sh — Установка Telemt MTProto Proxy на VPS
#
# Использование:
#   curl -sSL https://raw.githubusercontent.com/.../install_telemt.sh | bash
#   или: bash scripts/install_telemt.sh
#
# Что делает:
#   1. Ставит Docker (если нет)
#   2. Спрашивает домен маскировки и порт
#   3. Генерирует секрет
#   4. Создаёт telemt.toml и docker-compose.yml
#   5. Запускает контейнер
#   6. Настраивает firewall
#   7. Выводит ссылку tg://proxy и данные для бота
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf "${CYAN}${BOLD}→ %s${NC} " "$1"; }

INSTALL_DIR="/opt/telemt"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CONFIG_FILE="$INSTALL_DIR/telemt.toml"

# ──────────── Проверки ────────────

check_root() {
    if [[ "${EUID:-0}" -ne 0 ]]; then
        die "Запустите от root: sudo bash $0"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Поддерживается только Linux"
    fi
    . /etc/os-release
    log "ОС: $PRETTY_NAME"
}

detect_ip() {
    PUBLIC_IP=""
    if command -v curl &>/dev/null; then
        PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$PUBLIC_IP" ]] && command -v wget &>/dev/null; then
        PUBLIC_IP=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(hostname -I | awk '{print $1}')
    fi
    log "IP сервера: $PUBLIC_IP"
}

# ──────────── Docker ────────────

install_docker() {
    if command -v docker &>/dev/null; then
        log "Docker уже установлен: $(docker --version)"
        return
    fi

    log "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    log "Docker установлен: $(docker --version)"
}

ensure_docker_compose() {
    if docker compose version &>/dev/null; then
        log "Docker Compose: $(docker compose version --short)"
        return
    fi
    if command -v docker-compose &>/dev/null; then
        log "Docker Compose (standalone): $(docker-compose --version)"
        return
    fi
    warn "Docker Compose не найден, устанавливаю плагин..."
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
    docker compose version &>/dev/null || die "Не удалось установить Docker Compose"
}

# ──────────── Проверка порта ────────────

check_port() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        local proc
        proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1)
        warn "Порт $port занят: $proc"
        return 1
    fi
    return 0
}

# ──────────── Интерактивный ввод ────────────

prompt_config() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}   Настройка Telemt MTProto Proxy${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    # Порт
    PROXY_PORT="443"
    ask "Порт для прокси [443]:"
    read -r input_port
    if [[ -n "$input_port" ]]; then
        PROXY_PORT="$input_port"
    fi
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Порт должен быть числом"
    if ! check_port "$PROXY_PORT"; then
        ask "Порт $PROXY_PORT занят. Продолжить? [y/N]:"
        read -r yn
        [[ "$yn" =~ ^[yYдД] ]] || die "Отменено"
    fi

    # Домен маскировки
    echo ""
    echo -e "${CYAN}Домен маскировки (TLS_DOMAIN):${NC}"
    echo "  DPI видит этот домен в SNI вместо Telegram."
    echo "  Выбирайте домен на том же ASN/хостере что и VPS."
    echo "  Примеры: 1c.ru, wildberries.ru, sberbank.ru"
    echo ""
    ask "Домен маскировки:"
    read -r TLS_DOMAIN
    if [[ -z "$TLS_DOMAIN" ]]; then
        die "Домен обязателен"
    fi
    # Валидация: только буквы, цифры, точки, дефисы
    if [[ ! "$TLS_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        die "Домен содержит недопустимые символы"
    fi

    # Проверка домена
    if command -v curl &>/dev/null; then
        if curl -fsSL --max-time 5 -o /dev/null "https://$TLS_DOMAIN" 2>/dev/null; then
            log "Домен $TLS_DOMAIN доступен по HTTPS ✓"
        else
            warn "Домен $TLS_DOMAIN не отвечает по HTTPS. Убедитесь что он рабочий."
        fi
    fi

    # API порт
    API_PORT="9091"
    ask "Порт API для управления ботом [9091]:"
    read -r input_api
    if [[ -n "$input_api" ]]; then
        API_PORT="$input_api"
    fi
    [[ "$API_PORT" =~ ^[0-9]+$ ]] || die "Порт API должен быть числом"

    # API токен
    API_TOKEN=""
    ask "API токен (пустой = без авторизации):"
    read -r API_TOKEN

    # Middle proxy
    USE_MIDDLE_PROXY="true"
    ask "Использовать middle proxy (для ad tag)? [Y/n]:"
    read -r yn
    if [[ "$yn" =~ ^[nN] ]]; then
        USE_MIDDLE_PROXY="false"
    fi

    # Per-user лимиты по умолчанию
    echo ""
    echo -e "${CYAN}Лимиты по умолчанию для новых ключей:${NC}"
    MAX_TCP_CONNS="0"
    ask "Макс. TCP соединений на юзера (0 = без лимита) [0]:"
    read -r input_conns
    [[ -n "$input_conns" ]] && MAX_TCP_CONNS="$input_conns"

    MAX_UNIQUE_IPS="0"
    ask "Макс. уникальных IP на юзера (0 = без лимита) [0]:"
    read -r input_ips
    [[ -n "$input_ips" ]] && MAX_UNIQUE_IPS="$input_ips"

    # Генерация секрета
    SECRET=$(openssl rand -hex 16)
    log "Секрет сгенерирован: $SECRET"
}

# ──────────── Генерация конфига ────────────

generate_config() {
    mkdir -p "$INSTALL_DIR"

    cat > "$CONFIG_FILE" << TOML
# telemt.toml — автосгенерирован install_telemt.sh
# Дата: $(date -Iseconds)

[general]
use_middle_proxy = ${USE_MIDDLE_PROXY}
fast_mode = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${PROXY_PORT}
max_connections = 10000

[server.api]
enabled = true
listen = "0.0.0.0:${API_PORT}"
whitelist = []
$([ -n "$API_TOKEN" ] && echo "auth_header = \"$API_TOKEN\"" || echo "# auth_header = \"\"")

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
tls_emulation = true
alpn_enforce = true

# Имитация реальной задержки TLS handshake (0 = мгновенно = подозрительно)
server_hello_delay_min_ms = 10
server_hello_delay_max_ms = 50

# Реальные серверы отправляют session tickets
tls_new_session_tickets = 2

[access]
replay_check_len = 65536
replay_window_secs = 1800

[access.users]
bot_default = "${SECRET}"
TOML

    log "Конфиг создан: $CONFIG_FILE"
}

generate_compose() {
    cat > "$COMPOSE_FILE" << 'YAML'
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML

    log "Docker Compose создан: $COMPOSE_FILE"
}

# ──────────── Запуск ────────────

start_telemt() {
    log "Запускаю Telemt..."
    cd "$INSTALL_DIR"
    docker compose pull --quiet
    docker compose up -d

    # Ждём запуска
    sleep 3

    if docker compose ps | grep -q "Up"; then
        log "Telemt запущен ✓"
    else
        err "Telemt не запустился! Логи:"
        docker compose logs --tail 20
        die "Проверьте конфигурацию"
    fi
}

# ──────────── Firewall ────────────

setup_firewall() {
    if ! command -v ufw &>/dev/null; then
        warn "UFW не установлен, пропускаю настройку firewall"
        return
    fi

    ufw allow "$PROXY_PORT"/tcp comment "Telemt MTProxy" 2>/dev/null || true
    # НЕ открываем API порт наружу — он для локального управления ботом
    log "Firewall: порт $PROXY_PORT открыт"
}

# ──────────── Проверка здоровья ────────────

check_health() {
    sleep 2
    if command -v curl &>/dev/null; then
        if curl -fsSL --max-time 5 "http://127.0.0.1:${API_PORT}/v1/health" &>/dev/null; then
            log "API health check: OK ✓"
        else
            warn "API на порту $API_PORT не отвечает (возможно нужно подождать)"
        fi
    fi
}

# ──────────── Вывод результата ────────────

print_result() {
    # Формируем ee-ссылку
    local hex_domain
    # xxd может отсутствовать на минимальных образах — fallback на od
    if command -v xxd &>/dev/null; then
        hex_domain=$(printf '%s' "$TLS_DOMAIN" | xxd -p | tr -d '\n')
    else
        hex_domain=$(printf '%s' "$TLS_DOMAIN" | od -A n -t x1 | tr -d ' \n')
    fi
    local full_secret="ee${SECRET}${hex_domain}"
    local proxy_link="tg://proxy?server=${PUBLIC_IP}&port=${PROXY_PORT}&secret=${full_secret}"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}   ✅ Telemt MTProto Proxy установлен!${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Сервер:${NC}      $PUBLIC_IP"
    echo -e "${BOLD}Порт:${NC}        $PROXY_PORT"
    echo -e "${BOLD}Домен:${NC}       $TLS_DOMAIN"
    echo -e "${BOLD}Секрет:${NC}      $SECRET"
    echo -e "${BOLD}API:${NC}         http://127.0.0.1:${API_PORT}"
    echo -e "${BOLD}Конфиг:${NC}      $CONFIG_FILE"
    echo ""
    echo -e "${BOLD}Ссылка для Telegram:${NC}"
    echo -e "${CYAN}${proxy_link}${NC}"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Для бота (/telemt_add):${NC}"
    echo ""
    echo -e "${CYAN}tmt_$(echo "$PUBLIC_IP" | tr '.' '_') Telemt-${TLS_DOMAIN%%.*} http://${PUBLIC_IP}:${API_PORT} $(curl -fsSL --max-time 3 https://ipinfo.io/country 2>/dev/null || echo 'XX')${NC}"
    if [[ -n "$API_TOKEN" ]]; then
        echo -e "(с токеном: добавьте 5-м полем: ${API_TOKEN})"
    fi
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
    echo "Управление:"
    echo "  docker compose -f $COMPOSE_FILE logs -f     # логи"
    echo "  docker compose -f $COMPOSE_FILE restart     # рестарт"
    echo "  docker compose -f $COMPOSE_FILE down        # остановить"
    echo "  curl http://127.0.0.1:${API_PORT}/v1/users  # пользователи"
    echo "  curl http://127.0.0.1:${API_PORT}/v1/health # здоровье"
    echo ""

    # Сохраняем данные в файл для удобства
    cat > "$INSTALL_DIR/server_info.txt" << EOF
# Telemt MTProxy Server Info
# Generated: $(date -Iseconds)

IP=$PUBLIC_IP
PORT=$PROXY_PORT
TLS_DOMAIN=$TLS_DOMAIN
SECRET=$SECRET
API_PORT=$API_PORT
API_TOKEN=$API_TOKEN
PROXY_LINK=$proxy_link
BOT_ADD_CMD=tmt_$(echo "$PUBLIC_IP" | tr '.' '_') Telemt-${TLS_DOMAIN%%.*} http://${PUBLIC_IP}:${API_PORT} $(curl -fsSL --max-time 3 https://ipinfo.io/country 2>/dev/null || echo 'XX') ${API_TOKEN}
EOF
    log "Данные сохранены в $INSTALL_DIR/server_info.txt"
}

# ──────────── Удаление ────────────

uninstall() {
    echo -e "${YELLOW}${BOLD}Удаление Telemt MTProxy${NC}"
    ask "Вы уверены? [y/N]:"
    read -r yn
    [[ "$yn" =~ ^[yYдД] ]] || { echo "Отменено"; exit 0; }

    cd "$INSTALL_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
    docker rmi whn0thacked/telemt-docker 2>/dev/null || true

    if command -v ufw &>/dev/null; then
        local port
        port=$(grep -oP 'port = \K\d+' "$CONFIG_FILE" 2>/dev/null || echo "443")
        ufw delete allow "$port"/tcp 2>/dev/null || true
    fi

    rm -rf "$INSTALL_DIR"
    log "Telemt удалён"
}

# ──────────── Main ────────────

main() {
    echo ""
    echo -e "${BOLD}🔷 Telemt MTProto Proxy Installer${NC}"
    echo ""

    # Проверка аргументов
    if [[ "${1:-}" == "uninstall" || "${1:-}" == "remove" ]]; then
        check_root
        uninstall
        exit 0
    fi

    if [[ "${1:-}" == "status" ]]; then
        if [[ -f "$COMPOSE_FILE" ]]; then
            cd "$INSTALL_DIR" && docker compose ps
        else
            echo "Telemt не установлен"
        fi
        exit 0
    fi

    # Проверка на повторную установку
    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Telemt уже установлен в $INSTALL_DIR"
        ask "Переустановить? [y/N]:"
        read -r yn
        [[ "$yn" =~ ^[yYдД] ]] || { echo "Отменено"; exit 0; }
        cd "$INSTALL_DIR" && docker compose down 2>/dev/null || true
    fi

    check_root
    check_os
    detect_ip
    install_docker
    ensure_docker_compose
    prompt_config
    generate_config
    generate_compose
    start_telemt
    setup_firewall
    check_health
    print_result
}

main "$@"
