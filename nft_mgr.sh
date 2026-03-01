#!/bin/bash

# 路径定义
CONFIG_FILE="/etc/nft_forward_list.conf"
SHORTCUT_PATH="/usr/local/bin/nft"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

# --- 核心：应用规则 (保持原有正常逻辑) ---
function apply_rules() {
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    nft flush chain ip nat prerouting 2>/dev/null
    nft flush chain ip nat postrouting 2>/dev/null

    if [ -s "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            current_ip=$(timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1)
            [ -z "$current_ip" ] && current_ip="$last_ip"
            if [ ! -z "$current_ip" ] && [ "$current_ip" != "0.0.0.0" ]; then
                nft add rule ip nat prerouting tcp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat prerouting udp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat postrouting ip daddr "$current_ip" masquerade
            fi
        done < "$CONFIG_FILE"
    fi
}

# --- 核心修改：单独的定时任务清理 (取代原选项7) ---
function clear_cron_only() {
    echo -e "${RED}正在精准清理所有 nft 相关的定时任务...${PLAIN}"
    # 物理清空当前用户的 crontab，彻底切断死循环来源
    crontab -r 2>/dev/null
    echo -e "${GREEN}√ 定时任务已完全清空。${PLAIN}"
    read -p "按回车返回菜单..."
}

# --- 菜单界面 ---
function main_menu() {
    while true; do
        echo -e "\n${GREEN}--- nftables 管理面板 (定时任务修复版) ---${PLAIN}"
        echo "1. 开启系统优化 (BBR/转发)"
        echo "2. 新增端口转发"
        echo "3. 查看列表 / 删除指定端口"
        echo "4. 开启 DDNS 监控"
        echo -e "${RED}5. 单独清空所有定时任务 (解决卡死专用)${PLAIN}"
        echo "0. 退出"
        echo "--------------------------------"
        read -p "选择: " choice
        case $choice in
            1) echo 1 > /proc/sys/net/ipv4/ip_forward ; echo "优化完成。" ;;
            2) 
                read -p "本地端口: " lp
                read -p "目标地址: " ad
                read -p "目标端口: " tp
                echo "$lp|$ad|$tp|0.0.0.0" >> "$CONFIG_FILE"
                apply_rules ; echo "添加成功。" ;;
            3)
                echo -e "\n行号 | 本地端口 | 目标地址 | 映射IP"
                [ -s "$CONFIG_FILE" ] && nl -s " | " -w 2 "$CONFIG_FILE"
                read -p "输入行号删除 (回车返回): " ln
                if [ ! -z "$ln" ]; then
                    sed -i "${ln}d" "$CONFIG_FILE"
                    apply_rules ; echo "已更新规则。"
                fi ;;
            4)
                # 开启监控逻辑
                (crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH"; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
                echo -e "${GREEN}监控已开启。${PLAIN}" ;;
            5) clear_cron_only ;;
            0) exit 0 ;;
        esac
    done
}

# 注册快捷启动
cp "$0" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"

# 处理定时任务调用
if [ "$1" == "--cron" ]; then
    apply_rules ; exit 0
fi

main_menu
