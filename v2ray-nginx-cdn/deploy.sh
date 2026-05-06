#!/bin/bash

set -e

# ── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
          echo -e "${BLUE}  $1${NC}"; \
          echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
pause() { read -p "$(echo -e "${CYAN}$1${NC}")" _; }

# ── 检查运行目录 ─────────────────────────────────────────────────────────────
[ ! -f "./configs/nginx.tmpl" ] && \
    error "请在 v2ray-nginx-cdn 目录下运行此脚本！\n  cd v2ray-nginx-cdn && bash deploy.sh"

# ════════════════════════════════════════════════════════════════════════════
step "第一步：确认端口已开放"
# ════════════════════════════════════════════════════════════════════════════

echo -e "部署前请确保服务器防火墙 / 云控制台安全组已开放以下端口：\n"
echo -e "  ${CYAN}80${NC}    TCP  - HTTP（Let's Encrypt 证书申请必须）"
echo -e "  ${CYAN}443${NC}   TCP  - HTTPS（VMess+TLS，走 Cloudflare CDN）"
echo -e "  ${CYAN}Trojan+TLS 端口${NC}  TCP  - Trojan+TLS 直连（默认 1220，下一步可自定义）"
echo -e "  ${CYAN}VMess Raw 端口${NC}   TCP  - VMess Raw 直连（默认 1312，下一步可自定义）"
echo ""
echo -e "${YELLOW}若使用 ufw，在确定端口后执行：${NC}"
echo -e "  ufw allow 80 && ufw allow 443 && ufw allow <Trojan端口> && ufw allow <VMess Raw端口> && ufw enable"
echo ""
pause "已了解，按 Enter 继续..."

# ════════════════════════════════════════════════════════════════════════════
step "第二步：检查 Docker 环境"
# ════════════════════════════════════════════════════════════════════════════

command -v docker &>/dev/null || \
    error "Docker 未安装，请先运行：\n  curl -fsSL https://get.docker.com | sh"

docker compose version &>/dev/null || \
    error "Docker Compose 未安装，请先运行：\n  apt install docker-compose-plugin -y"

# 检查是否需要 sudo
if docker ps &>/dev/null; then
    DOCKER="docker"
    info "Docker 环境正常（无需 sudo）"
elif sudo docker ps &>/dev/null 2>&1; then
    DOCKER="sudo docker"
    warn "需要 sudo 执行 docker"
    warn "建议后续执行：sudo usermod -aG docker \$USER 并重新登录"
else
    error "无法执行 docker 命令，请检查 Docker 安装"
fi

# ════════════════════════════════════════════════════════════════════════════
step "第三步：收集配置信息"
# ════════════════════════════════════════════════════════════════════════════

read -p "主域名（走 Cloudflare CDN，例如 play.example.com）: " MAIN_DOMAIN
[ -z "$MAIN_DOMAIN" ] && error "主域名不能为空"

read -p "直连域名（不走 CDN，例如 nv.example.com）: " DIRECT_DOMAIN
[ -z "$DIRECT_DOMAIN" ] && error "直连域名不能为空"

read -p "邮箱（Let's Encrypt 证书到期通知）: " EMAIL
[ -z "$EMAIL" ] && error "邮箱不能为空"

# 自动检测服务器 IP
SERVER_IP=$(curl -s --max-time 5 https://ipv4.icanhazip.com/ \
    || curl -s --max-time 5 https://api.ipify.org \
    || echo "")
echo ""
if [ -n "$SERVER_IP" ]; then
    info "检测到服务器 IP: ${SERVER_IP}"
    read -p "IP 是否正确？直接回车确认，或输入正确 IP: " INPUT_IP
    [ -n "$INPUT_IP" ] && SERVER_IP="$INPUT_IP"
else
    read -p "无法自动检测 IP，请手动输入服务器公网 IP: " SERVER_IP
    [ -z "$SERVER_IP" ] && error "服务器 IP 不能为空"
fi

# 端口配置
echo ""
read -p "Trojan+TLS 对外端口（直接回车使用默认 1220）: " INPUT_TROJAN_PORT
TROJAN_PORT=${INPUT_TROJAN_PORT:-1220}
if ! [[ "$TROJAN_PORT" =~ ^[0-9]+$ ]] || [ "$TROJAN_PORT" -lt 1 ] || [ "$TROJAN_PORT" -gt 65535 ]; then
    error "端口号无效：${TROJAN_PORT}，请输入 1~65535 之间的数字"
fi

