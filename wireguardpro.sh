#!/bin/bash
#
# WireGuard VPN 管理脚本 (集成版)
# 版本: 2.2.0
# 描述: WireGuard VPN完整管理解决方案 - 安装/查看/卸载一体化
# 功能: 安装配置、查看链接、一键卸载
# 作者: laobanbiefangcu
# 许可: MIT
#

# 严格模式设置
set -euo pipefail
IFS=$'\n\t'

# ======================= 全局配置 =======================

# 版本信息
readonly SCRIPT_VERSION="2.2.0"
readonly SCRIPT_NAME=$(basename "$0")

# 性能优化配置
readonly MAX_CONCURRENT_CLIENTS=50
readonly KEY_GENERATION_BATCH_SIZE=10

# 默认配置
readonly DEFAULT_PORT=51820
readonly DEFAULT_MTU=1420
readonly DEFAULT_CLIENT_COUNT=10
readonly WG_CONFIG_DIR="/etc/wireguard"
readonly LOG_FILE="/var/log/wireguard-install.log"
readonly BACKUP_DIR="/etc/wireguard/backup"

# 网络配置
readonly DEFAULT_IPV4_NETWORK="192.168.3"
readonly DEFAULT_IPV4_CIDR="192.168.3.0/24"
readonly ULA_IPV6_PREFIX="fd42:d686:95dc::"

# 可选网段
readonly PRESET_NETWORKS=(
    "192.168.3:192.168.3.0/24"
    "10.0.0:10.0.0.0/24"
    "172.16.0:172.16.0.0/24"
)

# 全局变量
DRY_RUN=0
FORCE_INSTALL=0
QUIET_MODE=0
port=$DEFAULT_PORT
mtu=$DEFAULT_MTU
client_count=$DEFAULT_CLIENT_COUNT
ipv4_network="$DEFAULT_IPV4_NETWORK"
ipv4_cidr="$DEFAULT_IPV4_CIDR"

# ======================= 颜色和提示配置 =======================

# 颜色定义
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    readonly RED=$(tput setaf 1)
    readonly GREEN=$(tput setaf 2)
    readonly YELLOW=$(tput setaf 3)
    readonly BLUE=$(tput setaf 4)
    readonly MAGENTA=$(tput setaf 5)
    readonly CYAN=$(tput setaf 6)
    readonly WHITE=$(tput setaf 7)
    readonly BOLD=$(tput bold)
    readonly RESET=$(tput sgr0)
else
    readonly RED='\033[31m'
    readonly GREEN='\033[32m'
    readonly YELLOW='\033[33m'
    readonly BLUE='\033[34m'
    readonly MAGENTA='\033[35m'
    readonly CYAN='\033[36m'
    readonly WHITE='\033[37m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
fi

# 日志级别图标
readonly ICON_INFO="[INFO]"
readonly ICON_OK="[OK]"
readonly ICON_WARN="[WARN]"
readonly ICON_ERROR="[ERROR]"
readonly ICON_QUESTION="[?]"

# 兼容旧式变量定义（为了兼容原脚本的echo语句）
readonly Info="${CYAN}${ICON_INFO}${RESET}"
readonly OK="${GREEN}${ICON_OK}${RESET}"
readonly Error="${RED}${ICON_ERROR}${RESET}"
readonly Warn="${YELLOW}${ICON_WARN}${RESET}"
readonly Question="${MAGENTA}${ICON_QUESTION}${RESET}"

