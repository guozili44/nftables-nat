#!/bin/bash
# ==============================================================================
# 脚本名称: SSR 综合管理脚本 (防火墙全能版)
# 核心功能: CLI双模、无Snell、保留ShadowTLS、SS-Rust旧配置保护、防爆破、BBRv3、防火墙管控
# 全局命令: ssr [可选参数: bbr | swap | clean | update]
# ==============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'
readonly SCRIPT_VERSION="15.0-Firewall-Edition"
readonly CONF_FILE="/etc/sysctl.d/99-bbr.conf"

trap 'echo -e "\n${GREEN}已安全退出脚本。${RESET}"; exit 0' SIGINT

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行！${RESET}" && exit 1
    local deps=("curl" "jq" "bc" "wget")
    local need_install=false
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then need_install=true; break; fi
    done
    if $need_install; then
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -yqq curl jq bc wget
        elif command -v yum >/dev/null 2>&1; then yum install -yq curl jq bc wget; fi
    fi
}

install_global_command() {
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0")
    [[ ! -L "/usr/local/bin/ssr" ]] && ln -sf "$SCRIPT_PATH" "/usr/local/bin/ssr" && chmod +x "$SCRIPT_PATH"
    
    if ! crontab -l 2>/dev/null | grep -q "ssr auto_task"; then
        crontab -l 2>/dev/null | grep -v "ssr auto_update" | crontab -
        (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/ssr auto_task > /dev/null 2>&1") | crontab -
    fi
}

# ==========================================================
# 核心功能模块 (防爆破 / BBR / Swap / 清理等)
# ==========================================================

install_fail2ban() {
    echo -e "${CYAN}>>> 正在部署 Fail2Ban 智能防爆破...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install fail2ban -yqq
        local log_path="/var/log/auth.log"
    else
        yum install epel-release -yq && yum install fail2ban -yq
        local log_path="/var/log/secure"
    fi
    local ssh_port=$(grep -E "^Port" /etc/ssh/sshd_config | awk '{print $2}' | head -n 1)
    [[ -z "$ssh_port" ]] && ssh_port=22

    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = $log_path
maxretry = 5
bantime = 86400
EOF
    systemctl restart fail2ban; systemctl enable fail2ban
    echo -e "${GREEN}✅ Fail2Ban 已启动！SSH 连续失败 5 次将被封禁 24 小时。${RESET}"
}

uninstall_fail2ban() {
    systemctl stop fail2ban 2>/dev/null; systemctl disable fail2ban 2>/dev/null
    if command -v apt-get >/dev/null 2>&1; then apt-get purge fail2ban -yqq; else yum remove fail2ban -yq; fi
    rm -rf /etc/fail2ban; echo -e "${GREEN}✅ Fail2Ban 已完全卸载。${RESET}"
}

install_bbrv3() {
    echo -e "${CYAN}>>> 准备调用 BBR 魔改脚本...${RESET}"
    echo -e "${YELLOW}⚠️ 注意: 更换内核存在极小概率导致无法开机！${RESET}"
    sleep 3; wget -O tcpx.sh "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh" && chmod +x tcpx.sh && ./tcpx.sh
}

uninstall_bbrv3() {
    echo -e "${RED}⚠️ 警告: 强制卸载内核极危险！请在【开启 BBRv3 魔改内核】菜单中卸载或安装原版内核。${RESET}"
}

auto_swap() {
    if swapon --show | grep -q "/swapfile"; then echo -e "${GREEN}✅ Swap 已存在！${RESET}"; return; fi
    local mem_size=$(free -m | awk '/^Mem:/{print $2}')
    local swap_size=2048; [[ "$mem_size" -le 1024 ]] && swap_size=1024
    fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size >/dev/null 2>&1
    chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo -e "${GREEN}✅ 成功启用 ${swap_size}MB Swap！${RESET}"
}

auto_clean() {
    local is_silent=$1
    if command -v apt-get >/dev/null 2>&1; then apt-get autoremove -yqq >/dev/null 2>&1; apt-get clean -qq >/dev/null 2>&1; fi
    if command -v journalctl >/dev/null 2>&1; then journalctl --vacuum-time=3d >/dev/null 2>&1; fi
    rm -rf /root/.cache/* 2>/dev/null
    [[ "$is_silent" != "silent" ]] && echo -e "${GREEN}✅ 系统垃圾清理完毕！${RESET}"
}

smart_optimization() {
    local total_mem=$(free -m | awk '/^Mem:/{print $2}' | tr -d '\r')
    local rmem_max somaxconn conntrack_max
    if [ "$total_mem" -le 512 ]; then rmem_max="16777216"; somaxconn="4096"; conntrack_max="65536"
    elif [ "$total_mem" -le 1024 ]; then rmem_max="33554432"; somaxconn="16384"; conntrack_max="262144"
    elif [ "$total_mem" -le 4096 ]; then rmem_max="67108864"; somaxconn="32768"; conntrack_max="524288"
    else rmem_max="134217728"; somaxconn="65535"; conntrack_max="1048576"; fi

    cat > "$CONF_FILE" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = 8192 262144 $rmem_max
net.ipv4.tcp_wmem = 8192 262144 $rmem_max
net.core.somaxconn = $somaxconn
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_notsent_lowat = 16384
net.netfilter.nf_conntrack_max = $conntrack_max
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ 智能调参完成！默认 BBR 已应用。${RESET}"
}

change_ssh_port() {
    read -rp "请输入新的 SSH 端口号 (1-65535): " new_port
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw allow "$new_port"/tcp >/dev/null 2>&1; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$new_port"/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        sed -i "s/^#\?Port [0-9]*/Port $new_port/g" /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        echo -e "${GREEN}✅ SSH 端口已修改为 $new_port。${RESET}"
    fi
}

change_root_password() {
    read -rp "请输入新的 root 密码: " new_pass
    [[ -z "$new_pass" ]] && return
    read -rp "请再次输入确认: " new_pass_confirm
    [[ "$new_pass" != "$new_pass_confirm" ]] && echo -e "${RED}两次密码不一致！${RESET}" && return
    echo "root:$new_pass" | chpasswd && echo -e "${GREEN}✅ 密码修改成功！${RESET}"
}

update_script() {
    echo -e "${CYAN}>>> 同步最新脚本数据...${RESET}"
    curl -Ls https://raw.githubusercontent.com/jinqians/menu/main/menu.sh -o /usr/local/bin/ssr.sh
    if [[ $? -eq 0 ]]; then
        chmod +x /usr/local/bin/ssr.sh
        echo -e "${GREEN}✅ 更新成功！重启面板...${RESET}"
        sleep 1; exec /usr/local/bin/ssr.sh
    else
        echo -e "${RED}❌ 更新失败！${RESET}"
    fi
}

# ==========================================================
# UFW/Firewall 防火墙与端口速管中心
# ==========================================================
fw_check() {
    if command -v apt-get >/dev/null 2>&1; then
        if ! command -v ufw >/dev/null 2>&1; then apt-get install ufw -yqq; fi
        ufw enable >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        if ! command -v firewall-cmd >/dev/null 2>&1; then yum install firewalld -yq; systemctl enable --now firewalld; fi
        systemctl start firewalld >/dev/null 2>&1
    fi
}

fw_list() {
    fw_check
    echo -e "${CYAN}>>> 当前防火墙状态与已开放端口：${RESET}"
    if command -v ufw >/dev/null 2>&1; then ufw status numbered
    elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --list-ports; fi
}

fw_allow() {
    fw_check
    read -rp "请输入需要开放的端口号 (1-65535): " port
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        if command -v ufw >/dev/null 2>&1; then ufw allow "$port"; ufw reload >/dev/null 2>&1
        elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --add-port="$port/tcp" --permanent; firewall-cmd --add-port="$port/udp" --permanent; firewall-cmd --reload >/dev/null 2>&1; fi
        echo -e "${GREEN}✅ 端口 $port 已成功对外开放！${RESET}"
    else
        echo -e "${RED}端口格式错误！${RESET}"
    fi
}

fw_deny() {
    fw_check
    read -rp "请输入需要关闭的端口号 (1-65535): " port
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        if command -v ufw >/dev/null 2>&1; then ufw delete allow "$port"; ufw delete allow "$port"/tcp 2>/dev/null; ufw delete allow "$port"/udp 2>/dev/null; ufw reload >/dev/null 2>&1
        elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --remove-port="$port/tcp" --permanent; firewall-cmd --remove-port="$port/udp" --permanent; firewall-cmd --reload >/dev/null 2>&1; fi
        echo -e "${GREEN}✅ 端口 $port 已成功关闭！${RESET}"
    else
        echo -e "${RED}端口格式错误！${RESET}"
    fi
}

fw_disable_all() {
    echo -e "${RED}⚠️ 警告：此操作将彻底关闭防火墙，你的服务器所有端口将完全暴露！${RESET}"
    read -rp "确定要一键开启所有端口吗？[y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw disable
        elif command -v firewall-cmd >/dev/null 2>&1; then
            systemctl stop firewalld; systemctl disable firewalld
        fi
        echo -e "${GREEN}✅ 防火墙已成功关闭，当前已开放所有端口！${RESET}"
    else
        echo -e "${YELLOW}已取消操作，防火墙保持原样。${RESET}"
    fi
}

firewall_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}           UFW/防火墙 极简管理中心${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 查看当前已开放的所有端口"
    echo -e "${YELLOW} 2.${RESET} 一键开放指定端口 (允许公网访问)"
    echo -e "${YELLOW} 3.${RESET} 一键关闭指定端口 (禁止公网访问)"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${RED} 4. 一键开启所有端口 (强制关闭防火墙)${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e " 0. 返回主菜单"
    read -rp "请输入对应数字 [0-4]: " fw_num
    case "$fw_num" in
        1) fw_list ;;
        2) fw_allow ;;
        3) fw_deny ;;
        4) fw_disable_all ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

