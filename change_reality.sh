#!/bin/bash
set -e

CONFIG_FILE="/usr/local/xray/config.json"
XRAY_PATH="/usr/local/xray/xray"

echo ">>> 检查依赖..."
apt install -y uuid-runtime qrencode jq curl ufw > /dev/null

echo ">>> 读取当前配置..."
OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
SERVER_NAME=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")
SERVER_IP=$(curl -s ifconfig.me)
PUBLIC_KEY=$($XRAY_PATH x25519 -i "$PRIVATE_KEY" | grep 'Public key' | awk '{print $3}')

echo ">>> 生成新的 UUID 和端口..."
NEW_UUID=$(uuidgen)
NEW_PORT=$((RANDOM % 50000 + 10000))

echo ">>> 更新配置..."
jq --arg uuid "$NEW_UUID" \
   --argjson port "$NEW_PORT" \
   '.inbounds[0].settings.clients[0].id = $uuid |
    .inbounds[0].port = $port' \
   "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo ">>> 更新防火墙..."
ufw delete allow ${OLD_PORT} >/dev/null 2>&1 || true
ufw allow ${NEW_PORT}/tcp
ufw allow ${NEW_PORT}/udp

echo ">>> 重启 Xray..."
systemctl restart xray

VLESS_URL="vless://${NEW_UUID}@${SERVER_IP}:${NEW_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality"

echo
echo "✅ 新链接："
echo "$VLESS_URL"
echo "$VLESS_URL" | qrencode -t ANSIUTF8
