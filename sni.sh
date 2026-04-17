#!/bin/bash
#
# VLESS SNI 本地服务器发现脚本（增强版）
# - 自动发现 VPS 附近的本地网站作为 SNI 伪装目标
# - 排除 Cloudflare / Fastly / Akamai / CloudFront 等主流 CDN
# - 排除明显 Anycast 边缘节点
# - 自动测速 + 评分 + 生成最优 SNI 列表
# - 额外输出 JSON 结果文件，便于脚本/面板直接调用
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
RESULTS_JSON="sni_test_results_$(date +%Y%m%d_%H%M%S).json"

# CDN IP 段（Cloudflare / Fastly / Akamai / CloudFront）
CDN_RANGES=(
    # Cloudflare
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
    "2400:cb00::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2405:b500::/32"
    "2405:8100::/32"
    "2a06:98c0::/29"
    "2c0f:f248::/32"

    # Fastly
    "151.101.0.0/16"
    "199.232.0.0/16"
    "2a04:4e42::/32"

    # Akamai（示例常见段）
    "23.0.0.0/12"
    "23.32.0.0/11"
    "2a02:26f0::/32"

    # AWS CloudFront（部分常见段）
    "13.32.0.0/15"
    "13.54.63.128/26"
    "13.59.250.0/26"
    "13.113.203.0/24"
    "13.124.199.0/24"
    "13.228.69.0/24"
    "34.195.252.0/24"
    "35.162.63.192/26"
    "52.15.127.128/26"
    "52.46.0.0/18"
    "52.84.0.0/15"
    "52.124.128.0/17"
    "54.182.0.0/16"
    "54.192.0.0/16"
    "54.230.0.0/16"
    "54.239.128.0/18"
    "54.239.192.0/19"
    "2600:9000::/28"
)

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}          VLESS SNI 本地服务器发现工具（增强版）${NC}"
    echo -e "${BLUE}          自动发现 VPS 附近的本地网站作为 SNI 伪装目标${NC}"
    echo -e "${BLUE}          排除主流 CDN + 智能评分 + JSON 输出${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_dependencies() {
    local missing_deps=()

    for cmd in curl jq dig openssl ipcalc sipcalc; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖: ${missing_deps[*]}${NC}"

        if command -v apt-get &> /dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y curl jq dnsutils openssl ipcalc sipcalc 2>/dev/null
        elif command -v yum &> /dev/null; then
            yum install -y curl jq bind-utils openssl ipcalc sipcalc 2>/dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y curl jq bind-utils openssl ipcalc sipcalc 2>/dev/null
        else
            echo -e "${RED}错误: 无法自动安装依赖,请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

