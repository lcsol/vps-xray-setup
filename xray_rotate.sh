#!/bin/bash
set -euo pipefail

# ========== 配置区 ==========
LOG_FILE="/var/log/xray_reality_rotate.log"

XRAY_BIN="/usr/local/xray/xray"
CONFIG_FILE="/usr/local/xray/config.json"
BACKUP_DIR="/etc/xray/backup"

FP_POOL=("chrome" "firefox" "safari" "edge" "ios" "android")
PORT_MIN=10000
PORT_MAX=60000

# 候选域名列表
CANDIDATES=(
  "www.apple.com"
  "www.icloud.com"
  "downloaddispatch.itunes.apple.com"
  "assets-xbxweb.xbox.com"
  "www.microsoft.com"
  "login.live.com"
  "d1.awsstatic.com"
  "mzstatic.com"
  "cdn-apple.com"
  "www.bing.com"
)

declare -A latency_map

# 测试函数：返回平均连接延迟(ms)，超时返回9999
test_latency() {
    local domain=$1
    local total=0
    local count=3
    for i in $(seq 1 $count); do
        local time=$(curl --connect-timeout 2 -o /dev/null -s -w "%{time_connect}" "https://$domain")
        if [[ -z "$time" ]]; then
            echo 9999
            return
        fi
        local ms=$(awk "BEGIN {printf \"%d\", $time * 1000}")
        total=$((total + ms))
    done
    echo $((total / count))
}

echo "Start testing TLS handshake latency..."

for d in "${CANDIDATES[@]}"; do
    m=$(test_latency "$d")
    latency_map["$d"]=$m
    if [[ "$m" -eq 9999 ]]; then
        echo "  $d : timeout"
    else
        echo "  $d : ${m} ms"
    fi
done

# 排序取前5
mapfile -t sorted < <(for d in "${!latency_map[@]}"; do echo "${latency_map[$d]} $d"; done | sort -n | head -n5)

# 构建 SNI_POOL
echo
echo "Top 5 fastest SNI candidates:"
SNI_POOL=()
for item in "${sorted[@]}"; do
    d=$(echo "$item" | cut -d' ' -f2-)
    echo "  $d (${latency_map[$d]} ms)"
    SNI_POOL+=("$d")
done

echo
echo "SNI_POOL=(\"${SNI_POOL[@]}\")"

# ========== 公共方法 ==========
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
require_bin() { command -v "$1" >/dev/null 2>&1 || { log "缺少命令 $1"; exit 1; } }
rand_from_array() { local -n arr=$1; echo "${arr[$RANDOM % ${#arr[@]}]}"; }

# ========== 前置检查 ==========
require_bin jq
require_bin curl
require_bin ufw
require_bin awk
require_bin openssl
require_bin uuidgen
require_bin qrencode

[[ -x "$XRAY_BIN" ]] || { log "未找到 Xray：$XRAY_BIN"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { log "未找到配置文件：$CONFIG_FILE"; exit 1; }
mkdir -p "$BACKUP_DIR"

# ========== 读取旧配置 ==========
OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
OLD_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")

OLD_SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
OLD_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
OLD_FP=$(jq -r '.inbounds[0].streamSettings.realitySettings.fingerprint' "$CONFIG_FILE")
OLD_FLOW=$(jq -r '.inbounds[0].settings.clients[0].flow' "$CONFIG_FILE")

PUBLIC_KEY=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | awk '/Public key/ {print $3}')

# ========== 生成新参数 ==========
while :; do NEW_SHORT_ID=$(openssl rand -hex 8); [[ "$NEW_SHORT_ID" != "$OLD_SID" ]] && break; done
while :; do NEW_UUID=$(uuidgen); [[ "$NEW_UUID" != "$OLD_UUID" ]] && break; done
while :; do NEW_FP=$(rand_from_array FP_POOL); [[ "$NEW_FP" != "$OLD_FP" ]] && break; done
while :; do NEW_SNI=$(rand_from_array SNI_POOL); [[ "$NEW_SNI" != "$OLD_SNI" ]] && break; done
while :; do NEW_PORT=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1); [[ "$NEW_PORT" -ne "$OLD_PORT" && "$NEW_PORT" -ne 22 ]] && break; done

log "更新计划: PORT $OLD_PORT->$NEW_PORT, UUID->$NEW_UUID, ShortID->$NEW_SHORT_ID, FP->$NEW_FP, SNI->$NEW_SNI"

# ========== 备份 ==========
BACKUP_FILE="$BACKUP_DIR/config_$(date '+%F_%H-%M-%S').json"
cp "$CONFIG_FILE" "$BACKUP_FILE"
log "已备份到 $BACKUP_FILE"

# ========== 修改配置 ==========
TMP_FILE=$(mktemp)
jq \
  --argjson port "$NEW_PORT" \
  --arg uuid "$NEW_UUID" \
  --arg sid "$NEW_SHORT_ID" \
  --arg fp "$NEW_FP" \
  --arg sni "$NEW_SNI" \
  '
  .inbounds[0].port = $port
  | .inbounds[0].settings.clients[0].id = $uuid
  | .inbounds[0].streamSettings.realitySettings.shortIds = [$sid]
  | .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
  | .inbounds[0].streamSettings.realitySettings.fingerprint = $fp
  ' "$CONFIG_FILE" > "$TMP_FILE"
mv "$TMP_FILE" "$CONFIG_FILE"

# ========== 防火墙 ==========
ufw delete allow "$OLD_PORT"/tcp >/dev/null 2>&1 || true
ufw delete allow "$OLD_PORT"/udp >/dev/null 2>&1 || true
ufw allow "$NEW_PORT"/tcp >/dev/null 2>&1
ufw allow "$NEW_PORT"/udp >/dev/null 2>&1
ufw reload
log "防火墙已更新: 移除 $OLD_PORT, 开放 $NEW_PORT"

# ========== 测试配置并重启 Xray ==========
if "$XRAY_BIN" -test -config "$CONFIG_FILE"; then
  if systemctl restart xray; then
    log "Xray 已重启成功"
  else
    log "⚠️ Xray 重启失败"
    exit 1
  fi
else
  log "配置测试失败，开始回滚..."
  cp "$BACKUP_FILE" "$CONFIG_FILE"
  ufw delete allow "$NEW_PORT"/tcp >/dev/null 2>&1 || true
  ufw delete allow "$NEW_PORT"/udp >/dev/null 2>&1 || true
  ufw allow "$OLD_PORT"/tcp >/dev/null 2>&1
  ufw allow "$OLD_PORT"/udp >/dev/null 2>&1
  systemctl restart xray
  log "已回滚到备份: $BACKUP_FILE"
  exit 1
fi

# ========== 生成 Reality 链接 ==========
SERVER_IP=$(curl -s ifconfig.me)
LINK="vless://${NEW_UUID}@${SERVER_IP}:${NEW_PORT}?encryption=none&security=reality&pbk=${PUBLIC_KEY}&sid=${NEW_SHORT_ID}&fp=${NEW_FP}&sni=${NEW_SNI}&type=tcp&flow=${OLD_FLOW}#Reality"

log "新 Reality 链接: $LINK"

# ========== 输出二维码 ==========
echo "=================================================="
echo "$LINK" | qrencode -t ANSIUTF8
sleep 1

