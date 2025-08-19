#!/bin/bash
# =========================================================
# 一键部署 Xray Reality + BBR/BBR2 + 网络优化（含安全与隐蔽性增强）
# 适用系统: Debian 11/12, Ubuntu 20.04/22.04
# =========================================================

# ======== 0. DNS 优化 ========
echo ">>> 配置 DNS ..."
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1       # Cloudflare
nameserver 8.8.8.8       # Google
nameserver 9.9.9.9       # Quad9
EOF

# 锁定 resolv.conf 防止被 DHCP 覆盖（可选，解锁命令: chattr -i /etc/resolv.conf）
chattr +i /etc/resolv.conf || true

# 如果 systemd-resolved 存在，则配置并重启
if [ -f /etc/systemd/resolved.conf ]; then
    sed -i '/^#DNS=/c\DNS=1.1.1.1 8.8.8.8 9.9.9.9' /etc/systemd/resolved.conf
    sed -i '/^#FallbackDNS=/c\FallbackDNS=1.0.0.1 8.8.4.4 149.112.112.112' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
fi

systemd-resolve --flush-caches || true
echo "✅ DNS 优化完成"

# ======== 1. 配置变量 ========
XRAY_PORT=$((RANDOM % 50000 + 10000))   # Reality 端口
SSH_ACCESS_MODE="any"                   # SSH 访问模式: any=全部IP, myip=仅当前公网IP

# SNI 候选池（直连可访问的 CDN / 大厂域名）
SNI_POOL=("www.icloud.com" "www.apple.com" "www.microsoft.com" "www.bing.com" "www.speedtest.net")
# TLS 指纹池
FP_POOL=("chrome" "firefox" "safari" "ios" "android")

rand_from_array() {
  local -n arr=$1
  echo "${arr[$RANDOM % ${#arr[@]}]}"
}
XRAY_DOMAIN=$(rand_from_array SNI_POOL)
XRAY_FP=$(rand_from_array FP_POOL)

# ======== 2. 检查 root 权限 ========
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本"
  exit 1
fi

# ======== 3. 系统更新 & 依赖安装 ========
echo ">>> 更新系统 & 安装依赖..."
apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" upgrade -y
apt install -y curl wget unzip qrencode socat net-tools iptables uuid-runtime ufw

# ======== 4. 配置防火墙 ========
echo ">>> 配置防火墙..."
# 删除旧规则（忽略错误）
ufw delete allow ${XRAY_PORT} || true

# 放行当前 XRAY 端口（TCP+UDP 一起）
ufw allow ${XRAY_PORT}

ufw allow ssh
if [ "$SSH_ACCESS_MODE" = "myip" ]; then
    MYIP=$(curl -s https://api.ipify.org)
    if [ -n "$MYIP" ]; then
        echo "仅允许 $MYIP 访问 SSH"
        ufw delete allow ssh || true
        ufw allow from $MYIP to any port 22 proto tcp
    fi
fi
ufw --force enable

# ======== 5. 启用 BBR/BBR2 ========
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

echo "=== 尝试启用 $cc_algo ==="
cat <<EOF >/etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc_algo
EOF

sysctl --system > /dev/null

# 检查当前拥塞控制算法
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

if [[ "$current_cc" == "$cc_algo" ]]; then
  echo "✅ $cc_algo 加速已启用"
else
  echo "⚠️ $cc_algo 未生效，当前算法: $current_cc"
  echo "👉 建议执行 reboot 后再检查：sysctl net.ipv4.tcp_congestion_control"
fi

# ======== 5.1 网络优化 ========
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
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
EOF
sysctl --system >/dev/null

# ======== 6. 安装 Xray ========
echo ">>> 安装 Xray..."
LATEST_XRAY=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d '"' -f 4)
mkdir -p /usr/local/xray
wget -O /usr/local/xray/xray.zip https://github.com/XTLS/Xray-core/releases/download/${LATEST_XRAY}/Xray-linux-64.zip
unzip -o /usr/local/xray/xray.zip -d /usr/local/xray
chmod 755 /usr/local/xray
chmod +x /usr/local/xray/xray

# ======== 7. 生成 Reality 密钥对 ========
CLIENT_ID=$(uuidgen)
REALITY_KEYS=$(/usr/local/xray/xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep Private | awk '{print $2}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep Password | awk '{print $2}')
SHORT_ID=$(openssl rand -hex 8)

# ======== 8. 写入配置 ========
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
          "dest": "${XRAY_DOMAIN}:443",
          "serverNames": ["${XRAY_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

chmod 600 /usr/local/xray/config.json
/usr/local/xray/xray -test -config /usr/local/xray/config.json || { echo "配置校验失败"; exit 1; }

# ======== 9. 配置 systemd ========
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/xray/xray -config /usr/local/xray/config.json
Restart=on-failure
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/usr/local/xray

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now xray

echo "Restart Xray"
systemctl restart xray
ufw reload

# ======== 10. 输出连接信息 ========
SERVER_IP=$(curl -s https://api.ipify.org)
VLESS_LINK="vless://${CLIENT_ID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_DOMAIN}&fp=${XRAY_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-Reality"

echo "=================================================="
echo "Server Parameters: "
echo "服务器IP: ${SERVER_IP}"
echo "端口: ${XRAY_PORT}"
echo "域名(SNI): ${XRAY_DOMAIN}"
echo "指纹(FP): ${XRAY_FP}"
echo "Public Key: ${PUBLIC_KEY}"
echo "Short ID: ${SHORT_ID}"
echo "UUID: ${CLIENT_ID}"
echo "VLESS 链接: ${VLESS_LINK}"
echo "=================================================="
echo "${VLESS_LINK}" | qrencode -t ANSIUTF8

sleep 1

echo "✅ Xray Reality 部署完成"

