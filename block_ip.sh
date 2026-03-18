#!/usr/bin/env bash
set -Eeuo pipefail

umask 022

SCRIPT_VERSION="2.3.2"
INSTALL_PATH="/usr/local/sbin/allow-cn-only.sh"
WORKDIR="/var/lib/allow-cn-only"
CONF_DIR="/etc/allow-cn-only"
SETTINGS_FILE="$CONF_DIR/settings.conf"
WHITELIST_V4_FILE="$CONF_DIR/whitelist_ipv4.txt"
WHITELIST_V6_FILE="$CONF_DIR/whitelist_ipv6.txt"
LOCK_FILE="/var/lock/allow-cn-only.lock"
APNIC_URL="https://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest"
MIRROR_V4_URL="https://ispip.clang.cn/all_cn_apnic.txt"
MIRROR_V6_URL="https://ispip.clang.cn/all_cn_ipv6_apnic.txt"

CHAIN_V4="CN_ONLY_V4"
CHAIN_V6="CN_ONLY_V6"
SET_V4="cn_ipv4"
SET_V4_TMP="cn_ipv4_tmp"
SET_V6="cn_ipv6"
SET_V6_TMP="cn_ipv6_tmp"
SYSTEMD_SERVICE="/etc/systemd/system/allow-cn-only.service"
SYSTEMD_TIMER="/etc/systemd/system/allow-cn-only.timer"
CRON_TAG="# allow-cn-only"

QUIET=0
ALLOW_PRIVATE_V4=0
ALLOW_PRIVATE_V6=0
FIRST_INSTALL_SSH_CHECK_DONE=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }

log()  { [ "$QUIET" -eq 1 ] || blue "$*"; }
warn() { [ "$QUIET" -eq 1 ] || yellow "$*"; }
die()  { red "$*"; exit 1; }

cleanup_files=()
cleanup() {
  local f
  for f in "${cleanup_files[@]:-}"; do
    [ -n "$f" ] && [ -e "$f" ] && rm -f "$f" || true
  done
}
trap cleanup EXIT

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 权限运行此脚本。"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_interactive() {
  [ "$QUIET" -eq 0 ] && [ -t 0 ]
}

ensure_config_files() {
  mkdir -p "$CONF_DIR"

  if [ ! -f "$SETTINGS_FILE" ]; then
    cat > "$SETTINGS_FILE" <<'EOF_SETTINGS'
# 1=放行内网私有地址源；0=不放行
ALLOW_PRIVATE_V4=0
ALLOW_PRIVATE_V6=0
FIRST_INSTALL_SSH_CHECK_DONE=0
EOF_SETTINGS
  fi

  if [ ! -f "$WHITELIST_V4_FILE" ]; then
    cat > "$WHITELIST_V4_FILE" <<'EOF_V4'
# 每行一个 IPv4 或 IPv4/CIDR，例如：
# 1.2.3.4
# 10.0.0.0/8
EOF_V4
  fi

  if [ ! -f "$WHITELIST_V6_FILE" ]; then
    cat > "$WHITELIST_V6_FILE" <<'EOF_V6'
# 每行一个 IPv6 或 IPv6/CIDR，例如：
# fc00::/7
# 2408:4000::/32
EOF_V6
  fi
}

load_settings() {
  ensure_config_files
  ALLOW_PRIVATE_V4=0
  ALLOW_PRIVATE_V6=0
  FIRST_INSTALL_SSH_CHECK_DONE=0
  # shellcheck disable=SC1090
  . "$SETTINGS_FILE"
  case "${ALLOW_PRIVATE_V4:-0}" in 0|1) : ;; *) ALLOW_PRIVATE_V4=0 ;; esac
  case "${ALLOW_PRIVATE_V6:-0}" in 0|1) : ;; *) ALLOW_PRIVATE_V6=0 ;; esac
  case "${FIRST_INSTALL_SSH_CHECK_DONE:-0}" in 0|1) : ;; *) FIRST_INSTALL_SSH_CHECK_DONE=0 ;; esac
}

save_setting() {
  local key="$1" value="$2"
  ensure_config_files
  if grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$SETTINGS_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$SETTINGS_FILE"
  fi
  load_settings
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "已有另一个实例正在运行，请稍后重试。"
  fi
}

