#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "安装失败：第 ${LINENO} 行执行出错，请检查上方输出。" >&2' ERR

# ============================================================
# L2TP Server Installer
#
# Ubuntu / Debian
# L2TP without IPsec / PSK
#
# 运行：
#   bash install-l2tp.sh
#
# 自定义示例：
#   VPN_USER=test \
#   VPN_PASSWORD=MyPassword123 \
#   VPN_MTU=1400 \
#   bash install-l2tp.sh
# ============================================================
  

# ============================================================
# 用户可修改参数
# ============================================================

# L2TP 用户名和密码
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASSWORD="${VPN_PASSWORD:-123456}"

# ============================================================
# L2TP 地址参数
# ============================================================

# L2TP 网段编号
# 默认 L2TP_ID=1：
#   网关      10.20.1.1
#   地址池    10.20.1.10-10.20.1.200
#   VPN 网段  10.20.1.0/24
#
# 例如：
#   L2TP_ID=101 bash install-l2tpv1.sh
# 将生成：
#   10.20.101.0/24
L2TP_ID="${L2TP_ID:-1}"

# 根据 L2TP_ID 自动生成前三段
VPN_NETWORK_PREFIX="10.20.${L2TP_ID}"

# 服务端 PPP 地址固定使用 .1
VPN_LOCAL_IP="${VPN_NETWORK_PREFIX}.1"

# 客户端地址池固定使用 .10 - .200
VPN_POOL_START="${VPN_NETWORK_PREFIX}.10"
VPN_POOL_END="${VPN_NETWORK_PREFIX}.200"

# VPN 网段固定 /24
VPN_SUBNET="${VPN_NETWORK_PREFIX}.0/24"

# L2TP UDP 端口
VPN_PORT="${VPN_PORT:-1701}"

# PPP MTU / MRU
VPN_MTU="${VPN_MTU:-1400}"

# 下发给客户端的 DNS
VPN_DNS1="${VPN_DNS1:-1.1.1.1}"
VPN_DNS2="${VPN_DNS2:-8.8.8.8}"

# 独立日志
VPN_LOG_FILE="${VPN_LOG_FILE:-/var/log/l2tp.log}"


# ============================================================
# RouterOS 配置参数
# ============================================================

# L2TP 实例命名标识
# 默认使用 l2tpv1
# 例如：
#   接口名   l2tpv1-150.129.80.61
#   路由表   to-l2tpv1-150.129.80.61
#   配置目录 /root/l2tpv1
L2TP_NAME="${L2TP_NAME:-l2tpv1}"

# 例如公网 IP：
#
# 150.129.80.61
#
# 自动生成：
#
# ${L2TP_NAME}-150.129.80.61
# to-${L2TP_NAME}-150.129.80.61
#

ROS_NAME_PREFIX="${ROS_NAME_PREFIX:-${L2TP_NAME}-}"
ROS_TABLE_PREFIX="${ROS_TABLE_PREFIX:-to-${L2TP_NAME}-}"
ROS_CONFIG_DIR="${ROS_CONFIG_DIR:-/root/${L2TP_NAME}}"

# RouterOS PPP Profile
ROS_PROFILE="${ROS_PROFILE:-default-encryption}"

# RouterOS 认证方式
ROS_ALLOW="${ROS_ALLOW:-mschap2}"


# ============================================================
# 基础检查
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行："
    echo "sudo bash $0"
    exit 1
fi

if [[ -z "${VPN_USER}" || -z "${VPN_PASSWORD}" ]]; then
    echo "错误：用户名和密码不能为空。"
    exit 1
fi

if [[ "${VPN_USER}" =~ [[:space:]] || "${VPN_PASSWORD}" =~ [[:space:]] ]]; then
    echo "错误：用户名和密码不能包含空格、Tab 或换行。"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "错误：无法识别操作系统。"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
    echo "错误：不支持当前系统：${PRETTY_NAME:-未知系统}"
    echo "当前脚本适用于 Ubuntu / Debian。"
    exit 1
