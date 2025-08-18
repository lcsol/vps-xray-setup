#!/bin/bash
# ========================================
# Xray Reality 防封脚本
# - 定期更新 UUID / 端口 / shortId / TLS 指纹 / SNI
# - 自动更新防火墙
# - 配置失败自动回滚
# - 可选推送新链接到邮箱/Telegram
# ========================================

set -euo pipefail
LOG_FILE="/var/log/xray_reality_rotate.log"

# ========== 配置区 ==========
XRAY_BIN="/usr/local/xray/xray"
CONFIG_FILE="/usr/local/xray/config.json"
BACKUP_DIR="/etc/xray/backup"

# SNI 候选池（替换为直连可访问的站点）
SNI_POOL=(
  "www.icloud.com"
  "www.speedtest.net"
  "www.microsoft.com"
  "www.apple.com"
  "www.bing.com"
)

# TLS 指纹池（uTLS 支持的常见指纹）
FP_POOL=("chrome" "firefox" "safari" "edge" "ios" "android")

# 端口范围（尽量避开常见端口）
PORT_MIN=10000
PORT_MAX=60000

# 推送设置（SMTP 示例，可替换为 Mailgun/Telegram API）
SMTP_ENABLED=0
SMTP_SERVER="smtp.example.com"
SMTP_PORT=587
SMTP_USER="noreply@example.com"
SMTP_PASS="yourpassword"
EMAIL_TO="yourmail@example.com"

# ========== 公共方法 ==========
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "缺少必要命令：$1，请先安装"; exit 1;
  }
}

rand_from_array() {
  local -n arr=$1
  echo "${arr[$RANDOM % ${#arr[@]}]}"
}

send_email() {
  local subject="$1"
  local body="$2"
  if [[ "$SMTP_ENABLED" -eq 1 ]]; then
    {
      echo "Subject: $subject"
      echo "To: $EMAIL_TO"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      echo "$body"
    } | curl -s --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
        --ssl-reqd \
        --mail-from "$SMTP_USER" \
        --mail-rcpt "$EMAIL_TO" \
        --user "$SMTP_USER:$SMTP_PASS" \
        -T -
  fi
}

# ========== 前置检查 ==========
require_bin jq
require_bin curl
require_bin ufw
require_bin openssl
require_bin uuidgen

[[ -x "$XRAY_BIN" ]] || { log "未找到 Xray 可执行文件：$XRAY_BIN"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { log "未找到 Xray 配置：$CONFIG_FILE"; exit 1; }
mkdir -p "$BACKUP_DIR"

# ========== 主流程 ==========
log "读取当前配置..."
OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
OLD_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
OLD_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")

# 生成新配置参数
NEW_UUID=$(uuidgen)
NEW_SHORT_ID=$(openssl rand -hex 8)
NEW_FP=$(rand_from_array FP_POOL)
NEW_SNI=$(rand_from_array SNI_POOL)

# 新端口（随机生成，避开旧端口和22）
while :; do
  NEW_PORT=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)
  [[ "$NEW_PORT" -ne "$OLD_PORT" && "$NEW_PORT" -ne 22 ]] && break
done

log "计划更新: PORT $OLD_PORT -> $NEW_PORT, UUID -> $NEW_UUID, shortId -> $NEW_SHORT_ID, fp -> $NEW_FP, SNI -> $NEW_SNI"

# 备份旧配置
BACKUP_FILE="$BACKUP_DIR/config_$(date '+%F_%H-%M-%S').json"
cp "$CONFIG_FILE" "$BACKUP_FILE"
log "已备份到：$BACKUP_FILE"

# 修改配置（先写入临时文件）
TMP_FILE=$(mktemp)
jq \
  --argjson port "$NEW_PORT" \
  --arg uuid "$NEW_UUID" \
  --arg sid "$NEW_SHORT_ID" \
  --arg sni "$NEW_SNI" \
  '
  .inbounds[0].port = $port
  | .inbounds[0].settings.clients[0].id = $uuid
  | .inbounds[0].streamSettings.realitySettings.shortIds = [$sid]
  | .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
  | .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443")
  ' "$CONFIG_FILE" > "$TMP_FILE"

# 测试新配置，不直接覆盖
if "$XRAY_BIN" -test -config "$TMP_FILE" >/dev/null 2>&1; then
  cp "$TMP_FILE" "$CONFIG_FILE"
  log "配置语法校验通过"
else
  log "配置测试失败，保持原配置不变"
  rm -f "$TMP_FILE"
  exit 1
fi

# 更新防火墙（仅 TCP）
ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1
log "防火墙已更新：移除 ${OLD_PORT}/tcp，开放 ${NEW_PORT}/tcp"

# 重启服务
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  log "Xray 已重启成功"
else
  log "Xray 重启失败，开始回滚..."
  cp "$BACKUP_FILE" "$CONFIG_FILE"
  ufw delete allow "${NEW_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
  systemctl restart xray || true
  log "已回滚到备份：$BACKUP_FILE"
  exit 1
fi

# 计算公钥（从私钥推导）
PBK=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | awk '/Public key/ {print $3}')

# 获取服务器 IP（多源回退）
get_public_ip() {
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://ip.sb"; do
    ip=$(curl -s "$url") || true
    if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
  done
  return 1
}
SERVER_IP=$(get_public_ip || echo "127.0.0.1")

# 生成新的 Reality 链接
LINK="vless://${NEW_UUID}@${SERVER_IP}:${NEW_PORT}?encryption=none&security=reality&pbk=${PBK}&sid=${NEW_SHORT_ID}&fp=${NEW_FP}&sni=${NEW_SNI}&type=tcp&flow=xtls-rprx-vision#Reality"

# 推送通知
send_email "Xray 配置已更新" "新链接：$LINK"

log "新 Reality 链接：$LINK"