# ==========================================================
# 后台任务与卸载逻辑
# ==========================================================

run_auto_task() {
    local latest_ver=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    if [[ -n "$latest_ver" && "$latest_ver" != "null" && -x "/usr/local/bin/ss-rust" ]]; then
        local current_ver=$(/usr/local/bin/ss-rust --version | awk '{print $2}')
        if [[ "$latest_ver" != *"$current_ver"* ]]; then
            [[ -d "/etc/ss-rust" ]] && cp -r "/etc/ss-rust" "/tmp/ss-rust-bak"
            bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) <<EOF
1
EOF
            if [[ -d "/tmp/ss-rust-bak" ]]; then rm -rf "/etc/ss-rust" && mv "/tmp/ss-rust-bak" "/etc/ss-rust"; systemctl restart ss-rust 2>/dev/null; fi
        fi
    fi
    auto_clean "silent"
}

total_uninstall() {
    echo -e "${RED}⚠️ 正在执行全量毁灭性卸载...${RESET}"
    
    systemctl stop ss-rust 2>/dev/null; rm -rf /etc/ss-rust /usr/local/bin/ss-rust /etc/systemd/system/ss-rust.service
    while IFS= read -r s; do systemctl stop "$s" 2>/dev/null; rm -f "/etc/systemd/system/$s"; done < <(systemctl list-units --type=service --all --no-legend | grep "shadowtls-" | awk '{print $1}')
    rm -f /usr/local/bin/shadow-tls
    uninstall_fail2ban >/dev/null 2>&1
    
    if swapon --show | grep -q "/swapfile"; then swapoff /swapfile; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab; fi
    rm -f "$CONF_FILE" && sysctl --system >/dev/null 2>&1
    crontab -l 2>/dev/null | grep -v "ssr auto_task" | crontab -
    rm -f /usr/local/bin/ssr /usr/local/bin/ssr.sh
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ 全量卸载完成！系统已恢复初始状态。${RESET}"
    exit 0
}

