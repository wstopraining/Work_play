#!/bin/bash
# 跑得快联机游戏 - 一键部署脚本
# 用法: 在服务器上 bash deploy.sh
# 自动探测 node/peerjs 路径，兼容 nvm/系统安装

set -e

echo "===== 跑得快联机游戏部署 ====="

# 1. 确保 nginx 已安装
if ! command -v nginx &>/dev/null; then
  echo "[1/6] 安装 nginx..."
  apt-get update -qq && apt-get install -y -qq nginx 2>/dev/null || yum install -y -q nginx 2>/dev/null || dnf install -y -q nginx 2>/dev/null
else
  echo "[1/6] nginx 已安装"
fi

# 2. 确保 Node.js 已安装（兼容 nvm）
NODE_BIN=$(command -v node 2>/dev/null || echo "")
if [ -z "$NODE_BIN" ] && [ -f "$HOME/.nvm/nvm.sh" ]; then
  source "$HOME/.nvm/nvm.sh"
  NODE_BIN=$(command -v node 2>/dev/null || echo "")
fi
if [ -z "$NODE_BIN" ]; then
  echo "[2/6] 未找到 Node.js，正在安装..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs 2>/dev/null || yum install -y -q nodejs 2>/dev/null
  NODE_BIN=$(command -v node)
fi
NODE_DIR=$(dirname "$NODE_BIN")
NPM_BIN="$NODE_DIR/npm"
echo "[2/6] Node.js: $("$NODE_BIN" -v) ($NODE_BIN)"

# 3. 安装 peerjs-server（如未安装）
PEERJS_BIN="$NODE_DIR/peerjs"
if [ ! -f "$PEERJS_BIN" ]; then
  echo "[3/6] 安装 peerjs-server..."
  "$NPM_BIN" install -g peerjs 2>/dev/null
fi
if [ ! -f "$PEERJS_BIN" ]; then
  # 探测 npm 全局 bin 路径
  NPM_GLOBAL_BIN=$("$NPM_BIN" bin -g 2>/dev/null || echo "$NODE_DIR")
  PEERJS_BIN="$NPM_GLOBAL_BIN/peerjs"
fi
if [ ! -f "$PEERJS_BIN" ]; then
  echo "错误: peerjs 安装失败，请手动运行: $NPM_BIN install -g peerjs"
  exit 1
fi
echo "[3/6] peerjs: $PEERJS_BIN"

# 4. 部署游戏页面
echo "[4/6] 部署游戏页面..."
mkdir -p /var/www/paodekuai
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/paodekuai.html" ]; then
  cp "$SCRIPT_DIR/paodekuai.html" /var/www/paodekuai/index.html
elif [ -f "$SCRIPT_DIR/index.html" ]; then
  cp "$SCRIPT_DIR/index.html" /var/www/paodekuai/index.html
else
  echo "错误: 找不到 paodekuai.html，请确保它在 deploy.sh 同目录下"
  exit 1
fi

# 5. 配置 nginx（直接写 nginx.conf 确保生效）
echo "[5/6] 配置 nginx..."
# 探测 nginx 用户
NGINX_USER=$(grep "^user" /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "nginx")
if [ -z "$NGINX_USER" ]; then NGINX_USER="nginx"; fi
if ! id "$NGINX_USER" &>/dev/null; then
  NGINX_USER=$(grep "^user" /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
  if ! id "$NGINX_USER" &>/dev/null; then NGINX_USER="nobody"; fi
fi

cat > /etc/nginx/nginx.conf << NGINXEOF
user $NGINX_USER;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 80;
        server_name _;
        root /var/www/paodekuai;
        index index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }

        location /peerjs {
            proxy_pass http://127.0.0.1:9000;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 86400;
        }
    }
}
NGINXEOF

nginx -t && systemctl restart nginx
echo "      nginx 已重启"

# 6. 创建并启动 PeerJS 服务（使用探测到的路径）
echo "[6/6] 配置 PeerJS 服务..."
cat > /etc/systemd/system/peerjs-server.service << EOF
[Unit]
Description=PeerJS Server for Paodekuai
After=network.target

[Service]
Type=simple
ExecStart=$PEERJS_BIN --port 9000 --path /peerjs
Restart=always
RestartSec=3
Environment=PATH=$NODE_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable peerjs-server
systemctl restart peerjs-server
sleep 2

# 验证
echo ""
echo "===== 验证 ====="
NGINX_STATUS=$(systemctl is-active nginx)
PEERJS_STATUS=$(systemctl is-active peerjs-server)
PAGE_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null || echo "000")
SIGNAL_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/peerjs/ 2>/dev/null || echo "000")

echo "nginx:    $NGINX_STATUS  (页面: $PAGE_CODE)"
echo "peerjs:   $PEERJS_STATUS  (信令: $SIGNAL_CODE)"

if [ "$NGINX_STATUS" = "active" ] && [ "$PEERJS_STATUS" = "active" ] && [ "$PAGE_CODE" = "200" ]; then
  SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  echo "===== 部署成功 ====="
  echo "访问地址: http://$SERVER_IP"
  echo "把地址发给同事，浏览器打开就能联机组队"
else
  echo ""
  echo "===== 部署可能有问题 ====="
  if [ "$PEERJS_STATUS" != "active" ]; then
    echo "PeerJS 启动失败，查看日志: journalctl -u peerjs-server --no-pager -n 20"
  fi
  if [ "$PAGE_CODE" != "200" ]; then
    echo "页面访问失败，检查: nginx -t && systemctl restart nginx"
  fi
fi
