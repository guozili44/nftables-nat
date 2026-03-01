#!/bin/bash

# 路径定义
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
SHORTCUT_PATH="/usr/local/bin/nft"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 核心解析与规则函数 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 增加超时控制，防止解析导致的卡死
        timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

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
            [ -z "$current_ip" ] && current_ip="$last_ip"
            if [ ! -z "$current_ip" ]; then
                nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
                nft add rule ip nat postrouting ip daddr $current_ip masquerade
            fi
        done < "$CONFIG_FILE"
    fi
    nft list ruleset > "$NFT_CONF" 2>/dev/null
}

# --- 菜单功能 ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    echo "net.core.default_qdisc=fq" > $SYS_OPT_CONF
    echo "net.ipv4.tcp_congestion_control=bbr" >> $SYS_OPT_CONF
    echo "net.ipv4.ip_forward=1" >> $SYS_OPT_CONF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}系统优化完成。${PLAIN}"
}

function add_forward() {
    read -p "本地监听端口: " lp
    read -p "目标地址: " ad
    read -p "目标端口: " tp
    tip=$(get_ip "$ad")
    [[ -z "$tip" ]] && tip="0.0.0.0"
    echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功。${PLAIN}"
}

# --- 修正后的 DDNS 监控逻辑 ---
function manage_cron() {
    # 确保快捷命令存在，以便 cron 调用
    local script_path=$(realpath "$0")
    cp "$script_path" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"

    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}当前状态：定时监控 [已开启]${PLAIN}"
        read -p "是否关闭定时监控？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
            echo -e "${YELLOW}监控已关闭。${PLAIN}"
        fi
    else
        echo -e "${RED}当前状态：定时监控 [已关闭]${PLAIN}"
        read -p "是否开启每 5 分钟自动同步域名 IP？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            # 修正写入逻辑，避免重复写入
            (crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH"; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}监控已开启。${PLAIN}"
        fi
    fi
}

function uninstall_all() {
    echo -e "${RED}警告：此操作将清理所有规则、任务并删除脚本自身！${PLAIN}"
    read -p "确定卸载？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
        nft flush ruleset 2>/dev/null
        rm -f "$CONFIG_FILE" "$NFT_CONF" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
        echo -e "${GREEN}卸载完成。${PLAIN}"
        rm -f "$0"
        exit 0
    fi
}

# --- 主交互面板 ---
function main_menu() {
    while true; do
        echo -e "\n${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
        echo "1. 开启 BBR + 系统转发优化"
        echo "2. 新增端口转发 (支持域名/IP)"
        echo "3. 查看当前转发列表"
        echo "4. 删除指定端口转发"
        echo "5. 清空所有转发规则"
        echo "6. 管理定时监控 (DDNS 修复版)"
        echo -e "${RED}7. 一键卸载脚本及任务${PLAIN}"
        echo "0. 退出"
        echo "--------------------------------"
        read -p "请选择操作 [0-7]: " choice
        case $choice in
            1) optimize_system ;;
            2) add_forward ;;
            3) 
                echo -e "\n本地端口 | 目标地址 | 目标端口 | 解析IP"
                [ -s "$CONFIG_FILE" ] && while IFS='|' read -r lp ad tp li; do printf "%-8s | %-15s | %-8s | %-15s\n" "$lp" "$ad" "$tp" "$(get_ip $ad)"; done < "$CONFIG_FILE"
                read -p "按回车返回..." ;;
            4) 
                read -p "输入要删除的端口: " dp
                sed -i "/^$dp|/d" "$CONFIG_FILE"
                apply_rules ;;
            5) > "$CONFIG_FILE" ; apply_rules ; echo "已清空。" ;;
            6) manage_cron ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 初始化
if ! command -v dig &> /dev/null || ! command -v nft &> /dev/null; then
    apt-get update && apt-get install -y dnsutils nftables cron || yum install -y bind-utils nftables cronie
fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1

# 定时任务入口
if [ "$1" == "--cron" ]; then
    apply_rules
    exit 0
fi

main_menu
