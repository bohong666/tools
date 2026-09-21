#!/bin/bash

# ================= 核心配置区 =================
PID_FILE="/tmp/.sys_helper.pid"
MEM_FILE="/dev/shm/.sys_cache_buffer"

# 动态计算资源：获取总内存(MB)并计算 18% 的占用量
TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
MEM_TARGET_MB=$(awk -v total="$TOTAL_MEM" 'BEGIN {print int(total * 0.18)}')

# 获取 CPU 核心数，用于动态调整压缩任务大小
CPU_CORES=$(nproc)
if [ "$CPU_CORES" -le 1 ]; then
    COMPRESS_SIZE="100M"
else
    COMPRESS_SIZE="300M"
fi
# ==============================================

# 颜色设置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ----------------- 守护进程逻辑 -----------------
if [[ "$1" == "--daemon" ]]; then
    # 1. 内存保活
    if [ ! -f "$MEM_FILE" ]; then
        dd if=/dev/zero of="$MEM_FILE" bs=1M count="$MEM_TARGET_MB" >/dev/null 2>&1
    fi

    # 2. CPU与网络动态保活
    while true; do
        # 任务 A：CPU 消耗
        head -c "$COMPRESS_SIZE" /dev/urandom | gzip > /dev/null 2>&1
        
        # 任务 B：网络消耗 (1/3 概率)
        if [ $((RANDOM % 3)) -eq 0 ]; then
            curl -sL "https://speed.cloudflare.com/__down?bytes=100000000" > /dev/null 2>&1
        fi
        
        # 任务 C：随机休眠 (1800~3600秒)
        sleep $((RANDOM % 1800 + 1800))
    done
    exit 0
fi
# ------------------------------------------------

function check_status() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo -e "保活脚本状态: ${GREEN}运行中 (Active)${NC}"
    else
        echo -e "保活脚本状态: ${RED}已停止 (Stopped)${NC}"
    fi
}

function assess_env() {
    echo -e "${YELLOW}正在检测系统当前环境... (请稍候几秒)${NC}"
    
    local cpu_idle=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | awk '{print $8}')
    local cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN {print 100 - idle}')
    
    local mem_usage=$(awk -v used="$(free -m | awk 'NR==2{print $3}')" -v total="$TOTAL_MEM" 'BEGIN {printf "%.2f", used * 100 / total}')
    
    local docker_count=0
    if command -v docker &> /dev/null; then
        docker_count=$(docker ps -q | wc -l)
    fi

    echo "-------------------------------------"
    printf "架构/核心数    : %s 核\n" "$CPU_CORES"
    printf "CPU 当前利用率 : %.2f%%\n" "$cpu_usage"
    printf "内存 当前利用率: %s%% (%s MB / %s MB)\n" "$mem_usage" "$(free -m | awk 'NR==2{print $3}')" "$TOTAL_MEM"
    echo "运行中的 Docker 容器数: $docker_count 个"
    echo "-------------------------------------"
    
    echo -e "${YELLOW}【系统评估建议】${NC}"
    if awk 'BEGIN {exit !('"$cpu_usage"' > 12.0 && '"$mem_usage"' > 12.0)}'; then
        echo -e "${GREEN}结论：当前机器已有充足的业务负载，满足 Oracle >10% 的要求！${NC}"
    else
        echo -e "${RED}结论：当前机器负载偏低（CPU或内存低于安全阈值 12%）。${NC}"
    fi
    echo ""
}

function start_service() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo -e "${YELLOW}保活程序已经在运行中了！${NC}"
        return
    fi
    echo "正在启动保活进程..."
    nohup bash "$(readlink -f "$0")" --daemon > /dev/null 2>&1 &
    echo $! > "$PID_FILE"
    echo -e "${GREEN}启动成功！预计占用内存: ${MEM_TARGET_MB} MB。${NC}"
}

function stop_service() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 $pid 2>/dev/null; then
            kill $pid
            echo "已终止后台进程 (PID: $pid)。"
        fi
        rm -f "$PID_FILE"
    fi
    
    if [ -f "$MEM_FILE" ]; then
        rm -f "$MEM_FILE"
        echo "已释放占用的虚拟内存。"
    fi
    echo -e "${GREEN}保活服务已彻底停止！${NC}"
}

function show_menu() {
    clear
    echo "========================================="
    echo "      Oracle VPS 智能自适应保活面板      "
    echo "========================================="
    check_status
    echo "========================================="
    echo "1. 环境检测与评估"
    echo "2. 开启保活服务"
    echo "3. 关闭保活服务"
    echo "4. 查看实时系统资源 (按 'q' 退出)"
    echo "0. 退出面板"
    echo "========================================="
    read -p "请输入选项 [0-4]: " choice
    
    case $choice in
        1)
            echo ""
            assess_env
            read -p "按回车键返回菜单..."
            show_menu
            ;;
        2)
            echo ""
            start_service
            sleep 2
            show_menu
            ;;
        3)
            echo ""
            stop_service
            sleep 2
            show_menu
            ;;
        4)
            top
            show_menu
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${NC}"
            sleep 1
            show_menu
            ;;
    esac
}

show_menu