has_systemd() {
  [ -d /run/systemd/system ] && command_exists systemctl
}

ipv6_enabled() {
  [ -s /proc/net/if_inet6 ] && command_exists ip6tables
}

pkg_install() {
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y "$@" >/dev/null 2>&1
  elif command_exists dnf; then
    dnf install -y "$@" >/dev/null 2>&1
  elif command_exists yum; then
    yum install -y "$@" >/dev/null 2>&1
  else
    die "未找到 apt-get/dnf/yum，无法自动安装依赖。"
  fi
}

install_dependencies() {
  local pkgs=()

  command_exists ipset || pkgs+=(ipset)
  command_exists iptables || pkgs+=(iptables)
  command_exists curl || pkgs+=(curl)
  command_exists awk || pkgs+=(gawk)
  command_exists flock || pkgs+=(util-linux)
  command_exists crontab || { has_systemd || pkgs+=(cron); }
  [ -e /etc/ssl/certs ] || pkgs+=(ca-certificates)

  if [ "${#pkgs[@]}" -gt 0 ]; then
    log "正在安装依赖：${pkgs[*]}"
    pkg_install "${pkgs[@]}"
  fi

  command_exists ipset || die "ipset 安装失败。"
  command_exists iptables || die "iptables 安装失败。"
  command_exists curl || die "curl 安装失败。"
  command_exists awk || die "awk/gawk 安装失败。"
}

fetch_apnic_file() {
  local apnic_file
  apnic_file="$(mktemp /tmp/apnic.XXXXXX)"
  cleanup_files+=("$apnic_file")

  log "正在从 APNIC 官方源拉取最新中国 IP 段数据..."
  if curl -4 -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 45 "$APNIC_URL" -o "$apnic_file"; then
    :
  elif curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 45 "$APNIC_URL" -o "$apnic_file"; then
    :
  else
    rm -f "$apnic_file"
    return 1
  fi

  [ -s "$apnic_file" ] || return 1
  printf '%s\n' "$apnic_file"
}

fetch_mirror_cn_lists() {
  local v4_tmp v6_tmp
  mkdir -p "$WORKDIR"
  v4_tmp="$(mktemp /tmp/cn_v4_mirror.XXXXXX)"
  v6_tmp="$(mktemp /tmp/cn_v6_mirror.XXXXXX)"
  cleanup_files+=("$v4_tmp" "$v6_tmp")

  warn "APNIC 官方源下载失败，正在尝试镜像源兜底..."
  curl -4 -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 20 "$MIRROR_V4_URL" -o "$v4_tmp" || \
  curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 20 "$MIRROR_V4_URL" -o "$v4_tmp" || \
  return 1

  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$v4_tmp" || return 1
  grep -Ev '^[[:space:]]*(#|$)' "$v4_tmp" | sort -u > "$WORKDIR/cn_ipv4.txt"

  if ipv6_enabled; then
    if curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 20 "$MIRROR_V6_URL" -o "$v6_tmp" && \
       grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' "$v6_tmp"; then
      grep -Ev '^[[:space:]]*(#|$)' "$v6_tmp" | sort -u > "$WORKDIR/cn_ipv6.txt"
    else
      warn "镜像源 IPv6 数据下载失败，将仅使用 IPv4 规则。"
      : > "$WORKDIR/cn_ipv6.txt"
    fi
  fi

  [ -s "$WORKDIR/cn_ipv4.txt" ] || return 1
  green "已切换到镜像源完成中国 IP 库更新。"
}

refresh_cn_data() {
  local apnic_file
  if apnic_file="$(fetch_apnic_file)"; then
    build_cn_lists "$apnic_file"
    return 0
  fi
  fetch_mirror_cn_lists || die "官方源与镜像源均下载失败，请检查网络或稍后重试。"
}

