#!/bin/bash

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

CHAIN_NAME="BLOCK_OVERSEAS"
SET_NAME="cn_ips"
# 获取当前脚本的绝对路径，用于 systemd 服务
SCRIPT_PATH=$(readlink -f "$0")

function install_dependencies() {
    if [ -x "$(command -v apt)" ]; then
        apt-get update -y && apt-get install -y ipset iptables wget gawk >/dev/null 2>&1
    elif [ -x "$(command -v yum)" ]; then
        yum install -y ipset iptables wget gawk >/dev/null 2>&1
    fi
}

function enable_block() {
    install_dependencies

    echo "正在从 APNIC 获取最新的中国 IP 段..."
    wget -qO- http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest | awk -F\| '/CN\|ipv4/ { printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > /tmp/cn_ip.txt

    if [ ! -s /tmp/cn_ip.txt ]; then
        echo "❌ 获取 IP 段失败，请检查网络！"
        exit 1
    fi

    echo "正在配置 ipset 哈希表..."
    ipset destroy $SET_NAME 2>/dev/null
    ipset create $SET_NAME hash:net maxelem 100000

    awk -v setname="$SET_NAME" '{print "add " setname " " $1}' /tmp/cn_ip.txt | ipset restore

    echo "正在配置 iptables 防火墙规则..."
    iptables -D INPUT -j $CHAIN_NAME 2>/dev/null
    iptables -F $CHAIN_NAME 2>/dev/null
    iptables -X $CHAIN_NAME 2>/dev/null

    iptables -N $CHAIN_NAME
    iptables -A $CHAIN_NAME -i lo -j RETURN
    iptables -A $CHAIN_NAME -m state --state RELATED,ESTABLISHED -j RETURN
    iptables -A $CHAIN_NAME -m set --match-set $SET_NAME src -j RETURN
    iptables -A $CHAIN_NAME -j DROP

    iptables -I INPUT 1 -j $CHAIN_NAME

    echo "✅ 海外 IP 屏蔽已成功开启！"
}

function disable_block() {
    echo "正在清除海外 IP 屏蔽规则..."
    iptables -D INPUT -j $CHAIN_NAME 2>/dev/null
    iptables -F $CHAIN_NAME 2>/dev/null
    iptables -X $CHAIN_NAME 2>/dev/null
    ipset destroy $SET_NAME 2>/dev/null
    echo "✅ 屏蔽已关闭，当前所有 IP 均可连接。"
}

function setup_autostart() {
    SERVICE_FILE="/etc/systemd/system/block-overseas-ip.service"
    
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Block Overseas IP Service (APNIC Update)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH start
RemainAfterExit=yes
ExecStop=$SCRIPT_PATH stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable block-overseas-ip.service
    echo "✅ 开机自启已设置成功！每次重启服务器将自动拉取最新 IP 并拦截海外连接。"
    echo "⚠️  注意：请不要移动或删除当前脚本 ($SCRIPT_PATH)，否则自启将失效。"
}

function remove_autostart() {
    SERVICE_FILE="/etc/systemd/system/block-overseas-ip.service"
    if [ -f "$SERVICE_FILE" ]; then
        systemctl disable block-overseas-ip.service >/dev/null 2>&1
        rm -f $SERVICE_FILE
        systemctl daemon-reload
        echo "✅ 已取消开机自启。"
    else
        echo "⚠️ 未找到自启服务，无需取消。"
    fi
}

# 增加静默参数支持，供 systemd 或 crontab 调用
if [ "$1" == "start" ]; then
    enable_block
    exit 0
elif [ "$1" == "stop" ]; then
    disable_block
    exit 0
fi

# 交互式菜单
echo "========================================="
echo " 国内 VPS 屏蔽海外 IP 一键管理脚本 (终极版)"
echo "========================================="
echo "1. 开启屏蔽海外 IP (仅允许国内 IP 访问)"
echo "2. 关闭屏蔽 (恢复默认，允许所有 IP 访问)"
echo "-----------------------------------------"
echo "3. 设置开机自启 (重启自动更新IP并屏蔽)"
echo "4. 取消开机自启"
echo "-----------------------------------------"
echo "5. 退出"
echo "========================================="
read -p "请输入选项 [1-5]: " option

case $option in
    1) enable_block ;;
    2) disable_block ;;
    3) setup_autostart ;;
    4) remove_autostart ;;
    5) exit 0 ;;
    *) echo "无效选项，请重新运行脚本。" ;;
esac
