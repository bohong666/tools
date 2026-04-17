#!/bin/bash
#
# VLESS SNI 本地服务器发现脚本（增强版）
# - 自动发现 VPS 附近的本地网站作为 SNI 伪装目标
# - 排除 Cloudflare / Fastly / Akamai / CloudFront 等主流 CDN
# - 简单排除 Anycast 边缘节点
# - 自动测速 + 评分 + 文本报告 + JSON 输出
#

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

    # Akamai（常见段）
    "23.0.0.0/12"
    "23.32.0.0/11"
    "2a02:26f0::/32"

    # AWS CloudFront（常见段）
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
    echo -e "${BLUE}          排除主流 CDN + 智能评分 + JSON 输出${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_dependencies() {
    local missing_deps=()

    for cmd in curl jq dig openssl ipcalc sipcalc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}正在安装缺失的依赖: ${missing_deps[*]}${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq 2>/dev/null
            apt-get install -y curl jq dnsutils openssl ipcalc sipcalc 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y curl jq bind-utils openssl ipcalc sipcalc 2>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y curl jq bind-utils openssl ipcalc sipcalc 2>/dev/null
        else
            echo -e "${RED}错误: 无法自动安装依赖,请手动安装: ${missing_deps[*]}${NC}"
            exit 1
        fi
    fi
}

get_vps_location() {
    echo -e "${YELLOW}正在获取 VPS 位置信息...${NC}"

    VPS_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || curl -6 -s --max-time 5 https://api64.ipify.org || echo "")
    if [ -z "$VPS_IP" ]; then
        echo -e "${RED}无法获取 VPS 公网 IP${NC}"
        VPS_IP="0.0.0.0"
    fi

    local apis=(
        "https://ipapi.co/$VPS_IP/json/"
        "http://ip-api.com/json/$VPS_IP"
        "https://freeipapi.com/api/json/$VPS_IP"
    )

    local response=""
    local api_ok=0

    for api in "${apis[@]}"; do
        response=$(curl -s --max-time 5 "$api" || echo "")
        if [ -n "$response" ] && echo "$response" | jq empty >/dev/null 2>&1; then
            api_ok=1
            break
        fi
    done

    if [ $api_ok -eq 0 ]; then
        echo -e "${RED}所有 IP API 均不可用，使用默认值继续${NC}"
        VPS_COUNTRY="Unknown"
        VPS_COUNTRY_CODE="US"
        VPS_CITY="Unknown"
        VPS_REGION="Unknown"
        VPS_LAT="0"
        VPS_LON="0"
        VPS_ORG="Unknown"
    else
        VPS_COUNTRY=$(echo "$response" | jq -r '.country_name // .country // "Unknown"')
        VPS_COUNTRY_CODE=$(echo "$response" | jq -r '.country_code // .countryCode // "US"')
        VPS_CITY=$(echo "$response" | jq -r '.city // "Unknown"')
        VPS_REGION=$(echo "$response" | jq -r '.region // .regionName // "Unknown"')
        VPS_LAT=$(echo "$response" | jq -r '.latitude // .lat // "0"')
        VPS_LON=$(echo "$response" | jq -r '.longitude // .lon // "0"')
        VPS_ORG=$(echo "$response" | jq -r '.org // .isp // "Unknown"')
    fi

    echo -e "${GREEN}VPS 位置: $VPS_CITY, $VPS_REGION, $VPS_COUNTRY${NC}"
    echo -e "${GREEN}VPS IP: $VPS_IP${NC}"
    echo -e "${GREEN}运营商: $VPS_ORG${NC}"
    echo ""
}