build_cn_lists() {
  local apnic_file="$1"
  local v4_file v6_file

  mkdir -p "$WORKDIR"
  v4_file="$WORKDIR/cn_ipv4.txt"
  v6_file="$WORKDIR/cn_ipv6.txt"

  awk -F'|' '
    $2=="CN" && $3=="ipv4" {
      c=$5+0
      bits=0
      while (c>1) {
        c=int(c/2)
        bits++
      }
      print $4 "/" (32-bits)
    }
  ' "$apnic_file" | sort -u > "$v4_file"

  awk -F'|' '
    $2=="CN" && $3=="ipv6" {
      print $4 "/" $5
    }
  ' "$apnic_file" | sort -u > "$v6_file"

  [ -s "$v4_file" ] || die "中国 IPv4 列表生成失败。"
  if ipv6_enabled && [ ! -s "$v6_file" ]; then
    warn "未生成 IPv6 中国地址段列表，将仅启用 IPv4 屏蔽。"
  fi
}

sync_ipset_family() {
  local family="$1" real_set="$2" tmp_set="$3" src_file="$4" maxelem="$5"

  [ -s "$src_file" ] || die "IP 列表文件不存在或为空：$src_file"

  ipset create "$real_set" hash:net family "$family" maxelem "$maxelem" -exist
  ipset destroy "$tmp_set" >/dev/null 2>&1 || true
  ipset create "$tmp_set" hash:net family "$family" maxelem "$maxelem"
  awk -v s="$tmp_set" '{print "add " s " " $1}' "$src_file" | ipset restore -!
  ipset swap "$tmp_set" "$real_set"
  ipset destroy "$tmp_set"
}

sync_ipsets() {
  sync_ipset_family inet  "$SET_V4" "$SET_V4_TMP" "$WORKDIR/cn_ipv4.txt" 262144
  if ipv6_enabled && [ -s "$WORKDIR/cn_ipv6.txt" ]; then
    sync_ipset_family inet6 "$SET_V6" "$SET_V6_TMP" "$WORKDIR/cn_ipv6.txt" 131072
  fi
}

delete_jump_rules_v4() {
  while iptables -D INPUT -j "$CHAIN_V4" >/dev/null 2>&1; do :; done
}

delete_jump_rules_v6() {
  if ipv6_enabled; then
    while ip6tables -D INPUT -j "$CHAIN_V6" >/dev/null 2>&1; do :; done
  fi
}

ipset_exists() {
  ipset list -n 2>/dev/null | grep -Fxq -- "$1"
}

rules_active_v4() {
  iptables -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN_V4"
}

rules_active_v6() {
  ipv6_enabled && ip6tables -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN_V6"
}

reapply_rules_if_active() {
  if rules_active_v4 || rules_active_v6; then
    if ipset_exists "$SET_V4"; then
      apply_rules
      green "规则已按最新配置重新加载。"
    else
      warn "检测到旧规则状态异常：规则已启用但中国 IP 集合不存在。请执行“开启屏蔽并立即更新 IP 库”重新初始化。"
    fi
  else
    yellow "当前屏蔽规则未启用，配置已保存；下次开启屏蔽时自动生效。"
  fi
}

apply_whitelist_v4() {
  [ -f "$WHITELIST_V4_FILE" ] || return 0
  while IFS= read -r cidr; do
    cidr="${cidr%%[[:space:]]*}"
    [ -n "$cidr" ] || continue
    case "$cidr" in \#*) continue ;; esac
    iptables -A "$CHAIN_V4" -s "$cidr" -j RETURN
  done < "$WHITELIST_V4_FILE"
}

apply_whitelist_v6() {
  [ -f "$WHITELIST_V6_FILE" ] || return 0
  while IFS= read -r cidr; do
    cidr="${cidr%%[[:space:]]*}"
    [ -n "$cidr" ] || continue
    case "$cidr" in \#*) continue ;; esac
    ip6tables -A "$CHAIN_V6" -s "$cidr" -j RETURN
  done < "$WHITELIST_V6_FILE"
}

apply_private_allow_v4() {
  [ "$ALLOW_PRIVATE_V4" -eq 1 ] || return 0
  iptables -A "$CHAIN_V4" -s 10.0.0.0/8 -j RETURN
  iptables -A "$CHAIN_V4" -s 172.16.0.0/12 -j RETURN
  iptables -A "$CHAIN_V4" -s 192.168.0.0/16 -j RETURN
  iptables -A "$CHAIN_V4" -s 100.64.0.0/10 -j RETURN
}