read -p "VMess Raw 对外端口（直接回车使用默认 1312）: " INPUT_VMESS_RAW_PORT
VMESS_RAW_PORT=${INPUT_VMESS_RAW_PORT:-1312}
if ! [[ "$VMESS_RAW_PORT" =~ ^[0-9]+$ ]] || [ "$VMESS_RAW_PORT" -lt 1 ] || [ "$VMESS_RAW_PORT" -gt 65535 ]; then
    error "端口号无效：${VMESS_RAW_PORT}，请输入 1~65535 之间的数字"
fi

[ "$TROJAN_PORT" = "$VMESS_RAW_PORT" ] && error "两个端口不能相同"

# 生成 UUID 和密码
VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
TROJAN_PASSWORD=$(cat /proc/sys/kernel/random/uuid)

echo ""
info "VMess UUID      : $VMESS_UUID"
info "Trojan 密码     : $TROJAN_PASSWORD"
info "Trojan+TLS 端口 : $TROJAN_PORT"
info "VMess Raw 端口  : $VMESS_RAW_PORT"
warn "凭证将在部署完成后保存到 ./credentials.txt"
echo ""
echo -e "${YELLOW}若使用 ufw，请现在执行：${NC}"
echo -e "  ufw allow 80 && ufw allow 443 && ufw allow ${TROJAN_PORT} && ufw allow ${VMESS_RAW_PORT} && ufw enable"
echo ""
pause "防火墙端口已确认开放，按 Enter 继续..."

# ════════════════════════════════════════════════════════════════════════════
step "第四步：配置 Cloudflare DNS"
# ════════════════════════════════════════════════════════════════════════════

echo -e "请在 Cloudflare DNS 面板完成以下操作：\n"
echo -e "  1. 添加两条 A 记录（${YELLOW}均设为灰色云 / 仅 DNS${NC}）："
echo -e "     类型  名称                     内容"
echo -e "     ────────────────────────────────────────────────"
echo -e "     A     ${CYAN}${MAIN_DOMAIN}${NC}     ${SERVER_IP}"
echo -e "     A     ${CYAN}${DIRECT_DOMAIN}${NC}   ${SERVER_IP}"
echo ""
echo -e "  2. ${YELLOW}SSL/TLS → 概述 → 加密模式 → 选择「完全 (Full)」${NC}"
echo ""
pause "以上操作已完成，按 Enter 继续..."

# 验证 DNS 解析
info "验证 DNS 解析中（最多等待 30s）..."
sleep 3

# 检查 DNS 查询工具是否可用
if command -v nslookup &>/dev/null; then
    DNS_LOOKUP() { nslookup "$1" 8.8.8.8 2>/dev/null | awk '/^Address:/{ip=$2} END{print ip}' | grep -v '#' | head -1; }
elif command -v dig &>/dev/null; then
    DNS_LOOKUP() { dig +short "$1" @8.8.8.8 2>/dev/null | tail -1; }
elif command -v host &>/dev/null; then
    DNS_LOOKUP() { host "$1" 8.8.8.8 2>/dev/null | awk '/has address/{print $4}' | head -1; }
else
    warn "未找到 DNS 查询工具（nslookup/dig/host），跳过 DNS 验证"
    DNS_LOOKUP() { echo ""; }
fi

for DOMAIN in "$MAIN_DOMAIN" "$DIRECT_DOMAIN"; do
    RESOLVED=$(DNS_LOOKUP "$DOMAIN")
    if [ "$RESOLVED" = "$SERVER_IP" ]; then
        info "${DOMAIN} → ${RESOLVED} ✓"
    else
        warn "${DOMAIN} 解析到「${RESOLVED}」，期望「${SERVER_IP}」"
        warn "DNS 可能尚未生效（传播通常需要 1~5 分钟）"
        read -p "是否仍然继续？[y/N]: " CONT
        [[ ! "$CONT" =~ ^[Yy]$ ]] && error "请等待 DNS 生效后重新运行脚本"
    fi
done

# ════════════════════════════════════════════════════════════════════════════
step "第五步：生成配置文件（第一阶段）"
# ════════════════════════════════════════════════════════════════════════════

mkdir -p v2ray/config acme html vhost

