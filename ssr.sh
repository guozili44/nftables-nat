#!/bin/bash
# =========================================
# 作者: muyu
# 描述: 统一管理脚本 - 已移除 Snell，新增 SS-Rust 自动更新
# 启动命令: ssr
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="3.1-Custom"

# 安装全局命令 (已由 menu 改为 ssr)
install_global_command() {
    echo -e "${CYAN}正在配置全局命令 'ssr'...${RESET}"
    
    # 将当前脚本路径创建软链接到 /usr/local/bin/ssr
    SCRIPT_PATH=$(readlink -f "$0")
    
    if [ -f "/usr/local/bin/ssr" ]; then
        rm -f "/usr/local/bin/ssr"
    fi
    ln -s "$SCRIPT_PATH" "/usr/local/bin/ssr"
    chmod +x "$SCRIPT_PATH"
    
    echo -e "${GREEN}配置成功！现在您可以在任何位置使用 'ssr' 命令来启动管理脚本${RESET}"
}

# 检查并安装依赖 [cite: 3, 5]
check_dependencies() {
    local deps=("bc" "curl" "jq")
    local need_update=false
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            need_update=true
            break
        fi
    done
    
    if [ "$need_update" = true ]; then
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y bc curl jq [cite: 6, 8]
        elif [ -x "$(command -v yum)" ]; then
            yum install -y bc curl jq [cite: 9, 11]
        fi
    fi
}

# 获取 CPU 使用率 [cite: 13]
get_cpu_usage() {
    local pid=$1
    local cpu_cores=$(nproc)
    if [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
        local cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" | tail -1 | awk '{print $9}')
        echo "scale=2; $cpu_usage / $cpu_cores" | bc -l
    fi
}

# 自动更新 SS-Rust 逻辑 (新增)
auto_update_ss_rust() {
    echo -e "${CYAN}正在检查 Shadowsocks-Rust 最新版本...${RESET}"
    local latest_ver=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    
    if [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ]; then
        echo -e "${RED}获取版本失败，请检查网络${RESET}"
        return
    fi

    echo -e "${YELLOW}最新版本: $latest_ver${RESET}"
    
    # 停止旧服务并删除旧配置（应用户要求：无需备份，避免规则混杂）[cite: 33, 34]
    systemctl stop ss-rust 2>/dev/null
    rm -rf "/etc/ss-rust"
    echo -e "${YELLOW}已删除旧配置文件，防止规则冲突${RESET}"

    # 调用原安装脚本进行更新安装
    manage_ss_rust
    echo -e "${GREEN}Shadowsocks-Rust 已尝试更新至 $latest_ver${RESET}"
}

# 检查服务状态并显示 (已移除 Snell 部分) [cite: 16, 31]
check_and_show_status() {
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    
    # 检查 SS-2022 状态 [cite: 32]
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_pid=$(systemctl show -p MainPID ss-rust | cut -d'=' -f2)
        local ss_running=$(systemctl is-active ss-rust &> /dev/null && echo 1 || echo 0)
        printf "${GREEN}SS-2022 已安装${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}\n"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi
    
    # 检查 ShadowTLS 状态 [cite: 36, 41]
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        echo -e "${GREEN}ShadowTLS 已安装${RESET}"
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
}

# 安装管理函数 [cite: 49]
manage_ss_rust() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh); }
manage_vless() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh); }
manage_shadowtls() { bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh); }

# 卸载功能 [cite: 65, 66]
uninstall_ss_rust() {
    systemctl stop ss-rust 2>/dev/null
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/etc/ss-rust"
    echo -e "${GREEN}SS-2022 卸载完成并已清理配置${RESET}"
}

# 主菜单 [cite: 58]
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          SS-Rust 管理脚本 (Custom)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    check_and_show_status
    echo -e "${YELLOW}=== 安装与更新 ===${RESET}"
    echo -e "${GREEN}1.${RESET} SS-2022 安装/管理"
    echo -e "${GREEN}2.${RESET} 自动更新 SS-Rust (含配置清理)"
    echo -e "${GREEN}3.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}4.${RESET} ShadowTLS 安装管理"
    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}6.${RESET} 卸载 ShadowTLS"
    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}0.${RESET} 退出"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}退出后，输入 ssr 可再次进入脚本${RESET}"
    read -rp "请输入选项: " num
}

# 初始检查 [cite: 15]
[[ "$(id -u)" != "0" ]] && echo -e "${RED}请以 root 权限运行${RESET}" && exit 1
check_dependencies
install_global_command

# 主循环 [cite: 61, 62, 69]
while true; do
    show_menu
    case "$num" in
        1) manage_ss_rust ;;
        2) auto_update_ss_rust ;;
        3) manage_vless ;;
        4) manage_shadowtls ;;
        5) uninstall_ss_rust ;;
        6) # 卸载 ShadowTLS 逻辑
           while IFS= read -r s; do systemctl stop "$s"; rm -f "/etc/systemd/system/$s"; done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
           echo -e "${GREEN}ShadowTLS 已卸载${RESET}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回主菜单..."
done