apply_private_allow_v6() {
  [ "$ALLOW_PRIVATE_V6" -eq 1 ] || return 0
  ip6tables -A "$CHAIN_V6" -s fc00::/7 -j RETURN
}

create_chain_v4() {
  load_settings
  delete_jump_rules_v4
  iptables -N "$CHAIN_V4" >/dev/null 2>&1 || true
  iptables -F "$CHAIN_V4"
  iptables -A "$CHAIN_V4" -i lo -j RETURN
  iptables -A "$CHAIN_V4" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  apply_private_allow_v4
  apply_whitelist_v4
  iptables -A "$CHAIN_V4" -m set --match-set "$SET_V4" src -j RETURN
  iptables -A "$CHAIN_V4" -j DROP
  iptables -I INPUT 1 -j "$CHAIN_V4"
}

create_chain_v6() {
  ipv6_enabled || return 0
  load_settings
  delete_jump_rules_v6
  ip6tables -N "$CHAIN_V6" >/dev/null 2>&1 || true
  ip6tables -F "$CHAIN_V6"
  ip6tables -A "$CHAIN_V6" -i lo -j RETURN
  ip6tables -A "$CHAIN_V6" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  apply_private_allow_v6
  apply_whitelist_v6
  ip6tables -A "$CHAIN_V6" -m set --match-set "$SET_V6" src -j RETURN
  ip6tables -A "$CHAIN_V6" -j DROP
  ip6tables -I INPUT 1 -j "$CHAIN_V6"
}

apply_rules() {
  log "正在应用 IPv4/IPv6 防火墙规则..."
  create_chain_v4
  if ipv6_enabled && [ -s "$WORKDIR/cn_ipv6.txt" ]; then
    create_chain_v6
  else
    warn "系统未启用 IPv6 或无 ip6tables，已跳过 IPv6 规则。"
  fi
}

remove_rules() {
  log "正在清理防火墙规则..."
  delete_jump_rules_v4
  iptables -F "$CHAIN_V4" >/dev/null 2>&1 || true
  iptables -X "$CHAIN_V4" >/dev/null 2>&1 || true
  delete_jump_rules_v6
  if ipv6_enabled; then
    ip6tables -F "$CHAIN_V6" >/dev/null 2>&1 || true
    ip6tables -X "$CHAIN_V6" >/dev/null 2>&1 || true
  fi
  ipset destroy "$SET_V4" >/dev/null 2>&1 || true
  ipset destroy "$SET_V4_TMP" >/dev/null 2>&1 || true
  ipset destroy "$SET_V6" >/dev/null 2>&1 || true
  ipset destroy "$SET_V6_TMP" >/dev/null 2>&1 || true
}

write_systemd_units() {
  cat > "$SYSTEMD_SERVICE" <<EOF_SERVICE
[Unit]
Description=Allow China IPs only firewall updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --quiet update
EOF_SERVICE

  cat > "$SYSTEMD_TIMER" <<'EOF_TIMER'
[Unit]
Description=Daily update of China IP allowlist

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
  systemctl enable --now "$(basename "$SYSTEMD_TIMER")" >/dev/null 2>&1
}

remove_systemd_units() {
  if has_systemd; then
    systemctl disable --now "$(basename "$SYSTEMD_TIMER")" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

enable_autoupdate() {
  log "正在启用自动更新..."
  if has_systemd; then
    write_systemd_units
    green "已启用 systemd 定时更新：每天 03:00 自动刷新中国 IP 库。"
  else
    command_exists crontab || die "系统无 systemd，且未安装 crontab，无法启用自动更新。"
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true; \
      echo "0 3 * * * $INSTALL_PATH --quiet update $CRON_TAG"; \
      echo "@reboot sleep 90 && $INSTALL_PATH --quiet update $CRON_TAG") | crontab -
    green "已启用 cron 自动更新：每天 03:00 + 开机后 90 秒刷新中国 IP 库。"
  fi
}

disable_autoupdate() {
  log "正在关闭自动更新..."
  remove_systemd_units
  if command_exists crontab; then
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true) | crontab -
  fi
  green "自动更新已关闭。"
}

