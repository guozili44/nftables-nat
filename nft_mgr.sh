#!/bin/bash

# 路径定义
CONFIG_FILE="/etc/nft_forward_list.conf"
SHORTCUT_PATH="/usr/local/bin/nft"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1

# --- 核心转发应用 ---
function apply_rules() {
    # 建立标准基础结构
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    
    # 强制排空旧规则，防止堆叠卡死
    nft flush chain ip nat prerouting 2>/dev/null
    nft flush chain ip nat postrouting 2>/dev/null

    if [ -s "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            # 增加 2 秒解析超时，防止域名解析挂起整个系统
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

# --- 强力卸载 (彻底解决清理无效) ---
function uninstall_all() {
    echo -e "${RED}执行强力卸载...${PLAIN}"
    # 1. 必须先清空 cron，否则脚本删了后台还会报错
    crontab -r 2>/dev/null
    # 2. 彻底排空内核规则
    nft flush ruleset 2>/dev/null
    # 3. 删除所有文件
    rm -f "$CONFIG_FILE" "$SHORTCUT_PATH" /etc/nftables.conf
    echo -e "${GREEN}卸载完成，环境已净化。${PLAIN}"
    rm -f "$0"
    exit 0
}

# --- 菜单界面 ---
function main_menu() {
    echo -e "\n${GREEN}--- nftables 极简管理版 ---${PLAIN}"
    echo "1. 新增转发"
    echo "2. 查看/删除端口"
    echo "3. 管理 DDNS 监控"
    echo -e "${RED}7. 一键强力卸载${PLAIN}"
    echo "0. 退出"
    read -p "选择: " choice
    case $choice in
        1)
            read -p "本地端口: " lp
            read -p "目标地址: " ad
            read -p "目标端口: " tp
            echo "$lp|$ad|$tp|0.0.0.0" >> "$CONFIG_FILE"
            apply_rules && echo "添加成功" ;;
        2)
            echo "当前列表："
            cat -n "$CONFIG_FILE" 2>/dev/null
            read -p "输入行号删除 (直接回车取消): " line_num
            if [ ! -z "$line_num" ]; then
                sed -i "${line_num}d" "$CONFIG_FILE"
                apply_rules && echo "已更新"
            fi ;;
        3)
            if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
                crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
                echo "监控已关闭"
            else
                (crontab -l 2>/dev/null; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
                echo "监控已开启 (5分钟/次)"
            fi ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
}

# 初始化依赖
command -v nft >/dev/null || (apt-get update && apt-get install -y nftables dnsutils cron)
# 注册快捷键
cp "$0" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"

# Cron 定时调用入口
if [ "$1" == "--cron" ]; then
    apply_rules ; exit 0
fi

main_menu
