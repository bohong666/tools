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

# nginx 站点配置路径：Alpine 用 http.d，其余发行版用 conf.d
if [[ -d /etc/nginx/http.d ]]; then
  NGINX_CONF=/etc/nginx/http.d/magnet.conf
else
  NGINX_CONF=/etc/nginx/conf.d/magnet.conf
fi

say() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash $0"

# ------------------------------------------------------------
# 1. 识别系统 / 包管理器 / init
# ------------------------------------------------------------
OS_NAME="unknown"
PM="none"
INIT="unknown"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-${ID:-unknown}}"
fi

for c in apt-get dnf yum apk zypper pacman; do
  if command -v "$c" >/dev/null 2>&1; then PM="$c"; break; fi
done

if [[ -d /run/systemd/system ]]; then
  INIT=systemd
elif command -v rc-update >/dev/null 2>&1; then
  INIT=openrc
elif command -v service >/dev/null 2>&1; then
  INIT=sysv
fi

say "系统: $OS_NAME"
say "包管理器: $PM     init: $INIT"

if [[ "$PM" == "none" ]]; then
  echo
  echo "---- 诊断信息（请把这一段完整发给我）----"
  echo "os-release : $OS_NAME"
  echo "内核       : $(uname -a 2>/dev/null)"
  echo "PATH       : $PATH"
  echo "已查找     : apt-get dnf yum apk zypper pacman"
  echo "init       : $INIT"
  echo "libc       : $(ldd --version 2>&1 | head -1)"
  echo "------------------------------------------"
  die "未找到任何包管理器"
fi

if [[ "$INIT" != "systemd" ]]; then
  echo
  say "注意：本机没有 systemd（init=$INIT），服务将改用后台进程方式托管"
fi

# ------------------------------------------------------------
# 2. 安装依赖
# ------------------------------------------------------------
say "安装依赖 (aria2 / nginx / htpasswd / python3) ..."
case "$PM" in
  apt-get)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq aria2 nginx apache2-utils curl python3 openssl ca-certificates
    ;;
  dnf)
    dnf install -y -q aria2 nginx httpd-tools curl python3 openssl ca-certificates
    ;;
  yum)
    yum install -y -q aria2 nginx httpd-tools curl python3 openssl ca-certificates
    ;;
  apk)
    apk add --no-cache aria2 nginx apache2-utils curl python3 openssl ca-certificates
    ;;
  zypper)
    zypper --non-interactive install aria2 nginx apache2-utils curl python3 openssl ca-certificates
    ;;
  pacman)
    pacman -Sy --noconfirm --needed aria2 nginx apache2-utils curl python3 openssl ca-certificates
    ;;
  *)
    die "不支持的包管理器: $PM"
    ;;
esac

for bin in aria2c nginx curl python3; do
  command -v "$bin" >/dev/null 2>&1 || die "安装后仍找不到 $bin，请手动安装后重试"
done
ok "依赖安装完成"

# ------------------------------------------------------------
# 2. 运行用户与目录
# ------------------------------------------------------------
say "创建运行用户 aria2 与下载目录 $DL_DIR ..."
if ! id -u aria2 >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    useradd -r -M -s /usr/sbin/nologin -d "$DL_DIR" aria2
  else
    # BusyBox 系（Alpine）：adduser -S 系统用户 -D 不设密码 -H 不建 home
    adduser -S -D -H -h "$DL_DIR" -s /sbin/nologin aria2
  fi
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
# 5. 服务托管（SSH 断开不影响）
# ------------------------------------------------------------
ARIA_BIN=$(command -v aria2c)

# 运行期目录（pid / 日志），确保 aria2 用户可写
mkdir -p /run/aria2 /var/log/aria2
chown -R aria2:aria2 /run/aria2 /var/log/aria2

if [[ "$INIT" == "systemd" ]]; then
  say "安装 aria2 systemd 服务 ..."
  cat > /etc/systemd/system/aria2.service <<EOF
[Unit]
Description=aria2 download daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aria2
Group=aria2
UMask=0022
ExecStart=$ARIA_BIN --conf-path=$ARIA_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now aria2
  ok "aria2 已由 systemd 启动"

elif [[ "$INIT" == "openrc" ]]; then
  say "安装 aria2 OpenRC 服务 ..."
  cat > /etc/init.d/aria2 <<EOF
#!/sbin/openrc-run

name="aria2"
description="aria2 download daemon"
command="$ARIA_BIN"
command_args="--conf-path=$ARIA_CONF"
command_user="aria2:aria2"
command_background=true
pidfile="/run/aria2/aria2.pid"
output_log="/var/log/aria2/aria2.log"
error_log="/var/log/aria2/aria2.log"

depend() {
    need net
    after firewall
}
EOF
  chmod +x /etc/init.d/aria2
  rc-update add aria2 default >/dev/null 2>&1 || true
  rc-service aria2 restart
  ok "aria2 已由 OpenRC 启动"

else
  say "无 systemd / OpenRC，改用后台守护脚本 ..."
  cat > /usr/local/bin/aria2-ctl <<EOF
#!/bin/sh
# aria2 简易托管（适用于无 systemd/openrc 的精简系统）
PIDFILE=/run/aria2/aria2.pid
case "\$1" in
  start)
    if [ -f \$PIDFILE ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
      echo "aria2 已在运行"; exit 0
    fi
    su -s /bin/sh aria2 -c "$ARIA_BIN --conf-path=$ARIA_CONF --daemon=true --daemon-conf=$ARIA_CONF_DIR/daemon.conf"
    ;;
  stop)
    [ -f \$PIDFILE ] && kill "\$(cat \$PIDFILE)" 2>/dev/null && rm -f \$PIDFILE
    echo "aria2 已停止"
    ;;
  status)
    if [ -f \$PIDFILE ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
      echo "running"
    else
      echo "stopped"
    fi
    ;;
  *) echo "用法: \$0 {start|stop|status}"; exit 1 ;;
esac
EOF
  chmod +x /usr/local/bin/aria2-ctl
  printf 'pid-file=/run/aria2/aria2.pid\nlog=/var/log/aria2/aria2.log\n' > "$ARIA_CONF_DIR/daemon.conf"
  chown aria2:aria2 "$ARIA_CONF_DIR/daemon.conf"
  /usr/local/bin/aria2-ctl start
  ok "aria2 已后台启动（用 aria2-ctl start|stop|status 管理）"
fi

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

if [[ "$INIT" == "systemd" ]]; then
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
elif [[ "$INIT" == "openrc" ]]; then
  rc-update add nginx default >/dev/null 2>&1 || true
  rc-service nginx restart
else
  nginx -s reload >/dev/null 2>&1 || nginx
fi
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
