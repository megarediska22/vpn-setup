#!/usr/bin/env bash
# ============================================================================
# sing-box VPS Setup: VLESS + REALITY
# Автоматическая настройка VPN сервера на чистом VPS
# Работает на Ubuntu 20.04 / 22.04 / 24.04 и Debian 11/12
# Клиенты: macOS, Android (Hiddify / NekoBox), iOS (Shadowrocket/Stash)
# ============================================================================

set -euo pipefail

# ── Цвета и форматирование ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

# ── Проверка root ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Запустите скрипт от root: sudo bash setup.sh"
    exit 1
fi

# ── Проверка ОС ─────────────────────────────────────────────────────────────
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    error "Поддерживаются только Ubuntu и Debian"
    exit 1
fi

DOMAIN=""
SERVER_IP=""

# ── Параметры ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)   DOMAIN="$2";   shift 2 ;;
        --ip)       SERVER_IP="$2"; shift 2 ;;
        -h|--help)
            echo "Использование: sudo bash setup.sh [--domain DOMAIN] [--ip IP]"
            echo ""
            echo "Если не указан --ip, скрипт определит его автоматически."
            echo "Если не указан --domain, будет использован IP-адрес."
            exit 0
            ;;
        *) error "Неизвестный параметр: $1"; exit 1 ;;
    esac
done

# ── Определение IP ──────────────────────────────────────────────────────────
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -s4 https://ifconfig.me 2>/dev/null || \
                curl -s4 https://api.ipify.org 2>/dev/null || \
                echo "")
    if [[ -z "$SERVER_IP" ]]; then
        error "Не удалось определить IP. Укажите через --ip"
        exit 1
    fi
fi
info "IP сервера: $SERVER_IP"

# ── Генерация параметров ────────────────────────────────────────────────────
step "Генерация конфигурации"

# UUID — генерируем через sing-box, fallback через /proc/sys
if command -v sing-box &>/dev/null; then
    UUID=$(sing-box generate uuid 2>/dev/null || uuidgen)
else
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
fi
info "UUID: $UUID"

# Reality ключевая пара (X25519)
KEYPAIR=$(sing-box generate reality-keypair 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i 'private' | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i 'public' | awk '{print $NF}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Не удалось сгенерировать ключи Reality. Установите sing-box и повторите."
    exit 1
fi
info "Reality Private Key: $PRIVATE_KEY"
info "Reality Public Key:  $PUBLIC_KEY"

# Short ID — 8 hex символов
SHORT_ID=$(openssl rand -hex 8)
info "Short ID: $SHORT_ID"

# Server name (SNI) для маскировки трафика
DEST_SNI="www.microsoft.com"
DEST_PORT="443"

# Локальный порт для sing-box
LOCAL_PORT="443"

# ── Обновление системы ─────────────────────────────────────────────────────
step "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
info "Система обновлена"

# ── Установка зависимостей ──────────────────────────────────────────────────
step "Установка зависимостей"
apt-get install -y -qq curl wget jq unzip systemd-resolved
info "Зависимости установлены"

# ── Установка sing-box ─────────────────────────────────────────────────────
step "Установка sing-box"

# Определяем архитектуру
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)    SING_ARCH="amd64" ;;
    aarch64)   SING_ARCH="arm64" ;;
    armv7l)    SING_ARCH="armv7" ;;
    *)         error "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

# Получаем последнюю версию
SING_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
if [[ -z "$SING_VER" || "$SING_VER" == "null" ]]; then
    error "Не удалось определить последнюю версию sing-box"
    exit 1
fi
info "Последняя версия sing-box: v$SING_VER"

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_VER}/sing-box-${SING_VER}-linux-${SING_ARCH}.tar.gz"
curl -sL "$DOWNLOAD_URL" -o /tmp/sing-box.tar.gz
tar -xzf /tmp/sing-box.tar.gz -C /tmp/
cp /tmp/sing-box-${SING_VER}-linux-${SING_ARCH}/sing-box /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf /tmp/sing-box*

