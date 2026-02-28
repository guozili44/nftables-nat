#!/usr/bin/env bash
set -e

# 修改路径，避免覆盖系统主配置文件
CONF_DIR="/etc/nftables.d"
CONF="$CONF_DIR/nft-forward.conf"
STATE="/etc/nftables-forward.state"

mkdir -p "$CONF_DIR"

pause(){ read -rp "按回车继续..." _; }

need_root(){
    [ "$EUID" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
}

# ---------- 安装 nftables ----------
install_nftables(){
    if command -v nft >/dev/null 2>&1; then
        echo "nftables 已安装"
    else
        if command -v apt >/dev/null 2>&1; then
            apt update && apt install -y nftables
        elif command -v yum >/dev/null 2>&1; then
            yum install -y nftables
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nftables
        else
            echo "无法识别包管理器"; exit 1
        fi
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    
    # 确保主配置引用了我们的目录（如果主配置存在）
    if [ -f /etc/nftables.conf ] && ! grep -q "$CONF_DIR" /etc/nftables.conf; then
        echo "include \"$CONF_DIR/*.conf\"" >> /etc/nftables.conf
    fi
    echo "nftables 环境准备就绪"
}

# ---------- 精准卸载功能 ----------
uninstall_script(){
    echo "正在精准清理脚本相关规则..."
    # 只删除脚本建立的专属表
    if nft list tables | grep -q "nft_forward_script"; then
        nft delete table ip nft_forward_script
        echo "已清除专属转发规则表。"
    fi
    rm -f "$CONF" "$STATE"
    echo "已删除配置文件。"
    pause
}

# ---------- 初始化 RELAY_LAN_IP ----------
init_relay_ip(){
    if [ ! -f "$STATE" ]; then
        echo "请输入【本机内网 IP】（用于 SNAT）"
        read -rp "RELAY_LAN_IP: " RELAY_LAN_IP
        echo "RELAY_LAN_IP=${RELAY_LAN_IP}" > "$STATE"
    fi
    source "$STATE"
}

# ---------- 读取已有规则 ----------
load_rules(){
    PORTS=(); DIPS=(); DPORTS=(); NOTES=()
    [ -f "$CONF" ] || return
    while read -r line; do
        case "$line" in
            \#\ \[*\]*) NOTES+=("$(echo "$line" | sed 's/# \[\(.*\)\]/\1/')") ;;
            define\ RELAY_PORT_IN_*) PORTS+=("$(echo "$line" | awk '{print $NF}')") ;;
            define\ DEST_IP_*) DIPS+=("$(echo "$line" | awk '{print $NF}')") ;;
            define\ DEST_PORT_OUT_*) DPORTS+=("$(echo "$line" | awk '{print $NF}')") ;;
        esac
    done < "$CONF"
}

# ---------- 写入专属规则表 ----------
write_conf(){
    COUNT="${#PORTS[@]}"
    {
        echo "define RELAY_LAN_IP = $RELAY_LAN_IP"
        # 使用专属表名 nft_forward_script
        echo "table ip nft_forward_script {"
        
        # 定义变量
        for i in $(seq 1 "$COUNT"); do
            idx=$((i-1))
            [ -n "${NOTES[$idx]:-}" ] && echo "    # [${NOTES[$idx]}]"
            echo "    define RELAY_PORT_IN_${i} = ${PORTS[$idx]}"
            echo "    define DEST_IP_${i} = ${DIPS[$idx]}"
            echo "    define DEST_PORT_OUT_${i} = ${DPORTS[$idx]}"
        done

        echo '    chain prerouting {'
        echo '        type nat hook prerouting priority -100; policy accept;'
        for i in $(seq 1 "$COUNT"); do
            echo "        tcp dport \$RELAY_PORT_IN_${i} dnat to \$DEST_IP_${i}:\$DEST_PORT_OUT_${i}"
            echo "        udp dport \$RELAY_PORT_IN_${i} dnat to \$DEST_IP_${i}:\$DEST_PORT_OUT_${i}"
        done
        echo '    }'

        echo '    chain postrouting {'
        echo '        type nat hook postrouting priority 100; policy accept;'
        for i in $(seq 1 "$COUNT"); do
            echo "        ip daddr \$DEST_IP_${i} tcp dport \$DEST_PORT_OUT_${i} snat to \$RELAY_LAN_IP"
            echo "        ip daddr \$DEST_IP_${i} udp dport \$DEST_PORT_OUT_${i} snat to \$RELAY_LAN_IP"
        done
        echo '    }'
        echo '}'
    } > "$CONF"

    # 先清理旧的专属表，再加载新配置
    nft delete table ip nft_forward_script 2>/dev/null || true
    nft -f "$CONF"
}

# ---------- 菜单功能 ----------
add_forward(){
    init_relay_ip; load_rules
    read -rp "本地端口: " IN_PORT; read -rp "目标IP: " DIP; read -rp "目标端口: " DPORT; read -rp "备注: " NOTE
    PORTS+=("$IN_PORT"); DIPS+=("$DIP"); DPORTS+=("$DPORT"); NOTES+=("$NOTE")
    write_conf; echo "已添加转发"; pause
}

delete_forward(){
    init_relay_ip; load_rules
    [ "${#PORTS[@]}" -eq 0 ] && { echo "无规则"; pause; return; }
    for i in "${!PORTS[@]}"; do echo "$((i+1)). ${PORTS[$i]} -> ${DIPS[$i]}:${DPORTS[$i]} [${NOTES[$i]}]"; done
    read -rp "删除序号: " IDX
    IDX=$((IDX-1))
    unset PORTS[$IDX] DIPS[$IDX] DPORTS[$IDX] NOTES[$IDX]
    PORTS=("${PORTS[@]}"); DIPS=("${DIPS[@]}"); DPORTS=("${DPORTS[@]}"); NOTES=("${NOTES[@]}")
    write_conf; echo "已删除"; pause
}

list_forward(){
    load_rules
    [ "${#PORTS[@]}" -eq 0 ] && echo "没有转发规则"
    for i in "${!PORTS[@]}"; do echo "${PORTS[$i]} -> ${DIPS[$i]}:${DPORTS[$i]}  [${NOTES[$i]}]"; done
    pause
}

# ---------- 主菜单 ----------
need_root
while true; do
    clear
    echo "========== nftables 转发管理 (安全隔离版) =========="
    echo "1) 安装/环境检查"
    echo "2) 添加转发"
    echo "3) 删除转发"
    echo "4) 查看转发"
    echo "9) 仅清理本脚本规则并卸载"
    echo "0) 退出"
    read -rp "请选择: " C
    case "$C" in
        1) install_nftables; pause ;;
        2) add_forward ;;
        3) delete_forward ;;
        4) list_forward ;;
        9) uninstall_script ;;
        0) exit 0 ;;
        *) echo "无效选择"; pause ;;
    esac
done
