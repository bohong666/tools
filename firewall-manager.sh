#!/bin/bash
# ufw-manager.sh
# 统一使用 ufw 管理防火墙，如果当前是 iptables，会自动切换
# 作者：ChatGPT GPT-5
# 版本：v1.0
# 更新时间：2025-11-07

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行（sudo bash $0）"
  exit 1
fi

FW_VERSION="v1.0"

# 检测防火墙并切换到 ufw
setup_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    FW_TYPE="ufw"
  elif command -v iptables >/dev/null 2>&1; then
    echo "⚠️ 当前使用 iptables，正在切换到 ufw..."
    # 保存 iptables 规则（可选）
    iptables-save > "/root/iptables_backup_$(date +%F_%H%M%S).rules"
    # 清空 iptables 规则
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    echo "✅ iptables 已清空"
    # 安装并启用 ufw
    apt update && apt install -y ufw
    ufw enable
    FW_TYPE="ufw"
    echo "✅ 已切换到 ufw 防火墙"
  else
    echo "❌ 系统没有安装 ufw 或 iptables，请先安装 ufw"
    exit 1
  fi
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
  echo "3) TCP + UDP（同时开放）"
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
    ufw allow "$port/$p"
    echo "✅ 已允许 $p 端口 $port"
  done
}

# 禁止端口
deny_port() {
  local port=$1
  local proto=$2
  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")
  for p in "${proto_list[@]}"; do
    ufw deny "$port/$p"
    echo "🚫 已禁止 $p 端口 $port"
  done
}

# 删除端口
delete_port() {
  local port=$1
  local proto=$2
  [[ "$proto" == "both" ]] && proto_list=("tcp" "udp") || proto_list=("$proto")
  for p in "${proto_list[@]}"; do
    # 使用 ufw delete 规则
    while true; do
      num=$(ufw status numbered | grep "$port/$p" | awk -F'[][]' '{print $2}' | tail -n1)
      [ -z "$num" ] && break
      ufw delete "$num"
    done
    echo "🧹 已删除 $p 端口 $port"
  done
}

# 开启/关闭防火墙
toggle_firewall() {
  local action=$1
  if [ "$action" == "on" ]; then
    ufw enable
    echo "✅ 防火墙已开启"
  else
    ufw disable
    echo "⚠️ 防火墙已关闭"
  fi
}

# 保存规则（ufw 自动保存，无需额外操作）
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

# 启动脚本
main_menu
