#!/usr/bin/env bash
# ============================================================
#  VPS 磁力临时下载一键部署
#  aria2 (RPC 常驻后台) + nginx (HTTP 直链 + Basic Auth)
#  针对 1C1G 小内存优化；支持 Debian/Ubuntu / CentOS/Alma/Rocky
#
#  用法:  sudo bash install.sh
#  可选:  PORT=8080 DL_DIR=/srv/dl sudo -E bash install.sh
# ============================================================
set -euo pipefail

PORT="${PORT:-8080}"
DL_DIR="${DL_DIR:-/srv/dl}"
ARIA_CONF_DIR=/etc/aria2
ARIA_CONF="$ARIA_CONF_DIR/aria2.conf"
SESSION_FILE="$ARIA_CONF_DIR/aria2.session"
INFO_FILE=/root/magnet-info.txt
NGINX_CONF=/etc/nginx/conf.d/magnet.conf

say() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash $0"

# ------------------------------------------------------------
# 1. 安装依赖
# ------------------------------------------------------------
say "安装依赖 (aria2 / nginx / htpasswd / python3) ..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq aria2 nginx apache2-utils curl python3 openssl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q aria2 nginx httpd-tools curl python3 openssl ca-certificates
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q aria2 nginx httpd-tools curl python3 openssl ca-certificates
else
  die "未识别包管理器，请手动安装 aria2 nginx htpasswd curl python3"
fi
ok "依赖安装完成"

# ------------------------------------------------------------
# 2. 运行用户与目录
# ------------------------------------------------------------
say "创建运行用户 aria2 与下载目录 $DL_DIR ..."
if ! id -u aria2 >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -d "$DL_DIR" aria2
fi
mkdir -p "$DL_DIR" "$ARIA_CONF_DIR"
chown -R aria2:aria2 "$DL_DIR"
chmod 755 "$DL_DIR"
ok "目录就绪"

# ------------------------------------------------------------
# 3. 生成密钥
# ------------------------------------------------------------
RPC_SECRET=$(openssl rand -hex 16)
HTTP_USER=dl
HTTP_PASS=$(openssl rand -hex 6)

# ------------------------------------------------------------
# 4. aria2 配置（小内存保守参数）
# ------------------------------------------------------------
say "写入 aria2 配置 ..."
touch "$SESSION_FILE"

cat > "$ARIA_CONF" <<EOF
# ---- 基础 ----
dir=$DL_DIR
file-allocation=none
continue=true
auto-file-renaming=true
allow-overwrite=false
disk-cache=16M
console-log-level=warn
summary-interval=0

# ---- 会话持久化：重启后自动续传 ----
save-session=$SESSION_FILE
save-session-interval=60
input-file=$SESSION_FILE

# ---- 并发：1C1G 保守设置 ----
max-concurrent-downloads=1
max-connection-per-server=4
split=4
min-split-size=4M
max-overall-download-limit=0
max-download-limit=0

# ---- BT / 磁力 ----
listen-port=51413
dht-listen-port=51413
enable-dht=true
enable-dht6=false
bt-enable-lpd=false
enable-peer-exchange=true
bt-max-peers=30
bt-request-peer-speed-limit=500K
seed-time=0
bt-save-metadata=true
follow-torrent=true
bt-tracker=udp://tracker.opentrackr.org:1337/announce,udp://open.stealth.si:80/announce,udp://tracker.torrent.eu.org:451/announce,udp://exodus.desync.com:6969/announce,udp://tracker.openbittorrent.com:6969/announce,udp://open.demonii.com:1337/announce

# ---- 上传限速：降低被商家判定滥用 P2P 的风险 ----
max-overall-upload-limit=100K
max-upload-limit=50K

# ---- RPC（仅本机监听，不对外暴露）----
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=6800
rpc-secret=$RPC_SECRET
rpc-allow-origin-all=true
EOF

chown root:aria2 "$ARIA_CONF"
chmod 640 "$ARIA_CONF"
chown aria2:aria2 "$SESSION_FILE"
ok "aria2 配置完成"

# ------------------------------------------------------------
# 5. systemd 服务（SSH 断开不影响）
# ------------------------------------------------------------
say "安装 aria2 systemd 服务 ..."
cat > /etc/systemd/system/aria2.service <<'EOF'
[Unit]
Description=aria2 download daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aria2
Group=aria2
UMask=0022
ExecStart=/usr/bin/aria2c --conf-path=/etc/aria2/aria2.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now aria2
ok "aria2 已启动"

# ------------------------------------------------------------
# 6. nginx 直链服务
# ------------------------------------------------------------
say "配置 nginx 直链服务 (端口 $PORT) ..."
htpasswd -bc /etc/nginx/.htpasswd "$HTTP_USER" "$HTTP_PASS" >/dev/null 2>&1 \
  || die "生成 .htpasswd 失败，请检查 httpd-tools / apache2-utils 是否安装"

cat > "$NGINX_CONF" <<EOF
server {
    listen $PORT;
    server_name _;
    root $DL_DIR;
    charset utf-8;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    auth_basic "magnet-dl";
    auth_basic_user_file /etc/nginx/.htpasswd;

    client_max_body_size 0;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# SELinux（CentOS / Alma 常见）
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
  say "检测到 SELinux Enforcing，放行目录访问 ..."
  setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true
  chcon -R -t httpd_sys_content_t "$DL_DIR" 2>/dev/null || true
fi

nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 配置校验失败"; }
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "nginx 已启动"

# ------------------------------------------------------------
# 7. 防火墙
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  say "已放行 ufw 端口 $PORT"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  say "已放行 firewalld 端口 $PORT"
fi

# ------------------------------------------------------------
# 8. 输出访问信息
# ------------------------------------------------------------
IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$IP" ]] && IP="<你的VPS公网IP>"

cat > "$INFO_FILE" <<EOF
磁力下载服务信息
==================
下载目录 : $DL_DIR
HTTP 端口: $PORT
访问地址 : http://$IP:$PORT/
用户名   : $HTTP_USER
密码     : $HTTP_PASS
RPC 密钥 : $RPC_SECRET
管理菜单 : bash /root/magnet.sh
EOF
chmod 600 "$INFO_FILE"

echo
echo "================================================"
cat "$INFO_FILE"
echo "================================================"
echo
echo "下一步：把 magnet.sh 上传到 /root/ 后执行"
echo "  bash /root/magnet.sh"
echo
