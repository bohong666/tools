#!/bin/bash
#
# VLESS SNI 本地服务器发现脚本
# 自动发现 VPS 附近的本地网站作为 SNI 伪装目标
#
# 使用方法:
# bash <(curl -fsSL https://your-url/sni-finder.sh)
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
VPS_IP=""
VPS_COUNTRY=""
VPS_COUNTRY_CODE=""
VPS_CITY=""
VPS_REGION=""
VPS_LAT=""
VPS_LON=""
VPS_ORG=""
RESULTS_FILE="sni_test_results_$(date +%Y%m%d_%H%M%S).txt"
JSON_FILE="sni_test_results_$(date +%Y%m%d_%H%M%S).json"

# 打印标题
print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          VLESS SNI 本地服务器发现工具${NC}"
    echo -e "${BLUE}          自动发现 VPS 附近的本地网站作为 SNI 伪装目标${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq dig ping nc; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖: ${missing_deps[*]}${NC}"
        
        if command -v apt-get &> /dev/null; then
            apt-get update -qq
            apt-get install -y curl jq dnsutils iputils-ping netcat-openbsd 2>/dev/null || \
            apt-get install -y curl jq dnsutils iputils-ping netcat 2>/dev/null
        elif command -v yum &> /dev/null; then
            yum install -y curl jq bind-utils iputils nc 2>/dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y curl jq bind-utils iputils nc 2>/dev/null
        else
            echo -e "${RED}错误: 无法自动安装依赖,请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

