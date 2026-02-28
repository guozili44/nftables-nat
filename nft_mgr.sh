#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/nft_forward_list.conf"
TABLE_NAME="nat_forward"
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"
SHORTCUT_PATH="/usr/local/bin/nft" # 快捷命令路径

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 自动检查并安装依赖 & 注册快捷命令 ---
function check_dependencies() {
    local apps=("nft" "dig" "ss")
    local missing=()
    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then missing+=("$app"); fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}正在安装必要依赖...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y nftables dnsutils iproute2 cron
        else
            yum install -y nftables bind-utils iproute2 cronie
        fi
    fi
    systemctl enable nftables && systemctl start nftables > /dev/null 2>&1

    # 注册快捷命令 nft (如果当前不是 nft 本体命令)
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
        echo -e "${GREEN}快捷启动已就绪！以后只需输入 nft 即可打开面板。${PLAIN}"
    fi
}

# --- 2. 端口占用检测 ---
function check_port_occupy() {
    if ss -tuln | grep -q ":$1 "; then return 1; else return 0; fi
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
    nft delete table ip $TABLE_NAME 2>/dev/null
    nft add table ip $TABLE_NAME
    nft add chain ip $TABLE_NAME prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip $TABLE_NAME postrouting { type nat hook postrouting priority 100 \; }

    [ ! -f "$CONFIG_FILE" ] && return
    while IFS='|' read -r lp addr tp last_ip; do
        [ -z "$lp" ] && continue
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            nft add rule ip $TABLE_NAME prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip $TABLE_NAME prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip $TABLE_NAME postrouting ip daddr $current_ip masquerade
        fi
    done < "$CONFIG_FILE"
}

# --- 4. 卸载功能 ---
function uninstall_all() {
    echo -e "${RED}警告：将彻底卸载并清理环境！${PLAIN}"
    read -p "确认卸载？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
        nft delete table ip $TABLE_NAME 2>/dev/null
        rm -f "$CONFIG_FILE" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
        echo -e "${GREEN}卸载完成，快捷命令已移除。${PLAIN}"
        exit 0
    fi
}

# --- 5. 主菜单 ---
if [ "$1" == "--cron" ]; then apply_rules ; exit 0 ; fi
check_dependencies

while true; do
    echo -e "\n${BLUE}========================================${PLAIN}"
    echo -e "${GREEN}      nftables 转发管理器 (快捷版)      ${PLAIN}"
    echo -e "${BLUE}========================================${PLAIN}"
    echo "1. 开启 BBR + 系统内核转发优化"
    echo "2. 新增端口转发 (自动检测端口冲突)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 彻底清空专属转发规则"
    echo "6. 管理定时监控 (DDNS 动态同步)"
    echo -e "${RED}7. 卸载脚本并清理快捷命令${PLAIN}"
    echo "0. 退出"
    echo "----------------------------------------"
    read -p "选择: " choice
    case $choice in
        1) 
            sudo tee $SYS_OPT_CONF > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
EOF
            sudo sysctl --system ;;
        2) 
            read -p "本地监听端口: " lport
            if ! check_port_occupy "$lport"; then
                echo -e "${RED}错误: 端口 $lport 已占用！${PLAIN}"
                ss -tulnp | grep ":$lport "
            else
                read -p "目标地址: " taddr
                read -p "目标端口: " tport
                tip=$(get_ip "$taddr")
                if [ -z "$tip" ]; then echo "解析失败"; else
                    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
                    apply_rules ; echo -e "${GREEN}成功。${PLAIN}"
                fi
            fi ;;
        3) 
            echo -e "\n本地端口 | 目标地址 | 目标端口 | 解析IP"
            [ -s "$CONFIG_FILE" ] && while IFS='|' read -r lp ad tp li; do printf "%-8s | %-15s | %-8s | %-15s\n" "$lp" "$ad" "$tp" "$(get_ip $ad)"; done < "$CONFIG_FILE"
            read -p "回车继续..." ;;
        4) read -p "输入删除端口: " dp ; sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ;;
        5) rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE" ; nft delete table ip $TABLE_NAME 2>/dev/null ;;
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
