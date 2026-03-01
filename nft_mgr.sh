cat > nft.sh << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/nft_forward_list.conf"
SHORTCUT_PATH="/usr/local/bin/nft"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# --- 1. 核心转发逻辑 (防堆叠版) ---
function get_ip() {
    local addr=$1
    if [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$addr"
    else
        # 增加 2 秒解析超时，防止因 DNS 导致面板卡死
        timeout 2 dig +short "$addr" | grep -E '^[0-9.]+$' | tail -n1
    fi
}

function apply_rules() {
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null
    nft flush chain ip nat prerouting 2>/dev/null
    nft flush chain ip nat postrouting 2>/dev/null

    if [ -s "$CONFIG_FILE" ]; then
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

# --- 2. 强力卸载 (彻底解决清理无效和卡死) ---
function uninstall_all() {
    echo -e "${RED}开始彻底清理环境...${PLAIN}"
    # 先清理 Cron 任务，切断后台自启动来源
    crontab -r 2>/dev/null
    # 强制排空内核防火墙钩子
    nft flush ruleset 2>/dev/null
    # 停止服务释放可能的锁
    systemctl stop nftables 2>/dev/null
    # 删除所有物理痕迹
    rm -f "$CONFIG_FILE" "$SHORTCUT_PATH" /etc/nftables.conf /etc/sysctl.d/99-sys-opt.conf
    systemctl start nftables 2>/dev/null
    echo -e "${GREEN}卸载完成！环境已恢复纯净。${PLAIN}"
    rm -f "$0"
    exit 0
}

# --- 3. 监控管理 (解决 DDNS 冲突) ---
function manage_cron() {
    local script_path=$(realpath "$0")
    cp "$script_path" "$SHORTCUT_PATH" && chmod +x "$SHORTCUT_PATH"
    if crontab -l 2>/dev/null | grep -q "$SHORTCUT_PATH"; then
        echo -e "${GREEN}状态：监控中${PLAIN}"
        read -p "关闭监控？(y/n): " oc
        [[ "$oc" == [yY] ]] && crontab -l | grep -v "$SHORTCUT_PATH" | crontab -
    else
        echo -e "${RED}状态：已关闭${PLAIN}"
        read -p "开启每 5 分钟同步？(y/n): " oc
        if [[ "$oc" == [yY] ]]; then
            (crontab -l 2>/dev/null | grep -v "$SHORTCUT_PATH"; echo "*/5 * * * * $SHORTCUT_PATH --cron > /dev/null 2>&1") | crontab -
            echo "开启成功。"
        fi
    fi
}

# --- 4. 交互面板 ---
function main_menu() {
    while true; do
        echo -e "\n${GREEN}--- nftables 转发管理 (最终修正版) ---${PLAIN}"
        echo "1. 开启 BBR + 系统优化"
        echo "2. 新增端口转发"
        echo "3. 查看/删除当前转发"
        echo "4. 管理定时监控 (DDNS 修复)"
        echo -e "${RED}7. 一键强力卸载${PLAIN}"
        echo "0. 退出"
        read -p "选择: " choice
        case $choice in
            1)
                echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-sys-opt.conf
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-sys-opt.conf
                echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-sys-opt.conf
                sysctl --system >/dev/null 2>&1 ; echo "优化完成。" ;;
            2)
                read -p "本地端口: " lp
                read -p "目标地址: " ad
                read -p "目标端口: " tp
                echo "$lp|$ad|$tp|0.0.0.0" >> "$CONFIG_FILE"
                apply_rules ; echo "添加成功。" ;;
            3)
                echo -e "\n行号 | 本地端口 | 目标地址 | 映射IP"
                [ -s "$CONFIG_FILE" ] && nl -s " | " -w 2 "$CONFIG_FILE"
                read -p "输入行号删除 (直接回车返回): " ln
                if [ ! -z "$ln" ]; then
                    sed -i "${ln}d" "$CONFIG_FILE"
                    apply_rules ; echo "已更新规则。"
                fi ;;
            4) manage_cron ;;
            7) uninstall_all ;;
            0) exit 0 ;;
        esac
    done
}

# 初始化依赖
if ! command -v nft &>/dev/null; then
    apt-get update && apt-get install -y nftables dnsutils cron || yum install -y nftables bind-utils cronie
fi
systemctl enable nftables && systemctl start nftables > /dev/null 2>&1
cp "$0" "$SHORTCUT_PATH" 2>/dev/null && chmod +x "$SHORTCUT_PATH" 2>/dev/null

if [ "$1" == "--cron" ]; then
    apply_rules ; exit 0
fi

main_menu
EOF
chmod +x nft.sh && ./nft.sh