install_self() {
  ensure_config_files
  mkdir -p "$(dirname "$INSTALL_PATH")"
  if [ "$(readlink -f "$0")" != "$INSTALL_PATH" ]; then
    cp -f "$0" "$INSTALL_PATH"
    chmod 0755 "$INSTALL_PATH"
  fi
}

yesno_label() {
  if [ "$1" -eq 1 ]; then
    printf '已开启'
  else
    printf '已关闭'
  fi
}

rule_status_v4() {
  if iptables -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN_V4"; then
    printf '已启用'
  else
    printf '未启用'
  fi
}

rule_status_v6() {
  if ipv6_enabled && ip6tables -S INPUT 2>/dev/null | grep -q -- "-j $CHAIN_V6"; then
    printf '已启用'
  elif ipv6_enabled; then
    printf '未启用'
  else
    printf '系统未启用'
  fi
}

autoupdate_status() {
  if has_systemd && systemctl is-enabled "$(basename "$SYSTEMD_TIMER")" >/dev/null 2>&1; then
    printf 'systemd timer 已启用'
  elif command_exists crontab && crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
    printf 'cron 已启用'
  else
    printf '未启用'
  fi
}

count_whitelist_entries() {
  local file="$1"
  grep -Ev '^\s*($|#)' "$file" 2>/dev/null | wc -l | awk '{print $1}'
}

whitelist_has_entry() {
  local family="$1" entry="$2" file
  if [ "$family" = "4" ]; then
    file="$WHITELIST_V4_FILE"
  else
    file="$WHITELIST_V6_FILE"
  fi
  grep -Fqx "$entry" "$file" 2>/dev/null
}

show_runtime_overview() {
  load_settings
  echo "IPv4 屏蔽：$(rule_status_v4)"
  echo "IPv6 屏蔽：$(rule_status_v6)"
  echo "自动更新：$(autoupdate_status)"
  echo "内网 IPv4 默认放行：$(yesno_label "$ALLOW_PRIVATE_V4")"
  echo "内网 IPv6 默认放行：$(yesno_label "$ALLOW_PRIVATE_V6")"
  echo "IPv4 白名单条目：$(count_whitelist_entries "$WHITELIST_V4_FILE")"
  echo "IPv6 白名单条目：$(count_whitelist_entries "$WHITELIST_V6_FILE")"
}

current_ssh_ip() {
  get_current_ssh_source_ip 2>/dev/null || true
}

current_ssh_judgement() {
  local current_ip family
  current_ip="$(current_ssh_ip)"
  [ -n "$current_ip" ] || { printf '未检测到'; return 0; }
  family="$(ip_family "$current_ip")"
  case "$family" in
    4)
      if ipset_exists "$SET_V4"; then
        if is_cn_ip "$current_ip"; then
          printf '国内 IP'
        else
          printf '海外或非中国 IP'
        fi
      else
        printf '中国 IPv4 库未加载，暂无法判定'
      fi
      ;;
    6)
      if ! ipv6_enabled; then
        printf 'IPv6 规则未启用，暂无法判定'
      elif ipset_exists "$SET_V6"; then
        if is_cn_ip "$current_ip"; then
          printf '国内 IP'
        else
          printf '海外或非中国 IP'
        fi
      else
        printf '中国 IPv6 库未加载，暂无法判定'
      fi
      ;;
    *) printf 'IP 格式无法识别' ;;
  esac
}

current_ssh_whitelist_status() {
  local current_ip family
  current_ip="$(current_ssh_ip)"
  [ -n "$current_ip" ] || { printf '未检测到'; return 0; }
  family="$(ip_family "$current_ip")"
  case "$family" in
    4|6)
      if whitelist_has_entry "$family" "$current_ip"; then
        printf '已在白名单'
      else
        printf '未在白名单'
      fi
      ;;
    *) printf '无法判断' ;;
  esac
}

show_current_ssh_status() {
  echo "当前 SSH 来源 IP：$(current_ssh_ip | sed 's/^$/未检测到/')"
  echo "当前 SSH 判定结果：$(current_ssh_judgement)"
  echo "当前 SSH 白名单状态：$(current_ssh_whitelist_status)"
}

