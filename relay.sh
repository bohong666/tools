#!/usr/bin/env sh
set -e

BASE_DIR="/opt/xray-relay"
XRAY_BIN="$BASE_DIR/xray"
CONF="$BASE_DIR/xray.json"
DB="$BASE_DIR/targets.db"
PID="$BASE_DIR/xray.pid"

################################
# 基础函数
################################
die() { echo "[ERROR] $1"; exit 1; }

is_alpine() { grep -qi alpine /etc/os-release; }

need_root() {
  [ "$(id -u)" = 0 ] || die "请使用 root 运行"
}

################################
# 安装最小依赖 + xray
################################
install_xray() {
  mkdir -p "$BASE_DIR"

  if [ -x "$XRAY_BIN" ]; then
    return
  fi

  echo "[INFO] 安装 Xray（最小版本）..."

  if is_alpine; then
    apk add --no-cache curl unzip
  else
    apt update
    apt install -y curl unzip
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) A=64 ;;
    aarch64|arm64) A=arm64 ;;
    *) die "不支持的架构: $ARCH" ;;
  esac

  curl -fsSL -o /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$A.zip"

  unzip -q /tmp/xray.zip -d /tmp/xray
  mv /tmp/xray/xray "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  rm -rf /tmp/xray*
}

################################
# 解析 vless://
################################
parse_vless() {
  VLESS="$1"

  UUID=$(echo "$VLESS" | sed -n 's|vless://\([^@]*\)@.*|\1|p')
  HOSTPORT=$(echo "$VLESS" | sed -n 's|.*@\([^?]*\).*|\1|p')
  HOST=${HOSTPORT%:*}
  PORT=${HOSTPORT#*:}

  PBK=$(echo "$VLESS" | sed -n 's|.*pbk=\([^&]*\).*|\1|p')
  SNI=$(echo "$VLESS" | sed -n 's|.*sni=\([^&]*\).*|\1|p')
  SID=$(echo "$VLESS" | sed -n 's|.*sid=\([^&]*\).*|\1|p')
}

################################
# 添加落地
################################
add_target() {
  echo "请输入 vless:// 链接："
  read VLESS

  parse_vless "$VLESS"
  [ -z "$UUID" ] && die "解析失败"

  echo "$UUID|$HOST|$PORT|$PBK|$SNI|$SID" >> "$DB"
  echo "[OK] 已添加落地节点"
}

################################
# 列表 / 选择
################################
list_targets() {
  nl -w2 -s'. ' "$DB" 2>/dev/null || echo "暂无落地"
}

select_target() {
  list_targets
  echo "选择序号："
  read N
  LINE=$(sed -n "${N}p" "$DB") || die "无效序号"
  echo "$LINE" > "$DB.current"
}

################################
# 生成配置
################################
gen_config() {
  [ -f "$DB.current" ] || die "未选择落地节点"

  IFS="|" read UUID HOST PORT PBK SNI SID < "$DB.current"

  echo "设置 Shadowsocks 监听端口："
  read SS_PORT
  echo "设置 Shadowsocks 密码："
  read SS_PASS

  SS_METHOD="aes-128-gcm" # 固定为 Clash Party 兼容加密

  cat > "$CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$BASE_DIR/access.log",
    "error": "$BASE_DIR/error.log"
  },
  "inbounds": [{
    "port": $SS_PORT,
    "protocol": "shadowsocks",
    "settings": {
      "method": "$SS_METHOD",
      "password": "$SS_PASS",
      "network": "tcp,udp"
    }
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$HOST",
        "port": $PORT,
        "users": [{
          "id": "$UUID",
          "encryption": "none",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "$SNI",
        "publicKey": "$PBK",
        "shortId": "$SID",
        "fingerprint": "chrome"
      }
    }
  }]
}
EOF

  echo "$SS_PORT|$SS_PASS" > "$BASE_DIR/ss.info"
  echo "[OK] 配置生成完成，Shadowsocks 已就绪"
}

################################
# 启停
################################
start_xray() {
  stop_xray
  nohup "$XRAY_BIN" run -config "$CONF" >/dev/null 2>&1 &
  echo $! > "$PID"
  sleep 1
  echo "[OK] Xray 已启动"
}

stop_xray() {
  [ -f "$PID" ] && kill "$(cat $PID)" 2>/dev/null || true
}

################################
# 输出 ss:// 链接
################################
show_ss() {
  [ -f "$BASE_DIR/ss.info" ] || die "未生成 SS 信息"
  IFS="|" read SS_PORT SS_PASS < "$BASE_DIR/ss.info"
  IP=$(curl -s ipinfo.io/ip)
  SS_LINK=$(echo -n "$SS_METHOD:$SS_PASS@$IP:$SS_PORT" | base64 -w0)
  echo
  echo "====== Shadowsocks 信息 ======"
  echo "服务器: $IP"
  echo "端口:   $SS_PORT"
  echo "密码:   $SS_PASS"
  echo "加密:   $SS_METHOD"
  echo "链接:   ss://$SS_LINK#NAT-Relay"
  echo "=============================="
}

################################
# 菜单
################################
menu() {
  echo
  echo "1) 添加落地 VLESS"
  echo "2) 查看落地列表"
  echo "3) 选择落地"
  echo "4) 生成配置并启动"
  echo "5) 查看 SS 链接"
  echo "6) 停止 Xray"
  echo "0) 退出"
  read C

  case "$C" in
    1) add_target ;;
    2) list_targets ;;
    3) select_target ;;
    4) gen_config; start_xray ;;
    5) show_ss ;;
    6) stop_xray ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
}

################################
# 主入口
################################
need_root
install_xray

while true; do
  menu
done

