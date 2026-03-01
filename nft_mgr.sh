#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/nft_forward_list.conf"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"
SHORTCUT_PATH="/usr/local/bin/nft"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 基础环境准备 ---
function check_env() {
    if ! command -v nft &> /dev/null || ! command -v dig &> /dev/null; then
        echo -e "${YELLOW}安装必要依赖...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y nftables dnsutils iproute2 cron
        else
            yum install -y nftables bind-utils iproute2 cronie
        fi
    fi
    systemctl enable nftables && systemctl start nftables > /dev/null 2>&1

    # 注册快捷命令 nft
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
        echo -e "${GREEN}快捷启动已就绪！输入 nft 即可。${PLAIN}"
    fi
}

# --- 2. 核心转发逻辑 (标准 nat 表版) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

function apply_rules() {
    # 建立标准 nat 表结构 (如果不存在)
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    # 1. 这种模式下，为了防冲突，我们先清空 prerouting 和 postrouting 链中
    # 带有 "nft_mgr" 标记的规则（或者先简单 flush，如果你确认只有这个脚本在用 nat 表）
    # 为确保 100% 成功，这里采用最稳妥的重置方式：
    nft flush chain ip nat prerouting
    nft flush chain ip nat postrouting

    [ ! -f "$CONFIG_FILE" ] && return
    
    while IFS='|' read -r lp addr tp last_ip; do
        [ -z "$lp" ] && continue
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            # 直接写入标准 nat 表的 prerouting 和 postrouting 链
            nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat postrouting ip daddr $current_ip masquerade
        fi
    done < "$CONFIG_FILE"
}

# --- 3. 卸载与清理 ---
function uninstall_all() {
    echo -e "${RED}确认要完全卸载吗？此操作将清空 nat 表中的所有 prerouting/postrouting 规则。${PLAIN}"
    read -p "请输入 [y/n]: " confirm
    if [[ "$confirm" == [yY] ]]; then
        crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
        nft flush table ip nat 2>/dev/null
        rm -f "$CONFIG_FILE" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
        echo -e "${GREEN}卸载完成！标准 nat 表已重置。${PLAIN}"
        exit 0
    fi
}

# --- 4. 菜单逻辑 ---
check_env
if [ "$1" == "--cron" ]; then apply_rules ; exit 0 ; fi

while true; do
    echo -e "\n${BLUE}========================================${PLAIN}"
    echo -e "${GREEN}      nftables 转发管理器 (标准兼容版)      ${PLAIN}"
    echo -e "${BLUE}========================================${PLAIN}"
    echo "1. 开启 BBR + 系统内核转发优化"
    echo "2. 新增端口转发 (标准 nat 表)"
    echo "3. 查看当前转发列表"
    echo "4. 删除单条转发并重载"
    echo "5. 一键清空所有转发规则"
    echo "6. 管理定时监控 (DDNS 动态同步)"
    echo -e "${RED}7. 完全卸载脚本${PLAIN}"
    echo "0. 退出"
    echo "----------------------------------------"
    read -p "选择: " choice
    case $choice in
        1) 
            echo -e "${YELLOW}优化中...${PLAIN}"
            sudo tee $SYS_OPT_CONF > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
EOF
            sudo sysctl --system ;;
        2) 
            read -p "本地端口: " lp
            if ss -tuln | grep -q ":$lp "; then
                echo -e "${RED}错误: 端口 $lp 已占用！${PLAIN}"
            else
                read -p "目标地址: " ad
                read -p "目标端口: " tp
                tip=$(get_ip "$ad")
                if [ -z "$tip" ]; then echo "解析失败"; else
                    echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
                    apply_rules ; echo -e "${GREEN}添加成功。${PLAIN}"
                fi
            fi ;;
        3) 
            echo -e "\n本地端口 | 目标地址 | 目标端口 | 解析IP"
            [ -s "$CONFIG_FILE" ] && while IFS='|' read -r lp ad tp li; do printf "%-8s | %-15s | %-8s | %-15s\n" "$lp" "$ad" "$tp" "$(get_ip $ad)"; done < "$CONFIG_FILE"
            read -p "回车继续..." ;;
        4) read -p "输入要删除的本地端口: " dp ; sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ; echo "已更新。" ;;
        5) 
            rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE"
            nft flush chain ip nat prerouting
            nft flush chain ip nat postrouting
            echo "所有规则已清空。" ;;
        6) 
            if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
                echo -e "${GREEN}监控运行中${PLAIN}" ; read -p "关闭？(y/n): " oc
                [[ "$oc" == [yY] ]] && crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
            else
                echo -e "${RED}监控未开启${PLAIN}" ; read -p "开启？(y/n): " oc
                [[ "$oc" == [yY] ]] && (crontab -l 2>/dev/null; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            fi ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
done