status() {
  load_settings
  echo "版本：$SCRIPT_VERSION"
  show_runtime_overview
  show_current_ssh_status
  echo "首次安装 SSH 检测：$(yesno_label "$FIRST_INSTALL_SSH_CHECK_DONE")"
  echo "安装路径：$INSTALL_PATH"
  echo "数据目录：$WORKDIR"
}

get_current_ssh_source_ip() {
  local ip
  if [ -n "${SSH_CONNECTION:-}" ]; then
    ip="${SSH_CONNECTION%% *}"
    [ -n "$ip" ] && printf '%s\n' "$ip" && return 0
  fi
  if [ -n "${SSH_CLIENT:-}" ]; then
    ip="${SSH_CLIENT%% *}"
    [ -n "$ip" ] && printf '%s\n' "$ip" && return 0
  fi
  ip="$(who am i 2>/dev/null | awk -F'[()]' 'NF>=2{print $2; exit}')"
  [ -n "$ip" ] && printf '%s\n' "$ip" && return 0
  return 1
}

ip_family() {
  case "$1" in
    *:*) printf '6' ;;
    *.*) printf '4' ;;
    *) printf '0' ;;
  esac
}

is_cn_ip() {
  local ip="$1" family
  family="$(ip_family "$ip")"
  case "$family" in
    4) ipset test "$SET_V4" "$ip" >/dev/null 2>&1 ;;
    6) ipv6_enabled && ipset test "$SET_V6" "$ip" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

add_whitelist_entry_noninteractive() {
  local family="$1" entry="$2" file
  if [ "$family" = "4" ]; then
    file="$WHITELIST_V4_FILE"
  else
    file="$WHITELIST_V6_FILE"
  fi
  grep -Fqx "$entry" "$file" 2>/dev/null || printf '%s\n' "$entry" >> "$file"
}

maybe_prompt_whitelist_current_ssh() {
  local current_ip family answer
  load_settings
  [ "$FIRST_INSTALL_SSH_CHECK_DONE" -eq 0 ] || return 0
  is_interactive || return 0

  if ! current_ip="$(get_current_ssh_source_ip)"; then
    warn "未检测到当前 SSH 来源 IP，已跳过首次安装白名单检查。"
    save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
    return 0
  fi

  family="$(ip_family "$current_ip")"
  if [ "$family" = "0" ]; then
    warn "当前 SSH 来源 IP 格式无法识别：$current_ip，已跳过首次安装白名单检查。"
    save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
    return 0
  fi

  if [ "$family" = "6" ] && ! ipv6_enabled; then
    warn "检测到当前 SSH 来源为 IPv6：$current_ip，但系统未启用 IPv6 规则，已跳过白名单检查。"
    save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
    return 0
  fi

  echo "-----------------------------------------"
  echo " 首次安装 SSH 来源检查"
  echo "-----------------------------------------"
  echo "检测到当前 SSH 来源 IP：$current_ip"

  if is_cn_ip "$current_ip"; then
    green "判定结果：国内 IP。默认不会被本脚本拦截，已自动跳过白名单添加。"
    save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
    return 0
  fi

  if whitelist_has_entry "$family" "$current_ip"; then
    yellow "判定结果：非国内 IP，但该来源已在白名单中，无需重复添加。"
    save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
    return 0
  fi

  yellow "判定结果：非国内 IP。若继续启用屏蔽，当前 SSH 来源可能会被拦截。"
  read -r -p "是否将当前 SSH 来源 IP 一键加入白名单？[Y/n]: " answer
  case "${answer:-Y}" in
    Y|y|YES|yes|'')
      add_whitelist_entry_noninteractive "$family" "$current_ip"
      green "已将当前 SSH 来源 IP 加入白名单：$current_ip"
      ;;
    *)
      warn "你选择不加入白名单，请确认自己还有其他可用管理入口。"
      ;;
  esac
  save_setting FIRST_INSTALL_SSH_CHECK_DONE 1
}

update_rules() {
  acquire_lock
  install_dependencies
  ensure_config_files
  refresh_cn_data
  sync_ipsets
  apply_rules
  green "海外 IP 屏蔽已启用，且中国 IP 库已更新到最新。"
}

