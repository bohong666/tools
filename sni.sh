#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VLESS SNI 服务器发现脚本 - 基于地理位置
自动发现 VPS 附近的本地网站作为 SNI 伪装目标
"""

import socket
import ssl
import time
import subprocess
import json
import requests
import dns.resolver
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import math

class LocalSNIFinder:
    def __init__(self, timeout=5):
        self.timeout = timeout
        self.vps_info = None
        self.discovered_domains = []
        self.test_results = []
    
    def get_vps_location(self):
        """获取 VPS 的详细地理位置信息"""
        print("正在获取 VPS 位置信息...")
        try:
            # 使用多个 IP 信息服务以提高准确性
            response = requests.get('https://ipapi.co/json/', timeout=10)
            if response.status_code == 200:
                data = response.json()
                self.vps_info = {
                    'ip': data.get('ip'),
                    'city': data.get('city'),
                    'region': data.get('region'),
                    'country': data.get('country_name'),
                    'country_code': data.get('country_code'),
                    'latitude': data.get('latitude'),
                    'longitude': data.get('longitude'),
                    'timezone': data.get('timezone'),
                    'asn': data.get('asn'),
                    'org': data.get('org')
                }
                print(f"VPS 位置: {self.vps_info['city']}, {self.vps_info['region']}, {self.vps_info['country']}")
                print(f"VPS IP: {self.vps_info['ip']}")
                print(f"运营商: {self.vps_info['org']}\n")
                return True
        except Exception as e:
            print(f"获取 VPS 信息失败: {e}")
        return False
    
    def calculate_distance(self, lat1, lon1, lat2, lon2):
        """计算两个经纬度之间的距离(公里)"""
        R = 6371  # 地球半径(公里)
        
        lat1_rad = math.radians(lat1)
        lat2_rad = math.radians(lat2)
        delta_lat = math.radians(lat2 - lat1)
        delta_lon = math.radians(lon2 - lon1)
        
        a = math.sin(delta_lat/2)**2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(delta_lon/2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        
        return R * c
    
    def discover_local_domains(self):
        """发现本地域名"""
        domains = set()
        
        # 方法1: 基于国家/地区的常见 TLD 和本地域名
        country_tlds = {
            'US': ['com', 'us', 'net', 'org'],
            'CN': ['cn', 'com.cn'],
            'JP': ['jp', 'co.jp', 'ne.jp'],
            'KR': ['kr', 'co.kr'],
            'SG': ['sg', 'com.sg'],
            'HK': ['hk', 'com.hk'],
            'TW': ['tw', 'com.tw'],
            'DE': ['de'],
            'UK': ['uk', 'co.uk'],
            'FR': ['fr'],
            'NL': ['nl'],
            'RU': ['ru'],
            'BR': ['br', 'com.br'],
            'AU': ['au', 'com.au'],
            'IN': ['in', 'co.in']
        }
        
        # 方法2: 查找同 ASN 的其他域名(同机房/同运营商)
        print("正在发现本地域名...")
        
        # 基于地理位置生成候选域名
        country_code = self.vps_info.get('country_code', 'US')
        city = self.vps_info.get('city', '').lower().replace(' ', '')
        region = self.vps_info.get('region', '').lower().replace(' ', '')
        
        # 常见的本地服务类型
        service_types = [
            'cdn', 'cache', 'static', 'assets', 'media', 'images',
            'api', 'data', 'storage', 'file', 'download',
            'news', 'blog', 'portal', 'forum', 'shop',
            'cloud', 'server', 'host', 'web'
        ]
        
        # 生成候选域名
        tlds = country_tlds.get(country_code, ['com', 'net'])
        
        for tld in tlds:
            # 通用服务域名
            for service in service_types:
                domains.add(f"{service}.{tld}")
                if city:
                    domains.add(f"{city}-{service}.{tld}")
                    domains.add(f"{service}-{city}.{tld}")
        
        # 方法3: 查询同 IP 段的反向 DNS
        if self.vps_info['ip']:
            nearby_domains = self.find_nearby_ip_domains()
            domains.update(nearby_domains)
        
        return list(domains)
    
    def find_nearby_ip_domains(self):
        """查找同 IP 段的域名(通过反向 DNS)"""
        domains = set()
        vps_ip = self.vps_info['ip']
        
        try:
            # 获取 IP 的 C 段
            ip_parts = vps_ip.split('.')
            ip_prefix = '.'.join(ip_parts[:3])
            
            print(f"扫描 IP 段 {ip_prefix}.0/24 的邻近服务器...")
            
            # 扫描部分 IP(避免扫描整个 C 段)
            scan_ips = [f"{ip_prefix}.{i}" for i in [1, 2, 5, 10, 20, 50, 100, 150, 200, 250, 254]]
            
            for ip in scan_ips:
                try:
                    # 反向 DNS 查询
                    hostname = socket.gethostbyaddr(ip)[0]
                    if hostname and not hostname.endswith('.in-addr.arpa'):
                        domains.add(hostname)
                        print(f"  发现: {hostname} ({ip})")
                except:
                    pass
            
        except Exception as e:
            print(f"IP 段扫描出错: {e}")
        
        return domains
    
    def fetch_domains_from_api(self):
        """从公共 API 获取地理位置相关的域名"""
        domains = set()
        
        try:
            # 使用 Cloudflare DNS 查询本地常见域名
            # 这里可以扩展更多 API 来源
            
            country_code = self.vps_info.get('country_code', '').lower()
            
            # 一些已知的区域性 CDN 和服务
            regional_services = {
                'cn': ['staticfile.org', 'bootcdn.cn', 'staticdn.net'],
                'jp': ['sakura.ne.jp', 'xserver.jp'],
                'kr': ['cdnjs.kr', 'gabia.com'],
                'sg': ['sgp1.cdn.digitaloceanspaces.com'],
                'de': ['hetzner.com', 'contabo.com'],
                'us': ['cdn77.com', 'stackpath.com', 'bunny.net'],
                'hk': ['hkix.net'],
            }
            
            if country_code in regional_services:
                domains.update(regional_services[country_code])
            
        except Exception as e:
            print(f"API 查询出错: {e}")
        
        return domains
    
    def test_domain(self, domain):
        """测试单个域名的可用性和性能"""
        result = {
            'domain': domain,
            'ip': None,
            'distance_km': None,
            'tcp_latency': None,
            'tls_latency': None,
            'tls_version': None,
            'cert_issuer': None,
            'cert_valid': False,
            'status': 'Failed',
            'score': 0
        }
        
        try:
            # DNS 解析
            ip = socket.gethostbyname(domain)
            result['ip'] = ip
            
            # 获取目标服务器的地理位置
            try:
                geo_response = requests.get(f'https://ipapi.co/{ip}/json/', timeout=5)
                if geo_response.status_code == 200:
                    geo_data = geo_response.json()
                    target_lat = geo_data.get('latitude')
                    target_lon = geo_data.get('longitude')
                    
                    if target_lat and target_lon and self.vps_info['latitude'] and self.vps_info['longitude']:
                        distance = self.calculate_distance(
                            self.vps_info['latitude'],
                            self.vps_info['longitude'],
                            target_lat,
                            target_lon
                        )
                        result['distance_km'] = distance
            except:
                pass
            
            # TCP 连接测试
            start = time.time()
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect((domain, 443))
            result['tcp_latency'] = (time.time() - start) * 1000
            sock.close()
            
            # TLS 握手测试
            start = time.time()
            context = ssl.create_default_context()
            
            with socket.create_connection((domain, 443), timeout=self.timeout) as sock:
                with context.wrap_socket(sock, server_hostname=domain) as ssock:
                    result['tls_latency'] = (time.time() - start) * 1000
                    result['tls_version'] = ssock.version()
                    
                    cert = ssock.getpeercert()
                    if cert:
                        result['cert_valid'] = True
                        issuer = dict(x[0] for x in cert['issuer'])
                        result['cert_issuer'] = issuer.get('organizationName', 'Unknown')
            
            result['status'] = 'Success'
            
            # 计算综合分数(距离越近、延迟越低,分数越高)
            score = 100
            
            if result['distance_km']:
                # 距离分数: 100km 内满分,每 100km 减 10 分
                distance_penalty = min(50, result['distance_km'] / 100 * 10)
                score -= distance_penalty
            
            if result['tcp_latency']:
                # 延迟分数: 10ms 内满分,每 10ms 减 5 分
                latency_penalty = min(30, result['tcp_latency'] / 10 * 5)
                score -= latency_penalty
            
            if result['tls_latency']:
                # TLS 分数: 20ms 内满分,每 20ms 减 5 分
                tls_penalty = min(20, result['tls_latency'] / 20 * 5)
                score -= tls_penalty
            
            result['score'] = max(0, score)
            
        except Exception as e:
            result['error'] = str(e)
        
        return result
    
    def test_discovered_domains(self, domains, max_workers=20):
        """批量测试发现的域名"""
        print(f"\n开始测试 {len(domains)} 个候选域名...\n")
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(self.test_domain, domain): domain 
                      for domain in domains}
            
            completed = 0
            for future in as_completed(futures):
                completed += 1
                result = future.result()
                if result['status'] == 'Success':
                    self.test_results.append(result)
                    print(f"[{completed}/{len(domains)}] ✓ {result['domain']} "
                          f"- {result['distance_km']:.0f if result['distance_km'] else '?'}km "
                          f"- {result['tcp_latency']:.1f}ms")
                else:
                    print(f"[{completed}/{len(domains)}] ✗ {result['domain']}")
        
        # 按分数排序
        self.test_results.sort(key=lambda x: x['score'], reverse=True)
    
    def generate_report(self):
        """生成测试报告"""
        print("\n" + "="*90)
        print("VLESS SNI 本地服务器发现报告")
        print("="*90)
        
        print(f"\nVPS 位置: {self.vps_info['city']}, {self.vps_info['region']}, {self.vps_info['country']}")
        print(f"VPS IP: {self.vps_info['ip']}")
        print(f"测试时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"成功发现可用域名: {len(self.test_results)} 个")
        
        if not self.test_results:
            print("\n⚠ 未发现可用的本地域名,建议:")
            print("1. 手动添加已知的本地网站域名到脚本中")
            print("2. 扩大搜索范围")
            print("3. 使用区域性 CDN 服务")
            return
        
        # Top 推荐
        print("\n" + "-"*90)
        print("TOP 推荐 SNI 域名 (按综合评分排序)")
        print("-"*90)
        print(f"{'排名':<6}{'域名':<35}{'距离(km)':<12}{'TCP(ms)':<12}{'TLS(ms)':<12}{'分数':<8}")
        print("-"*90)
        
        for idx, result in enumerate(self.test_results[:20], 1):
            distance = f"{result['distance_km']:.0f}" if result['distance_km'] else "未知"
            tcp = f"{result['tcp_latency']:.1f}" if result['tcp_latency'] else "N/A"
            tls = f"{result['tls_latency']:.1f}" if result['tls_latency'] else "N/A"
            score = f"{result['score']:.1f}"
            
            print(f"{idx:<6}{result['domain']:<35}{distance:<12}{tcp:<12}{tls:<12}{score:<8}")
        
        # 使用建议
        print("\n" + "="*90)
        print("使用建议")
        print("="*90)
        print("\n1. 优先选择物理距离 < 500km 的域名")
        print("2. 选择 TCP 和 TLS 延迟都较低的域名")
        print("3. 避免选择知名国际网站(如 Google, Cloudflare 等)")
        print("4. 建议选择本地 CDN、云服务商或区域性服务")
        print("5. 在 VLESS 配置中使用: \"sni\": \"选定的域名\"")
        print("6. 定期重新测试,因为服务器状态会变化")
        
        print("\n推荐配置示例:")
        if self.test_results:
            top3 = self.test_results[:3]
            for i, result in enumerate(top3, 1):
                print(f"  选项 {i}: \"sni\": \"{result['domain']}\"")
        
        # 保存结果
        self.save_results()
    
    def save_results(self):
        """保存结果到文件"""
        filename = f"local_sni_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump({
                'test_time': datetime.now().isoformat(),
                'vps_info': self.vps_info,
                'total_tested': len(self.test_results),
                'results': self.test_results
            }, f, indent=2, ensure_ascii=False)
        
        print(f"\n结果已保存到: {filename}")

def main():
    print("="*90)
    print("VLESS SNI 本地服务器发现工具")
    print("自动发现 VPS 附近的本地网站作为 SNI 伪装目标")
    print("="*90)
    print()
    
    finder = LocalSNIFinder(timeout=5)
    
    # 获取 VPS 位置
    if not finder.get_vps_location():
        print("无法获取 VPS 位置信息,程序退出")
        return
    
    # 发现候选域名
    discovered = finder.discover_local_domains()
    api_domains = finder.fetch_domains_from_api()
    all_domains = list(set(discovered) | set(api_domains))
    
    print(f"共发现 {len(all_domains)} 个候选域名")
    
    if not all_domains:
        print("\n未能自动发现候选域名,请手动添加本地网站域名")
        return
    
    # 测试域名
    finder.test_discovered_domains(all_domains, max_workers=20)
    
    # 生成报告
    finder.generate_report()

if __name__ == "__main__":
    main()
