#!/bin/bash
# =========================================
# 作者: jinqians (Modified)
# 启动命令: ssr
# 功能: 移除Snell，保留ShadowTLS，支持SS-Rust平滑更新、智能调参、全量卸载
# =========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

current_version="6.0-Custom"
CONF_FILE="/etc/sysctl.d/99-bbr.conf"

# --- 1. 智能调参逻辑 (深度集成) ---
smart_optimization() {
    echo -e "${CYAN}>>> 正在启动智能调参...${RESET}"
    
    # 获取系统信息 
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    
    # 动态参数计算 [cite: 75, 76, 77, 78]
    if [ "$TOTAL_MEM" -le 512 ]; then
        RMEM_MAX="16777216"; SOMAXCONN="4096"; CONNTRACK_MAX="65536"
    elif [ "$TOTAL_MEM" -le 1024 ]; then
        RMEM_MAX="33554432"; SOMAXCONN="16384"; CONNTRACK_MAX="262144"
    elif [ "$TOTAL_MEM" -le 4096 ]; then
        RMEM_MAX="67108864"; SOMAXCONN="32768"; CONNTRACK_MAX="524288"
    else
        RMEM_MAX="134217728"; SOMAXCONN="65535"; CONNTRACK_MAX="1048576"
    fi

    # 写入优化配置 [cite: 83, 84, 85]
    cat > "$CONF_FILE" << EOF
# Linux Network Tuning (Proxy Optimized)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $RMEM_MAX
net.ipv4.tcp_rmem = 8192 262144 $RMEM_MAX
net.ipv4.tcp_wmem = 8192 262144 $RMEM_MAX
net.core.somaxconn = $SOMAXCONN
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_notsent_lowat = 16384
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
EOF

    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 智能调参完成！BBR已开启，内核参数已根据 ${TOTAL_MEM}MB 内存优化。${RESET}"
}

# --- 2. 核心功能函数 ---
install_global_command() {
    SCRIPT_PATH=$(readlink -f "$0")
    ln -sf "$SCRIPT_PATH" "/usr/local/bin/ssr"
    chmod +x "$SCRIPT_PATH"
    if ! crontab -l 2>/dev/null | grep -q "ssr auto_update"; then
        (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/ssr auto_update > /dev/null 2>&1") | crontab -
    fi
}

change_ssh_port() {
    read -p "请输入新的 SSH 端口号: " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]]; then
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart ssh
        echo -e "${GREEN}SSH 端口已修改为 $new_port。${RESET}"
    fi
}

auto_update_ss_rust() {
    [ -d "/etc/ss-rust" ] && cp -r "/etc/ss-rust" "/tmp/ss-rust-bak"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) <<EOF
1
EOF
    if [ -d "/tmp/ss-rust-bak" ]; then
        rm -rf "/etc/ss-rust" && mv "/tmp/ss-rust-bak" "/etc/ss-rust"
        systemctl restart ss-rust 2>/dev/null
    fi
}

total_uninstall() {
    echo -e "${RED}正在全量卸载所有组件...${RESET}"
    systemctl stop ss-rust 2>/dev/null
    rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service "$CONF_FILE"
    crontab -l | grep -v "ssr auto_update" | crontab -
    rm -f /usr/local/bin/ssr
    echo -e "${GREEN}全量卸载完成。${RESET}"
    exit 0
}

# --- 3. 主菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW}1.${RESET} SS-2022 安装管理"
    echo -e "${YELLOW}2.${RESET} VLESS Reality 安装管理"
    echo -e "${YELLOW}3.${RESET} ShadowTLS 安装管理"
    echo -e "${YELLOW}4.${RESET} ${GREEN}智能调参 (BBR/内核优化)${RESET}"
    echo -e "${YELLOW}5.${RESET} 服务器时间同步"
    echo -e "${YELLOW}6.${RESET} 修改 SSH 端口"
    echo -e "${RED}7. 全量干净卸载脚本${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "0. 退出"
    read -rp "请输入选项: " num
}

if [ "${1:-}" == "auto_update" ]; then
    auto_update_ss_rust
    exit 0
fi

install_global_command
while true; do
    show_menu
    case "$num" in
        1) bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) ;;
        2) bash <(curl -sL https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh) ;;
        3) bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh) ;;
        4) smart_optimization ;;
        5) sudo apt update && sudo apt install systemd-timesyncd -y && sudo systemctl enable --now systemd-timesyncd ;;
        6) change_ssh_port ;;
        7) total_uninstall ;;
        0) exit 0 ;;
    esac
    read -n 1 -s -r -p "按任意键返回..."
done
