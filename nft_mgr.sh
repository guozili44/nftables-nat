#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 自动检查并安装依赖 ---
function check_dependencies() {
    echo -e "${BLUE}[1/3] 正在检查系统依赖...${PLAIN}"
    local apps=("nft" "dig" "sysctl" "crontab")
    local missing=()

    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null && [ "$app" != "crontab" ]; then
            missing+=("$app")
        fi
    done

    # 特殊检查 crontab
    if ! command -v crontab &> /dev/null; then
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y cron
            systemctl enable cron && systemctl start cron
        else
            yum install -y cronie
            systemctl enable crond && systemctl start crond
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}检测到缺少组件: ${missing[*]}，正在安装...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update
            apt-get install -y nftables dnsutils iproute2
        else
            yum install -y nftables bind-utils procps-ng
        fi
    fi
    
    # 确保 nftables 服务启动
    systemctl enable nftables && systemctl start nftables
    echo -e "${GREEN}依赖检查完成。${PLAIN}"
}

# --- 2. 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR、内核转发及系统优化...${PLAIN}"
    sudo tee /etc/sysctl.d/99-sys-opt.conf > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl --system
    echo -e "${GREEN}系统优化已完成。${PLAIN}"
}

# --- 3. 域名解析与转发逻辑 ---
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

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            current_ip=$(get_ip "$addr")
            if [ ! -z "$current_ip" ]; then
                nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat postrouting ip daddr $current_ip masquerade
            fi
        done < "$CONFIG_FILE"
    fi
    nft list ruleset > "$NFT_CONF"
}

# --- 4. 定时任务管理 ---
function manage_cron() {
    local script_path=$(realpath "$0")
    if crontab -l 2>/dev/null | grep -q "$script_path"; then
        echo -e "${GREEN}当前状态：定时监控 [已开启]${PLAIN}"
        read -p "是否关闭定时监控？(y/n): " opt
        [[ "$opt" == [yY] ]] && crontab -l | grep -v "$script_path" | crontab - && echo "已关闭。"
    else
        echo -e "${RED}当前状态：定时监控 [已关闭]${PLAIN}"
        read -p "是否开启每 5 分钟自动更新域名 IP？(y/n): " opt
        if [[ "$opt" == [yY] ]]; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $script_path --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}已开启。${PLAIN}"
        fi
    fi
}

# --- 5. 交互面板功能 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址 (域名/IP): " taddr
    read -p "请输入目标端口: " tport
    tip=$(get_ip "$taddr")
    [ -z "$tip" ] && echo -e "${RED}解析失败!${PLAIN}" && return
    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功。${PLAIN}"
}

function show_forward() {
    echo -e "\n${BLUE}--- 当前转发列表 ---${PLAIN}"
    if [ ! -s "$CONFIG_FILE" ]; then echo "暂无数据"; return; fi
    printf "%-8s | %-20s | %-8s | %-15s\n" "本地端口" "目标地址" "目标端口" "当前IP"
    while IFS='|' read -r lp addr tp last_ip; do
        printf "%-8s | %-20s | %-8s | %-15s\n" "$lp" "$addr" "$tp" "$(get_ip $addr)"
    done < "$CONFIG_FILE"
}

function reset_all() {
    read -p "危险操作：确定清空所有配置和规则吗？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE"
        nft flush ruleset
        echo "" > "$NFT_CONF"
        echo -e "${GREEN}已彻底重置。${PLAIN}"
    fi
}

# --- 6. 运行入口 ---
if [ "$1" == "--cron" ]; then
    apply_rules
    exit 0
fi

check_dependencies

while true; do
    echo -e "\n${BLUE}==============================${PLAIN}"
    echo -e "${GREEN}   nftables 域名转发管理面板   ${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名)"
    echo "3. 查看当前转发列表"
    echo "4. 删除单条转发"
    echo "5. 彻底清空配置与规则 (防冲突)"
    echo "6. 管理定时监控 (DDNS 自动同步)"
    echo "0. 退出"
    echo "------------------------------"
    read -p "请选择: " choice
    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车返回..." ;;
        4) 
            show_forward
            read -p "输入要删除的本地端口: " dp
            sed -i "/^$dp|/d" "$CONFIG_FILE"
            apply_rules ; echo "已删除。"
            ;;
        5) reset_all ;;
        6) manage_cron ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
