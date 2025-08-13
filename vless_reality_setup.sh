#!/bin/bash
# =========================================================
# 一键部署 Xray Reality + BBR 加速
# 适用系统: Debian 11/12, Ubuntu 20.04/22.04
# 
# =========================================================

# ======== 1. 配置变量 ========
XRAY_PORT=$((RANDOM % 50000 + 10000))  # Reality 端口
XRAY_DOMAIN="www.icloud.com"           # 用于伪装的域名（建议选高可用CDN站）
SSH_ACCESS_MODE="any"                  # SSH 访问模式: any=允许全部IP, myip=只允许当前公网IP

# ======== 2. 检查 root 权限 ========
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

# ======== 3. 系统更新 ========
echo ">>> 更新系统..."
apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y

# ======== 4. 安装依赖 ========
echo ">>> 安装依赖..."
apt install -y curl wget unzip qrencode socat net-tools iptables uuid-runtime

# ======== 5. 配置防火墙 ========
echo ">>> 配置防火墙..."
apt install -y ufw

# 删除旧的 XRAY 端口规则（忽略错误）
ufw delete allow ${XRAY_PORT}/tcp || true
ufw delete allow ${XRAY_PORT}/udp || true

# 放行当前 XRAY 端口
ufw allow ${XRAY_PORT}/tcp
ufw allow ${XRAY_PORT}/udp

# SSH 默认允许全部
ufw allow ssh

if [ "$SSH_ACCESS_MODE" = "myip" ]; then
    MYIP=$(curl -s https://api.ipify.org)
    if [ -n "$MYIP" ]; then
        echo "仅允许当前IP访问SSH: $MYIP"
        ufw delete allow ssh || true
        ufw allow from $MYIP to any port 22 proto tcp
    else
        echo "⚠️ 获取公网 IP 失败，SSH 限制未生效"
    fi
fi

# 启用 UFW（无需交互）
ufw --force enable

echo "✅ 防火墙配置完成"


# ======== 6. 启用 BBR 加速 ========
echo "=== 检查内核版本 ==="
kernel_version=$(uname -r | awk -F '.' '{print $1"."$2}')
major=$(echo "$kernel_version" | cut -d. -f1)
minor=$(echo "$kernel_version" | cut -d. -f2)

if (( major < 4 || (major == 4 && minor < 9) )); then
    echo "⚠️ 内核版本低于 4.9，BBR 不受支持，请升级内核后再试。"
    exit 1
fi

# 判断是否支持 bbr2
if (( major > 5 || (major == 5 && minor >= 9) )); then
    cc_algo="bbr2"
else
    cc_algo="bbr"
fi

echo "=== 启用 $cc_algo ==="
cat <<EOF >/etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc_algo
EOF

sysctl --system > /dev/null

# 检查当前拥塞控制算法
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$current_cc" == "$cc_algo" ]]; then
  echo "✅ $cc_algo 加速已启用"
else
  echo "⚠️ $cc_algo 未生效，当前算法: $current_cc"
fi

# ======== 7. 下载并安装最新稳定版 Xray ========
echo ">>> 安装 Xray 最新稳定版..."
LATEST_XRAY=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f 4)
mkdir -p /usr/local/xray
wget -O /usr/local/xray/xray.zip https://github.com/XTLS/Xray-core/releases/download/${LATEST_XRAY}/Xray-linux-64.zip
unzip -o /usr/local/xray/xray.zip -d /usr/local/xray
chmod +x /usr/local/xray/xray

# ======== 8. 生成 Reality 密钥对 ========
echo ">>> 生成 UUID ..."
CLIENT_ID=$(uuidgen)
echo ">>> 生成 Reality 密钥对..."
REALITY_KEYS=$(/usr/local/xray/xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep Private | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep Public | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# ======== 9. 写入 Xray 配置 ========
echo ">>> 写入 Xray 配置..."
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

# ======== 10. 配置 Systemd 服务 ========
echo ">>> 配置 Xray systemd 服务..."
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/xray/xray -config /usr/local/xray/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ======== 11. 显示连接信息 ========
SERVER_IP=$(curl -s https://api.ipify.org)
#CLIENT_ID=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/xray/config.json)

VLESS_LINK="vless://${CLIENT_ID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality"

echo "=================================================="
echo "✅ Xray Reality 已安装完成"
echo "服务器IP: ${SERVER_IP}"
echo "端口: ${XRAY_PORT}"
echo "域名: ${XRAY_DOMAIN}"
echo "Public Key: ${PUBLIC_KEY}"
echo "Short ID: ${SHORT_ID}"
echo "UUID: ${CLIENT_ID}"
echo "VLESS 链接: ${VLESS_LINK}"
echo "=================================================="

# 生成二维码
echo "${VLESS_LINK}" | qrencode -t ANSIUTF8

# ======== 12. 可选：禁用 root 密码登录（默认注释） ========
# echo ">>> 禁用 root 密码登录，仅允许密钥登录..."
# sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# systemctl restart ssh

# ======== 13. 重启 VPS（确保加速与防火墙规则生效） ========
echo ">>> 重启服务器以应用所有设置..."
reboot
