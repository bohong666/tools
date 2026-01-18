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
    
    for cmd in curl jq dig openssl; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖: ${missing_deps[*]}${NC}"
        
        if command -v apt-get &> /dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y curl jq dnsutils openssl 2>/dev/null
        elif command -v yum &> /dev/null; then
            yum install -y curl jq bind-utils openssl 2>/dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y curl jq bind-utils openssl 2>/dev/null
        else
            echo -e "${RED}错误: 无法自动安装依赖,请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

# 获取 VPS 位置信息
get_vps_location() {
    echo -e "${YELLOW}正在获取 VPS 位置信息...${NC}"
    
    # 先获取 IPv4 地址(即使 VPS 是 IPv6)
    local ipv4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    
    if [ -z "$ipv4" ]; then
        # 尝试获取 IPv6
        ipv4=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
    fi
    
    if [ -z "$ipv4" ]; then
        echo -e "${RED}无法获取 IP 地址${NC}"
        return 1
    fi
    
    VPS_IP="$ipv4"
    
    # 获取地理位置信息
    local response=$(curl -s --max-time 10 "https://ipapi.co/$VPS_IP/json/" 2>/dev/null)
    
    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        echo -e "${YELLOW}尝试备用 IP 信息服务...${NC}"
        response=$(curl -s --max-time 10 "http://ip-api.com/json/$VPS_IP" 2>/dev/null)
        
        if [ -z "$response" ]; then
            echo -e "${RED}无法获取 VPS 位置信息${NC}"
            return 1
        fi
        
        # 解析 ip-api.com 格式
        VPS_COUNTRY=$(echo "$response" | jq -r '.country // "Unknown"')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.countryCode // "US"')
        VPS_CITY=$(echo "$response" | jq -r '.city // "Unknown"')
        VPS_REGION=$(echo "$response" | jq -r '.regionName // "Unknown"')
        VPS_LAT=$(echo "$response" | jq -r '.lat // "0"')
        VPS_LON=$(echo "$response" | jq -r '.lon // "0"')
        VPS_ORG=$(echo "$response" | jq -r '.isp // "Unknown"')
    else
        # 解析 ipapi.co 格式
        VPS_COUNTRY=$(echo "$response" | jq -r '.country_name // "Unknown"')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.country_code // "US"')
        VPS_CITY=$(echo "$response" | jq -r '.city // "Unknown"')
        VPS_REGION=$(echo "$response" | jq -r '.region // "Unknown"')
        VPS_LAT=$(echo "$response" | jq -r '.latitude // "0"')
        VPS_LON=$(echo "$response" | jq -r '.longitude // "0"')
        VPS_ORG=$(echo "$response" | jq -r '.org // "Unknown"')
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

# 生成候选域名列表 - 使用真实存在的网站
generate_candidate_domains() {
    local domains=()
    
    # 根据国家/地区添加真实存在的本地网站
    case "$VPS_COUNTRY_CODE" in
        "HK")
            # 香港本地网站
            domains+=(
                "hk.yahoo.com"
                "www.scmp.com"
                "www.discuss.com.hk"
                "www.hkgolden.com"
                "lihkg.com"
                "www.mingpao.com"
                "std.stheadline.com"
                "news.now.com"
                "www.singtao.ca"
                "hk01.com"
                "www.hkexnews.hk"
                "www.weather.gov.hk"
                "www.immd.gov.hk"
                "eclass.hkedcity.net"
                "www.hkpl.gov.hk"
            )
            ;;
        "CN")
            # 中国本地网站(未被墙的)
            domains+=(
                "www.163.com"
                "www.sohu.com"
                "www.sina.com.cn"
                "www.qq.com"
                "www.taobao.com"
                "www.jd.com"
                "www.baidu.com"
                "www.bilibili.com"
                "www.douban.com"
                "www.zhihu.com"
            )
            ;;
        "JP")
            # 日本本地网站
            domains+=(
                "www.yahoo.co.jp"
                "www.rakuten.co.jp"
                "www.dmm.com"
                "www.nicovideo.jp"
                "www.pixiv.net"
                "www.2ch.net"
                "www.asahi.com"
                "www.nikkei.com"
            )
            ;;
        "KR")
            # 韩国本地网站
            domains+=(
                "www.naver.com"
                "www.daum.net"
                "www.nate.com"
                "www.gmarket.co.kr"
                "www.coupang.com"
            )
            ;;
        "SG")
            # 新加坡本地网站
            domains+=(
                "www.straitstimes.com"
                "www.channelnewsasia.com"
                "www.todayonline.com"
                "www.hardwarezone.com.sg"
            )
            ;;
        "TW")
            # 台湾本地网站
            domains+=(
                "www.pchome.com.tw"
                "www.mobile01.com"
                "www.ettoday.net"
                "www.udn.com"
                "www.chinatimes.com"
                "www.ptt.cc"
            )
            ;;
        "US")
            # 美国区域性网站(非大厂)
            domains+=(
                "www.craigslist.org"
                "www.weather.gov"
                "www.yelp.com"
                "www.zillow.com"
                "www.espn.com"
                "www.cnn.com"
                "www.nytimes.com"
            )
            ;;
        "DE")
            # 德国本地网站
            domains+=(
                "www.spiegel.de"
                "www.heise.de"
                "www.chip.de"
                "www.otto.de"
                "www.zalando.de"
            )
            ;;
        *)
            # 通用候选域名
            domains+=(
                "www.wikipedia.org"
                "www.archive.org"
            )
            ;;
    esac
    
    # 添加一些通用 CDN 和云服务(非美国大厂)
    domains+=(
        "bunny.net"
        "cdn77.com"
        "www.keycdn.com"
    )
    
    # 输出唯一域名
    printf '%s\n' "${domains[@]}" | sort -u
}