calculate_distance() {
    local lat1=$1 lon1=$2 lat2=$3 lon2=$4
    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" 'BEGIN {
        pi = 3.14159265358979323846
        R = 6371
        lat1_rad = lat1 * pi / 180
        lat2_rad = lat2 * pi / 180
        delta_lat = (lat2 - lat1) * pi / 180
        delta_lon = (lon2 - lon1) * pi / 180
        a = sin(delta_lat/2)^2 + cos(lat1_rad)*cos(lat2_rad)*sin(delta_lon/2)^2
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

is_anycast_domain() {
    local domain=$1
    local ip1 ip2
    ip1=$(dig +short "$domain" A @8.8.8.8 2>/dev/null | head -n1)
    ip2=$(dig +short "$domain" A @1.1.1.1 2>/dev/null | head -n1)
    if [ -n "$ip1" ] && [ -n "$ip2" ] && [ "$ip1" != "$ip2" ]; then
        echo 1
    else
        echo 0
    fi
}

test_domain_once() {
    local domain=$1

    local ip
    ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' | head -n1)
    if [ -z "$ip" ]; then
        ip=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' | head -n1)
    fi
    [ -z "$ip" ] && return 1

    if is_cdn_ip "$ip"; then
        echo -e "${YELLOW}跳过 $domain (CDN: $ip)${NC}"
        return 1
    fi

    if [ "$(is_anycast_domain "$domain")" -eq 1 ]; then
        echo -e "${YELLOW}跳过 $domain (疑似 Anycast)${NC}"
        return 1
    fi

    local tcp_start tcp_end tcp_latency
    tcp_start=$(date +%s%N)
    if ! timeout 5 bash -c "exec 3<>/dev/tcp/$domain/443 2>/dev/null" 2>/dev/null; then
        return 1
    fi
    tcp_end=$(date +%s%N)
    tcp_latency=$(awk -v s="$tcp_start" -v e="$tcp_end" 'BEGIN {printf "%.1f", (e-s)/1000000}')
    exec 3>&- 2>/dev/null

    local tls_start tls_end tls_latency tls_output
    tls_start=$(date +%s%N)
    tls_output=$(timeout 7 openssl s_client -connect "$domain:443" -servername "$domain" -brief 2>&1 </dev/null || true)
    tls_end=$(date +%s%N)

    if ! echo "$tls_output" | grep -q "Protocol  : TLS"; then
        return 1
    fi
    if echo "$tls_output" | grep -qi "no peer certificate"; then
        return 1
    fi
    tls_latency=$(awk -v s="$tls_start" -v e="$tls_end" 'BEGIN {printf "%.1f", (e-s)/1000000}')

    local distance="N/A"
    if [ -n "$VPS_LAT" ] && [ -n "$VPS_LON" ] && [ "$VPS_LAT" != "0" ] && [ "$VPS_LON" != "0" ]; then
        local geo_info target_lat target_lon
        geo_info=$(curl -s --max-time 3 "https://ipapi.co/$ip/json/" 2>/dev/null || echo "")
        if [ -n "$geo_info" ] && echo "$geo_info" | jq empty >/dev/null 2>&1; then
            target_lat=$(echo "$geo_info" | jq -r '.latitude // .lat // empty')
            target_lon=$(echo "$geo_info" | jq -r '.longitude // .lon // empty')
            if [ -n "$target_lat" ] && [ -n "$target_lon" ] && [ "$target_lat" != "null" ] && [ "$target_lon" != "null" ]; then
                distance=$(calculate_distance "$VPS_LAT" "$VPS_LON" "$target_lat" "$target_lon" 2>/dev/null || echo "N/A")
            fi
        fi
    fi

    local score=100
    if [ "$distance" != "N/A" ]; then
        local distance_penalty
        distance_penalty=$(awk -v d="$distance" 'BEGIN {p=(d/100)*10; if(p>50)p=50; printf "%.1f", p}')
        score=$(awk -v s="$score" -v p="$distance_penalty" 'BEGIN {printf "%.1f", s-p}')
    fi
    local latency_penalty
    latency_penalty=$(awk -v t="$tcp_latency" 'BEGIN {p=(t/10)*5; if(p>30)p=30; printf "%.1f", p}')
    score=$(awk -v s="$score" -v p="$latency_penalty" 'BEGIN {r=s-p; if(r<0)r=0; printf "%.1f", r}')

    echo "$domain|$ip|$distance|$tcp_latency|$tls_latency|$score"
    return 0
}

test_domain() {
    local domain=$1
    local attempt
    for attempt in 1 2; do
        if result=$(test_domain_once "$domain" 2>/dev/null); then
            echo "$result"
            return 0
        fi
        sleep 0.3
    done
    return 1
}

test_all_domains() {
    local domains=("$@")
    local total=${#domains[@]}
    echo -e "${YELLOW}开始测试 $total 个候选域名...${NC}"
    echo ""

    local tmp_results
    tmp_results=$(mktemp)

    local max_jobs=10

    for domain in "${domains[@]}"; do
        {
            local r
            r=$(test_domain "$domain" 2>/dev/null || true)
            if [ -n "$r" ]; then
                echo "$r" >>"$tmp_results"
                echo -e "${GREEN}✓ $domain${NC}"
            else
                echo -e "${RED}✗ $domain${NC}"
            fi
        } &

        while [ "$(jobs -r | wc -l)" -ge "$max_jobs" ]; do
            wait -n || true
        done

        sleep 0.1
    done

    wait || true

    if [ -s "$tmp_results" ]; then
        sort -t'|' -k6 -rn "$tmp_results"
        rm -f "$tmp_results"
    else
        rm -f "$tmp_results"
        echo ""
        return 0
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
    echo "4. 已自动排除主流 CDN / 疑似 Anycast 节点"
    echo "5. 在 VLESS / sing-box 配置中使用: \"sni\": \"选定的域名\""
    echo ""

    echo "推荐配置示例(前 3 个):"
    local count=0
    echo "$results_data" | head -n 3 | while IFS='|' read -r domain ip distance tcp tls score; do
        count=$((count + 1))
        echo "  选项 $count: \"sni\": \"$domain\"  (分数: $score, TCP: ${tcp}ms, 距离: ${distance}km)"
    done

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
    } >"$RESULTS_FILE"

    echo "$results_data" | awk -F'|' -v vps_ip="$VPS_IP" -v vps_country="$VPS_COUNTRY" \
        -v vps_cc="$VPS_COUNTRY_CODE" -v vps_city="$VPS_CITY" -v vps_region="$VPS_REGION" \
        -v vps_org="$VPS_ORG" -v vps_lat="$VPS_LAT" -v vps_lon="$VPS_LON" -v total="$total_count" '
    BEGIN {
        print "{"
        printf "  \"vps\": {\n"
        printf "    \"ip\": \"%s\",\n", vps_ip
        printf "    \"country\": \"%s\",\n", vps_country
        printf "    \"country_code\": \"%s\",\n", vps_cc
        printf "    \"city\": \"%s\",\n", vps_city
        printf "    \"region\": \"%s\",\n", vps_region
        printf "    \"org\": \"%s\",\n", vps_org
        printf "    \"lat\": \"%s\",\n", vps_lat
        printf "    \"lon\": \"%s\"\n", vps_lon
        printf "  },\n"
        printf "  \"results\": [\n"
    }
    {
        printf "    {\"domain\": \"%s\", \"ip\": \"%s\", \"distance_km\": \"%s\", \"tcp_ms\": \"%s\", \"tls_ms\": \"%s\", \"score\": \"%s\"}", $1, $2, $3, $4, $5, $6
        if (NR==total) {
            printf "\n"
        } else {
            printf ",\n"
        }
    }
    END {
        print "  ]"
        print "}"
    }' >"$RESULTS_JSON"

    echo ""
    echo -e "${GREEN}详细文本结果已保存到: $RESULTS_FILE${NC}"
    echo -e "${GREEN}JSON 结果已保存到:   $RESULTS_JSON${NC}"
    echo ""
    echo "最优 SNI 列表示例（前 5 个）："
    echo "  jq -r '.results[0:5].domain' \"$RESULTS_JSON\""
}

main() {
    print_header
    check_dependencies
    get_vps_location

    echo -e "${YELLOW}正在生成候选域名列表...${NC}"
    mapfile -t all_domains < <(generate_candidate_domains)
    echo -e "${GREEN}共发现 ${#all_domains[@]} 个候选域名${NC}"
    echo ""

    if [ ${#all_domains[@]} -eq 0 ]; then
        echo -e "${RED}未能生成候选域名${NC}"
        exit 1
    fi

    set +e
    test_results=$(test_all_domains "${all_domains[@]}")
    set -e

    generate_report "$test_results"
}

main