get_vps_location() {
    echo -e "${YELLOW}正在获取 VPS 位置信息...${NC}"

    local ipv4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")

    if [ -z "$ipv4" ]; then
        ipv4=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
    fi

    if [ -z "$ipv4" ]; then
        echo -e "${RED}无法获取 IP 地址${NC}"
        return 1
    fi

    VPS_IP="$ipv4"

    local response=$(curl -s --max-time 10 "https://ipapi.co/$VPS_IP/json/" 2>/dev/null)

    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        echo -e "${YELLOW}尝试备用 IP 信息服务...${NC}"
        response=$(curl -s --max-time 10 "http://ip-api.com/json/$VPS_IP" 2>/dev/null)

        if [ -z "$response" ]; then
            echo -e "${RED}无法获取 VPS 位置信息${NC}"
            return 1
        fi

        VPS_COUNTRY=$(echo "$response" | jq -r '.country // "Unknown"')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.countryCode // "US"')
        VPS_CITY=$(echo "$response" | jq -r '.city // "Unknown"')
        VPS_REGION=$(echo "$response" | jq -r '.regionName // "Unknown"')
        VPS_LAT=$(echo "$response" | jq -r '.lat // "0"')
        VPS_LON=$(echo "$response" | jq -r '.lon // "0"')
        VPS_ORG=$(echo "$response" | jq -r '.isp // "Unknown"')
    else
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

calculate_distance() {
    local lat1=$1
    local lon1=$2
    local lat2=$3
    local lon2=$4

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

generate_candidate_domains() {
    local domains=()

    case "$VPS_COUNTRY_CODE" in
        "HK")
            domains+=(
                "hk.yahoo.com"
                "www.scmp.com"
                "www.discuss.com.hk"
                "www.hkgolden.com"
                "lihkg.com"
                "www.mingpao.com"
                "std.stheadline.com"
                "news.now.com"
                "hk01.com"
                "www.hkexnews.hk"
                "www.weather.gov.hk"
                "www.immd.gov.hk"
                "eclass.hkedcity.net"
                "www.hkpl.gov.hk"
            )
            ;;
        "CN")
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
            domains+=(
                "www.yahoo.co.jp"
                "www.rakuten.co.jp"
                "www.dmm.com"
                "www.nicovideo.jp"
                "www.pixiv.net"
                "www.asahi.com"
                "www.nikkei.com"
            )
            ;;
        "KR")
            domains+=(
                "www.naver.com"
                "www.daum.net"
                "www.nate.com"
                "www.gmarket.co.kr"
                "www.coupang.com"
            )
            ;;
        "SG")
            domains+=(
                "www.straitstimes.com"
                "www.channelnewsasia.com"
                "www.todayonline.com"
                "www.hardwarezone.com.sg"
            )
            ;;
        "TW")
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
            domains+=(
                "www.spiegel.de"
                "www.heise.de"
                "www.chip.de"
                "www.otto.de"
                "www.zalando.de"
            )
            ;;
        *)
            domains+=(
                "www.wikipedia.org"
                "www.archive.org"
            )
            ;;
    esac

    domains+=(
        "bunny.net"
        "cdn77.com"
        "www.keycdn.com"
    )

    printf '%s\n' "${domains[@]}" | sort -u
}

# 判断 IP 是否属于主流 CDN
is_cdn_ip() {
    local ip=$1

    for range in "${CDN_RANGES[@]}"; do
        if [[ "$ip" =~ : ]]; then
            if sipcalc "$range" "$ip" 2>/dev/null | grep -q "is in"; then
                return 0
            fi
        else
            if ipcalc -c "$ip" "$range" &>/dev/null; then
                return 0
            fi
        fi
    done

    return 1
}

# 简单 Anycast 检测：不同公共 DNS 解析结果不同则视为 Anycast
is_anycast_domain() {
    local domain=$1

    local ip1=$(dig +short "$domain" A @8.8.8.8 2>/dev/null | head -n1)
    local ip2=$(dig +short "$domain" A @1.1.1.1 2>/dev/null | head -n1)

    if [ -n "$ip1" ] && [ -n "$ip2" ] && [ "$ip1" != "$ip2" ]; then
        echo 1
    else
        echo 0
    fi
}

test_domain() {
    local domain=$1

    # DNS 解析
    local ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -n1)

    if [ -z "$ip" ]; then
        ip=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' | head -n1)
    fi

    if [ -z "$ip" ]; then
        return 1
    fi

    # 排除 CDN
    if is_cdn_ip "$ip"; then
        echo -e "${YELLOW}跳过 $domain (CDN 节点: $ip)${NC}"
        return 1
    fi

    # 排除明显 Anycast
    if [ "$(is_anycast_domain "$domain")" -eq 1 ]; then
        echo -e "${YELLOW}跳过 $domain (疑似 Anycast 边缘节点)${NC}"
        return 1
    fi

    # TCP 443 测试
    local tcp_start=$(date +%s%N)
    if timeout 5 bash -c "exec 3<>/dev/tcp/$domain/443 2>/dev/null" 2>/dev/null; then
        local tcp_end=$(date +%s%N)
        local tcp_latency=$(awk -v start="$tcp_start" -v end="$tcp_end" 'BEGIN {printf "%.1f", (end-start)/1000000}')
        exec 3>&- 2>/dev/null
    else
        return 1
    fi

    # TLS 握手测试（必须是 HTTPS）
    local tls_start=$(date +%s%N)
    local tls_output=$(timeout 7 openssl s_client -connect "$domain:443" -servername "$domain" -brief 2>&1 </dev/null)
    local tls_end=$(date +%s%N)

    if ! echo "$tls_output" | grep -q "Protocol  : TLS"; then
        return 1
    fi
    if echo "$tls_output" | grep -qi "no peer certificate"; then
        return 1
    fi

    local tls_latency=$(awk -v start="$tls_start" -v end="$tls_end" 'BEGIN {printf "%.1f", (end-start)/1000000}')

    # 目标 IP 地理位置
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

    # 评分
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

    echo "$domain|$ip|$distance|$tcp_latency|$tls_latency|$score"
}