# ── docker-compose.yml ────────────────────────────────────────────────────
cat > docker-compose.yml << EOF
version: '3'
services:

  nginx:
    image: nginx:1.22
    container_name: nginx
    ports:
      - '80:80'
      - '443:443'
    restart: always
    volumes:
      - '/var/run/docker.sock:/tmp/docker.sock:ro'
      - './configs:/etc/nginx/conf.d'
      - './certs:/etc/nginx/certs'
      - './vhost:/etc/nginx/vhost.d'
      - './html:/usr/share/nginx/html'

  dockergen:
    image: jwilder/docker-gen:0.9
    container_name: dockergen
    restart: always
    command: >-
      -notify-sighup nginx -watch /etc/docker-gen/templates/nginx.tmpl
      /etc/nginx/conf.d/default.conf
    volumes:
      - '/var/run/docker.sock:/tmp/docker.sock:ro'
      - './configs/nginx.tmpl:/etc/docker-gen/templates/nginx.tmpl'
      - './configs:/etc/nginx/conf.d'
      - './certs:/etc/nginx/certs'
      - './vhost:/etc/nginx/vhost.d'
      - './html:/usr/share/nginx/html'

  nginx-proxy-acme:
    image: nginxproxy/acme-companion:2.2
    container_name: nginx-proxy-acme
    restart: always
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
      - './acme:/etc/acme.sh'
      - './configs:/etc/nginx/conf.d'
      - './certs:/etc/nginx/certs'
      - './vhost:/etc/nginx/vhost.d'
      - './html:/usr/share/nginx/html'
    environment:
      - DEFAULT_EMAIL=${EMAIL}
      - NGINX_PROXY_CONTAINER=nginx
      - NGINX_DOCKER_GEN_CONTAINER=dockergen

  v2ray:
    image: ghcr.io/v2fly/v2ray:v5.14.1-64-std
    container_name: v2ray
    restart: always
    environment:
      - v2ray.vmess.aead.forced=false
      - VIRTUAL_HOST=${MAIN_DOMAIN},${DIRECT_DOMAIN}
      - LETSENCRYPT_HOST=${MAIN_DOMAIN},${DIRECT_DOMAIN}
      - VIRTUAL_PORT=1310
    ports:
      - '${VMESS_RAW_PORT}:1312'
      - '${TROJAN_PORT}:1220'
    volumes:
      - './v2ray/config:/etc/v2ray/'
      - './certs:/etc/certs'
EOF

# ── v2ray config（第一阶段，不含 Trojan+TLS，证书尚未生成）────────────────
cat > v2ray/config/config.json << EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 1310,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess"}
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 1312,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {"network": "tcp"}
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "freedom"}],
  "dns": {"servers": ["8.8.8.8", "8.8.4.4", "localhost"]}
}
EOF

info "配置文件生成完成"

# ════════════════════════════════════════════════════════════════════════════
step "第六步：启动服务"
# ════════════════════════════════════════════════════════════════════════════

$DOCKER compose down 2>/dev/null || true
$DOCKER compose up -d
sleep 5
$DOCKER compose ps

# ════════════════════════════════════════════════════════════════════════════
step "第七步：等待 SSL 证书申请（最多 5 分钟）"
# ════════════════════════════════════════════════════════════════════════════

CERT_PATH="./certs/${MAIN_DOMAIN}/fullchain.pem"
MAX_WAIT=300
ELAPSED=0

while [ ! -f "$CERT_PATH" ]; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo ""
        error "证书申请超时！请排查后重新运行脚本。\n\
排查命令：\n\
  $DOCKER compose logs nginx-proxy-acme | tail -30\n\
常见原因：\n\
  - DNS 尚未生效（先用 nslookup 验证）\n\
  - 80 端口未开放\n\
  - Cloudflare 未设为灰色云"
    fi
    printf "\r  等待证书中... %ds / %ds" "$ELAPSED" "$MAX_WAIT"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
info "证书申请成功！"

# 验证 SAN 证书同时覆盖两个域名
SAN_INFO=$(openssl x509 -in "$CERT_PATH" -text -noout 2>/dev/null \
    | grep -A1 "Subject Alternative" | tail -1 | tr -d ' ')
info "证书覆盖域名: $SAN_INFO"

if [[ "$SAN_INFO" != *"$DIRECT_DOMAIN"* ]]; then
    warn "证书未包含 ${DIRECT_DOMAIN}，Trojan+TLS 客户端验证可能失败"
    warn "请确认 ${DIRECT_DOMAIN} 的 DNS A 记录已添加且为灰色云"
    pause "按 Enter 仍然继续，或 Ctrl+C 退出后排查..."
fi

# ════════════════════════════════════════════════════════════════════════════
step "第八步：更新配置（加入 Trojan+TLS）"
# ════════════════════════════════════════════════════════════════════════════

cat > v2ray/config/config.json << EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 1310,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess"}
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 1312,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0}]
      },
      "streamSettings": {"network": "tcp"}
    },
    {
      "listen": "0.0.0.0",
      "port": 1220,
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "${TROJAN_PASSWORD}", "level": 0}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/etc/certs/${MAIN_DOMAIN}/fullchain.pem",
            "keyFile": "/etc/certs/${MAIN_DOMAIN}/key.pem"
          }]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "freedom"}],
  "dns": {"servers": ["8.8.8.8", "8.8.4.4", "localhost"]}
}
EOF

$DOCKER compose restart v2ray
sleep 5

