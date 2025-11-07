#!/bin/bash
# ufw-manager.sh
# ufw 专用防火墙管理器 v1.4
# 自动保持 SSH 开放，简化交互，端口操作稳定
# 更新时间：2025-11-07

# 检查 root
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行"
  exit 1
fi

FW_VERSION="v1.4"

# 获取当前 SSH 端口
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
[ -z "$SSH_PORT" ] && SSH_PORT=22
echo "🔹 当前 SSH 端口：$SSH_PORT"

# 安装/启用 ufw
setup_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    echo "⚠️ 系统未安装 ufw，正在安装..."
    apt update && apt install -y ufw
  fi
  ufw --force enable
  ufw allow "$SSH_PORT"/tcp
  echo "✅ ufw 已启用，SSH 端口 $SSH_PORT 保证开放"
}

# 显示 ufw 状态
show_status() {
  echo "=================================="
  echo "🧭 ufw 防火墙管理器 - $FW_VERSION"
  echo "=================================="
  ufw status verbose
  echo "=================================="
}

# 协议选择
choose_proto() {
  echo
  echo "请选择协议类型："
  echo "1) TCP"
  echo "2) UDP"
  echo "3) TCP + UDP"
  read -p "输入编号 (1/2/3): " proto_choice
  case $proto_choice in
    1) proto="tcp" ;;
    2) proto="udp" ;;
    3) proto="both" ;;
    *) echo "❌ 输入无效，默认 TCP"; proto="tcp" ;;
  esac
  echo "$proto"
}

# 添加端口
add_port() {
  local port=$1
  local proto=$2
  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")
  for p in "${proto_list[@]}"; do
    if ! ufw status | grep -qw "$port/$p"; then
      ufw allow "$port/$p"
      echo "✅ 已允许 $p 端口 $port"
    else
      echo "⚠️ $p 端口 $port 已存在规则，跳过"
    fi
  done
  ufw allow "$SSH_PORT"/tcp
}

# 禁止端口
deny_port() {
  local port=$1
  local proto=$2
  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")
  for p in "${proto_list[@]}"; do
    if [ "$port" == "$SSH_PORT" ] && [ "$p" == "tcp" ]; then
      echo "⚠️ 避免禁止 SSH 端口 $SSH_PORT"
      continue
    fi
    if ! ufw status | grep -qw "$port/$p"; then
      ufw deny "$port/$p"
      echo "🚫 已禁止 $p 端口 $port"
    else
      echo "⚠️ $p 端口 $port 已存在允许规则，禁止成功"
    fi
  done
  ufw allow "$SSH_PORT"/tcp
}

# 删除端口
delete_port() {
  local port=$1
  local proto=$2
  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")
  for p in "${proto_list[@]}"; do
    if [ "$port" == "$SSH_PORT" ] && [ "$p" == "tcp" ]; then
      echo "⚠️ 避免删除 SSH 端口 $SSH_PORT 规则"
      continue
    fi
    while true; do
      mapfile -t nums < <(ufw status numbered | grep "$port/$p" | awk -F'[][]' '{print $2}' | sort -r)
      [ ${#nums[@]} -eq 0 ] && break
      for num in "${nums[@]}"; do
        ufw --force delete "$num"
        echo "🧹 已删除 $p 端口 $port (规则编号 $num)"
      done
    done
  done
  ufw allow "$SSH_PORT"/tcp
}

# 开启/关闭防火墙
toggle_firewall() {
  local action=$1
  if [ "$action" == "on" ]; then
    ufw --force enable
    echo "✅ 防火墙已开启"
  else
    ufw --force disable
    echo "⚠️ 防火墙已关闭"
    ufw allow "$SSH_PORT"/tcp
  fi
}

# 保存规则
save_rules() {
  ufw reload
  echo "✅ ufw 规则已重新加载"
}

# 主菜单
main_menu() {
  setup_ufw
  show_status

  echo
  echo "=============================="
  echo "🔥 ufw 防火墙管理菜单"
  echo "=============================="
  echo "1) 查看端口规则"
  echo "2) 开启防火墙"
  echo "3) 关闭防火墙"
  echo "4) 添加允许端口"
  echo "5) 添加禁止端口"
  echo "6) 删除端口规则"
  echo "7) 保存规则"
  echo "8) 退出"
  echo "=============================="

  read -p "请选择操作编号: " choice
  case $choice in
    1) show_status ;;
    2) toggle_firewall on ;;
    3) toggle_firewall off ;;
    4)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      add_port "$port" "$proto"
      ;;
    5)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      deny_port "$port" "$proto"
      ;;
    6)
      read -p "请输入端口号: " port
      proto=$(choose_proto)
      delete_port "$port" "$proto"
      ;;
    7) save_rules ;;
    8) echo "👋 已退出"; exit 0 ;;
    *) echo "❌ 无效选项" ;;
  esac

  echo
  read -p "是否返回主菜单？(y/n): " again
  [ "$again" = "y" ] && main_menu || echo "✅ 操作完成。"
}

main_menu
