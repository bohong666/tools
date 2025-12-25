#!/bin/bash

# ================================================
# 服务器监控系统 - 客户端一键安装脚本 v2
# 修复 Debian 12 pip 安装问题
# ================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
╔════════════════════════════════════════════════╗
║     服务器监控系统 - 客户端一键安装 v2         ║
║     Server Monitor - Client Installer          ║
╚════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        VERSION=$(sw_vers -productVersion)
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 检测到操作系统: $OS $VERSION${NC}"
}

# 检查 Python 环境
check_python() {
    echo -e "\n${YELLOW}→ 检查 Python 环境...${NC}"
    
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
        PYTHON_VERSION=$(python3 --version | awk '{print $2}')
        echo -e "${GREEN}✓ Python 已安装: $PYTHON_VERSION${NC}"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
        PYTHON_VERSION=$(python --version | awk '{print $2}')
        echo -e "${GREEN}✓ Python 已安装: $PYTHON_VERSION${NC}"
    else
        echo -e "${YELLOW}! 未检测到 Python，正在安装...${NC}"
        install_python
    fi
}

# 安装 Python
install_python() {
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pip python3-dev build-essential
        PYTHON_CMD="python3"
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        sudo yum install -y python3 python3-pip python3-devel gcc
        PYTHON_CMD="python3"
    elif [[ "$OS" == "macos" ]]; then
        brew install python3
        PYTHON_CMD="python3"
    fi
    echo -e "${GREEN}✓ Python 安装完成${NC}"
}

# 安装依赖包
install_dependencies() {
    echo -e "\n${YELLOW}→ 安装 Python 依赖...${NC}"
    
    # 检查并安装 pip
    if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
        echo -e "${YELLOW}! 未找到 pip，正在安装...${NC}"
        
        if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
            sudo apt-get update -qq
            sudo apt-get install -y python3-pip python3-dev build-essential
        elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
            sudo yum install -y python3-pip python3-devel gcc
        elif [[ "$OS" == "macos" ]]; then
            $PYTHON_CMD -m ensurepip --upgrade
        fi
        
        if ! command -v pip3 &> /dev/null && ! command -v pip &> /dev/null; then
            echo -e "${RED}✗ pip 安装失败${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ pip 安装完成${NC}"
    fi
    
    # 确定 pip 命令
    if command -v pip3 &> /dev/null; then
        PIP_CMD="pip3"
    elif command -v pip &> /dev/null; then
        PIP_CMD="pip"
    fi
    
    echo -e "${YELLOW}→ 升级 pip...${NC}"
    $PIP_CMD install --upgrade pip --break-system-packages 2>/dev/null || \
    $PIP_CMD install --upgrade pip 2>/dev/null || \
    $PYTHON_CMD -m pip install --upgrade pip 2>/dev/null || true
    
    echo -e "${YELLOW}→ 安装 psutil 和 requests...${NC}"
    
    # 尝试多种安装方式
    if $PIP_CMD install psutil requests --break-system-packages 2>/dev/null; then
        echo -e "${GREEN}✓ 依赖安装完成 (使用 --break-system-packages)${NC}"
    elif $PIP_CMD install psutil requests 2>/dev/null; then
        echo -e "${GREEN}✓ 依赖安装完成${NC}"
    elif $PYTHON_CMD -m pip install psutil requests --break-system-packages 2>/dev/null; then
        echo -e "${GREEN}✓ 依赖安装完成 (使用 python -m pip)${NC}"
    elif sudo apt-get install -y python3-psutil python3-requests 2>/dev/null; then
        echo -e "${GREEN}✓ 依赖安装完成 (使用系统包管理器)${NC}"
    else
        echo -e "${RED}✗ 依赖安装失败${NC}"
        echo -e "${YELLOW}尝试手动安装: pip3 install --break-system-packages psutil requests${NC}"
        exit 1
    fi
}