# 获取 VPS 位置信息
get_vps_location() {
    echo -e "${YELLOW}正在获取 VPS 位置信息...${NC}"
    
    local response=$(curl -s --max-time 10 https://ipapi.co/json/)
    
    if [ -z "$response" ]; then
        echo -e "${RED}无法获取 VPS 信息,尝试备用服务...${NC}"
        response=$(curl -s --max-time 10 http://ip-api.com/json/)
        
        if [ -z "$response" ]; then
            echo -e "${RED}无法获取 VPS 位置信息${NC}"
            return 1
        fi
        
        # 解析 ip-api.com 格式
        VPS_IP=$(echo "$response" | jq -r '.query // empty')
        VPS_COUNTRY=$(echo "$response" | jq -r '.country // empty')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.countryCode // empty')
        VPS_CITY=$(echo "$response" | jq -r '.city // empty')
        VPS_REGION=$(echo "$response" | jq -r '.regionName // empty')
        VPS_LAT=$(echo "$response" | jq -r '.lat // empty')
        VPS_LON=$(echo "$response" | jq -r '.lon // empty')
        VPS_ORG=$(echo "$response" | jq -r '.isp // empty')
    else
        # 解析 ipapi.co 格式
        VPS_IP=$(echo "$response" | jq -r '.ip // empty')
        VPS_COUNTRY=$(echo "$response" | jq -r '.country_name // empty')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.country_code // empty')
        VPS_CITY=$(echo "$response" | jq -r '.city // empty')
        VPS_REGION=$(echo "$response" | jq -r '.region // empty')
        VPS_LAT=$(echo "$response" | jq -r '.latitude // empty')
        VPS_LON=$(echo "$response" | jq -r '.longitude // empty')
        VPS_ORG=$(echo "$response" | jq -r '.org // empty')
    fi
    
    echo -e "${GREEN}VPS 位置: $VPS_CITY, $VPS_REGION, $VPS_COUNTRY${NC}"
    echo -e "${GREEN}VPS IP: $VPS_IP${NC}"
    echo -e "${GREEN}运营商: $VPS_ORG${NC}"
    echo ""
    
    return 0
}

# 计算两点间距离(公里) - 使用 Haversine 公式
calculate_distance() {
    local lat1=$1
    local lon1=$2
    local lat2=$3
    local lon2=$4
    
    # 使用 awk 进行浮点数计算
    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" 'BEGIN {
        pi = 3.14159265358979323846
        R = 6371
        
        lat1_rad = lat1 * pi / 180
        lat2_rad = lat2 * pi / 180
        delta_lat = (lat2 - lat1) * pi / 180
        delta_lon = (lon2 - lon1) * pi / 180
        
        a = sin(delta_lat/2) * sin(delta_lat/2) + cos(lat1_rad) * cos(lat2_rad) * sin(delta_lon/2) * sin(delta_lon/2)
        c = 2 * atan2(sqrt(a), sqrt(1-a))
        
        distance = R * c
        printf "%.0f", distance
    }'
}

# 生成候选域名列表
generate_candidate_domains() {
    local domains=()
    
    # 基于国家代码的 TLD
    declare -A country_tlds=(
        ["US"]="com us net org"
        ["CN"]="cn com.cn net.cn"
        ["JP"]="jp co.jp ne.jp or.jp"
        ["KR"]="kr co.kr or.kr"
        ["SG"]="sg com.sg"
        ["HK"]="hk com.hk"
        ["TW"]="tw com.tw"
        ["DE"]="de com"
        ["GB"]="uk co.uk org.uk"
        ["FR"]="fr com"
        ["NL"]="nl"
        ["RU"]="ru"
        ["BR"]="br com.br"
        ["AU"]="au com.au"
        ["IN"]="in co.in"
        ["CA"]="ca"
        ["IT"]="it"
        ["ES"]="es"
    )
    
    # 常见服务前缀
    local prefixes="cdn cache static assets api data storage file cloud server host web media images news blog"
    
    # 获取当前国家的 TLD
    local tlds=${country_tlds[$VPS_COUNTRY_CODE]:-"com net org"}
    
    # 生成域名组合
    for tld in $tlds; do
        for prefix in $prefixes; do
            domains+=("$prefix.$tld")
        done
    done
    
    # 添加区域性知名服务(非国际大厂)
    case "$VPS_COUNTRY_CODE" in
        "CN")
            domains+=("staticfile.org" "bootcdn.cn" "cdn.baomitu.com" "staticdn.net")
            ;;
        "JP")
            domains+=("sakura.ne.jp" "xserver.jp" "coreserver.jp")
            ;;
        "KR")
            domains+=("gabia.com" "cafe24.com")
            ;;
        "SG")
            domains+=("cdn.sg" "sgp.digitalocean.com")
            ;;
        "DE")
            domains+=("hetzner.com" "contabo.com" "netcup.de")
            ;;
        "US")
            domains+=("bunny.net" "cdn77.com" "stackpath.com")
            ;;
        "HK")
            domains+=("hkix.net" "pccw.com")
            ;;
    esac
    
    # 输出唯一域名
    printf '%s\n' "${domains[@]}" | sort -u
}

# 扫描同 IP 段的域名
scan_nearby_ips() {
    echo -e "${YELLOW}正在扫描同 IP 段的邻近服务器...${NC}"
    
    local ip_prefix=$(echo "$VPS_IP" | cut -d. -f1-3)
    local found_domains=()
    
    # 扫描部分 IP
    for i in 1 2 5 10 20 50 100 150 200 250 254; do
        local test_ip="$ip_prefix.$i"
        
        # 反向 DNS 查询
        local hostname=$(dig +short -x "$test_ip" 2>/dev/null | head -n1 | sed 's/\.$//')
        
        if [ -n "$hostname" ] && [[ ! "$hostname" =~ in-addr.arpa$ ]]; then
            echo -e "  ${GREEN}发现: $hostname ($test_ip)${NC}"
            found_domains+=("$hostname")
        fi
    done &
    
    wait
    
    printf '%s\n' "${found_domains[@]}"
}

