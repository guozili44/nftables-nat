#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
SHORTCUT_PATH="/usr/local/bin/nft"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 注册快捷命令 ---
function register_shortcut() {
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
    fi
}

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

# --- 域名解析函数 (增加超时保护) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 增加 2 秒超时，防止 DNS 解析卡死脚本
        timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

# --- 应用规则到内核 ---
function apply_rules() {
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    nft flush chain ip nat prerouting
    nft flush chain ip nat postrouting

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            current_ip=$(get_ip "$addr")
            # 如果解析失败且有历史 IP，则沿用历史 IP，否则跳过
            [[ -z "$current_ip" ]] && current_ip="$last_ip"
            
            if [ ! -z "$current_ip" ] && [ "$current_ip" != "0.0.0.0" ]; then
                nft add rule ip nat prerouting tcp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat prerouting udp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat postrouting ip daddr "$current_ip" masquerade
            fi
        done < "$CONFIG_FILE"
    fi
    nft list ruleset > "$NFT_CONF"
}

# --- 新增转发 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址 (IP 或 域名): " taddr
    read -p "请输入目标端口: " tport

    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${YELLOW}警告: 无法立即解析地址，将设为 0.0.0.0 待后续更新。${PLAIN}"
        tip="0.0.0.0"
    fi

    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功！${PLAIN}"
}

# --- 查看转发 ---
function show_forward() {
    echo -e "\n${YELLOW}当前转发列表：${PLAIN}"
    echo "-----------------------------------------------------------"
    printf "%-10s | %-20s | %-10s | %-15s\n" "本地端口" "目标地址" "目标端口" "当前解析IP"
    [ -f "$CONFIG_FILE" ] && while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        printf "%-10s | %-20s | %-10s | %-15s\n" "$lp" "$addr" "$tp" "${current_ip:-解析失败}"
    done < "$CONFIG_FILE"
    echo "-----------------------------------------------------------"
}

# --- 删除转发 ---
function del_forward() {
    show_forward
    read -p "请输入要删除的本地端口: " del_port
    sed -i "/^$del_port|/d" "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}已删除端口 $del_port 的转发规则。${PLAIN}"
}

# --- 监控脚本 (DDNS 追踪更新 - 优化版) ---
function ddns_update() {
    [ ! -f "$CONFIG_FILE" ] && return
    local changed=0
    local temp_file=$(mktemp)
    
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        # 只有在解析成功且与旧 IP 不同时才标记变更
        if [ ! -z "$current_ip" ] && [ "$current_ip" != "$last_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    
    mv "$temp_file" "$CONFIG_FILE"
    
    if [ $changed -eq 1 ]; then
        apply_rules
    fi
}

# --- 管理定时监控 (修复去重逻辑) ---
function manage_cron() {
    register_shortcut
    
    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}当前状态：定时监控 [已开启]${PLAIN}"
        read -p "是否关闭定时监控？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
            echo -e "${YELLOW}定时监控已关闭。${PLAIN}"
        fi
    else
        echo -e "${RED}当前状态：定时监控 [已关闭]${PLAIN}"
        read -p "是否开启每 5 分钟自动同步域名 IP？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            # 先清理可能存在的旧残留，再添加新任务
            (crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH"; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}定时监控已开启，每 5 分钟执行一次。${PLAIN}"
        fi
    fi
}

# --- 主菜单 ---
function main_menu() {
    echo -e "\n${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名/IP)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 清空所有转发规则"
    echo "6. 管理定时监控 (DDNS 同步)"
    echo "0. 退出"
    echo "--------------------------------"
    read -p "请选择操作 [0-6]: " choice

    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车返回..." ;;
        4) del_forward ;;
        5) 
            read -p "确定要清空吗？(y/n): " conf
            if [[ "$conf" == [yY] ]]; then
                > "$CONFIG_FILE" ; apply_rules ; echo "已清空。" 
            fi ;;
        6) manage_cron ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

# --- 环境检查与依赖安装 ---
if ! command -v dig &> /dev/null || ! command -v nft &> /dev/null || ! command -v crontab &> /dev/null; then
    echo -e "${YELLOW}正在安装必要依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y dnsutils nftables iproute2 cron
        systemctl enable cron && systemctl start cron
    else
        yum install -y bind-utils nftables iproute2 cronie
        systemctl enable crond && systemctl start crond
    fi
fi

# 确保服务启动
systemctl start nftables > /dev/null 2>&1
register_shortcut

# 如果带参数运行（用于定时任务）
if [ "$1" == "--cron" ]; then
    ddns_update
    exit 0
fi

# 启动主循环
while true; do main_menu; done
