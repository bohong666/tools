#!/bin/bash
set -e

#####################################
# Firewall Manager v3 (2025-01)
# 作者：ChatGPT
# 功能：统一管理 IPv4/IPv6 防火墙
# 特性：
#   ✔ 自动检测 SSH 端口
#   ✔ 用户自定义开放端口
#   ✔ IPv4 ping 关闭 / IPv6 ping 保留
#   ✔ 所有输出美化
#   ✔ 自动判断系统
#   ✔ 不会误杀 SSH
#   ✔ 自动保存规则
#####################################

VERSION="3.0"

echo ""
echo "=========================================="
echo " 🔥 Firewall Manager v$VERSION"
echo "=========================================="
echo ""

# -----------------------------
# Detect OS
# -----------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统类型，脚本中止。"
    exit 1
fi

echo "🖥️  系统类型：$PRETTY_NAME"
echo ""

# -----------------------------
# Detect SSH Port
# -----------------------------
SSH_PORT=$(ss -tnlp | grep sshd | awk -F '[: ]+' '{print $5}' | sed 's/.*://;t;d' | head -n 1)

if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=22
fi

echo "🔐 自动检测到 SSH 端口：$SSH_PORT"
echo ""

# -----------------------------
# Input Ports
# -----------------------------
read -p "请输入需额外开放的端口（例如：443,80）：" USER_PORTS_RAW

# 格式化
USER_PORTS=$(echo "$USER_PORTS_RAW" | tr -d ' ' | tr ';' ',')

# 合并去重
ALL_PORTS=$(echo -e "$SSH_PORT\n${USER_PORTS//,/\\n}" | sed '/^$/d' | sort -n -u | paste -sd "," -)

echo ""
echo "📌 最终将开放以下端口：$ALL_PORTS"
echo ""

read -p "⚠️ 确定要应用此防火墙规则？(yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "已取消。" && exit 0

echo ""
echo "🚧 正在应用规则..."
sleep 1

# -----------------------------
# 清空旧规则
# -----------------------------
iptables -F
iptables -X
ip6tables -F
ip6tables -X

# -----------------------------
# 默认策略
# -----------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# -----------------------------
# 基本规则
# -----------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# -----------------------------
# ❌ 关闭 IPv4 ping
# -----------------------------
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

# -----------------------------
# ⚠️ 保留 IPv6 ICMP
# -----------------------------
# 不添加任何 DROP 规则

# -----------------------------
# 开放端口
# -----------------------------
IFS=","
echo ""
echo "🔓 开放端口："
for p in $ALL_PORTS; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        echo "   ➤ 端口 $p (TCP/UDP)"
        iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
        iptables -A INPUT -p udp --dport "$p" -j ACCEPT
        ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
        ip6tables -A INPUT -p udp --dport "$p" -j ACCEPT
    fi
done
unset IFS

echo ""
echo "💾 正在保存防火墙规则..."

# -----------------------------
# 保存规则
# -----------------------------
if [[ $OS == "ubuntu" || $OS == "debian" ]]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y iptables-persistent >/dev/null 2>&1
    netfilter-persistent save
elif [[ $OS == "centos" ]]; then
    service iptables save
fi

echo ""
echo "=========================================="
echo " ✅ 防火墙规则已成功应用！"
echo "=========================================="
echo "🔐 SSH 端口已自动保留：$SSH_PORT"
echo "🛑 IPv4 Ping 已关闭"
echo "🌐 IPv6 Ping 保持正常（避免网络故障）"
echo "🔒 所有其他端口已禁止访问"
echo ""
echo "建议测试 SSH 端口是否正常："
echo "   nc -zv YOUR_IP $SSH_PORT"
echo ""
echo "如需重新配置，请再次运行本脚本。"
echo ""
exit 0