# 获取用户配置
get_user_config() {
    echo -e "\n${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}            配置客户端信息              ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}\n"
    
    # 服务端地址
    echo -e "${YELLOW}请输入服务端地址 (例: http://192.168.1.100:3000):${NC}"
    read -p "服务端地址: " SERVER_URL
    
    if [ -z "$SERVER_URL" ]; then
        echo -e "${RED}✗ 服务端地址不能为空${NC}"
        exit 1
    fi
    
    # 服务器名称
    echo -e "\n${YELLOW}请输入服务器名称 (例: MyServer-01):${NC}"
    read -p "服务器名称: " SERVER_NAME
    
    if [ -z "$SERVER_NAME" ]; then
        SERVER_NAME=$(hostname)
        echo -e "${GREEN}→ 使用主机名作为服务器名称: $SERVER_NAME${NC}"
    fi
    
    # 商家名称
    echo -e "\n${YELLOW}请输入商家名称 (例: Vultr, 可选，直接回车跳过):${NC}"
    read -p "商家名称: " MERCHANT
    
    # 国家代码
    echo -e "\n${YELLOW}请输入国家代码 (例: US, CN, JP, HK, 默认: US):${NC}"
    read -p "国家代码: " COUNTRY
    COUNTRY=${COUNTRY:-US}
    
    # 操作系统
    echo -e "\n${YELLOW}检测操作系统类型...${NC}"
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]] || [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        OS_TYPE="linux"
    elif [[ "$OS" == "macos" ]]; then
        OS_TYPE="macos"
    else
        OS_TYPE="linux"
    fi
    echo -e "${GREEN}→ 操作系统: $OS_TYPE${NC}"
    
    # 价格
    echo -e "\n${YELLOW}请输入价格 (例: ¥50/月, 可选，直接回车跳过):${NC}"
    read -p "价格: " PRICE
    
    # 博客链接
    echo -e "\n${YELLOW}请输入博客链接 (可选，直接回车跳过):${NC}"
    read -p "博客链接: " BLOG_LINK
    
    # 采集间隔
    echo -e "\n${YELLOW}请输入采集间隔（秒，默认: 60，建议 30-120）:${NC}"
    read -p "采集间隔: " INTERVAL
    INTERVAL=${INTERVAL:-60}
    
    echo -e "\n${GREEN}✓ 配置信息收集完成${NC}"
}

# 注册服务器
register_server() {
    echo -e "\n${YELLOW}→ 正在向服务端注册...${NC}"
    
    REGISTER_DATA=$(cat <<REGISTER_EOF
{
  "name": "$SERVER_NAME",
  "merchant": "$MERCHANT",
  "country": "$COUNTRY",
  "os": "$OS_TYPE",
  "price": "$PRICE",
  "blog_link": "$BLOG_LINK"
}
REGISTER_EOF
)
    
    echo -e "${YELLOW}→ 连接到: $SERVER_URL/api/register${NC}"
    
    REGISTER_RESPONSE=$(curl -s -X POST "$SERVER_URL/api/register" \
        -H "Content-Type: application/json" \
        -d "$REGISTER_DATA" 2>&1)
    
    TOKEN=$(echo $REGISTER_RESPONSE | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}✗ 注册失败${NC}"
        echo -e "${RED}错误信息: $REGISTER_RESPONSE${NC}"
        echo -e "${YELLOW}请检查:${NC}"
        echo -e "${YELLOW}1. 服务端地址是否正确${NC}"
        echo -e "${YELLOW}2. 服务端是否正在运行${NC}"
        echo -e "${YELLOW}3. 网络是否连通: ping $(echo $SERVER_URL | sed 's|http://||' | sed 's|:.*||')${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 注册成功${NC}"
    echo -e "${GREEN}✓ Token: ${TOKEN:0:16}...${NC}"
}