ERRORS=$($DOCKER compose logs v2ray 2>&1 | grep -iE "failed|panic" | tail -3)
if [ -n "$ERRORS" ]; then
    warn "V2Ray 日志存在异常："
    echo "$ERRORS"
else
    info "V2Ray 运行正常 ✓"
fi

# ════════════════════════════════════════════════════════════════════════════
step "第九步：开启 Cloudflare CDN"
# ════════════════════════════════════════════════════════════════════════════

echo -e "请在 Cloudflare DNS 面板修改：\n"
echo -e "  ${CYAN}${MAIN_DOMAIN}${NC}    →  改为 🟠 ${YELLOW}橙色云（开启代理）${NC}"
echo -e "  ${CYAN}${DIRECT_DOMAIN}${NC}  →  保持 🌫️  ${GREEN}灰色云（不变）${NC}"
echo ""
pause "修改完成后按 Enter 继续..."

# ════════════════════════════════════════════════════════════════════════════
step "第十步：设置定时重启（证书续签后自动生效）"
# ════════════════════════════════════════════════════════════════════════════

PROJECT_DIR=$(pwd)
TZ_INFO=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "UTC")

if [[ "$TZ_INFO" == *"Shanghai"* ]] || [[ "$TZ_INFO" == *"Asia/Shanghai"* ]]; then
    CRON_EXPR="0 3 * * *"
    CRON_DESC="每天北京时间 03:00"
else
    CRON_EXPR="0 19 * * *"
    CRON_DESC="每天 UTC 19:00 = 北京时间 03:00（服务器时区：${TZ_INFO}）"
fi

# cron 写入 root crontab 时以 root 身份运行，不需要 sudo
# cron 写入普通用户 crontab 时，该用户已在 docker 组，也不需要 sudo
# 所以 cron 命令里固定用 docker，不用 ${DOCKER}
CRON_CMD="${CRON_EXPR} cd ${PROJECT_DIR} && find ./certs/${MAIN_DOMAIN}/fullchain.pem -mtime -2 2>/dev/null | grep -q . && docker compose restart v2ray >> /var/log/v2ray-restart.log 2>&1 || true"

if [ "$DOCKER" = "sudo docker" ]; then
    (sudo crontab -l 2>/dev/null | grep -v "v2ray.*restart"; echo "$CRON_CMD") | sudo crontab -
    info "已写入 root crontab：${CRON_DESC}"
else
    (crontab -l 2>/dev/null | grep -v "v2ray.*restart"; echo "$CRON_CMD") | crontab -
    info "已写入 crontab：${CRON_DESC}"
fi

# ── 保存凭证 ──────────────────────────────────────────────────────────────
cat > credentials.txt << EOF
V2Ray 部署凭证 - $(date)
════════════════════════════════════
主域名      : ${MAIN_DOMAIN}
直连域名    : ${DIRECT_DOMAIN}
服务器 IP   : ${SERVER_IP}
VMess UUID  : ${VMESS_UUID}
Trojan 密码 : ${TROJAN_PASSWORD}
════════════════════════════════════
端口说明
  443   VMess+TLS（经 Cloudflare CDN）
  ${TROJAN_PORT}  Trojan+TLS（直连）
  ${VMESS_RAW_PORT}  VMess Raw（直连，备用）
EOF
chmod 600 credentials.txt
info "凭证已保存到 ./credentials.txt（请妥善保管，不要提交到 git）"

# ════════════════════════════════════════════════════════════════════════════
step "🎉 部署完成！Surge 客户端配置"
# ════════════════════════════════════════════════════════════════════════════

echo -e "${GREEN}"
cat << SURGE
┌──────────────────────────────────────────────────────────────┐
│              Surge 配置（复制以下全部内容）                   │
└──────────────────────────────────────────────────────────────┘

[General]
loglevel = notify
dns-server = 8.8.8.8, 8.8.4.4, 223.5.5.5
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, localhost, *.local
ipv6 = false

[Proxy]
VMess-Raw = vmess, ${SERVER_IP}, ${VMESS_RAW_PORT}, username=${VMESS_UUID}, vmess-aead=true, tls=false
VMess-TLS = vmess, ${MAIN_DOMAIN}, 443, username=${VMESS_UUID}, vmess-aead=true, tls=true, ws=true, ws-path=/vmess, skip-cert-verify=false
Trojan-TLS = trojan, ${DIRECT_DOMAIN}, ${TROJAN_PORT}, password=${TROJAN_PASSWORD}, tls=true, skip-cert-verify=false

[Proxy Group]
Proxy = select, VMess-TLS, Trojan-TLS, VMess-Raw

[Rule]
GEOIP, CN, DIRECT
FINAL, Proxy
SURGE
echo -e "${NC}"