# Проверка
sing-box version
info "sing-box v$SING_VER установлен"

# ── Создание конфигурации ──────────────────────────────────────────────────
step "Создание конфигурации sing-box"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json << JSONEOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "listen_port": ${LOCAL_PORT},
      "users": [
        {
          "name": "user",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": false
        }
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN:-$SERVER_IP}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DEST_SNI}",
            "server_port": ${DEST_PORT}
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        },
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_cidr": [
          "geoip:private"
        ],
        "outbound": "block"
      }
    ],
    "final": "direct"
  }
}
JSONEOF

# Проверка конфигурации
if sing-box check -c /etc/sing-box/config.json; then
    info "Конфигурация валидна"
else
    error "Ошибка в конфигурации!"
    exit 1
fi

# ── Systemd сервис ─────────────────────────────────────────────────────────
step "Настройка systemd сервиса"

cat > /etc/systemd/system/sing-box.service << 'SVCEOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
sleep 2

if systemctl is-active --quiet sing-box; then
    info "sing-box запущен и работает"
else
    error "sing-box не запустился. Проверьте: journalctl -u sing-box -f"
    exit 1
fi

# ── Настройка файрвола ─────────────────────────────────────────────────────
step "Настройка файрвола"

if command -v ufw &>/dev/null; then
    ufw allow ssh >/dev/null 2>&1
    ufw allow ${LOCAL_PORT}/tcp >/dev/null 2>&1
    ufw allow ${LOCAL_PORT}/udp >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1
    info "UFW настроен"
else
    info "UFW не установлен, пропускаем (port开放 на VPS обычно открыт)"
fi

# ── Sysctl оптимизации ────────────────────────────────────────────────────
step "Сетевые оптимизации"

cat > /etc/sysctl.d/99-sing-box.conf << 'SYSCTLEOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
SYSCTLEOF

sysctl -p /etc/sysctl.d/99-sing-box.conf >/dev/null 2>&1
info "Sysctl оптимизации применены"

# ── Автообновление (systemd timer) ─────────────────────────────────────────
step "Настройка автообновления sing-box"

cat > /usr/local/bin/sing-box-updater.sh << 'UPDEOF'
#!/usr/bin/env bash
# Автообновление sing-box до последней версии
set -euo pipefail

CURRENT=$(sing-box version | head -1 | awk '{print $NF}' | sed 's/^v//')
LATEST=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/^v//')

if [[ "$CURRENT" != "$LATEST" && -n "$LATEST" && "$LATEST" != "null" ]]; then
    logger "sing-box: обновление с v${CURRENT} до v${LATEST}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SING_ARCH="amd64" ;;
        aarch64) SING_ARCH="arm64" ;;
        armv7l)  SING_ARCH="armv7" ;;
    esac
    
    systemctl stop sing-box
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${LATEST}/sing-box-${LATEST}-linux-${SING_ARCH}.tar.gz" -o /tmp/sing-box.tar.gz
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    cp /tmp/sing-box-${LATEST}-linux-${SING_ARCH}/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/sing-box*
    
    sing-box check -c /etc/sing-box/config.json && systemctl start sing-box
    logger "sing-box: обновлено до v${LATEST}"
fi
UPDEOF

chmod +x /usr/local/bin/sing-box-updater.sh

# Таймер для обновления каждую неделю
cat > /etc/systemd/system/sing-box-update.service << 'SVCEOF2'
[Unit]
Description=sing-box auto-update

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sing-box-updater.sh
SVCEOF2

cat > /etc/systemd/system/sing-box-update.timer << 'TIMEOF'
[Unit]
Description=Weekly sing-box update check

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TIMEOF

systemctl daemon-reload
systemctl enable --now sing-box-update.timer
info "Автообновление настроено (еженедельно)"

# ── Генерация конфигов для клиентов ────────────────────────────────────────
step "Генерация клиентских конфигов"

CLIENT_CONFIG_DIR="/root/vpn-clients"
mkdir -p "$CLIENT_CONFIG_DIR"

