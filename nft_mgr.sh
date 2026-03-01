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
            if [ ! -z "$current_ip" ] && [ "$current_ip" != "0.0.0.0" ]; then
                nft add rule ip nat prerouting tcp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat prerouting udp dport "$lp" dnat to "$current_ip:$tp"
                nft add rule ip nat postrouting ip daddr "$current_ip" masquerade
            fi
        done < "$CONFIG_FILE"
    fi
}

# --- 强力卸载选项 (修复清理无效问题) ---
function uninstall_all() {
    echo -e "${RED}正在进行深度清理...${PLAIN}"
    
    # 1. 停止相关服务以释放文件锁
    systemctl stop cron 2>/dev/null || systemctl stop crond 2>/dev/null
    
    # 2. 清理定时任务
    crontab -r 2>/dev/null
    echo -e "${GREEN}√ 定时任务已完全清空${PLAIN}"
    
    # 3. 强制重置防火墙规则
    nft flush ruleset 2>/dev/null
    systemctl restart nftables 2>/dev/null
    echo -e "${GREEN}√ 防火墙规则已排空${PLAIN}"
    
    # 4. 彻底删除物理文件
    rm -rf "$CONFIG_FILE" "$NFT_CONF" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
    echo -e "${GREEN}√ 配置文件及快捷命令已移除${PLAIN}"

    # 5. 重启 Cron 以恢复系统正常环境
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
    
    echo -e "${GREEN}卸载彻底完成！已回到纯净 Root 环境。${PLAIN}"
    rm -f "$0"
    exit 0
}

# --- 菜单功能 ---
function manage_cron() {
    # 每次开启监控前确保快捷路径存在
    local script_path=$(realpath "$0")
    cp "$script_path" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"

    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}监控运行中${PLAIN}"
        read -p "是否关闭？(y/n): " oc
        [[ "$oc" == [yY] ]] && crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
    else
        echo -e "${RED}监控已关闭${PLAIN}"
        read -p "是否开启 (每5分钟同步)？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            # 采用覆盖式写入，防止 crontab 堆叠导致卡死
            (crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH"; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            echo -e "${GREEN}开启成功${PLAIN}"
        fi
    fi
}

# --- 菜单循环 ---
function main_menu() {
    while true; do
        echo -e "\n${GREEN}--- nftables 管理面板 (深度修复版) ---${PLAIN}"
        echo "1. 开启 BBR + 系统优化"
        echo "2. 新增转发"
        echo "3. 查看列表"
        echo "4. 删除指定端口转发"
        echo "5. 清空转发规则"
        echo "6. 管理 DDNS 监控"
        echo -e "${RED}7. 一键强力卸载 (彻底回归 Root)${PLAIN}"
        echo "0. 退出"
        read -p "选择 [0-7]: " choice
        case $choice in
            1) 
                echo "net.core.default_qdisc=fq" > $SYS_OPT_CONF
                echo "net.ipv4.tcp_congestion_control=bbr" >> $SYS_OPT_CONF
                echo "net.ipv4.ip_forward=1" >> $SYS_OPT_CONF
                sysctl --system >/dev/null 2>&1
                echo "优化完成" ;;
            2) 
                read -p "本地端口: " lp
                read -p "目标地址: " ad
                read -p "目标端口: " tp
                tip=$(get_ip "$ad")
                [[ -z "$tip" ]] && tip="0.0.0.0"
                echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
                apply_rules ; echo "已添加" ;;
            3) 
                [ -s "$CONFIG_FILE" ] && cat "$CONFIG_FILE" | column -t -s "|"
                read -p "按回车返回..." ;;
            4) read -p "输入删除端口: " dp ; sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ;;
            5) > "$CONFIG_FILE" ; apply_rules ;;
            6) manage_cron ;;
            7) uninstall_all ;;
            0) exit 0 ;;
        esac
    done
}

# 依赖检查与定时入口
if ! command -v dig &> /dev/null; then apt-get update && apt-get install -y dnsutils nftables cron || yum install -y bind-utils nftables cronie; fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1

if [ "$1" == "--cron" ]; then
    apply_rules ; exit 0
fi

main_menu