# 测试单个域名
test_domain() {
    local domain=$1
    local result_line=""
    
    # DNS 解析
    local ip=$(dig +short "$domain" A 2>/dev/null | head -n1)
    
    if [ -z "$ip" ]; then
        return 1
    fi
    
    # TCP 连接测试
    local tcp_start=$(date +%s.%N)
    if timeout 3 bash -c "echo > /dev/tcp/$domain/443" 2>/dev/null; then
        local tcp_end=$(date +%s.%N)
        local tcp_latency=$(awk -v start="$tcp_start" -v end="$tcp_end" 'BEGIN {printf "%.1f", (end-start)*1000}')
    else
        return 1
    fi
    
    # TLS 握手测试
    local tls_start=$(date +%s.%N)
    local tls_info=$(echo | timeout 3 openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null)
    local tls_end=$(date +%s.%N)
    
    if [ -z "$tls_info" ]; then
        return 1
    fi
    
    local tls_latency=$(awk -v start="$tls_start" -v end="$tls_end" 'BEGIN {printf "%.1f", (end-start)*1000}')
    
    # 获取证书信息
    local cert_issuer=$(echo "$tls_info" | grep "issuer=" | head -n1 | sed 's/.*O = //' | cut -d',' -f1)
    
    # 获取目标 IP 的地理位置
    local distance="N/A"
    if [ -n "$VPS_LAT" ] && [ -n "$VPS_LON" ]; then
        local geo_info=$(curl -s --max-time 3 "https://ipapi.co/$ip/json/" 2>/dev/null)
        if [ -n "$geo_info" ]; then
            local target_lat=$(echo "$geo_info" | jq -r '.latitude // empty')
            local target_lon=$(echo "$geo_info" | jq -r '.longitude // empty')
            
            if [ -n "$target_lat" ] && [ -n "$target_lon" ]; then
                distance=$(calculate_distance "$VPS_LAT" "$VPS_LON" "$target_lat" "$target_lon")
            fi
        fi
    fi
    
    # 计算综合分数
    local score=100
    
    if [ "$distance" != "N/A" ]; then
        local distance_penalty=$(awk -v d="$distance" 'BEGIN {printf "%.1f", (d/100)*10}')
        score=$(awk -v s="$score" -v p="$distance_penalty" 'BEGIN {
            result = s - p;
            if (result < 50) result = 50;
            printf "%.1f", result
        }')
    fi
    
    local latency_penalty=$(awk -v t="$tcp_latency" 'BEGIN {printf "%.1f", (t/10)*5}')
    score=$(awk -v s="$score" -v p="$latency_penalty" 'BEGIN {
        result = s - p;
        if (result < 0) result = 0;
        printf "%.1f", result
    }')
    
    # 输出结果
    echo "$domain|$ip|$distance|$tcp_latency|$tls_latency|$cert_issuer|$score"
}