install_all() {
  acquire_lock
  install_self
  install_dependencies
  ensure_config_files
  refresh_cn_data
  sync_ipsets
  maybe_prompt_whitelist_current_ssh
  apply_rules
  enable_autoupdate
  green "安装完成。后续请使用：$INSTALL_PATH menu"
}

uninstall_all() {
  local self_path
  acquire_lock
  self_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  disable_autoupdate
  remove_rules
  rm -rf "$WORKDIR"
  rm -rf "$CONF_DIR"
  rm -f "$INSTALL_PATH"
  if [ -n "$self_path" ] && [ "$self_path" != "$INSTALL_PATH" ]; then
    rm -f "$self_path" || true
  fi
  green "已彻底卸载：规则、自动更新、数据文件、配置目录均已清理。"
}

show_file_entries() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "(空)"
    return
  fi
  nl -w2 -s'. ' "$file" | sed '/^[[:space:]]*[0-9]\+\.\s*#/d;/^[[:space:]]*[0-9]\+\.\s*$/d'
}

add_whitelist_entry() {
  local family="$1" entry
  read -r -p "请输入要放行的 IPv${family} 或 CIDR: " entry
  entry="${entry// /}"
  [ -n "$entry" ] || { warn "输入为空，已取消。"; return; }
  add_whitelist_entry_noninteractive "$family" "$entry"
  green "已加入白名单：$entry"
  reapply_rules_if_active
}

remove_whitelist_entry() {
  local family="$1" entry file tmp
  if [ "$family" = "4" ]; then
    file="$WHITELIST_V4_FILE"
  else
    file="$WHITELIST_V6_FILE"
  fi
  show_file_entries "$file"
  read -r -p "请输入要删除的 IPv${family} 或 CIDR（需完全一致）: " entry
  entry="${entry// /}"
  [ -n "$entry" ] || { warn "输入为空，已取消。"; return; }
  tmp="$(mktemp)"
  cleanup_files+=("$tmp")
  grep -Fvx "$entry" "$file" > "$tmp" || true
  cat "$tmp" > "$file"
  green "已删除白名单条目：$entry"
  reapply_rules_if_active
}

whitelist_menu() {
  local choice
  while true; do
    echo "-----------------------------------------"
    echo " 白名单管理"
    echo "-----------------------------------------"
    echo "当前 IPv4 白名单条目数：$(count_whitelist_entries "$WHITELIST_V4_FILE")"
    echo "当前 IPv6 白名单条目数：$(count_whitelist_entries "$WHITELIST_V6_FILE")"
    echo "1. 查看 IPv4 白名单 [当前: $(count_whitelist_entries "$WHITELIST_V4_FILE") 条]"
    echo "2. 添加 IPv4 白名单"
    echo "3. 删除 IPv4 白名单"
    echo "4. 查看 IPv6 白名单 [当前: $(count_whitelist_entries "$WHITELIST_V6_FILE") 条]"
    echo "5. 添加 IPv6 白名单"
    echo "6. 删除 IPv6 白名单"
    echo "0. 返回上级菜单"
    echo "-----------------------------------------"
    read -r -p "请输入选项 [0-6]: " choice
    case "$choice" in
      1) show_file_entries "$WHITELIST_V4_FILE" ;;
      2) add_whitelist_entry 4 ;;
      3) remove_whitelist_entry 4 ;;
      4) show_file_entries "$WHITELIST_V6_FILE" ;;
      5) add_whitelist_entry 6 ;;
      6) remove_whitelist_entry 6 ;;
      0) break ;;
      *) red "无效选项，请重新输入。" ;;
    esac
  done
}

toggle_private_allow() {
  local family="$1"
  if [ "$family" = "4" ]; then
    load_settings
    if [ "$ALLOW_PRIVATE_V4" -eq 1 ]; then
      save_setting ALLOW_PRIVATE_V4 0
      green "已关闭内网 IPv4 源地址默认放行。"
    else
      save_setting ALLOW_PRIVATE_V4 1
      green "已开启内网 IPv4 源地址默认放行（10/8、172.16/12、192.168/16、100.64/10）。"
    fi
  else
    load_settings
    if [ "$ALLOW_PRIVATE_V6" -eq 1 ]; then
      save_setting ALLOW_PRIVATE_V6 0
      green "已关闭内网 IPv6 源地址默认放行。"
    else
      save_setting ALLOW_PRIVATE_V6 1
      green "已开启内网 IPv6 源地址默认放行（fc00::/7）。"
    fi
  fi
  reapply_rules_if_active
}

