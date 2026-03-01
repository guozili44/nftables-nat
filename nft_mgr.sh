#!/bin/bash

# ==========================================
# nftables 端口转发管理面板 (Pro 完美版)
# ==========================================

# 配置文件路径
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
LOG_DIR="/var/log/nft_ddns"

# Github 脚本更新链接
RAW_URL="https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"
PROXY_URL="https://ghproxy.net/https://raw.githubusercontent.com/guozili44/nftables-nat/refs/heads/main/nft_mgr.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# 确保配置文件存在
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"

# --- 自动设置快捷命令 ---
function setup_alias() {
    local shell_rc="$HOME/.bashrc"
    local current_path=$(realpath "$0" 2>/dev/null || readlink -f "$0")
    
    if [[ ! -t 0 ]]; then return; fi

    if ! grep -q "alias nft=" "$shell_rc" 2>/dev/null; then
        echo "alias nft='bash \"$current_path\"'" >> "$shell_rc"
        echo -e "${GREEN}[系统提示] 快捷命令 'nft' 已添加！下次登录可直接输入 nft 打开面板。${PLAIN}"
        sleep 2
    else
        sed -i "s|alias nft=.*|alias nft='bash \"$current_path\"'|g" "$shell_rc"
    fi
}
setup_alias

# --- 系统优化与 BBR ---
function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    sudo tee /etc/sysctl.d/99-sys-opt.conf > /dev/null <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sudo sysctl --system >/dev/null 2>&1
    
    echo -e "${YELLOW}正在设置 nftables 开机自启...${PLAIN}"
    systemctl enable --now nftables >/dev/null 2>&1
    
    echo -e "${GREEN}系统优化配置及开机自启已应用。${PLAIN}"
    sleep 2
}

# --- 域名解析函数 (强化版) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short -t A "$addr" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -n1
    fi
}

# --- 原子化应用规则到内核 (极致性能) ---
function apply_rules() {
    local temp_nft=$(mktemp)
    
    # 构建基础表结构 (EOF必须顶格)
    cat <<EOF > "$temp_nft"
flush ruleset
table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    # 批量注入目标转发规则
    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        tcp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
            echo "        udp dport $lp dnat to $current_ip:$tp" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    # 构建回程 SNAT (Masquerade) (EOF必须顶格)
    cat <<EOF >> "$temp_nft"
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    while IFS='|' read -r lp addr tp last_ip; do
        local current_ip=$(get_ip "$addr")
        if [ -n "$current_ip" ]; then
            echo "        ip daddr $current_ip masquerade" >> "$temp_nft"
        fi
    done < "$CONFIG_FILE"

    # 闭合表结构 (EOF必须顶格)
    cat <<EOF >> "$temp_nft"
    }
}
EOF

    # 一次性原子化加载
    nft -f "$temp_nft"
    
    # 固化到系统配置
    cat "$temp_nft" > "$NFT_CONF"
    rm -f "$temp_nft"
}

# --- 新增转发 ---
function add_forward() {
    local lport taddr tport tip
    read -p "请输入本地监听端口 (1-65535): " lport
    
    if [[ ! "$lport" =~ ^[0-9]+$ ]] || [ "$lport" -lt 1 ] || [ "$lport" -gt 65535 ]; then
        echo -e "${RED}错误: 本地端口必须是 1 到 65535 之间的纯数字。${PLAIN}"
        sleep 2; return
    fi

    if grep -q "^$lport|" "$CONFIG_FILE" 2>/dev/null; then
        echo
