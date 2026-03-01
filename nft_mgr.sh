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

# --- 快捷命令注册 ---
function register_shortcut() {
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"
    fi
}

# --- 域名解析 (增加 2 秒硬超时防止卡死) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 限制解析时长，失败则返回空
        local res=$(timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1)
        echo "$res"
    fi
}

# --- 稳定规则应用 ---
function apply_rules() {
    # 建立基础表结构
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null

    # 清空旧规则 (静默处理)
    nft flush chain ip nat prerouting >/dev/null 2>&1
    nft flush chain ip nat postrouting >/dev/null 2>&1

    if [ -f "$CONFIG_FILE" ]; then
        while IFS='|' read -r lp addr tp last_ip; do
            [ -z "$lp" ] && continue
            current_ip=$(get_ip "$addr")
            
            # 解析失败则使用历史 IP
            [ -z "$current_ip" ] && current_ip="$last_ip"
            
            if [ ! -z "$current_ip" ] && [ "$current_ip" != "0.0.0.0" ]; then
                nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp 2>/dev/null
                nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp 2>/dev/null
                nft add rule ip nat postrouting ip daddr $current_ip masquerade 2>/dev/null
            fi
        done < "$CONFIG_FILE"
    fi
    # 保存至系统配置
    nft list ruleset > "$NFT_CONF" 2>/dev/null
}

# --- 一键卸载 (增强清理) ---
function uninstall_all() {
    echo -e "${RED}正在深度清理并卸载...${PLAIN}"
    # 移除定时任务
    crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
    # 清理防火墙并重启服务释放锁
    nft flush ruleset 2>/dev/null
    systemctl restart nftables >/dev/null 2>&1
    # 删除文件
    rm -f "$CONFIG_FILE" "$NFT_CONF" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
    echo -e "${GREEN}卸载完成。脚本已自删。${PLAIN}"
    rm -f "$0"
    exit 0
}

# --- 菜单功能逻辑 ---
function add_forward() {
    read -p "本地监听端口: " lp
    read -p "目标地址: " ad
    read -p "目标端口: " tp
    
    echo -e "${YELLOW}正在解析并验证规则...${PLAIN}"
    tip=$(get_ip "$ad")
    
    if [ -z "$tip" ]; then
        echo -e "${RED}警告：域名解析超时。将添加为待定状态，稍后由 DDNS 自动修复。${PLAIN}"
        tip="0.0.0.0"
    fi

    echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功。${PLAIN}"
}

function manage_cron() {
    register_shortcut
    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}定时监控已开启${PLAIN}"
        read -p "是否关闭？(y/n): " oc
        [[ "$oc" == [yY] ]] && crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
    else
        echo -e "${RED}定时监控未开启${PLAIN}"
        read -p "是否开启 (每5分钟同步)？(y/n): " oc
        [[ "$oc" == [yY] ]] && (crontab -l 2>/dev/null; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
    fi
}

# --- 主循环与初始化 ---
if ! command -v dig &> /dev/null || ! command -v nft &> /dev/null; then
    apt-get update && apt-get install -y dnsutils nftables cron || yum install -y bind-utils nftables cronie
fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1
register_shortcut

if [ "$1" == "--cron" ]; then
    apply_rules ; exit 0
fi

while true; do
    echo -e "\n${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (支持域名/IP)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 清空所有转发规则"
    echo "6. 管理定时监控 (DDNS 同步)"
    echo -e "${RED}7. 一键卸载脚本及所有任务${PLAIN}"
    echo "0. 退出"
    read -p "选择: " choice
    case $choice in
        1) 
            echo "net.core.default_qdisc=fq" > $SYS_OPT_CONF
            echo "net.ipv4.tcp_congestion_control=bbr" >> $SYS_OPT_CONF
            echo "net.ipv4.ip_forward=1" >> $SYS_OPT_CONF
            sysctl --system >/dev/null 2>&1 ;;
        2) add_forward ;;
        3) 
            echo -e "\n端口 | 目标 | 映射IP"
            [ -f "$CONFIG_FILE" ] && while IFS='|' read -r lp ad tp li; do printf "%-5s | %-15s | %-15s\n" "$lp" "$ad" "$(get_ip $ad)"; done < "$CONFIG_FILE"
            read -p "回车继续..." ;;
        4) read -p "输入删除端口: " dp ; sed -i "/^$dp|/d" "$CONFIG_FILE" ; apply_rules ;;
        5) > "$CONFIG_FILE" ; apply_rules ;;
        6) manage_cron ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
done
