#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    sudo tee /etc/sysctl.d/99-sys-opt.conf > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl --system
    echo -e "${GREEN}系统优化配置已应用。${PLAIN}"
}

# --- 域名解析函数 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short "$addr" | tail -n1
    fi
}

# --- 初始化 nftables 结构 ---
function init_nft() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
    touch $CONFIG_FILE
}

# --- 新增转发 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址 (IP 或 域名): " taddr
    read -p "请输入目标端口: " tport

    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${RED}无法解析地址，请检查输入。${PLAIN}"
        return
    fi

    # 写入配置文件以便追踪: local_port|target_addr|target_port|last_known_ip
    echo "$lport|$taddr|$tport|$tip" >> $CONFIG_FILE
    apply_rules
    echo -e "${GREEN}添加成功！${PLAIN}"
}

# --- 应用规则到内核 ---
function apply_rules() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }

    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat postrouting ip daddr $current_ip masquerade
        fi
    done < $CONFIG_FILE
    
    nft list ruleset > $NFT_CONF
}

# --- 查看转发 ---
function show_forward() {
    echo -e "\n${YELLOW}当前转发列表：${PLAIN}"
    echo "-----------------------------------------------------------"
    printf "%-10s | %-20s | %-10s | %-15s\n" "本地端口" "目标地址" "目标端口" "当前映射IP"
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        printf "%-10s | %-20s | %-10s | %-15s\n" "$lp" "$addr" "$tp" "$current_ip"
    done < $CONFIG_FILE
    echo "-----------------------------------------------------------"
}

# --- 删除转发 ---
function del_forward() {
    show_forward
    read -p "请输入要删除的本地端口: " del_port
    sed -i "/^$del_port|/d" $CONFIG_FILE
    apply_rules
    echo -e "${GREEN}已删除端口 $del_port 的转发规则。${PLAIN}"
}

# --- 监控脚本 (DDNS 追踪更新) ---
function ddns_update() {
    local changed=0
    temp_file=$(mktemp)
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        if [ "$current_ip" != "$last_ip" ] && [ ! -z "$current_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < $CONFIG_FILE
    mv "$temp_file" $CONFIG_FILE
    
    if [ $changed -eq 1 ]; then
        apply_rules
        echo "[$(date)] 检测到域名 IP 变动，规则已更新。"
    fi
}

# --- 主菜单 ---
function main_menu() {
    clear
    echo -e "${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名/IP)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 清空所有转发规则"
    echo "6. 立即触发 DDNS IP 更新检测"
    echo "0. 退出"
    echo "--------------------------------"
    read -p "请选择操作 [0-6]: " choice

    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车返回..." ;;
        4) del_forward ;;
        5) > $CONFIG_FILE ; apply_rules ; echo "已清空。" ;;
        6) ddns_update ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

# 检查依赖
if ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y dnsutils || yum install -y bind-utils
fi

# 如果带参数运行（用于定时任务）
if [ "$1" == "--cron" ]; then
    ddns_update
    exit 0
fi

while true; do main_menu; done