# 测试单个域名
test_domain() {
    local domain=$1
    
    # DNS 解析(支持 IPv4 和 IPv6)
    local ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -n1)
    
    if [ -z "$ip" ]; then
        # 尝试 IPv6
        ip=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' | head -n1)
    fi
    
    if [ -z "$ip" ]; then
        return 1
    fi
    
    # TCP 连接测试
    local tcp_start=$(date +%s%N)
    if timeout 5 bash -c "exec 3<>/dev/tcp/$domain/443 2>/dev/null" 2>/dev/null; then
        local tcp_end=$(date +%s%N)
        local tcp_latency=$(awk -v start="$tcp_start" -v end="$tcp_end" 'BEGIN {printf "%.1f", (end-start)/1000000}')
        exec 3>&- 2>/dev/null
    else
        return 1
    fi
    
    # TLS 握手测试
    local tls_start=$(date +%s%N)
    local tls_output=$(timeout 5 openssl s_client -connect "$domain:443" -servername "$domain" -brief 2>&1 </dev/null)
    local tls_end=$(date +%s%N)
    
    if ! echo "$tls_output" | grep -q "Verification: OK\|Verification error"; then
        return 1
    fi
    
    local tls_latency=$(awk -v start="$tls_start" -v end="$tls_end" 'BEGIN {printf "%.1f", (end-start)/1000000}')
    
    # 获取目标 IP 的地理位置
    local distance="N/A"
    if [ -n "$VPS_LAT" ] && [ -n "$VPS_LON" ] && [ "$VPS_LAT" != "0" ] && [ "$VPS_LON" != "0" ]; then
        local geo_info=$(curl -s --max-time 3 "https://ipapi.co/$ip/json/" 2>/dev/null)
        if [ -n "$geo_info" ] && ! echo "$geo_info" | grep -q "error"; then
            local target_lat=$(echo "$geo_info" | jq -r '.latitude // empty' 2>/dev/null)
            local target_lon=$(echo "$geo_info" | jq -r '.longitude // empty' 2>/dev/null)
            
            if [ -n "$target_lat" ] && [ -n "$target_lon" ] && [ "$target_lat" != "null" ] && [ "$target_lon" != "null" ]; then
                distance=$(calculate_distance "$VPS_LAT" "$VPS_LON" "$target_lat" "$target_lon" 2>/dev/null || echo "N/A")
            fi
        fi
    fi
    
    # 计算综合分数
    local score=100
    
    if [ "$distance" != "N/A" ]; then
        local distance_penalty=$(awk -v d="$distance" 'BEGIN {
            p = (d/100)*10;
            if (p > 50) p = 50;
            printf "%.1f", p
        }')
        score=$(awk -v s="$score" -v p="$distance_penalty" 'BEGIN {printf "%.1f", s - p}')
    fi
    
    local latency_penalty=$(awk -v t="$tcp_latency" 'BEGIN {
        p = (t/10)*5;
        if (p > 30) p = 30;
        printf "%.1f", p
    }')
    score=$(awk -v s="$score" -v p="$latency_penalty" 'BEGIN {
        result = s - p;
        if (result < 0) result = 0;
        printf "%.1f", result
    }')
    
    # 输出结果
    echo "$domain|$ip|$distance|$tcp_latency|$tls_latency|$score"
}

