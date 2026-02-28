cat > nft_mgr.sh << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/nft_forward_list.conf"
NFT_CONF="/etc/nftables.conf"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

function optimize_system() {
    echo -e "${YELLOW}正在配置 BBR 和内核转发...${PLAIN}"
    sudo tee /etc/sysctl.d/99-sys-opt.conf > /dev/null <<EOF2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF2
    sudo sysctl --system
    echo -e "${GREEN}系统优化配置已应用。${PLAIN}"
}

function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

function apply_rules() {
    nft flush ruleset
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
    [ ! -f "$CONFIG_FILE" ] && return
    while IFS='|' read -r lp addr tp last_ip; do
        [ -z "$lp" ] && continue
        current_ip=$(get_ip "$addr")
        if [ ! -z "$current_ip" ]; then
            nft add rule ip nat prerouting tcp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat prerouting udp dport $lp dnat to $current_ip:$tp
            nft add rule ip nat postrouting ip daddr $current_ip masquerade
        fi
    done < "$CONFIG_FILE"
    nft list ruleset > "$NFT_CONF"
}

function add_forward() {
    read -p "请输入本地监听端口: " lport
    read -p "请输入目标地址 (IP 或 域名): " taddr
    read -p "请输入目标端口: " tport
    tip=$(get_ip "$taddr")
    if [ -z "$tip" ]; then
        echo -e "${RED}无法解析地址，请检查输入。${PLAIN}"
        return
    fi
    echo "$lport|$taddr|$tport|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}添加成功！${PLAIN}"
}

function show_forward() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}当前没有任何转发规则。${PLAIN}"
        return
    fi
    echo -e "\n${YELLOW}当前转发列表：${PLAIN}"
    printf "%-10s | %-20s | %-10s | %-15s\n" "本地端口" "目标地址" "目标端口" "解析IP"
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        printf "%-10s | %-20s | %-10s | %-15s\n" "$lp" "$addr" "$tp" "$current_ip"
    done < "$CONFIG_FILE"
}

function del_forward() {
    show_forward
    [ ! -s "$CONFIG_FILE" ] && return
    read -p "请输入要删除的本地端口: " del_port
    sed -i "/^$del_port|/d" "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}已删除。${PLAIN}"
}

function reset_all() {
    read -p "确定要删除配置文件并清空所有规则吗？(y/n): " confirm
    if [[ "$confirm" == [yY] ]]; then
        rm -f "$CONFIG_FILE" && touch "$CONFIG_FILE"
        nft flush ruleset
        echo "" > "$NFT_CONF"
        echo -e "${GREEN}环境已彻底清空。${PLAIN}"
    fi
}

function ddns_update() {
    [ ! -f "$CONFIG_FILE" ] && exit 0
    local changed=0
    temp_file=$(mktemp)
    while IFS='|' read -r lp addr tp last_ip; do
        current_ip=$(get_ip "$addr")
        if [ "$current_ip" != "$last_ip" ] && [ ! -z "$current_ip" ]; then
            echo "$lp|$addr|$tp|$current_ip" >> "$temp_file"
            changed=1
        else
            echo "$lp|$addr|$tp|$last_ip" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    mv "$temp_file" "$CONFIG_FILE"
    [ $changed -eq 1 ] && apply_rules
}

if ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y dnsutils || yum install -y bind-utils
fi

if [ "$1" == "--cron" ]; then
    ddns_update
    exit 0
fi

while true; do
    echo -e "\n${GREEN}--- nftables 转发管理器 ---${PLAIN}"
    echo "1. 开启 BBR + 系统优化"
    echo "2. 新增转发 (支持域名)"
    echo "3. 查看当前列表"
    echo "4. 删除单条转发"
    echo "5. 彻底清空配置与规则"
    echo "6. 立即同步域名 IP"
    echo "0. 退出"
    read -p "选择: " choice
    case $choice in
        1) optimize_system ;;
        2) add_forward ;;
        3) show_forward ; read -p "按回车继续..." ;;
        4) del_forward ;;
        5) reset_all ;;
        6) ddns_update ; echo "更新完成。" ;;
        0) exit 0 ;;
    esac
done
EOF
chmod +x nft_mgr.sh && ./nft_mgr.sh