# 初始化日志文件
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# ======================= 菜单系统 =======================

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║           ${BOLD}WireGuard VPN 管理工具 v$SCRIPT_VERSION${RESET}${CYAN}             ║${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║  ${GREEN}1.${RESET} 安装/重新安装 WireGuard VPN                         ║"
    echo -e "${CYAN}║  ${BLUE}2.${RESET} 查看所有客户端链接                                  ║"
    echo -e "${CYAN}║  ${YELLOW}3.${RESET} 查看指定客户端链接                                  ║"
    echo -e "${CYAN}║  ${CYAN}4.${RESET} 提取纯净链接（无格式）                              ║"
    echo -e "${CYAN}║  ${MAGENTA}5.${RESET} 查看服务状态                                        ║"
    echo -e "${CYAN}║  ${GREEN}7.${RESET} 生成 Surge/Loon/Clash 配置                         ║"
    echo -e "${CYAN}║  ${RED}6.${RESET} 一键卸载 WireGuard                                 ║"
    echo -e "${CYAN}║  ${WHITE}0.${RESET} 退出                                                ║"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# 查看所有客户端链接
show_all_links() {
    # 临时禁用严格模式以避免循环中断
    set +euo pipefail
    
    echo -e "${Info} ============== 所有客户端链接 =============="
    local found=0
    local links_found=0
    local configs_found=0
    
    echo -e "${Info} 正在扫描所有客户端配置文件..."
    echo ""
    
    for i in {1..10}; do
        local wg_file="/etc/wireguard/wg_ubuntu_${i}.wg"
        local conf_file="/etc/wireguard/wg_ubuntu_${i}.conf"
        
        if [[ -f "$wg_file" ]]; then
            echo -e "${OK} ======== 客户端 ${i} ========"
            # 使用while read循环避免stdin干扰
            while IFS= read -r line; do
                echo "$line"
            done < "$wg_file" 2>/dev/null
            echo ""
            echo "----------------------------------------"
            echo ""
            found=$((found + 1))
            links_found=$((links_found + 1))
        elif [[ -f "$conf_file" ]]; then
            echo -e "${Warn} 客户端${i}: 配置文件存在但链接文件缺失"
            echo -e "${Info} 配置文件位置: $conf_file"
            echo ""
            found=$((found + 1))
            configs_found=$((configs_found + 1))
        fi
    done
    
    echo -e "${Info} ============== 统计结果 =============="
    if [[ $found -eq 0 ]]; then
        echo -e "${Error} 未找到任何客户端配置文件"
        echo -e "${Info} 请先运行安装功能创建配置"
    else
        echo -e "${OK} 扫描完成！总共找到 $found 个客户端配置"
        echo -e "${OK} 其中 $links_found 个有完整的 wireguard:// 链接"
        if [[ $configs_found -gt 0 ]]; then
            echo -e "${Warn} 其中 $configs_found 个缺少链接文件"
        fi
        echo -e "${Info} "
        echo -e "${Info} 使用方法: 复制完整的 wireguard:// 链接到客户端导入"
        echo -e "${Info} 提示: 每个链接都是完整的一行，确保复制时不要截断"
    fi
    
    # 恢复严格模式
    set -euo pipefail
    
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
}

# 输出纯净的WireGuard链接（不带格式）
show_clean_links() {
    # 临时禁用严格模式
    set +euo pipefail
    
    for i in {1..10}; do
        local wg_file="/etc/wireguard/wg_ubuntu_${i}.wg"
        if [[ -f "$wg_file" ]]; then
            while IFS= read -r line; do
                echo "$line"
            done < "$wg_file" 2>/dev/null
        fi
    done
    
    # 恢复严格模式
    set -euo pipefail
    
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
}

# 查看指定客户端链接
show_specific_link() {
    echo -e "${Info} ============== 查看指定客户端链接 =============="
    read -p "请输入客户端编号 (1-10): " client_num < /dev/tty
    
    if [[ -z "$client_num" ]] || [[ ! "$client_num" =~ ^[0-9]+$ ]] || [[ $client_num -lt 1 ]] || [[ $client_num -gt 10 ]]; then
        echo -e "${Error} 无效的客户端编号，请输入 1-10 之间的数字"
        read -p "按任意键返回主菜单..." -n 1 < /dev/tty
        return
    fi
    
    local wg_file="/etc/wireguard/wg_ubuntu_${client_num}.wg"
    local conf_file="/etc/wireguard/wg_ubuntu_${client_num}.conf"
    
    echo ""
    if [[ -f "$wg_file" ]]; then
        echo -e "${OK} 客户端${client_num} wireguard://链接:"
        echo -e "${GREEN}$(cat "$wg_file")${RESET}"
        echo ""
        echo -e "${Info} 使用方法:"
        echo -e "${Info} 1. 复制上面的完整链接"
        echo -e "${Info} 2. 在WireGuard客户端中选择'从剪贴板导入'"
        echo -e "${Info} 3. 或直接点击链接自动导入"
    elif [[ -f "$conf_file" ]]; then
        echo -e "${Warn} 客户端${client_num} 配置文件存在但链接文件缺失"
        echo -e "${Info} 配置文件内容:"
        cat "$conf_file"
        echo ""
        echo -e "${Info} 建议重新运行安装功能以重新生成链接文件"
    else
        echo -e "${Error} 客户端${client_num} 不存在"
        echo -e "${Info} 可用客户端: 1-10 (需要先运行安装功能)"
    fi
    
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
}

# 查看服务状态
show_service_status() {
    echo -e "${Info} ============== WireGuard 服务状态 =============="
    
    # 检查服务状态
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        echo -e "${OK} WireGuard 服务状态: ${GREEN}运行中${RESET}"
    else
        echo -e "${Error} WireGuard 服务状态: ${RED}已停止${RESET}"
    fi
    
    # 检查开机启动
    if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null; then
        echo -e "${OK} 开机启动: ${GREEN}已启用${RESET}"
    else
        echo -e "${Warn} 开机启动: ${YELLOW}未启用${RESET}"
    fi
    
    echo ""
    
    # 显示接口信息
    if command -v wg >/dev/null 2>&1 && wg show >/dev/null 2>&1; then
        echo -e "${Info} WireGuard 接口信息:"
        wg show
        echo ""
        
        # 显示连接统计
        local peer_count=$(wg show wg0 peers 2>/dev/null | wc -l)
        echo -e "${Info} 配置的客户端数量: ${peer_count}"
        
        # 检查网络规则
        echo ""
        echo -e "${Info} 网络规则检查:"
        if iptables -L FORWARD -n | grep -q "ACCEPT.*wg0" || iptables -L FORWARD | head -3 | grep -q "ACCEPT"; then
            echo -e "${OK} IPv4 转发规则: ${GREEN}正常${RESET}"
        else
            echo -e "${Error} IPv4 转发规则: ${RED}异常${RESET}"
        fi
        
        if ip6tables -L FORWARD -n 2>/dev/null | grep -q "ACCEPT.*wg0" || ip6tables -L FORWARD 2>/dev/null | head -3 | grep -q "ACCEPT"; then
            echo -e "${OK} IPv6 转发规则: ${GREEN}正常${RESET}"
        else
            echo -e "${Warn} IPv6 转发规则: ${YELLOW}可能异常${RESET}"
        fi
    else
        echo -e "${Error} WireGuard 接口未创建或命令不可用"
    fi
    
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
}

# 生成 Surge/Loon/Clash 配置并显示链接
generate_all_configs_and_links() {
    # 临时禁用严格模式
    set +euo pipefail
    
    echo -e "${Info} ============== 生成 Surge/Loon/Clash 配置 =============="
    
    # 检查配置文件是否存在
    local found_configs=0
    for i in {1..10}; do
        if [[ -f "/etc/wireguard/wg_ubuntu_${i}.conf" ]]; then
            found_configs=$((found_configs + 1))
        fi
    done
    
    if [[ $found_configs -eq 0 ]]; then
        echo -e "${Error} 未找到任何 WireGuard 配置文件"
        echo -e "${Info} 请先运行安装功能创建配置"
        echo ""
        read -p "按任意键返回主菜单..." -n 1 < /dev/tty
        # 恢复严格模式
        set -euo pipefail
        return
    fi
    
    echo -e "${Info} 找到 $found_configs 个配置文件，开始生成..."
    
    # 创建 Python 生成脚本（内联）
    cat > /tmp/generate_configs.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import re
import os
import ipaddress
from typing import Dict

class WireGuardConfigParser:
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config_data = {}
        
    def parse(self) -> Dict:
        try:
            with open(self.config_path, 'r', encoding='utf-8') as f:
                content = f.read()
        except:
            return {}
        
        # 解析[Interface]段
        interface_match = re.search(r'\[Interface\](.*?)(?=\[|$)', content, re.DOTALL)
        if interface_match:
            interface_content = interface_match.group(1).strip()
            self._parse_interface(interface_content)
        
        # 解析[Peer]段
        peer_match = re.search(r'\[Peer\](.*?)$', content, re.DOTALL)
        if peer_match:
            peer_content = peer_match.group(1).strip()
            self._parse_peer(peer_content)
        
        return self.config_data
    
    def _parse_interface(self, content: str):
        self.config_data['interface'] = {}
        
        private_key_match = re.search(r'PrivateKey\s*=\s*(.+)', content)
        if private_key_match:
            self.config_data['interface']['private_key'] = private_key_match.group(1).strip()
        
        addresses = []
        ipv4_address = None
        ipv6_address = None
        
        for match in re.finditer(r'Address\s*=\s*(.+)', content):
            address_str = match.group(1).strip()
            addresses.append(address_str)
            
            try:
                addr = ipaddress.ip_interface(address_str)
                if addr.version == 4:
                    ipv4_address = str(addr.ip)
                elif addr.version == 6:
                    ipv6_address = str(addr.ip)
            except:
                continue
        
        self.config_data['interface']['addresses'] = addresses
        self.config_data['interface']['ipv4'] = ipv4_address
        self.config_data['interface']['ipv6'] = ipv6_address
        
        dns_match = re.search(r'DNS\s*=\s*(.+)', content)
        if dns_match:
            dns_str = dns_match.group(1).strip()
            dns_list = [dns.strip() for dns in dns_str.split(',')]
            self.config_data['interface']['dns'] = dns_list
            
            ipv4_dns = []
            ipv6_dns = []
            for dns in dns_list:
                try:
                    addr = ipaddress.ip_address(dns)
                    if addr.version == 4:
                        ipv4_dns.append(dns)
                    else:
                        ipv6_dns.append(dns)
                except:
                    ipv4_dns.append(dns)
            
            self.config_data['interface']['dns_ipv4'] = ipv4_dns
            self.config_data['interface']['dns_ipv6'] = ipv6_dns
    
    def _parse_peer(self, content: str):
        self.config_data['peer'] = {}
        
        public_key_match = re.search(r'PublicKey\s*=\s*(.+)', content)
        if public_key_match:
            self.config_data['peer']['public_key'] = public_key_match.group(1).strip()
        
        endpoint_match = re.search(r'Endpoint\s*=\s*(.+)', content)
        if endpoint_match:
            endpoint_str = endpoint_match.group(1).strip()
            self.config_data['peer']['endpoint'] = endpoint_str
            
            if endpoint_str.startswith('[') and ']:' in endpoint_str:
                ipv6_match = re.match(r'\[(.+?)\]:(\d+)', endpoint_str)
                if ipv6_match:
                    self.config_data['peer']['server'] = ipv6_match.group(1)
                    self.config_data['peer']['port'] = int(ipv6_match.group(2))
            else:
                if ':' in endpoint_str:
                    server, port = endpoint_str.rsplit(':', 1)
                    self.config_data['peer']['server'] = server
                    try:
                        self.config_data['peer']['port'] = int(port)
                    except:
                        self.config_data['peer']['port'] = 51820
        
        allowed_ips_match = re.search(r'AllowedIPs\s*=\s*(.+)', content)
        if allowed_ips_match:
            self.config_data['peer']['allowed_ips'] = allowed_ips_match.group(1).strip()
        
        keepalive_match = re.search(r'PersistentKeepalive\s*=\s*(\d+)', content)
        if keepalive_match:
            self.config_data['peer']['keepalive'] = int(keepalive_match.group(1))
        else:
            self.config_data['peer']['keepalive'] = 25

def main():
    os.makedirs('/etc/wireguard/configs', exist_ok=True)
    
    configs = []
    for client_num in range(1, 11):
        config_file = f"/etc/wireguard/wg_ubuntu_{client_num}.conf"
        if os.path.exists(config_file):
            parser = WireGuardConfigParser(config_file)
            wg_config = parser.parse()
            configs.append(wg_config)
        else:
            configs.append({})
    
    # 生成 Surge 汇总配置
    surge_configs = []
    for i, wg_config in enumerate(configs, 1):
        if not wg_config:
            continue
        interface = wg_config.get('interface', {})
        peer = wg_config.get('peer', {})
        
        config = f"""[WireGuard Ubuntu{i}]
private-key = {interface.get('private_key', '')}
self-ip = {interface.get('ipv4', '')}
self-ip-v6 = {interface.get('ipv6', '')}
dns-server = {', '.join(interface.get('dns', ['119.29.29.29', '2402:4e00::']))}
mtu = 1280
peer = (public-key = {peer.get('public_key', '')}, allowed-ips = "{peer.get('allowed_ips', '0.0.0.0/0, ::0/0')}", endpoint = {peer.get('server', '')}:{peer.get('port', 51820)}, keepalive = {peer.get('keepalive', 25)})"""
        
        surge_configs.append(config)
    
    with open('/etc/wireguard/configs/surge_all.conf', 'w', encoding='utf-8') as f:
        f.write("# Surge WireGuard 配置汇总\n")
        f.write("# 复制需要的配置段到 Surge 配置文件中\n\n")
        f.write("\n\n".join(surge_configs))
    
    # 生成 Loon 汇总配置
    loon_configs = []
    for i, wg_config in enumerate(configs, 1):
        if not wg_config:
            continue
        interface = wg_config.get('interface', {})
        peer = wg_config.get('peer', {})
        
        config = f"🇨🇳 Ubuntu{i} = WireGuard,interface-ip={interface.get('ipv4', '')},interface-ipv6={interface.get('ipv6', '')},private-key=\"{interface.get('private_key', '')}\",mtu=1280,dns={','.join(interface.get('dns_ipv4', ['119.29.29.29']))},dnsv6={','.join(interface.get('dns_ipv6', ['2402:4e00::']))},keepalive={peer.get('keepalive', 25)},peers=[{{public-key=\"{peer.get('public_key', '')}\",allowed-ips=\"{peer.get('allowed_ips', '0.0.0.0/0,::0/0')}\",endpoint={peer.get('server', '')}:{peer.get('port', 51820)}}}]"
        
        loon_configs.append(config)
    
    with open('/etc/wireguard/configs/loon_all.conf', 'w', encoding='utf-8') as f:
        f.write("# Loon WireGuard 配置汇总\n")
        f.write("# 复制需要的配置行到 Loon [Proxy] 段中\n\n")
        f.write("\n".join(loon_configs))
    
    # 生成 Clash 汇总配置
    clash_configs = []
    for i, wg_config in enumerate(configs, 1):
        if not wg_config:
            continue
        interface = wg_config.get('interface', {})
        peer = wg_config.get('peer', {})
        
        dns_formatted = str(interface.get('dns', ['119.29.29.29', '2402:4e00::'])).replace("'", '"')
        
        config = f"  - {{name: 🇨🇳 ubuntu{i}, type: wireguard, server: {peer.get('server', '')}, port: {peer.get('port', 51820)}, ip: {interface.get('ipv4', '')}, ipv6: {interface.get('ipv6', '')}, private-key: {interface.get('private_key', '')}, public-key: {peer.get('public_key', '')}, AllowedIPs = ::/0, 0.0.0.0/0, dns: {dns_formatted}, udp: true, benchmark-url: 'http://192.168.1.1'}}"
        
        clash_configs.append(config)
    
    with open('/etc/wireguard/configs/clash_all.yaml', 'w', encoding='utf-8') as f:
        f.write("# Clash WireGuard 配置汇总\n")
        f.write("# 复制到 Clash 配置文件的 proxies 段中\n\n")
        f.write("proxies:\n")
        f.write("\n".join(clash_configs))

if __name__ == "__main__":
    main()
EOF
    
    # 运行 Python 脚本生成配置
    echo -e "${Info} 正在生成配置文件..."
    if python3 /tmp/generate_configs.py; then
        echo -e "${OK} 配置生成成功！"
    else
        echo -e "${Error} 配置生成失败"
        rm -f /tmp/generate_configs.py
        echo ""
        read -p "按任意键返回主菜单..." -n 1 < /dev/tty
        # 恢复严格模式
        set -euo pipefail
        return
    fi
    
    # 清理临时文件
    rm -f /tmp/generate_configs.py
    
    echo ""
    echo -e "${Info} ============== 生成的配置文件 =============="
    echo -e "${OK} Surge 配置: /etc/wireguard/configs/surge_all.conf"
    echo -e "${OK} Loon 配置:  /etc/wireguard/configs/loon_all.conf"  
    echo -e "${OK} Clash 配置: /etc/wireguard/configs/clash_all.yaml"
    echo ""
    
    # 显示配置文件内容预览
    echo -e "${Info} ============== Surge 配置预览 =============="
    if [[ -f "/etc/wireguard/configs/surge_all.conf" ]]; then
        head -15 /etc/wireguard/configs/surge_all.conf
        echo -e "${YELLOW}... (更多内容请查看完整文件) ...${RESET}"
    fi
    
    echo ""
    echo -e "${Info} ============== Loon 配置预览 =============="
    if [[ -f "/etc/wireguard/configs/loon_all.conf" ]]; then
        head -7 /etc/wireguard/configs/loon_all.conf
        echo -e "${YELLOW}... (更多内容请查看完整文件) ...${RESET}"
    fi
    
    echo ""
    echo -e "${Info} ============== Clash 配置预览 =============="
    if [[ -f "/etc/wireguard/configs/clash_all.yaml" ]]; then
        head -8 /etc/wireguard/configs/clash_all.yaml
        echo -e "${YELLOW}... (更多内容请查看完整文件) ...${RESET}"
    fi
    
    echo ""
    echo -e "${Info} ============== WireGuard 原始链接 =============="
    echo -e "${Info} 以下是所有客户端的 wireguard:// 链接："
    echo ""
    
    # 显示所有 WireGuard 链接
    local found=0
    for i in {1..10}; do
        local wg_file="/etc/wireguard/wg_ubuntu_${i}.wg"
        if [[ -f "$wg_file" ]]; then
            echo -e "${OK} ======== 客户端 ${i} ========"
            cat "$wg_file" 2>/dev/null
            echo ""
            ((found++))
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        echo -e "${Warn} 未找到 wireguard:// 链接文件"
        echo -e "${Info} 链接文件位置: /etc/wireguard/wg_ubuntu_*.wg"
    else
        echo -e "${OK} 共显示 $found 个客户端的 wireguard:// 链接"
    fi
    
    echo ""
    echo -e "${Info} ============== 使用说明 =============="
    echo -e "${Info} 1. Surge: 复制 [WireGuard Ubuntu1] 整个段落到配置文件"
    echo -e "${Info} 2. Loon:  复制 🇨🇳 Ubuntu1 = ... 行到 [Proxy] 段"
    echo -e "${Info} 3. Clash: 复制 proxies 段下的节点到配置文件"
    echo -e "${Info} 4. WireGuard App: 直接使用 wireguard:// 链接导入"
    echo ""
    echo -e "${Info} 配置文件路径："
    echo -e "${Info} - /etc/wireguard/configs/surge_all.conf"
    echo -e "${Info} - /etc/wireguard/configs/loon_all.conf"
    echo -e "${Info} - /etc/wireguard/configs/clash_all.yaml"
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
    
    # 恢复严格模式
    set -euo pipefail
}

# 一键卸载功能
uninstall_wireguard() {
    echo -e "${Warn} ============== WireGuard 卸载程序 =============="
    echo -e "${RED}警告: 此操作将完全删除 WireGuard 及所有配置文件！${RESET}"
    echo -e "${Info} 将要执行的操作:"
    echo -e "${Info} 1. 停止 WireGuard 服务"
    echo -e "${Info} 2. 禁用开机启动"
    echo -e "${Info} 3. 清理防火墙规则"
    echo -e "${Info} 4. 删除配置文件和密钥"
    echo -e "${Info} 5. 卸载 WireGuard 软件包"
    echo -e "${Info} 6. 清理系统配置"
    echo ""
    
    read -p "确定要继续吗？(输入 'YES' 确认): " confirm < /dev/tty
    
    if [[ -z "$confirm" ]] || [[ "$confirm" != "YES" ]]; then
        echo -e "${Info} 卸载已取消"
        read -p "按任意键返回主菜单..." -n 1 < /dev/tty
        return
    fi
    
    echo -e "${Info} 开始卸载 WireGuard..."
    
    # 1. 停止服务
    echo -e "${Info} 停止 WireGuard 服务..."
    systemctl stop wg-quick@wg0 2>/dev/null || true
    systemctl disable wg-quick@wg0 2>/dev/null || true
    
    # 2. 清理网络接口
    if ip link show wg0 >/dev/null 2>&1; then
        echo -e "${Info} 删除 WireGuard 接口..."
        ip link delete wg0 2>/dev/null || true
    fi
    
    # 3. 清理防火墙规则
    echo -e "${Info} 清理防火墙规则..."
    # IPv4 规则清理
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    # 清理所有可能的NAT规则
    iptables -t nat -D POSTROUTING -s 192.168.3.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 192.168.55.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null || true
    
    # IPv6 规则清理
    ip6tables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -s 240e:390:6caa:26a1::/64 -j MASQUERADE 2>/dev/null || true
    
    # 4. 删除配置文件
    echo -e "${Info} 删除配置文件和密钥..."
    if [[ -d "/etc/wireguard" ]]; then
        rm -rf /etc/wireguard/*
        echo -e "${OK} 配置文件已删除"
    fi
    
    # 删除备份目录
    [[ -d "/etc/wireguard/backup" ]] && rm -rf /etc/wireguard/backup
    
    # 5. 卸载软件包
    echo -e "${Info} 卸载 WireGuard 软件包..."
    if command -v apt >/dev/null 2>&1; then
        apt remove --purge -y wireguard wireguard-tools 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y wireguard-tools 2>/dev/null || true
    fi
    
    # 6. 清理系统配置
    echo -e "${Info} 恢复系统网络配置..."
    systemctl daemon-reload
    
    # 7. 删除便捷脚本
    [[ -f "/root/show_wg_links.sh" ]] && rm -f /root/show_wg_links.sh
    
    echo -e "${OK} ============== 卸载完成 =============="
    echo -e "${OK} WireGuard 已完全卸载"
    echo -e "${Info} 系统已清理干净，可以重新安装或使用其他VPN方案"
    echo ""
    read -p "按任意键返回主菜单..." -n 1 < /dev/tty
}

# 主菜单循环
main_menu() {
    while true; do
        show_main_menu
        read -p "请选择功能 (0-7): " choice < /dev/tty
        
        case $choice in
            1)
                echo -e "${Info} 开始安装 WireGuard..."
                echo ""
                # 跳转到安装流程 (原来的脚本主体)
                return
                ;;
            2)
                show_all_links
                ;;
            3)
                show_specific_link
                ;;
            4)
                show_clean_links
                ;;
            5)
                show_service_status
                ;;
            7)
                generate_all_configs_and_links
                ;;
            6)
                uninstall_wireguard
                ;;
            0)
                echo -e "${Info} 感谢使用 WireGuard 管理工具！"
                exit 0
                ;;
            "")
                echo -e "${Warn} 未选择任何选项，请重新选择"
                sleep 2
                ;;
            *)
                echo -e "${Error} 无效选项，请选择 0-7"
                read -p "按任意键继续..." -n 1 < /dev/tty
                ;;
        esac
    done
}

# ======================= 工具函数 =======================

# 日志记录函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"
    
    echo "$log_entry" >> "$LOG_FILE"
    
    if [[ $QUIET_MODE -eq 0 ]]; then
        case "$level" in
            "INFO")
                echo -e "${CYAN}${ICON_INFO} ${message}${RESET}" >&2
                ;;
            "OK"|"SUCCESS")
                echo -e "${GREEN}${ICON_OK} ${message}${RESET}" >&2
                ;;
            "WARN"|"WARNING")
                echo -e "${YELLOW}${ICON_WARN} ${message}${RESET}" >&2
                ;;
            "ERROR")
                echo -e "${RED}${ICON_ERROR} ${message}${RESET}" >&2
                ;;
            "QUESTION")
                echo -e "${BLUE}${ICON_QUESTION} ${message}${RESET}" >&2
                ;;
            *)
                echo -e "${message}" >&2
                ;;
        esac
    fi
}

# 错误处理函数
handle_error() {
    local line_no=$1
    local error_code=$2
    local command_line=${3:-"Unknown"}
    
    log "ERROR" "脚本在第 $line_no 行出错，退出码: $error_code"
    log "ERROR" "失败的命令: $command_line"
    
    cleanup_on_error
    exit $error_code
}

# 错误时清理函数
cleanup_on_error() {
    log "WARN" "发生错误，正在清理..."
    
    # 停止WireGuard服务 (优化：批量操作)
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        wg-quick down wg0 2>/dev/null || true
        systemctl disable wg-quick@wg0 2>/dev/null || true
    fi
    
    # 清理可能的残留进程
    pkill -f "wg-quick" 2>/dev/null || true
    
    # 移除可能创建的配置文件
    if [[ -f "$WG_CONFIG_DIR/wg0.conf" ]]; then
        rm -f "$WG_CONFIG_DIR/wg0.conf"
    fi
    
    log "INFO" "清理完成"
}

# 优雅中断处理
cleanup_on_interrupt() {
    log "WARN" "安装被用户中断，正在清理..."
    cleanup_on_error
    exit 130
}

# 设置错误陷阱
trap 'handle_error $LINENO $? "$BASH_COMMAND"' ERR
trap cleanup_on_interrupt SIGINT SIGTERM

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local desc=${3:-"处理中"}
    
    local percentage=$((current * 100 / total))
    local bar_length=40
    local filled_length=$((percentage * bar_length / 100))
    
    printf "\\r${CYAN}[%s]${RESET} [" "$desc"
    printf "%*s" $filled_length | tr ' ' '='
    printf "%*s" $((bar_length - filled_length))
    printf "] %3d%% (%d/%d)" $percentage $current $total
    
    if [[ $current -eq $total ]]; then
        echo
    fi
}

# 确认提示
confirm() {
    local question=$1
    local default=${2:-"n"}
    
    while true; do
        if [[ $default == "y" ]]; then
            log "QUESTION" "$question [Y/n]: "
        else
            log "QUESTION" "$question [y/N]: "
        fi
        
        read -r response < /dev/tty
        response=${response:-$default}
        
        case $response in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                log "ERROR" "请回答 yes 或 no"
                ;;
        esac
    done
}

# 安全的网络请求
safe_curl() {
    local url=$1
    local timeout=${2:-10}
    local retries=${3:-3}
    local result
    
    for ((i=1; i<=retries; i++)); do
        if result=$(curl -s --connect-timeout $timeout --max-time $timeout "$url" 2>/dev/null); then
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
        fi
        
        if [[ $i -lt $retries ]]; then
            log "WARN" "网络请求失败，重试 $i/$retries (等待 ${i}s)"
            sleep $i
        fi
    done
    
    log "ERROR" "网络请求最终失败: $url"
    return 1
}

# ======================= 验证函数 =======================

# IPv4地址验证
validate_ipv4() {
    local ip=$1
    local IFS='.'
    read -ra octets <<< "$ip"
    
    if [[ ${#octets[@]} -ne 4 ]]; then
        return 1
    fi
    
    for octet in "${octets[@]}"; do
        if ! [[ $octet =~ ^[0-9]+$ ]] || [[ $octet -lt 0 ]] || [[ $octet -gt 255 ]]; then
            return 1
        fi
        
        # 检查前导零
        if [[ ${#octet} -gt 1 && ${octet:0:1} == "0" ]]; then
            return 1
        fi
    done
    
    return 0
}

# IPv4网络前缀验证
validate_ipv4_network() {
    local network=$1
    local IFS='.'
    read -ra octets <<< "$network"
    
    if [[ ${#octets[@]} -ne 3 ]]; then
        return 1
    fi
    
    for octet in "${octets[@]}"; do
        if ! [[ $octet =~ ^[0-9]+$ ]] || [[ $octet -lt 0 ]] || [[ $octet -gt 255 ]]; then
            return 1
        fi
    done
    
    # 检查是否为私有网络
    local first_octet=${octets[0]}
    local second_octet=${octets[1]}
    
    if [[ $first_octet -eq 10 ]]; then
        return 0
    elif [[ $first_octet -eq 172 && $second_octet -ge 16 && $second_octet -le 31 ]]; then
        return 0
    elif [[ $first_octet -eq 192 && $second_octet -eq 168 ]]; then
        return 0
    fi
    
    log "WARN" "警告: $network 不是标准私有网络范围"
    return 0  # 仍然允许，但发出警告
}

# 端口号验证
validate_port() {
    local port=$1
    
    if ! [[ $port =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi
    
    # 检查端口是否被占用 (优化：优先使用ss命令)
    if command -v ss >/dev/null 2>&1; then
        if ss -tulpn 2>/dev/null | grep -q ":$port "; then
            log "ERROR" "端口 $port 已被占用"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tulpn 2>/dev/null | grep -q ":$port "; then
            log "ERROR" "端口 $port 已被占用"
            return 1
        fi
    fi
    
    return 0
}

# 配置验证函数
validate_configuration() {
    local config_file="$1"
    
    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "配置文件不存在: $config_file"
        return 1
    fi
    
    # 检查配置文件格式
    if ! grep -q "^\[Interface\]" "$config_file" 2>/dev/null; then
        log "ERROR" "配置文件格式错误：缺少 [Interface] 段"
        return 1
    fi
    
    # 检查必要字段
    local required_fields=("PrivateKey" "Address")
    for field in "${required_fields[@]}"; do
        if ! grep -q "^${field} *=" "$config_file"; then
            log "ERROR" "配置文件缺少必要字段: $field"
            return 1
        fi
    done
    
    # 验证WireGuard配置语法 (如果wg命令可用)
    if command -v wg >/dev/null 2>&1; then
        if ! wg-quick strip "$config_file" >/dev/null 2>&1; then
            log "ERROR" "WireGuard配置语法验证失败"
            return 1
        fi
    fi
    
    log "INFO" "配置文件验证通过: $config_file"
    return 0
}

# 系统兼容性检查
check_system_requirements() {
    log "INFO" "检查系统要求..."
    
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "此脚本必须以root权限运行"
        exit 1
    fi
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        log "ERROR" "无法检测操作系统信息"
        exit 1
    fi
    
    # 检查是否为Linux系统
    if ! grep -qi linux /proc/version 2>/dev/null; then
        log "ERROR" "此脚本仅支持Linux系统"
        exit 1
    fi
    
    # 检查必需的命令
    local required_commands=("curl" "iptables" "ip6tables" "systemctl" "wg" "wg-quick")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log "INFO" "以下命令需要安装: ${missing_commands[*]}"
        if [[ "${missing_commands[*]}" =~ "wg" ]]; then
            log "INFO" "WireGuard 将在后续步骤中自动安装"
        fi
    fi
    
    # 检查内核模块
    if ! lsmod | grep -q wireguard 2>/dev/null && ! modprobe wireguard 2>/dev/null; then
        log "INFO" "WireGuard 内核模块将在安装后加载"
    fi
    
    # 检查systemd
    if ! command -v systemctl >/dev/null 2>&1; then
        log "ERROR" "需要 systemd 支持"
        exit 1
    fi
    
    log "OK" "系统要求检查通过"
}

# 检查现有安装
check_existing_installation() {
    if [[ -f "$WG_CONFIG_DIR/wg0.conf" ]] || ls "$WG_CONFIG_DIR"/wg_*.wg >/dev/null 2>&1; then
        log "WARN" "检测到已存在的 WireGuard 配置"
        
        # 无论如何都自动备份现有配置
        backup_existing_config
        
        if [[ $FORCE_INSTALL -eq 0 ]]; then
            if confirm "是否覆盖现有配置？" "n"; then
                log "INFO" "继续安装，现有配置已备份"
            else
                log "INFO" "安装已取消，配置已备份到: $BACKUP_DIR"
                exit 0
            fi
        else
            log "INFO" "强制安装模式，现有配置已自动备份"
        fi
    fi
}

# 备份现有配置
backup_existing_config() {
    local backup_dir="$BACKUP_DIR/$(date +%Y%m%d_%H%M%S)"
    
    log "INFO" "备份现有配置到: $backup_dir"
    mkdir -p "$backup_dir"
    
    local backup_count=0
    
    # 备份服务端配置文件
    if [[ -f "$WG_CONFIG_DIR/wg0.conf" ]]; then
        cp "$WG_CONFIG_DIR/wg0.conf" "$backup_dir/"
        ((backup_count++))
    fi
    
    # 备份客户端配置文件和链接文件
    find "$WG_CONFIG_DIR" -name "wg_*.conf" -o -name "wg_*.wg" -o -name "wg_*.png" | while read -r file; do
        if [[ -f "$file" ]]; then
            cp "$file" "$backup_dir/"
            ((backup_count++))
        fi
    done
    
    # 备份密钥文件
    for keyfile in sprivatekey spublickey cprivatekey* cpublickey*; do
        [[ -f "$WG_CONFIG_DIR/$keyfile" ]] && cp "$WG_CONFIG_DIR/$keyfile" "$backup_dir/"
    done
    
    log "OK" "备份完成，已保存 $backup_count 个文件到: $backup_dir"
    
    # 停止现有服务
    if systemctl is-active --quiet wg-quick@wg0; then
        log "INFO" "停止现有WireGuard服务"
        wg-quick down wg0
    fi
    
    log "OK" "配置备份完成"
}

# ======================= 网络检测函数 =======================

# 安全的网络接口检测
detect_network_interface() {
    log "INFO" "检测网络接口..."
    
    local default_interface
    local active_interfaces=()
    
    # 获取默认路由接口
    default_interface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    
    # 验证默认接口是否存在且UP
    if [[ -n "$default_interface" ]] && ip link show "$default_interface" >/dev/null 2>&1; then
        local interface_state
        interface_state=$(ip link show "$default_interface" | grep -o "state [A-Z]*" | awk '{print $2}')
        if [[ "$interface_state" == "UP" ]]; then
            echo "$default_interface"
            log "OK" "使用默认网络接口: $default_interface"
            return 0
        fi
    fi
    
    # 如果默认接口不可用，查找其他活跃接口
    while IFS= read -r interface; do
        if [[ "$interface" != "lo" && "$interface" != "wg0" ]]; then
            active_interfaces+=("$interface")
        fi
    done < <(ip link show | grep -E "^[0-9]+:" | grep "state UP" | awk -F': ' '{print $2}' | awk '{print $1}')
    
    if [[ ${#active_interfaces[@]} -gt 0 ]]; then
        local selected_interface="${active_interfaces[0]}"
        echo "$selected_interface"
        log "OK" "使用网络接口: $selected_interface"
        return 0
    fi
    
    # 最后的备选方案
    log "WARN" "无法检测到活跃的网络接口，使用默认值 eth0"
    echo "eth0"
    return 0
}

# 获取服务器IP地址
get_server_ip() {
    log "INFO" "获取服务器IP地址..."
    
    local server_ip=""
    
    # 检查环境变量
    if [[ -n "${WG_ENDPOINT_IP:-}" ]]; then
        server_ip="$WG_ENDPOINT_IP"
        log "OK" "使用环境变量指定的IP: $server_ip"
        echo "$server_ip"
        return 0
    fi
    
    # 检查是否强制使用IPv6
    if [[ "${WG_USE_IPV6:-}" == "1" ]]; then
        server_ip=$(get_ipv6_address)
        if [[ -n "$server_ip" ]]; then
            echo "$server_ip"
            return 0
        else
            log "WARN" "无法获取IPv6地址，回退到IPv4"
        fi
    fi
    
    # 尝试获取IPv4地址
    server_ip=$(get_ipv4_address)
    if [[ -n "$server_ip" ]]; then
        echo "$server_ip"
        return 0
    fi
    
    log "ERROR" "无法获取服务器IP地址"
    return 1
}

# 获取IPv4地址
get_ipv4_address() {
    local ipv4_sources=(
        "https://ipv4.icanhazip.com"
        "https://v4.ident.me"
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
    )
    
    for source in "${ipv4_sources[@]}"; do
        local ip
        if ip=$(safe_curl "$source" 5 1); then
            if validate_ipv4 "$ip"; then
                log "OK" "获取到IPv4地址: $ip (来源: $source)"
                echo "$ip"
                return 0
            fi
        fi
    done
    
    return 1
}

# 获取IPv6地址
get_ipv6_address() {
    local detected_interface
    detected_interface=$(detect_network_interface)
    
    # 尝试从网络接口获取全局IPv6地址
    local ipv6_addr
    ipv6_addr=$(ip -6 addr show "$detected_interface" 2>/dev/null | grep "inet6.*scope global" | head -1 | awk '{print $2}' | cut -d'/' -f1)
    
    if [[ -n "$ipv6_addr" ]]; then
        log "OK" "获取到IPv6地址: $ipv6_addr"
        echo "$ipv6_addr"
        return 0
    fi
    
    # 尝试通过外部服务获取IPv6地址
    local ipv6_sources=(
        "https://ipv6.icanhazip.com"
        "https://v6.ident.me"
    )
    
    for source in "${ipv6_sources[@]}"; do
        local ip
        if ip=$(safe_curl "$source" 5 1); then
            if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                log "OK" "获取到IPv6地址: $ip (来源: $source)"
                echo "$ip"
                return 0
            fi
        fi
    done
    
    return 1
}

# 智能检测IPv6前缀
detect_ipv6_prefix() {
    local detected_interface
    detected_interface=$(detect_network_interface)
    
    # 尝试获取服务器的全局IPv6前缀
    local ipv6_prefix
    ipv6_prefix=$(ip -6 addr show "$detected_interface" 2>/dev/null | grep "inet6.*scope global" | grep -v "::1" | head -1 | awk '{print $2}' | cut -d'/' -f1 | sed 's/::[^:]*$/::/')
    
    if [[ -n "$ipv6_prefix" && "$ipv6_prefix" != "::" ]]; then
        log "OK" "检测到IPv6前缀: $ipv6_prefix"
        echo "$ipv6_prefix"
        return 0
    fi
    
    # 回退到ULA私有地址
    log "INFO" "未检测到IPv6网段，使用ULA私有地址"
    echo "$ULA_IPV6_PREFIX"
    return 0
}

# ======================= 安全性函数 =======================

# 安全的密钥生成
generate_secure_keys() {
    log "INFO" "生成安全密钥..."
    
    local key_dir="$WG_CONFIG_DIR/keys"
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    
    # 设置严格的umask
    local old_umask
    old_umask=$(umask)
    umask 077
    
    # 生成服务端密钥
    if ! wg genkey > "$key_dir/server.key" 2>/dev/null; then
        log "ERROR" "无法生成服务端私钥"
        umask "$old_umask"
        return 1
    fi
    
    if ! wg pubkey < "$key_dir/server.key" > "$key_dir/server.pub" 2>/dev/null; then
        log "ERROR" "无法生成服务端公钥"
        umask "$old_umask"
        return 1
    fi
    
    # 设置严格权限
    chmod 600 "$key_dir/server.key"
    chmod 644 "$key_dir/server.pub"
    chown root:root "$key_dir"/*
    
    umask "$old_umask"
    
    log "OK" "服务端密钥生成完成"
    return 0
}

# 生成客户端密钥对
generate_client_keys() {
    local client_count=$1
    
    log "INFO" "为 $client_count 个客户端生成密钥对..."
    
    declare -ga CLIENT_PRIVATE_KEYS
    declare -ga CLIENT_PUBLIC_KEYS
    
    local old_umask
    old_umask=$(umask)
    umask 077
    
    for ((i=0; i<client_count; i++)); do
        show_progress $((i+1)) "$client_count" "生成客户端密钥"
        
        local private_key public_key
        if ! private_key=$(wg genkey 2>/dev/null); then
            log "ERROR" "无法生成客户端 $((i+1)) 私钥"
            umask "$old_umask"
            return 1
        fi
        
        if ! public_key=$(echo "$private_key" | wg pubkey 2>/dev/null); then
            log "ERROR" "无法生成客户端 $((i+1)) 公钥"
            umask "$old_umask"
            return 1
        fi
        
        CLIENT_PRIVATE_KEYS[i]="$private_key"
        CLIENT_PUBLIC_KEYS[i]="$public_key"
    done
    
    umask "$old_umask"
    log "OK" "客户端密钥生成完成"
    return 0
}

# 防火墙规则管理
setup_firewall_rules() {
    local interface=$1
    local ipv4_cidr=$2
    local ipv6_network=$3
    
    log "INFO" "设置防火墙规则..."
    
    # 检查是否与现有规则冲突
    if iptables -L 2>/dev/null | grep -q "wireguard-managed"; then
        log "WARN" "检测到已存在的 WireGuard 防火墙规则，清理后重新设置"
        cleanup_firewall_rules
    fi
    
    # IPv4 规则
    if ! iptables -I FORWARD -i wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; then
        log "ERROR" "无法添加IPv4转发规则"
        return 1
    fi
    
    if ! iptables -I FORWARD -o wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; then
        log "ERROR" "无法添加IPv4转发规则"
        return 1
    fi
    
    if ! iptables -t nat -A POSTROUTING -s "$ipv4_cidr" -o "$interface" -j MASQUERADE -m comment --comment "wireguard-managed" 2>/dev/null; then
        log "ERROR" "无法添加IPv4 NAT规则"
        return 1
    fi
    
    # IPv6 规则
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -I FORWARD -i wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null || log "WARN" "IPv6转发规则设置失败"
        ip6tables -I FORWARD -o wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null || log "WARN" "IPv6转发规则设置失败"
        ip6tables -t nat -A POSTROUTING -s "$ipv6_network" -o "$interface" -j MASQUERADE -m comment --comment "wireguard-managed" 2>/dev/null || log "WARN" "IPv6 NAT规则设置失败"
    fi
    
    log "OK" "防火墙规则设置完成"
    return 0
}

# 清理防火墙规则
cleanup_firewall_rules() {
    log "INFO" "清理WireGuard防火墙规则..."
    
    # 清理IPv4规则
    while iptables -D FORWARD -i wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; do
        :
    done
    
    while iptables -D FORWARD -o wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; do
        :
    done
    
    while iptables -t nat -D POSTROUTING -j MASQUERADE -m comment --comment "wireguard-managed" 2>/dev/null; do
        :
    done
    
    # 清理IPv6规则
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -D FORWARD -i wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; do
            :
        done
        
        while ip6tables -D FORWARD -o wg0 -j ACCEPT -m comment --comment "wireguard-managed" 2>/dev/null; do
            :
        done
        
        while ip6tables -t nat -D POSTROUTING -j MASQUERADE -m comment --comment "wireguard-managed" 2>/dev/null; do
            :
        done
    fi
    
    log "OK" "防火墙规则清理完成"
}

# 优化的安装函数
install_wireguard_packages() {
    log "INFO" "开始安装WireGuard..."
    
    # 更新软件包源（忽略签名错误）
    log "INFO" "更新软件包列表..."
    apt update -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true || true
    
    # 安装基础包
    log "INFO" "安装基础软件包..."
    apt install -y linux-headers-$(uname -r) curl qrencode || {
        log "ERROR" "安装基础包失败"
        exit 1
    }
    
    # 尝试安装WireGuard
    log "INFO" "安装WireGuard..."
    if apt install -y wireguard resolvconf; then
        log "OK" "WireGuard安装成功"
    else
        log "WARN" "从标准源安装失败，尝试其他方法..."
        # 移除可能有问题的源
        rm -f /etc/apt/sources.list.d/unstable.list /etc/apt/preferences.d/limit-unstable
        
        # 更新源列表
        apt update || true
        
        # 再次尝试安装
        if apt install -y wireguard wireguard-tools resolvconf; then
            log "OK" "WireGuard安装成功"
        else
            log "ERROR" "WireGuard安装失败"
            log "INFO" "请手动安装: apt install wireguard wireguard-tools"
            exit 1
        fi
    fi
}

# ======================= 主程序入口 =======================

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${Error} 此脚本需要root权限运行"
    echo -e "${Info} 请使用: sudo $0"
    exit 1
fi

# 启动主菜单系统
main_menu

# ======================= 安装流程 =======================
# 以下是原始的安装流程，由菜单选择后执行

# 调用安装函数
install_wireguard_packages

# 验证是否安装成功
if modprobe wireguard 2>/dev/null; then
    echo -e "${OK} WireGuard 内核模块加载成功"
    if lsmod | grep -q wireguard; then
        echo -e "${OK} WireGuard 模块验证通过"
    fi
else
    echo -e "${Warn} WireGuard 内核模块加载失败，但软件包已安装"
fi

# 配置步骤 WireGuard服务端

 
sysctl_config() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

# 开启 BBR
sysctl_config
if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]]; then
    echo -e "${OK} BBR 已启用并正常工作"
    if lsmod | grep -q tcp_bbr 2>/dev/null; then
        echo -e "${Info} BBR 作为内核模块运行"
    else
        echo -e "${Info} BBR 已编译进内核（推荐配置）"
    fi
else
    echo -e "${Warn} BBR 未启用，当前使用: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
fi
 
# 打开防火墙转发功能
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.accept_ra=2" >> /etc/sysctl.conf
sysctl -p


# 定义修改端口号，适合已经安装WireGuard而不想改端口
# （这些变量现在在脚本开头定义）


host=$(hostname -s)
# 获得服务器ip，自动获取
if [ ! -f '/usr/bin/curl' ]; then
    apt install -y curl
fi

# 获取服务器IP地址 (支持环境变量控制)
if [ "${WG_USE_IPV6:-}" = "1" ]; then
    echo -e "${Info} 获取服务器IPv6地址..."
    # 直接使用本机IPv6地址
    serverip=$(ip -6 addr show ens34 | grep "inet6.*scope global" | head -1 | awk '{print $2}' | cut -d'/' -f1)
    if [ -n "$serverip" ]; then
        echo -e "${OK} 使用本机IPv6地址: $serverip"
    else
        echo -e "${Error} 本机无IPv6地址，回退到IPv4"
        serverip=$(curl -4 ip.sb)
        echo -e "${OK} 获取到IPv4地址: $serverip"
    fi
elif [ -z "${WG_ENDPOINT_IP:-}" ]; then
    # 交互式选择
    echo -e "${Info} 选择Endpoint地址类型："
    echo "1. IPv4地址 (默认，兼容性最好)" 
    echo "2. IPv6地址"
    echo "3. 手动指定IP地址"
    read -p "请选择 [1-3]，默认为1: " ip_choice < /dev/tty
    ip_choice=${ip_choice:-1}
    
    case $ip_choice in
        2)
            echo -e "${Info} 获取服务器IPv6地址..."
            # 直接使用本机IPv6地址
            serverip=$(ip -6 addr show ens34 | grep "inet6.*scope global" | head -1 | awk '{print $2}' | cut -d'/' -f1)
            if [ -n "$serverip" ]; then
                echo -e "${OK} 使用本机IPv6地址: $serverip"
            else
                echo -e "${Error} 本机无IPv6地址，回退到IPv4"
                serverip=$(curl -4 ip.sb)
                echo -e "${OK} 获取到IPv4地址: $serverip"
            fi
            ;;
        3)
            read -p "请输入服务器IP地址: " manual_ip < /dev/tty
            if [ -z "$manual_ip" ]; then
                echo -e "${Error} 未输入IP地址，使用默认IPv4"
                serverip=$(curl -4 ip.sb)
            else
                serverip="$manual_ip"
                echo -e "${OK} 使用手动指定的IP地址: $serverip"
            fi
            ;;
        *)
            echo -e "${Info} 获取服务器IPv4地址..."
            serverip=$(curl -4 ip.sb)
            echo -e "${OK} 获取到IPv4地址: $serverip"
            ;;
    esac
else
    # 使用环境变量指定的IP
    serverip="${WG_ENDPOINT_IP:-}"
    echo -e "${OK} 使用环境变量指定的IP地址: $serverip"
fi

# 安装二维码插件
if [ ! -f '/usr/bin/qrencode' ]; then
    apt -y install qrencode
fi


# wg配置文件目录 /etc/wireguard
mkdir -p /etc/wireguard
chmod 750 -R /etc/wireguard
cd /etc/wireguard

# 生成服务端密钥对
wg genkey | tee sprivatekey | wg pubkey > spublickey

# IPv6前缀已在前面定义，这里删除重复定义

# 检测IPv6前缀
ipv6_prefix=$(detect_ipv6_prefix)

if [ "$ipv6_prefix" != "fd42:d686:95dc::" ]; then
    echo -e "${Info} 检测到IPv6前缀: $ipv6_prefix，将使用此网段"
else
    echo -e "${Info} 未检测到IPv6网段，使用ULA私有地址: fd42:d686:95dc::"
fi

# IPv4网段自定义配置
if [ -z "${WG_IPV4_NETWORK:-}" ]; then
    # 交互式选择IPv4网段
    echo -e "${Info} 配置WireGuard IPv4虚拟网段："
    echo "1. 192.168.3.0/24 (默认)"
    echo "2. 10.0.0.0/24"
    echo "3. 172.16.0.0/24"
    echo "4. 自定义网段"
    read -p "请选择 [1-4]，默认为1: " ipv4_choice < /dev/tty
    ipv4_choice=${ipv4_choice:-1}
    
    case $ipv4_choice in
        2)
            ipv4_network="10.0.0"
            ipv4_cidr="10.0.0.0/24"
            ;;
        3)
            ipv4_network="172.16.0"
            ipv4_cidr="172.16.0.0/24"
            ;;
        4)
            read -p "请输入自定义网段前缀 (如 192.168.100): " custom_network < /dev/tty
            if [ -z "$custom_network" ]; then
                echo -e "${Error} 未输入网段，使用默认 192.168.3"
                custom_network="192.168.3"
            fi
            if [[ $custom_network =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                ipv4_network="$custom_network"
                ipv4_cidr="${custom_network}.0/24"
            else
                echo -e "${Error} 网段格式错误，使用默认网段"
                ipv4_network="$DEFAULT_IPV4_NETWORK"
                ipv4_cidr="$DEFAULT_IPV4_CIDR"
            fi
            ;;
        *)
            ipv4_network="$DEFAULT_IPV4_NETWORK"
            ipv4_cidr="$DEFAULT_IPV4_CIDR"
            ;;
    esac
else
    # 使用环境变量指定的网段
    ipv4_network="$WG_IPV4_NETWORK"
    ipv4_cidr="${WG_IPV4_NETWORK}.0/24"
fi

echo -e "${OK} 选择的IPv4网段: $ipv4_cidr"

# 根据选择的网段动态生成客户端IP地址
user_ipv4=()
for ((i=2; i<=11; i++))
do
    user_ipv4[$(($i-2))]="${ipv4_network}.${i}"
done

# IPv6地址将在配置生成时动态计算
echo -e "${Info} 将为客户端分配IPv6地址: ${ipv6_prefix}2 到 ${ipv6_prefix}11"

# 为10个客户端生成密钥对
declare -a client_private_keys
declare -a client_public_keys

echo -e "${Info} 正在为10个客户端生成密钥对..."
for ((i=0; i<10; i++))
do
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    client_private_keys[$i]="$private_key"
    client_public_keys[$i]="$public_key"
    echo "客户端 $((i+1)) 密钥对已生成"
done

# 预检测网卡接口用于PostUp/PostDown规则
detect_interface_for_config() {
    local default_if=$(ip route | awk '/default/ {print $5}' | head -1)
    if [ -n "$default_if" ] && ip link show "$default_if" >/dev/null 2>&1; then
        echo "$default_if"
    else
        echo "eth0"  # 回退到默认值
    fi
}

detected_interface=$(detect_interface_for_config)
echo -e "${Info} PostUp/PostDown规则将使用网卡: ${detected_interface}"

# 生成完整的服务端配置文件（包含10个客户端）
echo -e "${Info} 生成服务端配置文件 wg0.conf..."

# 构建IPv6网段用于PostUp/PostDown规则
ipv6_network="${ipv6_prefix%::}::/64"

cat <<EOF >wg0.conf
[Interface]
PrivateKey = $(cat sprivatekey)
Address = ${ipv4_network}.1/24 
Address = ${ipv6_prefix}1/64 
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 1 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s ${ipv4_cidr} -o ${detected_interface} -j MASQUERADE; ip6tables -I FORWARD 1 -i wg0 -j ACCEPT; ip6tables -I FORWARD 1 -o wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -s ${ipv6_network} -o ${detected_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s ${ipv4_cidr} -o ${detected_interface} -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -o wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -s ${ipv6_network} -o ${detected_interface} -j MASQUERADE
ListenPort = $port
MTU = $mtu
EOF

echo -e "${Info} 服务端IPv4地址: ${ipv4_network}.1/24"
echo -e "${Info} 服务端IPv6地址: ${ipv6_prefix}1/64"

# 添加所有10个客户端的peer配置
for ((i=0; i<10; i++))
do
    client_num=$((i+1))
    ipv4=${user_ipv4[$i]}
    # 直接生成IPv6地址，确保与客户端配置一致
    client_ipv6_num=$((i+2))
    ipv6="${ipv6_prefix}${client_ipv6_num}"
    public_key=${client_public_keys[$i]}
    
    cat <<EOF >>wg0.conf

[Peer]
PublicKey = ${public_key}
AllowedIPs = ${ipv4}/32, ${ipv6}/128
EOF
    echo "服务端添加客户端 ${client_num}: IPv4=${ipv4}/32, IPv6=${ipv6}/128"
done

# 生成10个客户端配置文件
echo -e "${Info} 生成10个客户端配置文件..."
for ((i=0; i<10; i++))
do
    client_num=$((i+1))
    ipv4=${user_ipv4[$i]}
    # 直接在这里生成IPv6地址，避免数组问题
    client_ipv6_num=$((i+2))  # 从2开始
    ipv6="${ipv6_prefix}${client_ipv6_num}"
    private_key=${client_private_keys[$i]}
    
    # 确保变量正确展开
    echo -e "${Info} 生成客户端 ${client_num}: IPv4=${ipv4}, IPv6=${ipv6}"
    
    # 处理IPv6 Endpoint格式
    if [[ $serverip =~ : ]]; then
        # IPv6地址需要用方括号包围
        endpoint="[${serverip}]:${port}"
    else
        # IPv4地址直接使用
        endpoint="${serverip}:${port}"
    fi
    
    cat <<EOF >wg_${host}_${client_num}.conf
[Interface]
PrivateKey = ${private_key}
Address = ${ipv4}/24
Address = ${ipv6}/128
DNS = 119.29.29.29, 2402:4e00::

[Peer]
PublicKey = $(cat spublickey)
Endpoint = ${endpoint}
AllowedIPs = 0.0.0.0/0, ::0/0
PersistentKeepalive = 25
EOF

    # 验证配置文件内容
    if grep -q "${ipv6}/128" "wg_${host}_${client_num}.conf"; then
        echo -e "${OK} 客户端 ${client_num} 配置文件生成成功 - IPv6: ${ipv6}/128"
    else
        echo -e "${Error} 客户端 ${client_num} IPv6地址配置失败"
    fi
    
    # 生成二维码图片
    cat /etc/wireguard/wg_${host}_${client_num}.conf | qrencode -o wg_${host}_${client_num}.png 2>/dev/null
    
    # 生成wireguard://链接 (正确格式)
    # 提取配置信息
    private_key_encoded=$(echo -n "${private_key}" | sed 's/+/%2B/g;s/\//%2F/g;s/=/%3D/g')
    public_key_encoded=$(echo -n "$(cat spublickey)" | sed 's/+/%2B/g;s/\//%2F/g;s/=/%3D/g')
    
    # 构建wireguard://链接
    if [[ $serverip =~ : ]]; then
        # IPv6地址
        wg_link="wireguard://${private_key_encoded}@[${serverip}]:${port}/?publickey=${public_key_encoded}&address=${ipv4}%2F24%2C${ipv6}%2F128&dns=119.29.29.29%2C2402%3A4e00%3A%3A&allowed-ips=0.0.0.0%2F0%2C%3A%3A0%2F0#wg_${host}_${client_num}"
    else
        # IPv4地址
        wg_link="wireguard://${private_key_encoded}@${serverip}:${port}/?publickey=${public_key_encoded}&address=${ipv4}%2F24%2C${ipv6}%2F128&dns=119.29.29.29%2C2402%3A4e00%3A%3A&allowed-ips=0.0.0.0%2F0%2C%3A%3A0%2F0#wg_${host}_${client_num}"
    fi
    
    echo "$wg_link" > wg_${host}_${client_num}.wg
    echo -e "${OK} 客户端 ${client_num} wireguard://链接已生成"
done

echo -e "${OK} 所有客户端配置文件生成完成"
echo -e "${OK} 所有客户端wireguard://链接生成完成"
echo -e "${Info} 客户端IPv6地址分配: ${ipv6_prefix}2 到 ${ipv6_prefix}11"

# 汇总显示所有wireguard://链接
echo -e "${Info} ============== 客户端链接汇总 =============="
for ((i=0; i<10; i++))
do
    client_num=$((i+1))
    if [[ -f "wg_${host}_${client_num}.wg" ]]; then
        wg_link_content=$(cat wg_${host}_${client_num}.wg)
        echo -e "${OK} 客户端${client_num}: $wg_link_content"
    fi
done


# 网络接口检测已在前面定义，这里删除重复定义

# 检测实际网卡
ni=$(detect_network_interface)
echo -e "${Info} 检测到网络接口: ${ni}"

# 更新配置文件中的网卡名称
if [ "$ni" != "eth0" ]; then
    sed -i "s/eth0/${ni}/g" /etc/wireguard/wg0.conf
    echo -e "${Info} 已将配置文件中的网卡名称更新为: ${ni}"
fi

# 防火墙兼容性检查
check_firewall_compatibility() {
    # 检查FORWARD链策略
    forward_policy=$(iptables -L FORWARD | head -1 | grep -o "policy [A-Z]*" | awk '{print $2}')
    if [ "$forward_policy" = "DROP" ]; then
        echo -e "${Info} FORWARD链策略为DROP，PostUp规则将添加明确的ACCEPT规则"
    else
        echo -e "${Info} FORWARD链策略为ACCEPT，网络转发正常"
    fi
}

# 停止可能存在的WireGuard服务
echo -e "${Info} 停止现有WireGuard服务..."
wg-quick down wg0 2>/dev/null || true

# 检查防火墙兼容性
check_firewall_compatibility

# 启动WireGuard服务
echo -e "${Info} 启动WireGuard服务..."
if wg-quick up wg0; then
    echo -e "${OK} WireGuard服务启动成功！"
else
    echo -e "${Error} WireGuard服务启动失败，尝试重启..."
    sleep 2
    wg-quick down wg0 2>/dev/null || true
    sleep 1
    if wg-quick up wg0; then
        echo -e "${OK} WireGuard服务重启成功！"
    else
        echo -e "${Error} WireGuard服务启动失败，请检查配置"
        exit 1
    fi
fi

# 验证服务状态
echo -e "${Info} 验证WireGuard服务状态..."
sleep 2

# 链接查看功能已集成到主脚本菜单中

if wg show >/dev/null 2>&1; then
    echo -e "${OK} WireGuard接口创建成功"
else
    echo -e "${Error} WireGuard接口创建失败"
    exit 1
fi

# 验证网络规则
if iptables -L FORWARD | grep -q "ACCEPT.*wg0" || iptables -L FORWARD | head -3 | grep -q "ACCEPT"; then
    echo -e "${OK} 防火墙转发规则配置正确"
else
    echo -e "${Error} 防火墙转发规则可能有问题"
fi

# 设置开机启动
systemctl enable wg-quick@wg0
echo -e "${OK} 已设置WireGuard开机启动"

# 最终状态检查
echo -e "${OK} WireGuard配置完成！当前状态："
wg

# 配置验证 (优化增强)
echo -e "${Info} 正在验证配置文件..."
if validate_configuration "$WG_CONFIG_DIR/wg0.conf"; then
    echo -e "${OK} 服务端配置验证通过"
else
    echo -e "${Error} 服务端配置验证失败，请检查配置"
fi

# 连接测试和故障排除信息
echo -e "${OK} ============== 配置完成 =============="
echo -e "${OK} 服务器公网IP: $serverip"
echo -e "${OK} 监听端口: $port"
echo -e "${OK} 服务端配置文件: /etc/wireguard/wg0.conf"
echo -e "${OK} 客户端配置文件: /etc/wireguard/wg_${host}_1.conf 到 wg_${host}_10.conf"
echo -e "${OK} 二维码文件: /etc/wireguard/wg_${host}_1.png 到 wg_${host}_10.png"
echo -e "${OK} wireguard://链接文件: /etc/wireguard/wg_${host}_1.wg 到 wg_${host}_10.wg"

# 网络连通性检查
echo -e "${Info} ============== 网络状态检查 =============="
echo -e "${Info} WireGuard网关IPv4地址: ${ipv4_network}.1"
echo -e "${Info} WireGuard网关IPv6地址: ${ipv6_prefix}1"
echo -e "${Info} 客户端IPv6地址段: ${ipv6_prefix}2 到 ${ipv6_prefix}11"

# 检查端口是否正确监听
if netstat -ulnp | grep -q ":$port "; then
    echo -e "${OK} UDP $port 端口正常监听"
else
    echo -e "${Error} UDP $port 端口未监听，可能存在问题"
fi

# 检查防火墙规则
forward_count=$(iptables -L FORWARD | grep -c "ACCEPT")
if [ $forward_count -gt 0 ]; then
    echo -e "${OK} 防火墙FORWARD规则配置正常 (${forward_count}条ACCEPT规则)"
else
    echo -e "${Error} 防火墙FORWARD规则可能有问题"
fi

# 检查NAT规则
nat_count=$(iptables -t nat -L POSTROUTING | grep -c "MASQUERADE")
if [ $nat_count -gt 0 ]; then
    echo -e "${OK} NAT MASQUERADE规则配置正常 (${nat_count}条规则)"
else
    echo -e "${Error} NAT规则可能有问题"
fi

echo -e "${Info} ============== 故障排除提示 =============="
echo -e "${Info} 如果客户端连接失败，请检查："
echo -e "${Info} 1. 客户端配置文件中的服务器地址是否为: $serverip:$port"
echo -e "${Info} 2. 服务器防火墙是否允许UDP $port端口"
echo -e "${Info} 3. 云服务器安全组是否开放UDP $port端口"
echo -e "${Info} 4. 客户端网络是否限制WireGuard流量"
echo -e "${Info} "
echo -e "${Info} ============== 管理命令 =============="
echo -e "${Info} 重启WireGuard服务: systemctl restart wg-quick@wg0"
echo -e "${Info} 查看服务状态: systemctl status wg-quick@wg0"
echo -e "${Info} 查看接口状态: wg show"
echo -e "${Info} 查看实时日志: journalctl -u wg-quick@wg0 -f"
echo -e "${Info} 查看连接统计: wg show wg0 dump"
echo -e "${Info} "
echo -e "${Info} ============== 配置管理 =============="
echo -e "${Info} 配置备份目录: $BACKUP_DIR"
echo -e "${Info} 服务端配置: $WG_CONFIG_DIR/wg0.conf"
echo -e "${Info} 客户端配置: $WG_CONFIG_DIR/wg_${host}_*.conf"
echo -e "${Info} 二维码图片: $WG_CONFIG_DIR/wg_${host}_*.png"
echo -e "${Info} wireguard://链接: $WG_CONFIG_DIR/wg_${host}_*.wg"
echo -e "${Info} "
echo -e "${Info} ============== wireguard://链接使用方法 =============="
echo -e "${Info} 1. 复制 .wg 文件中的 wireguard:// 链接"
echo -e "${Info} 2. 在WireGuard客户端中选择'从剪贴板导入'"
echo -e "${Info} 3. 或者直接在浏览器中打开wireguard://链接自动导入"
echo -e "${Info} 4. 查看链接: cat $WG_CONFIG_DIR/wg_${host}_1.wg"
echo -e "${Info} 5. 查看所有链接: ls $WG_CONFIG_DIR/wg_${host}_*.wg"
echo -e "${Info} "
echo -e "${Info} ============== 快速复制链接 =============="
if [[ -f "$WG_CONFIG_DIR/wg_${host}_1.wg" ]]; then
    echo -e "${Info} 客户端1链接 (示例):"
    echo -e "${OK} $(cat $WG_CONFIG_DIR/wg_${host}_1.wg)"
    echo -e "${Info} "
    echo -e "${Info} 查看所有链接: 重新运行此脚本选择菜单选项2"
fi
echo -e "${Info} "
echo -e "${Info} ============== 管理功能 =============="
echo -e "${Info} 查看所有链接: 重新运行脚本选择选项2"
echo -e "${Info} 重新运行管理工具: bash $0"

# 安装完成后提示返回菜单
echo ""
read -p "按任意键返回主菜单..." -n 1 < /dev/tty
main_menu