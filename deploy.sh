#!/bin/bash
# 跑得快联机游戏 - 一键部署脚本
# 在云服务器上以 root 运行: bash deploy.sh
# 部署后: nginx 托管页面(80端口) + 自建 PeerJS 信令服务器(反代到 /peerjs)

set -e

echo "===== 跑得快联机游戏部署 ====="

# 1. 安装 nginx 和 Node.js
if ! command -v nginx &>/dev/null; then
  echo "[1/5] 安装 nginx..."
  apt-get update -qq && apt-get install -y -qq nginx
else
  echo "[1/5] nginx 已安装"
fi

if ! command -v node &>/dev/null; then
  echo "[2/5] 安装 Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
else
  echo "[2/5] Node.js 已安装: $(node -v)"
fi

# 3. 安装 peerjs-server
echo "[3/5] 安装 peerjs-server..."
npm install -g peerjs 2>/dev/null || true

# 4. 部署游戏页面
echo "[4/5] 部署游戏页面..."
mkdir -p /var/www/paodekuai
cp "$(dirname "$0")/paodekuai.html" /var/www/paodekuai/index.html

# 5. 配置 nginx
echo "[5/5] 配置 nginx..."
NGINX_CONF='server {
    listen 80;
    server_name _;

    root /var/www/paodekuai;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # PeerJS 信令服务器反代
    location /peerjs {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400;
    }
}'

# 兼容不同 nginx 目录结构，并清理可能冲突的默认配置
if [ -d /etc/nginx/sites-enabled ]; then
  rm -f /etc/nginx/sites-enabled/default
fi
if [ -d /etc/nginx/conf.d ]; then
  rm -f /etc/nginx/conf.d/default.conf
fi
if [ -d /etc/nginx/sites-available ]; then
  echo "$NGINX_CONF" > /etc/nginx/sites-available/paodekuai
  ln -sf /etc/nginx/sites-available/paodekuai /etc/nginx/sites-enabled/paodekuai
elif [ -d /etc/nginx/conf.d ]; then
  echo "$NGINX_CONF" > /etc/nginx/conf.d/paodekuai.conf
else
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  echo "$NGINX_CONF" > /etc/nginx/sites-available/paodekuai
  ln -sf /etc/nginx/sites-available/paodekuai /etc/nginx/sites-enabled/paodekuai
fi

nginx -t && systemctl restart nginx

# 6. 创建 peerjs-server systemd 服务
echo "创建 PeerJS 服务..."
cat > /etc/systemd/system/peerjs-server.service << 'SERVICE'
[Unit]
Description=PeerJS Server for Paodekuai
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/peerjs --port 9000 --path /peerjs
Restart=always
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable peerjs-server
systemctl restart peerjs-server

# 7. 开放防火墙
echo "配置防火墙..."
if command -v ufw &>/dev/null; then
  ufw allow 80/tcp 2>/dev/null || true
  ufw allow 9000/tcp 2>/dev/null || true
fi

# 完成
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "===== 部署完成 ====="
echo "访问地址: http://${SERVER_IP}"
echo "把上面的地址发给同事，大家打开就能联机组队了"
echo ""
echo "管理命令:"
echo "  查看状态: systemctl status peerjs-server"
echo "  重启信令: systemctl restart peerjs-server"
echo "  重启nginx: systemctl restart nginx"
echo "  查看日志: journalctl -u peerjs-server -f"
