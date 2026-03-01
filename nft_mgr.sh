#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
SHORTCUT_PATH="/usr/local/bin/nft"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"

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
    sudo tee $SYS_OPT_CONF > /dev/null <<EOF
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
        dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
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
            if [ ! -z "$current_ip" ]; then
                nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat postrouting ip daddr $current_ip masquerade
            fi
        done < "$CONFIG_FILE"
    fi
    nft list ruleset > "$NFT_CONF"
}

# --- 卸载脚本 (新增功能) ---
function uninstall_all() {
    echo -e "${RED}警告：此操作将清理所有转发规则、定时任务并删除脚本自身！${PLAIN}"
    read -p "确定要卸载吗？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        # 1. 清理定时任务
        crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
        
        # 2. 清空 nftables 规则
        nft flush chain ip nat prerouting 2>/dev/null
        nft flush chain ip nat postrouting 2>/dev/null
        
        # 3. 删除配置文件和快捷命令
        rm -f "$CONFIG_FILE"
        rm -f "$NFT_CONF"
        rm -f "$SYS_OPT_CONF"
        
        echo -e "${GREEN}卸载完成，正在删除脚本自身...${PLAIN}"
        rm -f "$SHORTCUT_PATH"
        rm -f "$0"
        exit 0
    else
        echo "已取消卸载。"
    fi
}

# --- 管理定时监控 (菜单6) ---
function manage_cron() {
    register_shortcut
    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}当前状态：定时监控 [已开启]${PLAIN}"
        read -p "是否关闭定时监控？(y/n): " oc
        [[ "$oc" == [yY] ]] && crontab -l | grep -v "$SHORTCUT_PATH" | crontab - && echo "已关闭。"
    else
        echo -e "${RED}当前状态：定时监控 [已关闭]${PLAIN}"
        read -p "是否开启每 5 分钟自动同步？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}已开启每 5 分钟同步。${PLAIN}"
        fi
    fi
    read -p "按回车返回..."
}

# --- 其他原有功能省略以保持精炼，逻辑与之前一致 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址: " taddr
    read -p "请输入目标端口: " tport
    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then echo -e "${RED}解析失败${PLAIN}"; return; fi
    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功。${PLAIN}"
}

function show_forward() {
    echo -e "\n${YELLOW}当前转发列表：${PLAIN}"
    [ -f "$CONFIG_FILE" ] && while IFS='|' read -r lp addr tp last_ip; do
        printf "%-8s | %-20s | %-8s | %-15s\n" "$lp" "$addr" "$tp" "$(get_ip $addr)"
    done < "$CONFIG_FILE"
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
    echo -e "${RED}7. 一键卸载脚本及所有任务${PLAIN}"
    echo "0. 退出"
    echo "--------------------------------"
    read -p "请选择操作 [0-7]: " choice
    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车返回..." ;;
        4) 
            show_forward
            read -p "输入要删除的端口: " dp
            sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ;;
        5) > "$CONFIG_FILE" ; apply_rules ; echo "已清空。" ;;
        6) manage_cron ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

# 自动检查依赖与初始化
if ! command -v dig &> /dev/null || ! command -v nft &> /dev/null || ! command -v crontab &> /dev/null; then
    apt-get update && apt-get install -y dnsutils nftables cron || yum install -y bind-utils nftables cronie
    systemctl enable cron || systemctl enable crond
    systemctl start cron || systemctl start crond
fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1
register_shortcut

if [ "$1" == "--cron" ]; then
    [ -f "$CONFIG_FILE" ] && {
        changed=0 ; temp_file=$(mktemp)
        while IFS='|' read -r lp addr tp last_ip; do
            current_ip=$(get_ip "$addr")
            if [ "$current_ip" != "$last_ip" ] && [ ! -z "$current_ip" ]; then
                echo "$lp|$addr|$tp|$current_ip" >> "$temp_file" ; changed=1
            else echo "$lp|$addr|$tp|$last_ip" >> "$temp_file" ; fi
        done < "$CONFIG_FILE"
        mv "$temp_file" "$CONFIG_FILE"
        [ $changed -eq 1 ] && apply_rules
    }
    exit 0
fi

while true; do main_menu; done
