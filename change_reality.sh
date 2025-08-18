#!/bin/bash
# ========================================
# Xray Reality rotation script
# - Periodically rotate UUID / port / shortId / SNI
# - Auto-update firewall
# - Rollback on failure
# - Optional: send the new link via SMTP/Telegram
# ========================================

set -euo pipefail
LOG_FILE="/var/log/xray_reality_rotate.log"

# ========== Configuration ==========
XRAY_BIN="/usr/local/xray/xray"
CONFIG_FILE="/usr/local/xray/config.json"
BACKUP_DIR="/etc/xray/backup"

# SNI candidates (stable, high-reputation TLS origins reachable from mainland China)
SNI_POOL=(
  "www.icloud.com"
  "www.microsoft.com"
  "www.bing.com"
  "www.apple.com"
  "cdn.cloudflare.com"
  "fonts.gstatic.com"
  "static.cloudflareinsights.com"
)

# Client TLS fingerprints (used by clients only; server link param)
FP_POOL=("chrome" "firefox" "safari" "edge" "ios" "android")

# Port range (avoid commonly scanned well-known ports)
PORT_MIN=10000
PORT_MAX=60000

# Notify via SMTP (example; replace with your provider or Telegram API)
SMTP_ENABLED=0
SMTP_SERVER="smtp.example.com"
SMTP_PORT=587
SMTP_USER="noreply@example.com"
SMTP_PASS="yourpassword"
EMAIL_TO="yourmail@example.com"

# ========== Helpers ==========
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1. Please install it first."; exit 1;
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

# ========== Pre-flight checks ==========
require_bin jq
require_bin curl
require_bin ufw
require_bin openssl
require_bin uuidgen

[[ -x "$XRAY_BIN" ]] || { log "Xray binary not found: $XRAY_BIN"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { log "Xray config not found: $CONFIG_FILE"; exit 1; }
mkdir -p "$BACKUP_DIR"

# ========== Main ==========
log "Reading current config..."
OLD_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
OLD_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG_FILE")
OLD_SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")

# Generate new parameters
NEW_UUID=$(uuidgen)
NEW_SHORT_ID=$(openssl rand -hex 8)
NEW_FP=$(rand_from_array FP_POOL)
NEW_SNI=$(rand_from_array SNI_POOL)

# New port (random; avoid old port and SSH 22)
while :; do
  NEW_PORT=$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)
  [[ "$NEW_PORT" -ne "$OLD_PORT" && "$NEW_PORT" -ne 22 ]] && break
done

log "Planned update: PORT $OLD_PORT -> $NEW_PORT, UUID -> $NEW_UUID, shortId -> $NEW_SHORT_ID, fp -> $NEW_FP, SNI $OLD_SNI -> $NEW_SNI"

# Backup old config
BACKUP_FILE="$BACKUP_DIR/config_$(date '+%F_%H-%M-%S').json"
cp "$CONFIG_FILE" "$BACKUP_FILE"
log "Backed up to: $BACKUP_FILE"

# Modify config (write to temp file first)
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

# Test the new config before applying
if "$XRAY_BIN" -test -config "$TMP_FILE" >/dev/null 2>&1; then
  cp "$TMP_FILE" "$CONFIG_FILE"
  log "Config validation OK"
else
  log "Config validation failed; keeping original config"
  rm -f "$TMP_FILE"
  exit 1
fi

# Update firewall (TCP only, rate-limit new port)
ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
ufw delete limit "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
ufw limit "${NEW_PORT}/tcp" >/dev/null 2>&1
log "Firewall updated: removed ${OLD_PORT}/tcp, limited ${NEW_PORT}/tcp"

# 重启服务
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  log "Xray restart OK"
else
  log "Xray restart failed; rolling back..."
  cp "$BACKUP_FILE" "$CONFIG_FILE"
  ufw delete limit "${NEW_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
  systemctl restart xray || true
  log "Rolled back to: $BACKUP_FILE"
  exit 1
fi

# Derive public key from private key
PBK=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" | awk '/Public key/ {print $3}')

# Get public IP (multi-source fallback)
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

# Compose new Reality link
LINK="vless://${NEW_UUID}@${SERVER_IP}:${NEW_PORT}?encryption=none&security=reality&pbk=${PBK}&sid=${NEW_SHORT_ID}&fp=${NEW_FP}&sni=${NEW_SNI}&type=tcp&flow=xtls-rprx-vision#Reality"

# Notify
send_email "Xray config updated" "New link: $LINK"

log "New Reality link: $LINK"