test_all_domains() {
    local domains=("$@")
    local total=${#domains[@]}

    echo -e "${YELLOW}开始测试 $total 个候选域名...${NC}"
    echo ""

    local tmp_results
    tmp_results=$(mktemp)

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

        if [ "$(jobs -r | wc -l)" -ge 10 ]; then
            wait -n
        fi
    done

    wait

    if [ -f "$tmp_results" ] && [ -s "$tmp_results" ]; then
        sort -t'|' -k6 -rn "$tmp_results"
        rm -f "$tmp_results"
    else
        rm -f "$tmp_results"
        return 1
    fi
}

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

    local total_count
    total_count=$(echo "$results_data" | wc -l)
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
    echo "4. 已自动排除主流 CDN / Anycast 节点"
    echo "5. 在 VLESS / sing-box 配置中使用: \"sni\": \"选定的域名\""
    echo ""

    echo "推荐配置示例(前 3 个):"
    local count=0
    echo "$results_data" | head -n 3 | while IFS='|' read -r domain ip distance tcp tls score; do
        count=$((count+1))
        echo "  选项 $count: \"sni\": \"$domain\"  (分数: $score, TCP: ${tcp}ms, 距离: ${distance}km)"
    done

    # 生成文本报告
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

    # 生成 JSON 输出（便于脚本/面板直接读取）
    echo "$results_data" | awk -F'|' '
    BEGIN {
        print "{"
    }
    NR==1 {
        printf "  \"vps\": {\n"
        printf "    \"ip\": \"%s\",\n", "'"$VPS_IP"'"
        printf "    \"country\": \"%s\",\n", "'"$VPS_COUNTRY"'"
        printf "    \"country_code\": \"%s\",\n", "'"$VPS_COUNTRY_CODE"'"
        printf "    \"city\": \"%s\",\n", "'"$VPS_CITY"'"
        printf "    \"region\": \"%s\",\n", "'"$VPS_REGION"'"
        printf "    \"org\": \"%s\",\n", "'"$VPS_ORG"'"
        printf "    \"lat\": \"%s\",\n", "'"$VPS_LAT"'"
        printf "    \"lon\": \"%s\"\n", "'"$VPS_LON"'"
        printf "  },\n"
        printf "  \"results\": [\n"
    }
    {
        printf "    {\"domain\": \"%s\", \"ip\": \"%s\", \"distance_km\": \"%s\", \"tcp_ms\": \"%s\", \"tls_ms\": \"%s\", \"score\": \"%s\"}", $1, $2, $3, $4, $5, $6
        if (NR=='"$total_count"') {
            printf "\n"
        } else {
            printf ",\n"
        }
    }
    END {
        print "  ]"
        print "}"
    }' > "$RESULTS_JSON"

    echo ""
    echo -e "${GREEN}详细文本结果已保存到: $RESULTS_FILE${NC}"
    echo -e "${GREEN}JSON 结果已保存到:   $RESULTS_JSON${NC}"
    echo ""
    echo "JSON 中的最优 SNI 列表可直接用于自动生成配置，例如:"
    echo "  jq -r '.results[0:5].domain' \"$RESULTS_JSON\""
}

main() {
    print_header
    check_dependencies

    if ! get_vps_location; then
        exit 1
    fi

    echo -e "${YELLOW}正在生成候选域名列表...${NC}"
    local all_domains=()
    mapfile -t all_domains < <(generate_candidate_domains)

    echo -e "${GREEN}共发现 ${#all_domains[@]} 个候选域名${NC}"
    echo ""

    if [ ${#all_domains[@]} -eq 0 ]; then
        echo -e "${RED}未能生成候选域名${NC}"
        exit 1
    fi

    local test_results
    test_results=$(test_all_domains "${all_domains[@]}")

    generate_report "$test_results"
}

main