# 并发测试所有域名
test_all_domains() {
    local domains=("$@")
    local total=${#domains[@]}
    local completed=0
    local success_count=0
    
    echo -e "${YELLOW}开始测试 $total 个候选域名...${NC}"
    echo ""
    
    # 创建临时文件
    local tmp_results=$(mktemp)
    
    # 并发测试(最多20个并发)
    local max_jobs=20
    local job_count=0
    
    for domain in "${domains[@]}"; do
        (
            result=$(test_domain "$domain")
            if [ $? -eq 0 ]; then
                echo "$result" >> "$tmp_results"
                echo -e "${GREEN}✓ $domain${NC}"
            else
                echo -e "${RED}✗ $domain${NC}"
            fi
        ) &
        
        ((job_count++))
        
        if [ $job_count -ge $max_jobs ]; then
            wait -n
            ((job_count--))
        fi
    done
    
    wait
    
    # 读取并排序结果
    if [ -f "$tmp_results" ]; then
        sort -t'|' -k7 -rn "$tmp_results"
        rm -f "$tmp_results"
    fi
}

# 生成报告
generate_report() {
    local results_data="$1"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                    测试报告${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo "VPS 位置: $VPS_CITY, $VPS_REGION, $VPS_COUNTRY"
    echo "VPS IP: $VPS_IP"
    echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    local total_count=$(echo "$results_data" | wc -l)
    echo "成功发现可用域名: $total_count 个"
    
    if [ -z "$results_data" ]; then
        echo ""
        echo -e "${RED}⚠ 未发现可用的本地域名${NC}"
        echo ""
        echo "建议:"
        echo "1. 手动添加已知的本地网站域名"
        echo "2. 检查网络连接"
        echo "3. 尝试使用区域性 CDN 服务"
        return
    fi
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}TOP 推荐 SNI 域名 (按综合评分排序)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    printf "%-6s %-35s %-12s %-12s %-12s %-8s\n" "排名" "域名" "距离(km)" "TCP(ms)" "TLS(ms)" "分数"
    echo "───────────────────────────────────────────────────────────────────────────────"
    
    local rank=1
    echo "$results_data" | head -n 20 | while IFS='|' read -r domain ip distance tcp tls issuer score; do
        printf "%-6s %-35s %-12s %-12s %-12s %-8s\n" "$rank" "$domain" "$distance" "$tcp" "$tls" "$score"
        ((rank++))
    done
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                    使用建议${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1. 优先选择物理距离 < 500km 的域名"
    echo "2. 选择 TCP 和 TLS 延迟都较低的域名"
    echo "3. 避免选择知名国际网站"
    echo "4. 建议选择本地 CDN、云服务商或区域性服务"
    echo "5. 在 VLESS 配置中使用: \"sni\": \"选定的域名\""
    echo "6. 定期重新测试,因为服务器状态会变化"
    echo ""
    
    echo "推荐配置示例:"
    echo "$results_data" | head -n 3 | while IFS='|' read -r domain ip distance tcp tls issuer score; do
        echo "  \"sni\": \"$domain\""
    done
    
    # 保存到文件
    {
        echo "VLESS SNI 测试报告"
        echo "=================="
        echo ""
        echo "VPS 信息:"
        echo "  位置: $VPS_CITY, $VPS_REGION, $VPS_COUNTRY"
        echo "  IP: $VPS_IP"
        echo "  运营商: $VPS_ORG"
        echo ""
        echo "测试结果:"
        echo ""
        printf "%-35s %-15s %-12s %-12s %-12s %-8s\n" "域名" "IP" "距离(km)" "TCP(ms)" "TLS(ms)" "分数"
        echo "──────────────────────────────────────────────────────────────────────────────────────────"
        echo "$results_data" | while IFS='|' read -r domain ip distance tcp tls issuer score; do
            printf "%-35s %-15s %-12s %-12s %-12s %-8s\n" "$domain" "$ip" "$distance" "$tcp" "$tls" "$score"
        done
    } > "$RESULTS_FILE"
    
    echo ""
    echo -e "${GREEN}结果已保存到: $RESULTS_FILE${NC}"
}

# 主函数
main() {
    print_header
    
    # 检查依赖
    check_dependencies
    
    # 获取 VPS 位置
    if ! get_vps_location; then
        exit 1
    fi
    
    # 生成候选域名
    echo -e "${YELLOW}正在生成候选域名列表...${NC}"
    local candidate_domains=($(generate_candidate_domains))
    
    # 扫描同 IP 段域名
    local nearby_domains=($(scan_nearby_ips))
    
    # 合并所有域名
    local all_domains=($(printf '%s\n' "${candidate_domains[@]}" "${nearby_domains[@]}" | sort -u))
    
    echo -e "${GREEN}共发现 ${#all_domains[@]} 个候选域名${NC}"
    echo ""
    
    if [ ${#all_domains[@]} -eq 0 ]; then
        echo -e "${RED}未能发现候选域名${NC}"
        exit 1
    fi
    
    # 测试所有域名
    local test_results=$(test_all_domains "${all_domains[@]}")
    
    # 生成报告
    generate_report "$test_results"
}

# 执行主函数
main
