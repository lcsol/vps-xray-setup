#!/bin/bash
set -euo pipefail
umask 077
# =========================================================
# One-click deploy: Xray Reality + BBR
# Supported OS: Debian 11/12, Ubuntu 20.04/22.04
# =========================================================

# ======== 1. Variables ========
XRAY_PORT=$((RANDOM % 50000 + 10000))  # Reality listening port (TCP only)
XRAY_DOMAIN="www.icloud.com"           # Decoy SNI/server name; pick a stable, high-reputation TLS origin
SSH_ACCESS_MODE="any"                  # SSH access mode: any=allow all IPs, myip=allow only current public IP

# ======== 2. Require root ========
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root"
  exit 1
fi

# ======== 3. Update system ========
echo ">>> Updating system..."
apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y

# ======== 4. Install dependencies ========
echo ">>> Installing dependencies..."
apt install -y curl wget unzip qrencode socat net-tools iptables uuid-runtime jq ufw

# ======== 5. Configure firewall ========
echo ">>> Configuring firewall..."

# Delete any previous rules for XRAY_PORT (ignore errors)
ufw delete allow ${XRAY_PORT}/tcp || true
ufw delete limit ${XRAY_PORT}/tcp || true
ufw delete allow ${XRAY_PORT}/udp || true

# Allow current XRAY port (TCP only, with rate limiting)
ufw limit ${XRAY_PORT}/tcp

# SSH (default allow all)
ufw allow ssh

if [ "$SSH_ACCESS_MODE" = "myip" ]; then
    MYIP=$(curl -s https://api.ipify.org)
    if [ -n "$MYIP" ]; then
        echo "Restrict SSH to current IP: $MYIP"
        ufw delete allow ssh || true
        ufw allow from $MYIP to any port 22 proto tcp
    else
        echo "⚠️ Failed to get public IP, SSH restriction not applied"
    fi
fi

# Enable UFW (non-interactive)
ufw --force enable

echo "✅ Firewall configured"


# ======== 6. Enable BBR congestion control ========
echo "=== Checking kernel version ==="
kernel_version=$(uname -r | awk -F '.' '{print $1"."$2}')
major=$(echo "$kernel_version" | cut -d. -f1)
minor=$(echo "$kernel_version" | cut -d. -f2)

if (( major < 4 || (major == 4 && minor < 9) )); then
    echo "⚠️ Kernel < 4.9, BBR unsupported. Please upgrade and re-run."
    exit 1
fi

# Pick bbr2 if supported
if (( major > 5 || (major == 5 && minor >= 9) )); then
    cc_algo="bbr2"
else
    cc_algo="bbr"
fi

echo "=== Enabling $cc_algo ==="
cat <<EOF >/etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc_algo
EOF

sysctl --system > /dev/null

# Verify congestion control
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$current_cc" == "$cc_algo" ]]; then
  echo "✅ $cc_algo enabled"
else
  echo "⚠️ $cc_algo not active, current: $current_cc"
fi

# Additional TCP tuning for throughput/latency
cat <<EOF >/etc/sysctl.d/99-net-optim.conf
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.somaxconn=4096
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.ip_local_port_range=10000 65000
EOF

sysctl --system > /dev/null

# ======== 7. Download and install latest Xray ========
echo ">>> Installing latest Xray..."

# Select build by architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    XRAY_PKG="Xray-linux-64.zip";;
  aarch64|arm64)
    XRAY_PKG="Xray-linux-arm64-v8a.zip";;
  armv7l|armv7)
    XRAY_PKG="Xray-linux-arm32-v7a.zip";;
  *)
    echo "Unsupported architecture: $ARCH"; exit 1;;
esac

LATEST_XRAY=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f 4)
mkdir -p /usr/local/xray
wget -O /usr/local/xray/xray.zip https://github.com/XTLS/Xray-core/releases/download/${LATEST_XRAY}/${XRAY_PKG}
unzip -o /usr/local/xray/xray.zip -d /usr/local/xray
chmod +x /usr/local/xray/xray

# ======== 8. Generate Reality keypair ========
echo ">>> Generating UUID..."
CLIENT_ID=$(uuidgen)
echo ">>> Generating Reality keypair..."
REALITY_KEYS=$(/usr/local/xray/xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep Public | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# ======== 9. Write Xray config ========
echo ">>> Writing Xray config..."
cat > /usr/local/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_ID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "reusePort": true
        },
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${XRAY_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# Validate config before installing service
echo ">>> Validating Xray config..."
chmod 700 /usr/local/xray || true
chmod 600 /usr/local/xray/config.json || true
if ! /usr/local/xray/xray -test -config /usr/local/xray/config.json; then
  echo "❌ Xray config validation failed."
  exit 1
fi

# ======== 10. Configure systemd unit ========
echo ">>> Configuring Xray systemd service..."
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/xray/xray run -config /usr/local/xray/config.json
Restart=on-failure
RestartSec=3
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ======== 11. Show connection info ========
SERVER_IP=$(curl -s https://api.ipify.org)
#CLIENT_ID=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/xray/config.json)

VLESS_LINK="vless://${CLIENT_ID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality"

echo "=================================================="
echo "✅ Xray Reality installation complete"
echo "Server IP: ${SERVER_IP}"
echo "Port: ${XRAY_PORT}"
echo "Domain (SNI): ${XRAY_DOMAIN}"
echo "Public Key: ${PUBLIC_KEY}"
echo "Short ID: ${SHORT_ID}"
echo "UUID: ${CLIENT_ID}"
echo "VLESS link: ${VLESS_LINK}"
echo "=================================================="

# Generate QR code
echo "${VLESS_LINK}" | qrencode -t ANSIUTF8

# ======== 12. Optional: disable root password login (commented by default) ========
# echo ">>> Disabling root password login, key-based only..."
# sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# systemctl restart ssh

# ======== 13. Reboot to apply all settings ========
if [ -f /var/run/reboot-required ] || [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "$cc_algo" ]; then
  echo "Rebooting to apply kernel changes..."
  reboot
else
  echo "No reboot needed."
fi