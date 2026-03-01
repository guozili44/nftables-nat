#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 自动检查并安装依赖 ---
function check_dependencies() {
    local apps=("nft" "dig")
    local missing=()
    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then missing+=("$app"); fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装必要依赖...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y nftables dnsutils cron
            systemctl enable cron && systemctl start cron
        else
            yum install -y nftables bind-utils cronie
            systemctl enable crond && systemctl start crond
        fi
    fi
    systemctl enable nftables && systemctl start nftables
}

# --- 2. 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}开启 BBR 和内核转发...${PLAIN}"
    sudo tee $SYS_OPT_CONF > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl --system
    echo -e "${GREEN}系统优化已应用。${PLAIN}"
}

# --- 3. 核心转发逻辑 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

function apply_rules() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
    [ ! -f "$CONFIG_FILE" ] && return
    while IFS='|' read -r lp addr tp last_ip; do
        [ -z "$lp" ] && continue
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat postrouting ip daddr $current_ip masquerade
        fi
    done < "$CONFIG_FILE"
    nft list ruleset > "$NFT_CONF"
}

# --- 4. 卸载脚本功能 ---
function uninstall_all() {
    echo -e "${RED}确认要完全卸载此脚本及所有转发规则吗？${PLAIN}"
    read -p "请输入 [y/n]: " confirm
    if [[ "$confirm" == [yY] ]]; then
        # 1. 清理定时任务
        local script_path=$(realpath "$0")
        crontab -l 2>/dev/null | grep -v "$script_path" | crontab -
        
        # 2. 清理 nftables 规则
        nft flush ruleset
        systemctl stop nftables
        systemctl disable nftables
        
        # 3. 删除配置文件
        rm -f "$CONFIG_FILE"
        rm -f "$NFT_CONF"
        rm -f "$SYS_OPT_CONF"
        
        echo -e "${GREEN}转发规则已清空，配置文件已删除。${PLAIN}"
        echo -e "${YELLOW}脚本即将自删...${PLAIN}"
        rm -f "$script_path"
        exit 0
    else
        echo "卸载已取消。"
    fi
}

# --- 5. 菜单与交互 ---
function manage_cron() {
    local script_path=$(realpath "$0")
    if crontab -l 2>/dev/null | grep -q "$script_path"; then
        echo -e "${GREEN}状态：定时监控运行中${PLAIN}"
        read -p "是否关闭？(y/n): " opt
        [[ "$opt" == [yY] ]] && crontab -l | grep -v "$script_path" | crontab -
    else
        echo -e "${RED}状态：定时监控未开启${PLAIN}"
        read -p "是否开启每5分钟同步？(y/n): " opt
        [[ "$opt" == [yY] ]] && (crontab -l 2>/dev/null; echo "*/5 * * * * $script_path --cron > /dev/null 2>&1") | crontab -
    fi
}

if [ "$1" == "--cron" ]; then apply_rules ; exit 0 ; fi
check_dependencies

while true; do
    echo -e "\n${BLUE}==============================${PLAIN}"
    echo -e "${GREEN}   nftables 域名转发管理面板   ${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 彻底清空配置与规则 (防冲突)"
    echo "6. 管理定时监控 (DDNS 自动同步)"
    echo -e "${RED}7. 卸载脚本并清理环境${PLAIN}"
    echo "0. 退出"
    echo "------------------------------"
    read -p "请选择: " choice
    case $choice in
        1) optimize_system ;;
        2) 
            read -p "本地端口: " lp
            read -p "目标地址: " ad
            read -p "目标端口: " tp
            echo "$lp|$ad|$tp|$(get_ip $ad)" >> "$CONFIG_FILE"
            apply_rules ;;
        3) 
            echo -e "\n本地端口 | 目标地址 | 目标端口 | 解析IP"
            while IFS='|' read -r lp ad tp li; do printf "%-8s | %-12s | %-8s | %-15s\n" "$lp" "$ad" "$tp" "$(get_ip $ad)"; done < "$CONFIG_FILE"
            read -p "回车继续..." ;;
        4) 
            read -p "输入要删除的本地端口: " dp
            sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ;;
        5) 
            rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE" ; nft flush ruleset ; echo "" > "$NFT_CONF" ;;
        6) manage_cron ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
done