# 并发测试所有域名
test_all_domains() {
    local domains=("$@")
    local total=${#domains[@]}
    
    echo -e "${YELLOW}开始测试 $total 个候选域名...${NC}"
    echo ""
    
    # 创建临时文件
    local tmp_results=$(mktemp)
    
    # 测试进度
    local completed=0
    
    for domain in "${domains[@]}"; do
        {
            result=$(test_domain "$domain" 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$result" ]; then
                echo "$result" >> "$tmp_results"
                echo -e "${GREEN}✓ $domain${NC}"
            else
                echo -e "${RED}✗ $domain${NC}"
            fi
        } &
        
        # 限制并发数
        if [ $(jobs -r | wc -l) -ge 10 ]; then
            wait -n
        fi
    done
    
    wait
    
    # 读取并排序结果
    if [ -f "$tmp_results" ] && [ -s "$tmp_results" ]; then
        sort -t'|' -k6 -rn "$tmp_results"
        rm -f "$tmp_results"
    else
        rm -f "$tmp_results"
        return 1
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
    
    if [ -z "$results_data" ]; then
        echo ""
        echo -e "${RED}⚠ 未发现可用的域名${NC}"
        echo ""
        echo "可能的原因:"
        echo "1. 网络连接问题"
        echo "2. 防火墙阻止了 HTTPS 连接"
        echo "3. 需要手动添加本地网站"
        return
    fi
    
    local total_count=$(echo "$results_data" | wc -l)
    echo "成功发现可用域名: $total_count 个"
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}TOP 推荐 SNI 域名 (按综合评分排序)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    printf "%-6s %-40s %-12s %-12s %-12s %-8s\n" "排名" "域名" "距离(km)" "TCP(ms)" "TLS(ms)" "分数"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    
    local rank=1
    echo "$results_data" | head -n 20 | while IFS='|' read -r domain ip distance tcp tls score; do
        printf "%-6s %-40s %-12s %-12s %-12s %-8s\n" "$rank" "$domain" "$distance" "$tcp" "$tls" "$score"
        ((rank++))
    done
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                    使用建议${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "1. 优先选择分数 > 80 的域名"
    echo "2. 选择物理距离较近的域名(< 500km 更佳)"
    echo "3. TCP 和 TLS 延迟越低越好(< 50ms 理想)"
    echo "4. 避免选择可能被 GFW 风控的知名国际网站"
    echo "5. 在 VLESS 配置中使用格式: \"sni\": \"选定的域名\""
    echo ""
    
    echo "推荐配置示例(选择前3个):"
    local count=0
    echo "$results_data" | head -n 3 | while IFS='|' read -r domain ip distance tcp tls score; do
        count=$((count+1))
        echo "  选项 $count: \"sni\": \"$domain\"  (分数: $score)"
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
        echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "测试结果:"
        echo ""
        printf "%-40s %-15s %-12s %-12s %-12s %-8s\n" "域名" "IP" "距离(km)" "TCP(ms)" "TLS(ms)" "分数"
        echo "─────────────────────────────────────────────────────────────────────────────────────────────"
        echo "$results_data" | while IFS='|' read -r domain ip distance tcp tls score; do
            printf "%-40s %-15s %-12s %-12s %-12s %-8s\n" "$domain" "$ip" "$distance" "$tcp" "$tls" "$score"
        done
    } > "$RESULTS_FILE"
    
    echo ""
    echo -e "${GREEN}详细结果已保存到: $RESULTS_FILE${NC}"
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
    local all_domains=($(generate_candidate_domains))
    
    echo -e "${GREEN}共发现 ${#all_domains[@]} 个候选域名${NC}"
    echo ""
    
    if [ ${#all_domains[@]} -eq 0 ]; then
        echo -e "${RED}未能生成候选域名${NC}"
        exit 1
    fi
    
    # 测试所有域名
    local test_results=$(test_all_domains "${all_domains[@]}")
    
    # 生成报告
    generate_report "$test_results"
}

# 执行主函数
main