# ==========================================================
# 多级菜单逻辑
# ==========================================================

opt_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}             网络与系统优化菜单${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 智能一键配置 BBR 网络调参"
    echo -e "${YELLOW} 2.${RESET} 开启 BBRv3 魔改内核"
    echo -e "${YELLOW} 3.${RESET} 智能配置 Swap 虚拟内存"
    echo -e "${YELLOW} 4.${RESET} 自动清理系统垃圾与冗余日志"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e " 0. 返回主菜单"
    read -rp "请输入对应数字 [0-4]: " opt_num
    case "$opt_num" in
        1) smart_optimization ;;
        2) install_bbrv3 ;;
        3) auto_swap ;;
        4) auto_clean ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

sys_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}             安全与系统管理菜单${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 部署 Fail2Ban 智能防爆破"
    echo -e "${YELLOW} 2.${RESET} 服务器时间防偏移自动同步"
    echo -e "${YELLOW} 3.${RESET} 一键修改 SSH 安全端口"
    echo -e "${YELLOW} 4.${RESET} 一键修改 Root 密码"
    echo -e "${YELLOW} 5.${RESET} 手动更新 SSR 脚本并重启面板"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e " 0. 返回主菜单"
    read -rp "请输入对应数字 [0-5]: " sys_num
    case "$sys_num" in
        1) install_fail2ban ;;
        2) sudo apt-get update -qq && sudo apt-get install -yqq systemd-timesyncd && sudo systemctl enable --now systemd-timesyncd && echo -e "${GREEN}✅ 时间同步完成！${RESET}" ;;
        3) change_ssh_port ;;
        4) change_root_password ;;
        5) update_script ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

