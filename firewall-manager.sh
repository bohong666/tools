#!/bin/bash
# 自动安全防火墙管理脚本
# 支持：Debian / Ubuntu / CentOS
# 作者：ChatGPT（安全版）

### ------------------------
### 1. 检查 root 权限
### ------------------------
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 执行该脚本"
    exit 1
fi

### ------------------------
### 2. 检测系统类型
### ------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别系统类型"
    exit 1
fi

echo "🔍 检测到系统：$PRETTY_NAME"

### ------------------------
### 3. 自动检测 SSH 端口（防止被锁死）
### ------------------------
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | sed 's/.*://')

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi

echo "🔐 当前 SSH 端口自动检测为：$SSH_PORT"
echo "⚠️ 该端口将自动加入允许列表，确保不会断线。"

### ------------------------
### 4. 显示现有 iptables 规则
### ------------------------
echo -e "\n=========================="
echo "当前 IPv4 iptables 规则："
echo "=========================="
iptables -L -n -v
echo -e "\n=========================="
echo "当前 IPv6 ip6tables 规则："
echo "=========================="
ip6tables -L -n -v

### ------------------------
### 5. 用户输入需要开放的端口
### ------------------------
echo ""
echo "请输入你需要开放的端口（例如：443,80,12345）"
echo "SSH 端口（$SSH_PORT）会自动加入，无需重复输入"
read -p "允许的端口： " USER_PORTS

ALLOW_PORTS="$SSH_PORT"
if [ -n "$USER_PORTS" ]; then
    ALLOW_PORTS="$ALLOW_PORTS,$USER_PORTS"
fi

echo ""
echo "允许放行的端口最终为：$ALLOW_PORTS"

### ------------------------
### 6. 二次确认
### ------------------------
read -p "⚠️ 确认要应用此防火墙规则？ (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "❌ 用户取消"
    exit 1
fi

echo ""
echo "🚧 开始应用规则..."

### ------------------------
### 7. 清空旧规则 / 设置默认策略
### ------------------------
# IPv4
iptables -F
iptables -X
iptables -Z
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# IPv6
ip6tables -F
ip6tables -X
ip6tables -Z
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

### ------------------------
### 8. 基础规则
### ------------------------

# loopback
iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# 保持已建立连接
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

### ------------------------
### 9. 禁用 ICMP（拒绝 ping）
### ------------------------
iptables -A INPUT -p icmp -j DROP
ip6tables -A INPUT -p icmpv6 -j DROP

### ------------------------
### 10. 开放用户端口（TCP/UDP + IPv4/IPv6）
### ------------------------
IFS=',' read -ra PORT_ARRAY <<< "$ALLOW_PORTS"

for port in "${PORT_ARRAY[@]}"; do
    port_trim=$(echo $port | xargs)

    echo "放行端口：$port_trim (TCP/UDP)"
    
    iptables -A INPUT -p tcp --dport "$port_trim" -j ACCEPT
    iptables -A INPUT -p udp --dport "$port_trim" -j ACCEPT

    ip6tables -A INPUT -p tcp --dport "$port_trim" -j ACCEPT
    ip6tables -A INPUT -p udp --dport "$port_trim" -j ACCEPT
done

### ------------------------
### 11. 保存规则（无交互模式）
### ------------------------
if [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

    apt -y install iptables-persistent >/dev/null 2>&1
    netfilter-persistent save

    echo "💾 规则已保存（无交互模式：Debian/Ubuntu）"
elif [[ "$OS" == "centos" ]]; then
    service iptables save
    echo "💾 规则已保存（CentOS）"
else
    echo "⚠️ 未知系统，无法自动保存规则"
fi

### ------------------------
### 12. 完成
### ------------------------
echo ""
echo "✅ 防火墙规则已成功应用！"
echo "🔐 SSH ($SSH_PORT) 已自动放行。"
echo "🛑 Ping (ICMP) 已关闭。"
echo "🔒 所有其它端口默认关闭。"
echo ""
echo "建议：另开一个终端测试 SSH：" 
echo "nc -zv YOUR_IP $SSH_PORT"
echo ""
echo "如需增加/打开新端口，可重新运行此脚本。"