fi

if ! [[ "${L2TP_ID}" =~ ^[0-9]+$ ]] \
    || (( L2TP_ID < 1 || L2TP_ID > 254 )); then

    echo "错误：L2TP_ID 必须是 1 到 254 之间的数字。"
    exit 1
fi


if ! [[ "${VPN_PORT}" =~ ^[0-9]+$ ]] \
    || (( VPN_PORT < 1 || VPN_PORT > 65535 )); then

    echo "错误：VPN_PORT 必须是 1 到 65535 之间的数字。"
    exit 1
fi

if ! [[ "${VPN_MTU}" =~ ^[0-9]+$ ]] \
    || (( VPN_MTU < 576 || VPN_MTU > 1500 )); then

    echo "错误：VPN_MTU 必须是 576 到 1500 之间的数字。"
    exit 1
fi

if [[ "${VPN_LOG_FILE}" != /* || "${VPN_LOG_FILE}" == *$'\n'* ]]; then
    echo "错误：VPN_LOG_FILE 必须是绝对路径，且不能包含换行。"
    exit 1
fi


# ============================================================
# 安装依赖
# ============================================================

export DEBIAN_FRONTEND=noninteractive

echo
echo "=============================================="
echo "正在安装 L2TP 服务"
echo "=============================================="
echo

echo "正在更新软件源..."

apt-get update

echo
echo "正在安装依赖..."

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" \
    | debconf-set-selections

echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" \
    | debconf-set-selections

apt-get install -y \
    curl \
    iproute2 \
    iptables \
    iptables-persistent \
    ppp \
    xl2tpd


# ============================================================
# 加载 PPPoL2TP 模块
# ============================================================

modprobe pppol2tp 2>/dev/null || true


# ============================================================
# 检测公网接口
# ============================================================

WAN_IF=$(
    ip -4 route show default \
        | awk 'NR == 1 {print $5}'
)

if [[ -z "${WAN_IF}" ]]; then
    echo "错误：无法检测默认公网接口。"
    exit 1
fi


# ============================================================
# 检测本地出口网卡 IPv4
# ============================================================

LOCAL_IP=$(
    ip -4 addr show dev "${WAN_IF}" scope global \
        | awk '/inet / {print $2; exit}' \
        | cut -d/ -f1
)

LOCAL_IP="${LOCAL_IP//$'\r'/}"
LOCAL_IP="${LOCAL_IP//$'\n'/}"


# ============================================================
# 判断 IPv4 是否为私网 / 本地保留地址
# ============================================================

is_private_ipv4() {

    local ip="$1"

    case "${ip}" in
        10.*)
            return 0
            ;;
        127.*)
            return 0
            ;;
        169.254.*)
            return 0
            ;;
        192.168.*)
            return 0
            ;;
    esac

    if [[ "${ip}" =~ ^172\.([0-9]{1,3})\. ]]; then
        local second="${BASH_REMATCH[1]}"
        if (( second >= 16 && second <= 31 )); then
            return 0
        fi
    fi

    if [[ "${ip}" =~ ^100\.([0-9]{1,3})\. ]]; then
        local second="${BASH_REMATCH[1]}"
        if (( second >= 64 && second <= 127 )); then
            return 0
        fi
    fi

    return 1
}


# ============================================================
# 查询真实公网 IPv4
#
# 优先：
#   https://ip.me
#
# 备用：
#   http://cip.cc
#
# 规则：
#
# 1. 本地网卡 IP == 查询公网 IP
#    使用该 IP
#
# 2. 本地网卡 IP != 查询公网 IP
#    说明可能存在 NAT / 云平台公网映射
#    使用查询到的公网 IP
#
# 3. 外部查询失败
#    如果本地网卡 IP 是公网 IPv4，则使用本地 IP
#
# 4. 如果本地网卡 IP 是私网 / CGNAT / 回环地址，
#    且外部查询失败，则直接报错，避免把错误地址写入 RouterOS。
# ============================================================

QUERY_IP=""

# ------------------------------------------------------------
# 第一查询源：ip.me
# ------------------------------------------------------------

QUERY_IP=$(
    curl -4fsS \
        --connect-timeout 5 \
        --max-time 10 \
        https://ip.me \
        2>/dev/null \
    || true
)

QUERY_IP="$(
    printf '%s' "${QUERY_IP}" \
        | tr -d '\r\n[:space:]'
)"


# ------------------------------------------------------------
# 第二查询源：cip.cc
# ------------------------------------------------------------

if ! [[ "${QUERY_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

    QUERY_IP=$(
        curl -4fsS \
            --connect-timeout 5 \
            --max-time 10 \
            http://cip.cc \
            2>/dev/null \
            | awk '/^IP[[:space:]]*:/ {print $3; exit}' \
        || true
    )

    QUERY_IP="$(
        printf '%s' "${QUERY_IP}" \
            | tr -d '\r\n[:space:]'
    )"
fi


# ============================================================
# 判断最终公网 IP
# ============================================================

PUBLIC_IP=""

echo
echo "公网 IP 检测："
echo "----------------------------------------------"
echo "出口接口：${WAN_IF}"
echo "本地网卡 IP：${LOCAL_IP:-未检测到}"
echo "外部查询 IP：${QUERY_IP:-查询失败}"


# ------------------------------------------------------------
# 外部查询成功
# ------------------------------------------------------------

if [[ "${QUERY_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then

    if [[ "${LOCAL_IP}" == "${QUERY_IP}" ]]; then

        PUBLIC_IP="${LOCAL_IP}"

        echo "检测结果：本地 IP 与公网 IP 一致"
        echo "使用地址：${PUBLIC_IP}"

    else

        PUBLIC_IP="${QUERY_IP}"

        echo "检测结果：本地 IP 与公网 IP 不一致"
        echo "可能存在 NAT / 云平台公网映射"
        echo "使用外部查询地址：${PUBLIC_IP}"

    fi

else

    # --------------------------------------------------------
    # 外部查询失败
    # --------------------------------------------------------

    if [[ "${LOCAL_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        && ! is_private_ipv4 "${LOCAL_IP}"; then

        PUBLIC_IP="${LOCAL_IP}"

        echo "警告：外部公网 IP 查询失败"
        echo "本地出口网卡为公网 IPv4"
        echo "使用本地网卡地址：${PUBLIC_IP}"

    else

        echo
        echo "错误：无法获取有效公网 IPv4。"
        echo
        echo "出口接口：${WAN_IF}"
        echo "本地地址：${LOCAL_IP:-无}"
        echo "外部查询：失败"
        echo
        echo "请手工检查："
        echo "  curl ip.me"
        echo "  curl cip.cc"
        echo
        exit 1

    fi
fi


# ============================================================
# 最终公网 IPv4 格式检查
# ============================================================

if ! [[ "${PUBLIC_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "错误：公网 IPv4 地址格式异常：${PUBLIC_IP}"
    exit 1
fi

if is_private_ipv4 "${PUBLIC_IP}"; then
    echo "错误：最终检测到的地址不是公网 IPv4：${PUBLIC_IP}"
    exit 1
fi

echo "----------------------------------------------"
echo


# ============================================================
# RouterOS 名称
# ============================================================

ROS_L2TP_NAME="${ROS_NAME_PREFIX}${PUBLIC_IP}"
ROS_TABLE_NAME="${ROS_TABLE_PREFIX}${PUBLIC_IP}"

ROS_CONFIG_FILE="${ROS_CONFIG_DIR}/${ROS_L2TP_NAME}.rsc"


# ============================================================
# 显示检测结果
# ============================================================

echo
echo "操作系统：${PRETTY_NAME:-未知}"
echo "公网接口：${WAN_IF}"
echo "公网地址：${PUBLIC_IP}"
echo "L2TP ID：${L2TP_ID}"
echo "L2TP 地址池：${VPN_POOL_START}-${VPN_POOL_END}"
echo "RouterOS 接口：${ROS_L2TP_NAME}"
echo "RouterOS 路由表：${ROS_TABLE_NAME}"
echo


# ============================================================
# 备份旧配置
# ============================================================

BACKUP_TAG=$(date +%Y%m%d-%H%M%S)

backup_if_exists() {

    local source_file=$1

    if [[ -e "${source_file}" ]]; then

        cp -a \
            "${source_file}" \
            "${source_file}.bak.${BACKUP_TAG}"

    fi
}

backup_if_exists /etc/xl2tpd/xl2tpd.conf
backup_if_exists /etc/ppp/chap-secrets
backup_if_exists /etc/ppp/options.xl2tpd
backup_if_exists /etc/systemd/system/l2tp-log.service
backup_if_exists /etc/sysctl.d/99-l2tp-vpn.conf

mkdir -p /etc/xl2tpd
mkdir -p /etc/ppp


# ============================================================
# xl2tpd
# ============================================================

cat >/etc/xl2tpd/xl2tpd.conf <<EOF
; ${L2TP_NAME}
[global]
port = ${VPN_PORT}

[lns default]
ip range = ${VPN_POOL_START}-${VPN_POOL_END}
local ip = ${VPN_LOCAL_IP}
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF


# ============================================================
# PPP
#
# 不加入 lock
#
# 避免某些 pppd 环境出现：
#
# unrecognized option 'lock'
# ============================================================

umask 077

touch /etc/ppp/options.xl2tpd
touch /etc/ppp/chap-secrets

chmod 600 \
    /etc/ppp/options.xl2tpd \
    /etc/ppp/chap-secrets


cat >/etc/ppp/options.xl2tpd <<EOF
name l2tpd
auth
debug
mtu ${VPN_MTU}
mru ${VPN_MTU}
proxyarp
hide-password
noccp
noipdefault
nodefaultroute
ipcp-accept-local
ipcp-accept-remote
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}
EOF


# ============================================================
# PPP 用户
# ============================================================

cat >/etc/ppp/chap-secrets <<EOF
# client       server       password       IP
${VPN_USER}    *            ${VPN_PASSWORD}    *
EOF

chmod 600 /etc/ppp/chap-secrets


# ============================================================
# 开启 IPv4 转发
# ============================================================

cat >/etc/sysctl.d/99-l2tp-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF

sysctl --system >/dev/null


if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then

    echo "错误：IPv4 转发未成功开启。"
    exit 1

fi


# ============================================================
# Firewall
# ============================================================

add_rule() {

    local table=$1

    shift

    if ! iptables -t "${table}" -C "$@" 2>/dev/null; then

        iptables -t "${table}" -A "$@"

    fi
}


insert_rule() {

    local table=$1

    shift

    if ! iptables -t "${table}" -C "$@" 2>/dev/null; then

        iptables -t "${table}" -I "$@"

    fi
}


# ------------------------------------------------------------
# L2TP UDP 端口
# ------------------------------------------------------------

insert_rule filter INPUT \
    -p udp \
    --dport "${VPN_PORT}" \
    -j ACCEPT


# ------------------------------------------------------------
# VPN 客户端 → Internet
# ------------------------------------------------------------

insert_rule filter FORWARD \
    -s "${VPN_SUBNET}" \
    -j ACCEPT


# ------------------------------------------------------------
# Internet → 已建立连接 → VPN
# ------------------------------------------------------------

insert_rule filter FORWARD \
    -d "${VPN_SUBNET}" \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT


# ------------------------------------------------------------
# NAT
# ------------------------------------------------------------

add_rule nat POSTROUTING \
    -s "${VPN_SUBNET}" \
    -o "${WAN_IF}" \
    -j MASQUERADE


# ------------------------------------------------------------
# TCP MSS
#
# 解决部分站点：
#
# 网页打开慢
# Fast.com 异常
# HTTPS 卡住
#
# 注意：
# TCPMSS 只影响 TCP，不影响 UDP。
# ------------------------------------------------------------

add_rule mangle FORWARD \
    -s "${VPN_SUBNET}" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -j TCPMSS \
    --clamp-mss-to-pmtu


# ============================================================
# 保存 iptables
# ============================================================

netfilter-persistent save >/dev/null


# ============================================================
# 独立日志
# ============================================================

install -m 600 /dev/null "${VPN_LOG_FILE}"


cat >/etc/systemd/system/l2tp-log.service <<EOF
[Unit]
Description=L2TP and PPP log collector
After=systemd-journald.service
Requires=systemd-journald.service

[Service]
Type=simple

ExecStart=/usr/bin/journalctl \
-f \
-n 0 \
-o short-iso \
-t xl2tpd \
-t pppd

StandardOutput=append:${VPN_LOG_FILE}
StandardError=journal

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF


# ============================================================
# Logrotate
# ============================================================

if [[ "${VPN_LOG_FILE}" == "/var/log/l2tp.log" ]]; then

cat >/etc/logrotate.d/l2tp <<'EOF'
/var/log/l2tp.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

fi


# ============================================================
# 生成 MikroTik RouterOS 配置
# ============================================================
mkdir -p "${ROS_CONFIG_DIR}"

cat >"${ROS_CONFIG_FILE}" <<EOF
# ============================================================
# MikroTik RouterOS L2TP Client
# Instance: ${L2TP_NAME}
#
# Server:
# ${PUBLIC_IP}
#
# L2TP:
# No IPsec / No PSK
#
# Generated automatically by install-l2tp.sh
# ============================================================


/interface l2tp-client

add name="${ROS_L2TP_NAME}" \\
    connect-to=${PUBLIC_IP} \\
    user="${VPN_USER}" \\
    password="${VPN_PASSWORD}" \\
    use-ipsec=no \\
    profile=${ROS_PROFILE} \\
    allow=${ROS_ALLOW} \\
    add-default-route=no \\
    use-peer-dns=no \\
    disabled=no


/routing table

add name="${ROS_TABLE_NAME}" fib


/ip firewall nat

add chain=srcnat \\
    action=masquerade \\
    out-interface="${ROS_L2TP_NAME}" \\
    comment="NAT via ${ROS_L2TP_NAME}"


/ip route

add dst-address=0.0.0.0/0 \\
    gateway="${ROS_L2TP_NAME}" \\
    routing-table="${ROS_TABLE_NAME}" \\
    distance=1 \\
    comment="Default via ${ROS_L2TP_NAME}"


/tool netwatch

add host="${VPN_LOCAL_IP}" \\
    interval=10s \\
    timeout=5s \\
    type=simple \\
    name="${ROS_L2TP_NAME}" \\
    comment="Monitor ${ROS_L2TP_NAME}" \\
    down-script="/log warning \"L2TP ${ROS_L2TP_NAME} is DOWN\"" \\
    up-script="/log info \"L2TP ${ROS_L2TP_NAME} is UP\""

# ============================================================
# 策略路由示例
#
# 例如只让：
#
# 192.168.102.97
#
# 通过这条 L2TP：
#
# /routing rule
#
# add src-address=192.168.102.97/32 \\
#     action=lookup-only-in-table \\
#     table="${ROS_TABLE_NAME}"
#
# ============================================================
EOF

chmod 600 "${ROS_CONFIG_FILE}"


# ============================================================
# systemd
# ============================================================

systemctl daemon-reload

systemctl enable xl2tpd >/dev/null
systemctl enable l2tp-log.service >/dev/null


# ============================================================
# 先启动日志
# ============================================================

systemctl restart l2tp-log.service

if ! systemctl is-active --quiet l2tp-log.service; then

    echo
    echo "错误：L2TP 日志服务启动失败。"

    echo
    echo "检查："

    echo "journalctl -u l2tp-log.service -n 100 --no-pager"

    exit 1
fi


# ============================================================
# 重启 xl2tpd
#
# 必须 restart
#
# 因为配置文件已经被脚本重新生成。
# ============================================================

systemctl restart xl2tpd

sleep 1


if ! systemctl is-active --quiet xl2tpd; then

    echo
    echo "错误：xl2tpd 服务启动失败。"

    echo
    echo "请检查："

    echo "journalctl -u xl2tpd -n 100 --no-pager"

    exit 1
fi


# ============================================================
# 检查 UDP 监听
# ============================================================

if [[ -z "$(ss -H -lun "sport = :${VPN_PORT}" 2>/dev/null)" ]]; then

    echo
    echo "警告：未检测到 UDP ${VPN_PORT} 监听。"

    echo
    echo "当前 UDP 监听："

    ss -lunp || true

else

    echo
    echo "UDP ${VPN_PORT} 监听正常。"

fi


# ============================================================
# 最终输出
# ============================================================

echo
echo
echo "=============================================="
echo "${L2TP_NAME} 安装完成"
echo "=============================================="

echo
echo "服务器："
echo "----------------------------------------------"
echo "公网地址：${PUBLIC_IP}"
echo "公网接口：${WAN_IF}"
echo "${L2TP_NAME} 端口：UDP ${VPN_PORT}"

echo
echo "${L2TP_NAME}："
echo "----------------------------------------------"
echo "用户名：${VPN_USER}"
echo "密码：${VPN_PASSWORD}"
echo "IPsec：关闭"
echo "PSK：无"
echo "服务器隧道 IP：${VPN_LOCAL_IP}"
echo "客户端地址池：${VPN_POOL_START}-${VPN_POOL_END}"
echo "VPN 网段：${VPN_SUBNET}"
echo "MTU/MRU：${VPN_MTU}"
echo "DNS1：${VPN_DNS1}"
echo "DNS2：${VPN_DNS2}"

echo
echo "RouterOS："
echo "----------------------------------------------"
echo "接口名称：${ROS_L2TP_NAME}"
echo "路由表：${ROS_TABLE_NAME}"
echo "配置文件：${ROS_CONFIG_FILE}"

echo
echo "日志："
echo "----------------------------------------------"
echo "日志文件：${VPN_LOG_FILE}"

echo
echo "=============================================="


# ============================================================
# 常用命令
# ============================================================

echo
echo "查看 ROS 配置："
echo
echo "cat ${ROS_CONFIG_FILE}"

echo
echo "----------------------------------------------"

echo
echo "查看实时 L2TP 日志："
echo
echo "tail -f ${VPN_LOG_FILE}"

echo
echo "----------------------------------------------"

echo
echo "查看当前 PPP 客户端："
echo
echo "ip -br address | grep ppp"

echo
echo "----------------------------------------------"

echo
echo "查看 xl2tpd 状态："
echo
echo "systemctl status xl2tpd --no-pager"

echo
echo "----------------------------------------------"

echo
echo "查看 xl2tpd 日志："
echo
echo "journalctl -u xl2tpd -n 100 --no-pager"

echo
echo "----------------------------------------------"

echo
echo "查看防火墙："
echo
echo "iptables -L INPUT -n -v"
echo "iptables -L FORWARD -n -v"
echo "iptables -t nat -L POSTROUTING -n -v"

echo
echo "----------------------------------------------"

echo
echo "如果 VPS 服务商启用了安全组 / 云防火墙，"
echo "请额外放行：UDP ${VPN_PORT}"

echo