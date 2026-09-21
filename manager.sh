#!/bin/bash================= 核心配置区 =================PID_FILE="/tmp/.sys_helper.pid"
MEM_FILE="/dev/shm/.sys_cache_buffer"动态计算资源：获取总内存(MB)并计算 18% 的占用量TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
MEM_TARGET_MB=$(awk "BEGIN {printf "%.0f", $TOTAL_MEM * 0.18}")动态计算 CPU 核心数：根据核心数调整计算压力CORES=$(nproc)
if [ "$CORES" -le 1 ]; then
CPU_LOAD_MB=100  # 1核机器每次压缩 100M 数据，避免卡顿
else
CPU_LOAD_MB=300  # 多核机器压缩 300M 数据
fi==============================================颜色设置GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color----------------- 守护进程逻辑 -----------------if [[ "$1" == "--daemon" ]]; then
# 1. 内存保活：根据当前机器总内存的 18% 动态创建虚拟内存文件
if [ ! -f "$MEM_FILE" ]; then
dd if=/dev/zero of="$MEM_FILE" bs=1M count=$MEM_TARGET_MB >/dev/null 2>&1
fi# 2. CPU与网络动态保活 (自适应负载)
while true; do
    # 伪装任务 A：CPU 消耗。动态调整数据大小
    head -c ${CPU_LOAD_MB}M /dev/urandom | gzip > /dev/null 2>&1
    
    # 伪装任务 B：网络消耗。
    curl -sL "https://speed.cloudflare.com/__down?bytes=100000000" > /dev/null 2>&1
    
    # 伪装任务 C：随机休眠 1800 秒 (30 分钟) 到 3600 秒 (60 分钟)
    sleep $((RANDOM % 1800 + 1800))
done
exit 0
fi------------------------------------------------检查服务状态function check_status() {
if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
echo -e "保活脚本状态: ${GREEN}运行中 (Active)${NC} [当前占用: ${MEM_TARGET_MB}MB 内存]"
else
echo -e "保活脚本状态: ${RED}已停止 (Stopped)${NC}"
fi
}评估当前环境function assess_env() {
echo -e "${YELLOW}正在检测系统当前环境... (请稍候几秒)${NC}"# 获取 CPU 和内存利用率 (使用 awk 兼容性更好)
local cpu_idle=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | awk '{print $8}')
# 处理 top 命令输出格式的细微差异，确保获取到数字
if [ -z "$cpu_idle" ]; then
    cpu_idle=$(top -bn2 -d 0.5 | grep "CPU" | tail -n 1 | awk '{print $8}') # 适配部分系统
fi
local cpu_usage=$(awk "BEGIN {print 100 - $cpu_idle}")

local mem_total=$(free -m | awk 'NR==2{print $2}')
local mem_used=$(free -m | awk 'NR==2{print $3}')
local mem_usage=$(awk "BEGIN {printf \"%.2f\", $mem_used * 100 / $mem_total}")

local docker_count=0
if command -v docker &> /dev/null; then
    docker_count=$(docker ps -q | wc -l)
fi

echo "-------------------------------------"
printf "核心数         : %s 核\n" "$CORES"
printf "CPU 当前利用率 : %.2f%%\n" "$cpu_usage"
printf "内存 当前利用率: %s%% (%s MB / %s MB)\n" "$mem_usage" "$mem_used" "$mem_total"
echo "运行中的 Docker 容器数: $docker_count 个"
echo "-------------------------------------"

echo -e "${YELLOW}【系统评估建议】${NC}"
local is_cpu_high=$(awk "BEGIN {print ($cpu_usage > 12.0) ? 1 : 0}")
local is_mem_high=$(awk "BEGIN {print ($mem_usage > 12.0) ? 1 : 0}")

if [ "$is_cpu_high" -eq 1 ] && [ "$is_mem_high" -eq 1 ]; then
    echo -e "${GREEN}结论：当前机器已有充足的业务负载，满足 Oracle >10\% 的要求！${NC}"
    echo "建议：如果该负载是常态，您**不需要**开启本保活脚本。"
else
    echo -e "${RED}结论：当前机器负载偏低（CPU或内存低于安全阈值 12\%）。${NC}"
    echo "建议：为了防止被回收，建议开启保活脚本 (脚本将自动占用 ${MEM_TARGET_MB}MB 内存)。"
fi
echo ""
}启动服务function start_service() {
if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
echo -e "${YELLOW}保活程序已经在运行中了！${NC}"
return
fi
echo "正在启动保活进程 (智能分配中)..."
nohup "$0" --daemon > /dev/null 2>&1 &
echo $! > "$PID_FILE"
echo -e "${GREEN}启动成功！自动占用 ${MEM_TARGET_MB}MB 内存，CPU 压力已自适应调整为 ${CPU_LOAD_MB}M。${NC}"
}停止服务function stop_service() {
if [ -f "$PID_FILE" ]; then
local pid=$(cat "$PID_FILE")
if kill -0 $pid 2>/dev/null; then
kill $pid
echo "已终止后台进程 (PID: $pid)。"
fi
rm -f "$PID_FILE"
fiif [ -f "$MEM_FILE" ]; then
    rm -f "$MEM_FILE"
    echo "已释放占用的虚拟内存。"
fi
echo -e "${GREEN}保活服务已彻底停止！${NC}"
}交互菜单function show_menu() {
clear
echo "="
echo "   Oracle VPS 智能保活面板 (自适应版)    "
echo "="
check_status
echo "="
echo "1. 环境检测与评估 (判断是否需要保活)"
echo "2. 开启保活服务"
echo "3. 关闭保活服务"
echo "4. 查看实时系统资源 (按 'q' 退出)"
echo "0. 退出面板"
echo "="
read -p "请输入选项 [0-4]: " choicecase $choice in
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
        echo "退出面板。后台保活状态不受影响。"
        exit 0
        ;;
    *)
        echo -e "${RED}无效选项，请重新输入。${NC}"
        sleep 1
        show_menu
        ;;
esac
}运行主菜单show_menu