# 创建监控客户端
create_client_script() {
    echo -e "\n${YELLOW}→ 创建客户端脚本...${NC}"
    
    INSTALL_DIR="/opt/server-monitor-client"
    sudo mkdir -p $INSTALL_DIR
    
    cat | sudo tee $INSTALL_DIR/monitor_client.py > /dev/null << 'CLIENT_EOF'
#!/usr/bin/env python3
import psutil
import platform
import socket
import time
import json
import requests
import subprocess
import os
from datetime import datetime

class ServerMonitorClient:
    def __init__(self, server_url, token, server_name):
        self.server_url = server_url.rstrip('/')
        self.token = token
        self.server_name = server_name
        self.last_network_io = None
        self.last_check_time = None
        
    def get_cpu_info(self):
        cpu_percent = psutil.cpu_percent(interval=1)
        cpu_count = psutil.cpu_count(logical=True)
        return {'cores': cpu_count, 'usage': round(cpu_percent, 2)}
    
    def get_memory_info(self):
        mem = psutil.virtual_memory()
        return {
            'total': round(mem.total / (1024**3), 2),
            'used': round(mem.used / (1024**3), 2),
            'percent': round(mem.percent, 2)
        }
    
    def get_disk_info(self):
        disk = psutil.disk_usage('/')
        return {
            'total': round(disk.total / (1024**3), 2),
            'used': round(disk.used / (1024**3), 2),
            'percent': round(disk.percent, 2)
        }
    
    def get_network_info(self):
        net_io = psutil.net_io_counters()
        current_time = time.time()
        
        total_sent = round(net_io.bytes_sent / (1024**4), 2)
        total_recv = round(net_io.bytes_recv / (1024**4), 2)
        
        upload_speed = 0
        download_speed = 0
        
        if self.last_network_io and self.last_check_time:
            time_diff = current_time - self.last_check_time
            if time_diff > 0:
                upload_speed = round((net_io.bytes_sent - self.last_network_io.bytes_sent) / time_diff / (1024**2), 2)
                download_speed = round((net_io.bytes_recv - self.last_network_io.bytes_recv) / time_diff / (1024**2), 2)
        
        self.last_network_io = net_io
        self.last_check_time = current_time
        
        return {
            'total_sent': total_sent,
            'total_recv': total_recv,
            'upload_speed': max(0, upload_speed),
            'download_speed': max(0, download_speed)
        }
    
    def get_uptime(self):
        boot_time = psutil.boot_time()
        uptime_seconds = time.time() - boot_time
        total_seconds = 30 * 24 * 60 * 60
        uptime_percent = min(100, (uptime_seconds / total_seconds) * 100)
        return round(uptime_percent, 2)
    
    def ping_test(self, host, count=4):
        try:
            param = '-n' if platform.system().lower() == 'windows' else '-c'
            command = ['ping', param, str(count), host]
            output = subprocess.check_output(command, stderr=subprocess.STDOUT, 
                                           universal_newlines=True, timeout=10)
            
            if platform.system().lower() == 'windows':
                if 'Average' in output:
                    avg_line = [line for line in output.split('\n') if 'Average' in line][0]
                    return int(avg_line.split('=')[-1].strip().replace('ms', ''))
            else:
                if 'avg' in output:
                    avg_line = [line for line in output.split('\n') if 'avg' in line][0]
                    return int(float(avg_line.split('=')[1].split('/')[1]))
            return 0
        except:
            return 0
    
    def get_network_delays(self):
        print("正在测试三网延迟...")
        delays = {
            'ct': self.ping_test('www.189.cn'),      # 电信
            'cu': self.ping_test('www.10010.com'),   # 联通
            'cm': self.ping_test('www.10086.cn')     # 移动
        }
        print(f"延迟结果: 电信={delays['ct']}ms, 联通={delays['cu']}ms, 移动={delays['cm']}ms")
        
        # 如果移动失败，尝试备用地址
        if delays['cm'] == 0:
            print("移动延迟检测失败，尝试备用地址...")
            delays['cm'] = self.ping_test('www.cmcc.com')
            if delays['cm'] == 0:
                delays['cm'] = self.ping_test('8.8.8.8')  # 最后尝试Google DNS
        
        return delays
    
    def collect_all_metrics(self):
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] 正在采集数据...")
        return {
            'timestamp': datetime.now().isoformat(),
            'server_name': self.server_name,
            'cpu': self.get_cpu_info(),
            'memory': self.get_memory_info(),
            'disk': self.get_disk_info(),
            'network': self.get_network_info(),
            'uptime': self.get_uptime(),
            'delays': self.get_network_delays()
        }
    
    def send_metrics(self, metrics):
        try:
            headers = {
                'Content-Type': 'application/json',
                'Authorization': f'Bearer {self.token}'
            }
            response = requests.post(
                f'{self.server_url}/api/metrics',
                json=metrics,
                headers=headers,
                timeout=10
            )
            if response.status_code == 200:
                print(f"✓ 数据上报成功")
                return True
            else:
                print(f"✗ 上报失败: {response.status_code}")
                return False
        except Exception as e:
            print(f"✗ 发送错误: {e}")
            return False
    
    def run(self, interval=60):
        print(f"启动监控客户端...")
        print(f"服务端: {self.server_url}")
        print(f"名称: {self.server_name}")
        print(f"采集间隔: {interval}秒")
        print("-" * 50)
        
        self.get_network_info()
        time.sleep(2)
        
        while True:
            try:
                metrics = self.collect_all_metrics()
                self.send_metrics(metrics)
                time.sleep(interval)
            except KeyboardInterrupt:
                print("\n\n停止监控客户端...")
                break
            except Exception as e:
                print(f"错误: {e}")
                time.sleep(interval)

