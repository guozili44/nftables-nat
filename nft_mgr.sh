cat > nft.sh << 'EOF'
#!/bin/bash

# 路径与配置
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

# --- 注册快捷命令 ---
function register_shortcut() {
    local script_path=$(realpath "$0")
    if [ "$script_path" != "$SHORTCUT_PATH" ]; then
        cp "$script_path" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
    fi
}

# --- 域名解析 ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 增加超时防止卡死
        local res=$(timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1)
        echo "$res"
    fi
}

# --- 应用规则 ---
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

# --- 强力卸载 (选项7) ---
function uninstall_all() {
    echo -e "${RED}正在强力清理所有规则和任务...${PLAIN}"
    # 1. 清理定时任务
    crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH" | crontab -
    # 2. 清理 nftables
    nft flush chain ip nat prerouting 2>/dev/null
    nft flush chain ip nat postrouting 2>/dev/null
    # 3. 删除所有关联文件
    rm -f "$CONFIG_FILE" "$NFT_CONF" "$SYS_OPT_CONF" "$SHORTCUT_PATH"
    echo -e "${GREEN}卸载完成！脚本已自删，现已回到 root 提示符。${PLAIN}"
    rm -f "$0"
    exit 0 # 强制退出
}

# --- 新增转发 (选项2) ---
function add_forward() {
    read -p "本地监听端口: " lp
    read -p "目标地址: " ad
    read -p "目标端口: " tp
    tip=$(get_ip "$ad")
    if [ -z "$tip" ]; then
        echo -e "${YELLOW}警告：域名解析超时，已设为待定 IP。${PLAIN}"
        tip="0.0.0.0"
    fi
    echo "$lp|$ad|$tp|$tip" >> "$CONFIG_FILE"
    apply_rules
    echo -e "${GREEN}转发已添加。操作完成，现已退出脚本。${PLAIN}"
    exit 0 # 强制退出回到 root
}

# --- 菜单展示 ---
function show_menu() {
    echo -e "\n${GREEN}--- nftables 端口转发管理面板 ---${PLAIN}"
    echo "1. 开启 BBR + 系统转发优化"
    echo "2. 新增端口转发 (执行后将退出脚本)"
    echo "3. 查看当前转发列表"
    echo "4. 删除指定端口转发"
    echo "5. 清空所有转发规则"
    echo "6. 管理定时监控 (DDNS 同步)"
    echo -e "${RED}7. 一键卸载并删除脚本 (执行后将退出脚本)${PLAIN}"
    echo "0. 退出"
    echo "--------------------------------"
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) 
            echo "net.core.default_qdisc=fq" > $SYS_OPT_CONF
            echo "net.ipv4.tcp_congestion_control=bbr" >> $SYS_OPT_CONF
            echo "net.ipv4.ip_forward=1" >> $SYS_OPT_CONF
            sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}优化完成。${PLAIN}"
            exit 0 ;;
        2) add_forward ;;
        3) 
            echo -e "\n本地端口 | 目标地址 | 目标端口 | 解析IP"
            [ -s "$CONFIG_FILE" ] && while IFS='|' read -r lp ad tp li; do printf "%-8s | %-15s | %-8s | %-15s\n" "$lp" "$ad" "$tp" "$(get_ip $ad)"; done < "$CONFIG_FILE"
            read -p "按回车退出脚本..."
            exit 0 ;;
        4) 
            read -p "输入要删除的端口: " dp
            sed -i "/^$dp|/d" "$CONFIG_FILE"
            apply_rules
            echo "已删除。退出脚本。"
            exit 0 ;;
        5) > "$CONFIG_FILE" ; apply_rules ; echo "已清空。退出脚本。" ; exit 0 ;;
        6) 
            register_shortcut
            if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
                crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
                echo "定时监控已关闭。"
            else
                (crontab -l 2>/dev/null; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
                echo "定时监控已开启。"
            fi
            exit 0 ;;
        7) uninstall_all ;;
        0) exit 0 ;;
        *) echo "无效选项" ; exit 1 ;;
    esac
}

# 初始化依赖
if ! command -v dig &> /dev/null || ! command -v nft &> /dev/null; then
    apt-get update && apt-get install -y dnsutils nftables cron || yum install -y bind-utils nftables cronie
fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1
register_shortcut

# 定时任务入口
if [ "$1" == "--cron" ]; then
    apply_rules
    exit 0
fi

show_menu
EOF
chmod +x nft.sh && ./nft.sh