uninstall_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${RED}             组件专项卸载中心${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW} 1.${RESET} 卸载 Fail2Ban 智能防爆破"
    echo -e "${YELLOW} 2.${RESET} 卸载 BBRv3 魔改内核"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${RED} 3. 全量彻底卸载 (SS/ShadowTLS/脚本及环境)${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e " 0. 返回主菜单"
    read -rp "请输入对应数字 [0-3]: " uni_num
    case "$uni_num" in
        1) uninstall_fail2ban ;;
        2) uninstall_bbrv3 ;;
        3) total_uninstall ;;
        0) return ;;
        *) echo -e "${RED}无效选项！${RESET}" ;;
    esac
}

main_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}       SSR 综合智能管理脚本 v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    if [[ -x "/usr/local/bin/ss-rust" ]]; then
        local ss_run; ss_run=$(systemctl is-active ss-rust &> /dev/null && echo "运行中" || echo "已停止")
        echo -e "${GREEN} SS-2022  : 已安装 [${ss_run}]${RESET}"
    fi
    if systemctl list-units --type=service | grep -q "shadowtls-"; then
        echo -e "${GREEN} ShadowTLS: 已安装${RESET}"
    fi
    echo -e "${CYAN}--------------------------------------------${RESET}"
    
    echo -e "${YELLOW} 1.${RESET} SS-2022 安装/管理"
    echo -e "${YELLOW} 2.${RESET} VLESS Reality 安装/管理"
    echo -e "${YELLOW} 3.${RESET} ShadowTLS 安装/管理"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW} 4.${RESET} 网络与系统优化 (BBR/Swap/垃圾清理等)"
    echo -e "${YELLOW} 5.${RESET} 安全与系统管理 (Fail2Ban/SSH/更新等)"
    echo -e "${YELLOW} 6.${RESET} 防火墙与端口管理 (UFW极简管控)"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${RED} 7. 组件专项卸载 (专项卸载与全量清理)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e " 0. 退出脚本"
    
    read -rp "请输入对应数字 [0-7]: " num
    case "$num" in
        1) bash <(curl -sL https://raw.githubusercontent.com/jinqians/ss-2022.sh/main/ss-2022.sh) ;;
        2) bash <(curl -sL https://raw.githubusercontent.com/jinqians/vless/refs/heads/main/vless.sh) ;;
        3) bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh) ;;
        4) opt_menu ;;
        5) sys_menu ;;
        6) firewall_menu ;;
        7) uninstall_menu ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项！${RESET}" ;;
    esac
    
    echo -e "\n${CYAN}按任意键返回主菜单，或按 Ctrl+C 直接退出...${RESET}"
    read -n 1 -s -r
}

# ==========================================================
# 终极智能路由调度
# ==========================================================
check_env
install_global_command

if [[ -n "${1:-}" ]]; then
    case "$1" in
        bbr)        smart_optimization ;;
        swap)       auto_swap ;;
        clean)      auto_clean ;;
        update)     update_script ;;
        auto_task)  run_auto_task ;;
        *)
            echo -e "${RED}未知快捷指令: $1${RESET}"
            echo -e "可用指令: ${YELLOW}ssr [bbr | swap | clean | update]${RESET}"
            exit 1
            ;;
    esac
    exit 0
else
    # 强制遵守指令：底部无限循环机制
    while true; do
        main_menu
    done
fi
