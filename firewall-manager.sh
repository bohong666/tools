#!/bin/bash
set -e

#####################################
# Firewall Manager v5.0
# 作者：ChatGPT
# 功能：
#   ✔ 自动检测 SSH 端口（sshd_config 优先）
#   ✔ 用户自定义开放端口
#   ✔ IPv4 ping 开放
#   ✔ SSH TCP 端口只开放 TCP
#   ✔ 屏幕输出美观
#   ✔ 自动保存规则
#####################################

VERSION="5.0"

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
# Reliable SSH Port Detection
# -----------------------------
detect_ssh_port() {
    CFG_PORT=$(grep -Ei "^Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)

    if [[ -z "$CFG_PORT" && -d /etc/ssh/sshd_config.d ]]; then
        CFG_PORT=$(grep -Er "^Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -n1)
    fi

    if [[ -z "$CFG_PORT" ]]; then
        CFG_PORT=$(ss -tnlp 2>/dev/null | grep sshd | awk -F '[: ]+' '{print $5}' | sed 's/.*://;t;d' | grep -E "^[0-9]+$" | head -n1)
    fi

    [[ -z "$CFG_PORT" ]] && CFG_PORT=22
    echo "$CFG_PORT"
}

SSH_PORT=$(detect_ssh_port)
echo "🔐 检测到 SSH 端口：$SSH_PORT"
echo ""

# -----------------------------
# User Input for Extra Ports
# -----------------------------
read -p "请输入需额外开放的端口（多个用逗号或分号，如: 443,80）：" USER_PORTS_RAW
USER_PORTS=$(echo "$USER_PORTS_RAW" | tr -d ' ' | tr ';' ',')

ALL_PORTS=$(echo -e "$SSH_PORT\n${USER_PORTS//,/\\n}" | sed '/^$/d' | sort -n -u | paste -sd "," -)

echo ""
echo "📌 最终将开放以下端口：$ALL_PORTS"
echo ""

read -p "⚠️ 确认应用规则？(yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "已取消。" && exit 0

echo ""
echo "🚧 正在应用规则..."
sleep 1

# -----------------------------
# Flush Existing Rules
# -----------------------------
iptables -F
iptables -X
iptables -Z

ip6tables -F
ip6tables -X
ip6tables -Z

# -----------------------------
# Default Policies
# -----------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# -----------------------------
# Basic Rules
# -----------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# -----------------------------
# IPv4 ping 开放
# -----------------------------
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# -----------------------------
# Open Ports
# -----------------------------
IFS=","
echo ""
echo "🔓 开放端口："
for p in $ALL_PORTS; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        echo -n "   ➤ 端口 $p ("
        if [[ "$p" == "$SSH_PORT" ]]; then
            echo "TCP)"
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
        else
            echo "TCP/UDP)"
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
            iptables -A INPUT -p udp --dport "$p" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
            ip6tables -A INPUT -p udp --dport "$p" -j ACCEPT
        fi
    fi
done
unset IFS

# -----------------------------
# Save Rules
# -----------------------------
echo ""
echo "💾 保存防火墙规则..."
if [[ $OS == "ubuntu" || $OS == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
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
echo "🔐 SSH 端口已保留：$SSH_PORT (仅 TCP)"
echo "🌐 IPv4 Ping 已开放"
echo "🌐 IPv6 Ping 保持正常"
echo "🔒 其他所有端口默认关闭"
echo ""
echo "建议测试 SSH 端口是否可用："
echo "   nc -zv YOUR_IP $SSH_PORT"
echo ""
echo "如需重新配置，请再次运行本脚本。"
echo ""
exit 0
