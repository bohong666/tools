#!/bin/bash
set -e

#####################################
# Firewall Manager v5.3
# 作者：ChatGPT（为 HL 定制）
# 功能：
#   ✔ 自动检测 SSH 端口（sshd_config 优先）
#   ✔ 自动检测 iptables / ip6tables 是否存在
#   ✔ 多系统自动安装（Debian/Ubuntu/CentOS/Alpine/Arch）
#   ✔ 用户自定义开放端口
#   ✔ TCP/UDP 443 对 VLESS QUIC/UDP 优化
#   ✔ IPv4 ping 可选
#   ✔ IPv6 节点可用（完整 ICMPv6 放行）
#   ✔ SSH TCP 端口只开放 TCP
#   ✔ 屏幕美观输出
#   ✔ 自动保存规则
#####################################

VERSION="5.3"

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
# Check iptables availability
# -----------------------------
check_iptables() {
    if command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
        return 0
    fi

    echo "⚠️  系统未检测到 iptables / ip6tables，正在尝试安装..."

    case "$OS" in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y iptables iptables-persistent
            ;;
        centos|rhel)
            yum install -y iptables iptables-services
            ;;
        alpine)
            apk update
            apk add iptables ip6tables
            ;;
        arch)
            pacman -Sy --noconfirm iptables
            ;;
        *)
            echo "❌ 未知系统：$OS，无法自动安装 iptables，请手动安装后重试。"
            exit 1
            ;;
    esac

    if ! command -v iptables >/dev/null 2>&1; then
        echo "❌ iptables 安装失败，请手动检查系统环境。"
        exit 1
    fi
}

check_iptables
echo "✅ iptables 已就绪"
echo ""

# -----------------------------
# Detect SSH port
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
# User input for additional ports
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
iptables -F; iptables -X; iptables -Z
ip6tables -F; ip6tables -X; ip6tables -Z

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
# IPv4 ping (echo-request) 可选
# -----------------------------
read -p "是否允许 IPv4 Ping？(yes/no, 默认 yes): " PING_CONFIRM
[[ "$PING_CONFIRM" == "" ]] && PING_CONFIRM="yes"
if [[ "$PING_CONFIRM" == "yes" ]]; then
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    PING_STATUS="已开放"
else
    PING_STATUS="已关闭"
fi

# -----------------------------
# IPv6 必需 ICMPv6 放行
# -----------------------------
for t in destination-unreachable packet-too-big time-exceeded echo-request neighbor-solicitation neighbor-advertisement router-solicitation router-advertisement parameter-problem; do
    ip6tables -A INPUT -p icmpv6 --icmpv6-type $t -j ACCEPT
done

# -----------------------------
# Open Ports
# -----------------------------
IFS=","
echo ""
echo "🔓 开放端口："
for p in $ALL_PORTS; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
        if [[ "$p" == "$SSH_PORT" ]]; then
            echo "   ➤ 端口 $p (SSH TCP)"
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
        else
            echo "   ➤ 端口 $p (TCP/UDP, 支持 VLESS QUIC)"
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
elif [[ $OS == "alpine" ]]; then
    rc-update add iptables
    rc-service iptables save
fi

# -----------------------------
# Finish
# -----------------------------
echo ""
echo "=========================================="
echo " ✅ 防火墙规则已成功应用！"
echo "=========================================="
echo "🔐 SSH 端口已保留：$SSH_PORT (仅 TCP)"
echo "🌐 自定义端口 TCP/UDP 支持 VLESS QUIC：$USER_PORTS_RAW"
echo "🌐 IPv4 Ping：$PING_STATUS"
echo "🌐 IPv6 节点可用（完整 ICMPv6 放行）"
echo "🔒 其他所有端口默认关闭"
echo ""
echo "建议测试端口："
echo "   nc -zv YOUR_IP $SSH_PORT  # SSH"
for p in $USER_PORTS_RAW; do
    [[ "$p" =~ ^[0-9]+$ ]] && echo "   nc -zv YOUR_IP $p  # 自定义端口"
done
echo ""
echo "如需重新配置，请再次运行此脚本。"
echo ""
exit 0