private_menu() {
  local choice
  while true; do
    load_settings
    echo "-----------------------------------------"
    echo " 内网地址放行设置"
    echo "-----------------------------------------"
    echo "1. 切换 IPv4 内网地址默认放行 [当前: $(yesno_label "$ALLOW_PRIVATE_V4")]"
    echo "2. 切换 IPv6 内网地址默认放行 [当前: $(yesno_label "$ALLOW_PRIVATE_V6")]"
    echo "0. 返回上级菜单"
    echo "-----------------------------------------"
    read -r -p "请输入选项 [0-2]: " choice
    case "$choice" in
      1) toggle_private_allow 4 ;;
      2) toggle_private_allow 6 ;;
      0) break ;;
      *) red "无效选项，请重新输入。" ;;
    esac
  done
}

menu() {
  local choice
  while true; do
    load_settings
    echo "========================================="
    echo " 国内 VPS 屏蔽海外 IP 管理脚本 v$SCRIPT_VERSION"
    echo "========================================="
    echo "1. 开启屏蔽并立即更新 IP 库 [当前: $(rule_status_v4)]"
    echo "2. 关闭屏蔽 [当前: $(rule_status_v4)]"
    echo "3. 启用自动更新（每天 03:00） [当前: $(autoupdate_status)]"
    echo "4. 关闭自动更新 [当前: $(autoupdate_status)]"
    echo "5. 安装到系统并启用自动更新 [首次 SSH 检测: $(yesno_label "$FIRST_INSTALL_SSH_CHECK_DONE")]"
    echo "6. 查看状态"
    echo "7. 彻底卸载"
    echo "8. 管理白名单 [IPv4: $(count_whitelist_entries "$WHITELIST_V4_FILE") 条, IPv6: $(count_whitelist_entries "$WHITELIST_V6_FILE") 条]"
    echo "9. 管理内网地址放行开关 [IPv4: $(yesno_label "$ALLOW_PRIVATE_V4"), IPv6: $(yesno_label "$ALLOW_PRIVATE_V6")]"
    echo "0. 退出"
    echo "-----------------------------------------"
    show_runtime_overview
    show_current_ssh_status
    echo "========================================="
    read -r -p "请输入选项 [0-9]: " choice
    case "$choice" in
      1) update_rules ;;
      2) acquire_lock; remove_rules; green "已关闭屏蔽，恢复所有 IP 访问。" ;;
      3) install_self; enable_autoupdate ;;
      4) disable_autoupdate ;;
      5) install_all ;;
      6) status ;;
      7) uninstall_all; break ;;
      8) whitelist_menu ;;
      9) private_menu ;;
      0) exit 0 ;;
      *) red "无效选项，请重新输入。" ;;
    esac
  done
}

usage() {
  cat <<EOF_USAGE
用法：
  $0 install            安装到系统并启用自动更新
  $0 start              立即更新中国 IP 库并启用屏蔽
  $0 stop               关闭屏蔽并清理规则
  $0 update             更新中国 IP 库并重新应用规则
  $0 enable-auto        启用自动更新
  $0 disable-auto       关闭自动更新
  $0 status             查看当前状态
  $0 uninstall          彻底卸载
  $0 menu               打开交互菜单
  $0 --quiet <command>  静默执行，供 systemd/cron 调用
EOF_USAGE
}

main() {
  require_root
  if [ "${1:-}" = "--quiet" ]; then
    QUIET=1
    shift
  fi
  case "${1:-menu}" in
    install)      install_all ;;
    start|update) update_rules ;;
    stop)         acquire_lock; remove_rules; green "已关闭屏蔽，恢复所有 IP 访问。" ;;
    enable-auto)  install_self; enable_autoupdate ;;
    disable-auto) disable_autoupdate ;;
    status)       status ;;
    uninstall)    uninstall_all ;;
    menu)         menu ;;
    -h|--help|help) usage ;;
    *)            usage; exit 1 ;;
  esac
}

main "$@"
