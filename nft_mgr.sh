#!/bin/bash

# 配置路径
CONFIG_FILE="/etc/nft_forward_list.conf"
TABLE_NAME="nat_forward" # 专用表名，防止误伤其他规则
SYS_OPT_CONF="/etc/sysctl.d/99-sys-opt.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 自动检查并安装依赖 ---
function check_dependencies() {
    local apps=("nft" "dig" "ss")
    local missing=()
    for app in "${apps[@]}"; do
        if ! command -v "$app" &> /dev/null; then missing+=("$app"); fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装必要依赖 (nftables, dnsutils, iproute2)...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y nftables dnsutils iproute2 cron
        else
            yum install -y nftables bind-utils iproute2 cronie
        fi
    fi
    systemctl enable nftables && systemctl start nftables > /dev/null 2>&1
}

# --- 2. 端口占用检测功能 ---
function check_port_occupy() {
    local port=$1
    # 同时检查 TCP 和 UDP 监听状态
    if ss -tuln | grep -q ":$port "; then
        return 1 # 已被占用
    else
        return 0 # 未被占用
    fi
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
    # 仅清除并重建本脚本专用的表
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

# --- 4. 交互功能模块 ---
function add_forward() {
    read -p "请输入本地监听端口: " lport
    
    # 检查本地端口占用
    if ! check_port_occupy "$lport"; then
        echo -e "${RED}[错误] 端口 $lport 已被系统其他进程占用，请更换端口或停止冲突服务。${PLAIN}"
        # 显示占用该端口的服务信息
        ss -tulnp | grep ":$lport "
        return
    fi

    read -p "请输入目标地址 (域名/IP): " taddr
    read -p "请输入目标端口: " tport
    
    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${RED}解析失败，请检查目标地址是否正确。${PLAIN}"
        return
    fi

    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功！本地 $lport -> $taddr:$tport${PLAIN}"
}

function show_forward() {
    echo -e "\n${BLUE}--- 当前转发列表 (由 $TABLE_NAME 管理) ---${PLAIN}"
    if [ ! -s "$CONFIG_FILE" ]; then echo "暂无转发数据"; return; fi
    printf "%-8s | %-20s | %-8s | %-15s\n" "本地端口" "目标地址" "目标端口" "当前解析IP"
    while IFS='|' read -r lp addr tp last_ip; do
        printf "%-8s | %-20s | %-8s | %-15s\n" "$lp" "$addr" "$tp" "$(get_ip $addr)"
    done < "$CONFIG_FILE"
}

function uninstall_all() {
    echo -e "${RED}警告：将删除本脚本的所有规则和配置，并删除脚本自身！${PLAIN}"
    read -p "确认卸载？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        local script_path=$(realpath "$0")
        crontab -l 2>/dev/null | grep -v "$script_path" | crontab -
        nft delete table ip $TABLE_NAME 2>/dev/null
        rm -f "$CONFIG_FILE" "$SYS_OPT_CONF"
        echo -e "${GREEN}清理完毕。再见！${PLAIN}"
        rm -f "$script_path"
        exit 0
    fi
}

# --- 5. 主菜单 ---
check_dependencies
if [ "$1" == "--cron" ]; then apply_rules ; exit 0 ; fi

while true; do
    echo -e "\n${GREEN}      nftables 转发管理器 (增强版)      ${PLAIN}"
    echo "1. 开启 BBR + 系统内核转发优化"
    echo "2. 新增端口转发 (自动检测端口冲突)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 彻底清空本脚本专属规则"
    echo "6. 管理定时监控 (DDNS 动态同步)"
    echo -e "${RED}7. 卸载脚本并清理环境 (安全不伤系统)${PLAIN}"
    echo "0. 退出"
    echo "----------------------------------------"
    read -p "请选择 [0-7]: " choice
    case $choice in
        1) 
            echo -e "${YELLOW}优化系统参数中...${PLAIN}"
            sudo tee $SYS_OPT_CONF > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
EOF
            sudo sysctl --system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车返回..." ;;
        4) 
            show_forward
            read -p "输入要删除的本地端口: " dp
            sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ; echo "已删除。" ;;
        5) 
            rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE"
            nft delete table ip $TABLE_NAME 2>/dev/null ; echo "已清空。" ;;
        6) 
            sp=$(realpath "$0")
            if crontab -l 2>/dev/null | grep -q "$sp"; then
                echo -e "${GREEN}定时监控已开启。${PLAIN}"
                read -p "是否关闭？(y/n): " oc
                [[ "$oc" == [yY] ]] && crontab -l | grep -v "$sp" | crontab -
            else
                echo -e "${RED}定时监控未开启。${PLAIN}"
                read -p "是否开启每 5 分钟同步？(y/n): " oc
                [[ "$oc" == [yY] ]] && (crontab -l 2>/dev/null; echo "*/5 * * * * $sp --cron > /dev/null 2>&1") | crontab -
            fi ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
done
