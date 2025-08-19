#!/bin/bash
# =========================================
# 一键部署 Hysteria2 (TCP+TLS 自签证书版，无需域名)
# 自动检测端口并选择未使用端口
# =========================================

set -e

# ======== 1. 配置变量 ========
HY_PORT=443                         # 初始端口
HY_CONF_DIR="/etc/hysteria"
HY_BIN="/usr/local/bin/hysteria"
HY_PASS=$(openssl rand -hex 16)    # 自动生成强密码
HY_CERT="$HY_CONF_DIR/fullchain.pem"
HY_KEY="$HY_CONF_DIR/privkey.pem"

# ======== 2. 检查 root 权限 ========
if [ "$EUID" -ne 0 ]; then
    echo "请用 root 运行此脚本"
    exit 1
fi

# ======== 3. 自动检测端口是否被占用 ========
echo ">>> 检查端口冲突..."
while ss -tuln | grep -q ":$HY_PORT "; do
    echo "端口 $HY_PORT 已被占用，尝试下一个..."
    HY_PORT=$((HY_PORT + 1))
done
echo "✅ 使用端口: $HY_PORT"

# ======== 4. 安装依赖 ========
echo ">>> 安装依赖..."
apt update
apt install -y curl qrencode openssl

# ======== 5. 生成自签证书 ========
echo ">>> 生成自签证书..."
mkdir -p "$HY_CONF_DIR"
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=Hysteria2" \
    -keyout "$HY_KEY" -out "$HY_CERT"

# ======== 6. 下载 Hysteria2 ========
if [ ! -f "$HY_BIN" ]; then
    echo ">>> 下载 Hysteria2..."
    curl -L -o "$HY_BIN" https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
    chmod +x "$HY_BIN"
fi

# ======== 7. 生成 Hysteria2 服务端配置 ========
cat > "$HY_CONF_DIR/config.yaml" <<EOF
listen: :$HY_PORT

tls:
  cert: $HY_CERT
  key: $HY_KEY

auth:
  type: password
  password: $HY_PASS

transport:
  type: tcp
EOF

# ======== 8. 配置 systemd 服务 ========
cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria2 Server (TCP+TLS, No Domain)
After=network.target

[Service]
ExecStart=$HY_BIN server -c $HY_CONF_DIR/config.yaml
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

# ======== 9. 启动 Hysteria ========
systemctl daemon-reload
systemctl enable --now hysteria

# ======== 10. 配置防火墙 ========
ufw allow $HY_PORT/tcp || true

# ======== 11. 输出节点链接和二维码 ========
SERVER_IP=$(curl -s ipv4.icanhazip.com)
HY_URL="hysteria2://$HY_PASS@$SERVER_IP:$HY_PORT/?insecure=1#Hysteria2-TCP"

echo "===================================="
echo " Hysteria2 部署完成 (TCP+TLS 自签证书)"
echo " 地址: $SERVER_IP"
echo " 端口: $HY_PORT"
echo " 密码: $HY_PASS"
echo
echo "标准链接:"
echo "$HY_URL"
echo
echo "二维码 (Clash/Sing-box/Shadowrocket 通用):"
echo
qrencode -t ANSIUTF8 "$HY_URL"
sleep 1
echo "===================================="