# Определяем SNI — используем домен если есть, иначе IP
SNI="${DOMAIN:-$SERVER_IP}"

# VLESS URL для ручного ввода
VLESS_URL="vless://${UUID}@${SERVER_IP}:${LOCAL_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VPN-Reality"

# Sing-box конфиг для клиента (JSON)
cat > "${CLIENT_CONFIG_DIR}/client-config.json" << CLIENTEOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "sniff": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": ${LOCAL_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      },
      {
        "ip_cidr": ["geoip:private"],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
CLIENTEOF

# Hiddify / NekoBox конфиг (для Android)
cat > "${CLIENT_CONFIG_DIR}/hiddify-sub.txt" << HIDEEOF
${VLESS_URL}
HIDEEOF

# QR код в текстовом виде (для быстрого сканирования)
info "Сохранение QR кода..."
if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 "${VLESS_URL}" > "${CLIENT_CONFIG_DIR}/qr-code.txt" 2>/dev/null || true
else
    echo "QR код недоступен (установите qrencode)" > "${CLIENT_CONFIG_DIR}/qr-code.txt"
fi

chmod 600 "${CLIENT_CONFIG_DIR}"/*

# ── Вывод результатов ──────────────────────────────────────────────────────
step "Готово! Все настроено"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    VPN VLESS + REALITY                         ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ${CYAN}IP:${NC}           ${SERVER_IP}"
echo -e "${BOLD}║${NC}  ${CYAN}UUID:${NC}         ${UUID}"
echo -e "${BOLD}║${NC}  ${CYAN}Public Key:${NC}   ${PUBLIC_KEY}"
echo -e "${BOLD}║${NC}  ${CYAN}Short ID:${NC}     ${SHORT_ID}"
echo -e "${BOLD}║${NC}  ${CYAN}Dest SNI:${NC}     ${DEST_SNI}"
echo -e "${BOLD}║${NC}  ${CYAN}Dest Port:${NC}    ${DEST_PORT}"
echo -e "${BOLD}║${NC}  ${CYAN}Local Port:${NC}   ${LOCAL_PORT}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}VLESS URL (для ручного добавления):${NC}"
echo -e "${CYAN}${VLESS_URL}${NC}"
echo ""

echo -e "${BOLD}═══ macOS (Hiddify / Streisand / NekoRay) ═══${NC}"
echo -e "1. Скачайте Hiddify: https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532"
echo -e "2. Нажмите + → импорт из URL → вставьте VLESS URL выше"
echo -e "3. Или импортируйте конфиг-файл: ${CLIENT_CONFIG_DIR}/client-config.json"
echo ""

echo -e "${BOLD}═══ Android / Samsung (Hiddify / NekoBox) ═══${NC}"
echo -e "1. Скачайте Hiddify: https://play.google.com/store/apps/details?id=io.hiddify.android"
echo -e "2. Нажмите + → импорт из clipboard"
echo -e "3. Скопируйте VLESS URL выше — он автоматически добавится"
echo -e "4. Или добавьте подписку: ${CLIENT_CONFIG_DIR}/hiddify-sub.txt"
echo ""

echo -e "${BOLD}═══ Управление ═══${NC}"
echo -e "Статус:   ${CYAN}systemctl status sing-box${NC}"
echo -e "Логи:     ${CYAN}journalctl -u sing-box -f${NC}"
echo -e "Перезапуск: ${CYAN}systemctl restart sing-box${NC}"
echo -e "Автообновление: ${CYAN}systemctl list-timers sing-box-update*${NC}"
echo ""

echo -e "${BOLD}═══ Добавление нового клиента ═══${NC}"
echo -e "1. Сгенерируйте новый UUID: ${CYAN}sing-box generate uuid${NC}"
echo -e "2. Добавьте его в /etc/sing-box/config.json → inbounds[0].users"
echo -e "3. Перезапустите: ${CYAN}systemctl restart sing-box${NC}"
echo ""

echo -e "${GREEN}${BOLD}VPN готов к работе! Настройка заняла ~2 минуты.${NC}"