if __name__ == '__main__':
    SERVER_URL = os.getenv('MONITOR_SERVER_URL', '')
    TOKEN = os.getenv('MONITOR_TOKEN', '')
    SERVER_NAME = os.getenv('MONITOR_SERVER_NAME', socket.gethostname())
    INTERVAL = int(os.getenv('MONITOR_INTERVAL', '60'))
    
    if not SERVER_URL or not TOKEN:
        print("错误: 缺少必要的配置")
        exit(1)
    
    client = ServerMonitorClient(SERVER_URL, TOKEN, SERVER_NAME)
    client.run(interval=INTERVAL)
CLIENT_EOF

    sudo chmod +x $INSTALL_DIR/monitor_client.py
    echo -e "${GREEN}✓ 客户端脚本创建完成${NC}"
}

# 创建配置文件
create_config_file() {
    echo -e "\n${YELLOW}→ 创建配置文件...${NC}"
    
    cat | sudo tee $INSTALL_DIR/config.env > /dev/null << CONFIG_EOF
MONITOR_SERVER_URL=$SERVER_URL
MONITOR_TOKEN=$TOKEN
MONITOR_SERVER_NAME=$SERVER_NAME
MONITOR_INTERVAL=$INTERVAL
CONFIG_EOF

    echo -e "${GREEN}✓ 配置文件创建完成${NC}"
}

# 创建 systemd 服务
create_systemd_service() {
    echo -e "\n${YELLOW}→ 创建系统服务...${NC}"
    
    cat | sudo tee /etc/systemd/system/monitor-client.service > /dev/null << SERVICE_EOF
[Unit]
Description=Server Monitor Client
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/config.env
ExecStart=$PYTHON_CMD $INSTALL_DIR/monitor_client.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    sudo systemctl daemon-reload
    sudo systemctl enable monitor-client
    echo -e "${GREEN}✓ 系统服务创建完成${NC}"
}

# 启动服务
start_service() {
    echo -e "\n${YELLOW}→ 启动监控客户端...${NC}"
    sudo systemctl start monitor-client
    sleep 3
    
    if sudo systemctl is-active --quiet monitor-client; then
        echo -e "${GREEN}✓ 客户端启动成功${NC}"
    else
        echo -e "${RED}✗ 客户端启动失败${NC}"
        echo -e "${YELLOW}查看日志: journalctl -u monitor-client -n 50${NC}"
        exit 1
    fi
}

# 显示完成信息
show_completion() {
    echo -e "\n${GREEN}"
    cat << EOF
╔════════════════════════════════════════════════╗
║              🎉 安装完成！                     ║
╠════════════════════════════════════════════════╣
║                                                ║
║  ✅ 客户端已成功安装并启动                     ║
║                                                ║
║  📋 管理命令:                                  ║
║     systemctl start monitor-client            ║
║     systemctl stop monitor-client             ║
║     systemctl status monitor-client           ║
║     journalctl -u monitor-client -f           ║
║                                                ║
║  📝 配置信息:                                  ║
║     服务端: $SERVER_URL
║     服务器名: $SERVER_NAME
║     Token: ${TOKEN:0:16}...
║     间隔: ${INTERVAL}秒
║                                                ║
║  🌐 现在访问 Web 面板查看监控数据！            ║
║                                                ║
╚════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# 主流程
main() {
    detect_os
    check_python
    install_dependencies
    get_user_config
    register_server
    create_client_script
    create_config_file
    create_systemd_service
    start_service
    show_completion
}

main
