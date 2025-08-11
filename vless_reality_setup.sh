#!/bin/bash
# 一键安装 Xray (VLESS+Reality) + 防火墙 + BBR + 自动更新脚本
# 适用于 Debian 10+/Ubuntu 20+
# 运行前请以 root 用户执行

set -e

# === 配置区 ===
PORT=443
DOMAIN="www.cloudflare.com"
UUID=$(uuidgen)
SHORT_ID=$(openssl rand -hex 8)
XRAY_BIN="/usr/local/xray/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
UPDATE_LOG="/var/log/xray-update.log"
# ===========

function install_xray() {
  echo "==> 获取最新 Xray 版本号..."
  LATEST_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')
  echo "最新版本: $LATEST_VER"

  echo "==> 下载并安装 Xray..."
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v${LATEST_VER}/Xray-linux-64.zip
  mkdir -p /usr/local/xray
  unzip -o /tmp/xray.zip -d /usr/local/xray
  chmod +x ${XRAY_BIN}
  rm -f /tmp/xray.zip
}

function write_config() {
  echo "==> 生成 Xray 配置..."
  mkdir -p ${CONFIG_DIR}
  cat > ${CONFIG_FILE} <<EOF
{
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "",
            "email": "user@example.com"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${DOMAIN}"],
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
}

function create_service() {
  echo "==> 创建 systemd 服务..."
  cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray
}

function enable_firewall() {
  echo "==> 配置防火墙..."
  apt install -y ufw
  ufw allow ${PORT}/tcp
  ufw allow ${PORT}/udp
  ufw reload
}

function enable_bbr() {
  echo "==> 启用 BBR 加速..."
  modprobe tcp_bbr
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  sysctl -w net.core.default_qdisc=fq
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  if lsmod | grep -q bbr; then
    echo "BBR 加速已开启"
  else
    echo "BBR 加速开启失败"
  fi
}

function setup_auto_update() {
  echo "==> 设置 Xray 自动更新任务 (每周日凌晨1点)..."
  cat > /usr/local/bin/xray-update.sh <<'EOL'
#!/bin/bash
LOGFILE="/var/log/xray-update.log"
set -e
echo "$(date): 检查 Xray 更新..." >> $LOGFILE
CURRENT_VER=$(/usr/local/xray/xray -version | head -1 | awk '{print $2}')
LATEST_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')

if [ "$LATEST_VER" != "$CURRENT_VER" ]; then
  echo "$(date): 新版本 $LATEST_VER 可用，开始更新..." >> $LOGFILE
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v${LATEST_VER}/Xray-linux-64.zip
  unzip -o /tmp/xray.zip -d /usr/local/xray
  chmod +x /usr/local/xray/xray
  rm -f /tmp/xray.zip
  systemctl restart xray
  echo "$(date): Xray 更新成功，重启服务。" >> $LOGFILE
else
  echo "$(date): 已是最新版本 $CURRENT_VER，无需更新。" >> $LOGFILE
fi
EOL
  chmod +x /usr/local/bin/xray-update.sh

  (crontab -l 2>/dev/null; echo "0 1 * * 0 /usr/local/bin/xray-update.sh") | crontab -
  echo "自动更新任务已添加，每周日凌晨1点执行"
}

echo "==> 生成 Reality 私钥/公钥..."
PRIVATE_KEY=$(${XRAY_BIN} x25519 | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(${XRAY_BIN} x25519 --key ${PRIVATE_KEY} | grep "Public" | awk '{print $3}')

install_xray
write_config
create_service
enable_firewall
enable_bbr
setup_auto_update

systemctl restart xray

echo
echo "===== 安装完成 ====="
echo "地址: $(curl -s ipv4.icanhazip.com)"
echo "端口: ${PORT}"
echo "UUID: ${UUID}"
echo "Public Key: ${PUBLIC_KEY}"
echo "Short ID: ${SHORT_ID}"
echo "SNI: ${DOMAIN}"
echo "====================="
echo "Shadowrocket 配置请用 VLESS + Reality，流控 xtls-rprx-vision"
