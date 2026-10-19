#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
	  command -v bash >/dev/null 2>&1 || { echo "ERROR: Bash is required." >&2; exit 1; }
	    exec bash "$0" "$@"
fi

set -Eeuo pipefail
umask 077

# ============================================================
# User-editable defaults (used on the first run)
# ============================================================
DEFAULT_WG_ID=1
# Leave empty for automatic state-based increment. Set a number (0-254) to
# force a custom ID for interface names, routing table names and IP octet 3.
WG_ID_CUSTOM="118"
LOCATION_TEXT="工厂2F"
DEFAULT_VPS_LISTEN_PORT=58118
DEFAULT_ROS_LISTEN_PORT=10118
WG_NETWORK_PREFIX="10.11"
# Leave empty to use WG_NETWORK_PREFIX.WG_ID. Set all first three octets, for
# example "172.16.50", to make the IP network independent from the name ID.
WG_NETWORK_BASE_CUSTOM="10.100.118"
VPS_HOST_OCTET=1
ROS_HOST_OCTET=254
WG_MTU=1380

# RouterOS naming parts. With WG_ID=6 these defaults generate:
# interface=wgBD6, peer name=wgBD-6, routing-table=to-wgBD-6.
ROS_NAME_PART1="wg"
ROS_NAME_PART2="peerBD"
ROS_PUBLIC_KEY_CUSTOM=""
ROS_ID_SEPARATOR="-"
ROS_TABLE_PREFIX="to-"

# Optional custom keys. Leave empty to use automatic key generation.
# Public keys are derived from private keys; if supplied here, they are used
# only after the script verifies that each public/private pair matches.
VPS_PRIVATE_KEY_CUSTOM="AESo36unhNg9XCjuK0VNaH+gKOIBWaVvpUxvRKvuW20="
VPS_PUBLIC_KEY_CUSTOM="VgyeG/v7nJRt8jYJ/NNIeLCHPe+9l3u55pqnaCXoMmU="

ROS_PRIVATE_KEY_CUSTOM="+B7SlivaqdFW06lkO1kHrEJNBsWqu9fXIesdOb++81c="
ROS_PUBLIC_KEY_CUSTOM="WB9Fh3q/+FZe+V0Qpk0F9OtqvBf8PyY8fpPJIzJfKnc="

# 1 = verify that each supplied public key matches its private key (default)
# 0 = accept and write supplied public/private values without pair validation
VALIDATE_CUSTOM_KEY_PAIRS=0

# Runtime overrides are also supported, for example:
# WG_ID=8 VPS_LISTEN_PORT=58130 ROS_LISTEN_PORT=10008 bash this-script.sh
WG_ID_OVERRIDE="${WG_ID:-$WG_ID_CUSTOM}"
VPS_PORT_OVERRIDE="${VPS_LISTEN_PORT:-${WG_PORT:-}}"
ROS_PORT_OVERRIDE="${ROS_LISTEN_PORT:-}"
WG_NETWORK_PREFIX="${WG_NETWORK_PREFIX_OVERRIDE:-$WG_NETWORK_PREFIX}"
WG_NETWORK_BASE_CUSTOM="${WG_NETWORK_BASE_OVERRIDE:-$WG_NETWORK_BASE_CUSTOM}"
VPS_HOST_OCTET="${VPS_HOST_OCTET_OVERRIDE:-$VPS_HOST_OCTET}"
ROS_HOST_OCTET="${ROS_HOST_OCTET_OVERRIDE:-$ROS_HOST_OCTET}"
WG_MTU="${WG_MTU_OVERRIDE:-$WG_MTU}"
VPS_PRIVATE_KEY_CUSTOM="${VPS_PRIVATE_KEY_OVERRIDE:-$VPS_PRIVATE_KEY_CUSTOM}"
VPS_PUBLIC_KEY_CUSTOM="${VPS_PUBLIC_KEY_OVERRIDE:-$VPS_PUBLIC_KEY_CUSTOM}"
ROS_PRIVATE_KEY_CUSTOM="${ROS_PRIVATE_KEY_OVERRIDE:-$ROS_PRIVATE_KEY_CUSTOM}"
ROS_PUBLIC_KEY_CUSTOM="${ROS_PUBLIC_KEY_OVERRIDE:-$ROS_PUBLIC_KEY_CUSTOM}"
VALIDATE_CUSTOM_KEY_PAIRS="${VALIDATE_CUSTOM_KEY_PAIRS_OVERRIDE:-$VALIDATE_CUSTOM_KEY_PAIRS}"
ROS_NAME_PART1="${ROS_NAME_PART1_OVERRIDE:-$ROS_NAME_PART1}"
ROS_NAME_PART2="${ROS_NAME_PART2_OVERRIDE:-$ROS_NAME_PART2}"
ROS_ID_SEPARATOR="${ROS_ID_SEPARATOR_OVERRIDE:-$ROS_ID_SEPARATOR}"
ROS_TABLE_PREFIX="${ROS_TABLE_PREFIX_OVERRIDE:-$ROS_TABLE_PREFIX}"

WG_DIR="/etc/wireguard"
STATE_FILE="${WG_DIR}/routeros-installer.state"
ROS_PRIVATE_KEY_FILE="${ROS_PRIVATE_KEY_FILE:-${WG_DIR}/routeros-private.key}"
LAST_WG_ID=""
LAST_WG_PORT=""
LAST_ROS_LISTEN_PORT=""
LAST_SERVER_ENDPOINT=""

if [[ -r "$STATE_FILE" ]]; then
	  LAST_WG_ID="$(awk -F= '$1 == "LAST_WG_ID" {print $2; exit}' "$STATE_FILE")"
	    LAST_WG_PORT="$(awk -F= '$1 == "LAST_WG_PORT" {print $2; exit}' "$STATE_FILE")"
	      LAST_ROS_LISTEN_PORT="$(awk -F= '$1 == "LAST_ROS_LISTEN_PORT" {print $2; exit}' "$STATE_FILE")"
	        LAST_SERVER_ENDPOINT="$(awk -F= '$1 == "LAST_SERVER_ENDPOINT" {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE")"
fi

# Migration support: if an older version created wgNN configs before the state
# file existed, discover the highest numeric wgNN interface and its port.
if [[ -z "$LAST_WG_ID" ]]; then
	  shopt -s nullglob
	    for existing_config in "${WG_DIR}"/wg[0-9]*.conf; do
		        existing_name="$(basename "$existing_config" .conf)"
			    if [[ "$existing_name" =~ ^wg([0-9]+)$ ]]; then
				          existing_id="${BASH_REMATCH[1]}"
					        if [[ -z "$LAST_WG_ID" ]] || (( existing_id > LAST_WG_ID )); then
							        LAST_WG_ID="$existing_id"
								        LAST_WG_PORT="$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$existing_config")"
									      fi
									          fi
										    done
										      shopt -u nullglob
fi

if [[ -n "$WG_ID_OVERRIDE" ]]; then
	  WG_ID="$WG_ID_OVERRIDE"
  elif [[ "$LAST_WG_ID" =~ ^[0-9]+$ ]]; then
	    WG_ID="$((LAST_WG_ID + 1))"
    else
	      WG_ID="$DEFAULT_WG_ID"
fi

if [[ -n "$VPS_PORT_OVERRIDE" ]]; then
    WG_PORT="$VPS_PORT_OVERRIDE"
else
    WG_PORT="$DEFAULT_VPS_LISTEN_PORT"
fi

if [[ -n "$ROS_PORT_OVERRIDE" ]]; then
    ROS_LISTEN_PORT="$ROS_PORT_OVERRIDE"
else
    ROS_LISTEN_PORT="$DEFAULT_ROS_LISTEN_PORT"
fi

WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:-}"
WG_OUT_INTERFACE="${WG_OUT_INTERFACE:-}"
WG_OVERWRITE="${WG_OVERWRITE:-0}"

WG_INTERFACE="${WG_INTERFACE:-wg${WG_ID}}"
ROS_INTERFACE="${ROS_INTERFACE:-${ROS_NAME_PART1}${ROS_NAME_PART2}${WG_ID}}"
ROS_PEER_NAME="${ROS_PEER_NAME:-${ROS_NAME_PART1}${ROS_NAME_PART2}${ROS_ID_SEPARATOR}${WG_ID}}"
ROS_TABLE_NAME="${ROS_TABLE_NAME:-${ROS_TABLE_PREFIX}${ROS_NAME_PART1}${ROS_NAME_PART2}${ROS_ID_SEPARATOR}${WG_ID}}"
ROS_NETWATCH_NAME="${ROS_NETWATCH_NAME:-${ROS_NAME_PART1}${ROS_NAME_PART2}${WG_ID}}"

if [[ -n "$WG_NETWORK_BASE_CUSTOM" ]]; then
	  WG_NETWORK_BASE="$WG_NETWORK_BASE_CUSTOM"
  else
	    WG_NETWORK_BASE="${WG_NETWORK_PREFIX}.${WG_ID}"
fi

WG_NETWORK="${WG_NETWORK_BASE}.0/24"
WG_SERVER_ADDRESS="${WG_NETWORK_BASE}.${VPS_HOST_OCTET}"
WG_SERVER_CIDR="${WG_SERVER_ADDRESS}/24"
ROS_ADDRESS="${WG_NETWORK_BASE}.${ROS_HOST_OCTET}"
ROS_CIDR="${ROS_ADDRESS}/24"

OUTPUT_DIR="/root/wireguard-routeros"
SERVER_CONFIG="${WG_DIR}/${WG_INTERFACE}.conf"
ROS_CONFIG="${OUTPUT_DIR}/${ROS_INTERFACE}.rsc"

log() { printf '\033[1;32m[WireGuard]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
	  local code=$?
	    printf '\033[1;31m[ERROR]\033[0m Failed at line %s (exit %s).\n' "${BASH_LINENO[0]:-unknown}" "$code" >&2
	      exit "$code"
      }
      trap on_error ERR

      [[ "$EUID" -eq 0 ]] || die "Run this script as root."
      [[ "$WG_ID" =~ ^[0-9]+$ ]] && (( WG_ID >= 0 && WG_ID <= 254 )) || die "WG_ID must be from 0 to 254."
      [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "WG_PORT must be from 1 to 65535."
      [[ "$ROS_LISTEN_PORT" =~ ^[0-9]+$ ]] && (( ROS_LISTEN_PORT >= 1 && ROS_LISTEN_PORT <= 65535 )) || die "ROS_LISTEN_PORT must be from 1 to 65535."
      [[ "$WG_MTU" =~ ^[0-9]+$ ]] && (( WG_MTU >= 576 && WG_MTU <= 9000 )) || die "WG_MTU must be from 576 to 9000."
      [[ "$VPS_HOST_OCTET" =~ ^[0-9]+$ ]] && (( VPS_HOST_OCTET >= 1 && VPS_HOST_OCTET <= 254 )) || die "VPS_HOST_OCTET must be from 1 to 254."
      [[ "$ROS_HOST_OCTET" =~ ^[0-9]+$ ]] && (( ROS_HOST_OCTET >= 1 && ROS_HOST_OCTET <= 254 )) || die "ROS_HOST_OCTET must be from 1 to 254."
      [[ "$VPS_HOST_OCTET" != "$ROS_HOST_OCTET" ]] || die "VPS and RouterOS host octets must be different."
      [[ "$WG_NETWORK_PREFIX" =~ ^([0-9]{1,3}\.)[0-9]{1,3}$ ]] || die "WG_NETWORK_PREFIX must look like 10.100."
      [[ "$WG_NETWORK_BASE" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "WG_NETWORK_BASE_CUSTOM must look like 172.16.50."
      IFS=. read -r IP_OCTET_1 IP_OCTET_2 IP_OCTET_3 <<<"$WG_NETWORK_BASE"
for IP_OCTET in "$IP_OCTET_1" "$IP_OCTET_2" "$IP_OCTET_3"; do
  (( 10#$IP_OCTET <= 255 )) || die "Every IP network octet must be from 0 to 255."
done
[[ "$WG_INTERFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die "Invalid Linux WireGuard interface name."
[[ "$WG_OVERWRITE" == 0 || "$WG_OVERWRITE" == 1 ]] || die "WG_OVERWRITE must be 0 or 1."
[[ "$VALIDATE_CUSTOM_KEY_PAIRS" == 0 || "$VALIDATE_CUSTOM_KEY_PAIRS" == 1 ]] || die "VALIDATE_CUSTOM_KEY_PAIRS must be 0 or 1."

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard wireguard-tools iptables iproute2 curl qrencode ufw
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release 2>/dev/null || true
    dnf install -y wireguard-tools iptables iproute curl qrencode
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release 2>/dev/null || true
    yum install -y wireguard-tools iptables iproute curl qrencode
  else
    die "Only apt, dnf and yum based Linux distributions are supported."
  fi
}

detect_public_ip() {
  local result=""
  result="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$result" ]] || result="$(curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
  printf '%s' "$result"
}

HAS_EXISTING_WG_FILES=0
if [[ -d "$WG_DIR" ]] && [[ -n "$(find "$WG_DIR" -maxdepth 1 -type f -name '*.conf' -print -quit 2>/dev/null)" ]]; then
  HAS_EXISTING_WG_FILES=1
fi

if [[ "$HAS_EXISTING_WG_FILES" == 0 ]]; then
  log "First run: installing required packages."
  install_packages
else
  log "$WG_DIR already contains WireGuard configuration files; skipping package update and installation."
fi

for required_command in wg wg-quick ip iptables systemctl curl; do
  command -v "$required_command" >/dev/null 2>&1 || die "Missing required command: $required_command"
done

if [[ -z "$WG_OUT_INTERFACE" ]]; then
  WG_OUT_INTERFACE="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
fi
[[ -n "$WG_OUT_INTERFACE" ]] || die "Could not detect the default outbound interface."
[[ "$WG_OUT_INTERFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die "Invalid outbound interface name."

if [[ -z "$WG_SERVER_ENDPOINT" && -n "$LAST_SERVER_ENDPOINT" ]]; then
  WG_SERVER_ENDPOINT="$LAST_SERVER_ENDPOINT"
fi
if [[ -z "$WG_SERVER_ENDPOINT" ]]; then
  WG_SERVER_ENDPOINT="$(detect_public_ip)"
fi
[[ -n "$WG_SERVER_ENDPOINT" ]] || die "Could not detect the public IP; set WG_SERVER_ENDPOINT."

mkdir -p "$WG_DIR" "$OUTPUT_DIR"
chmod 700 "$WG_DIR" "$OUTPUT_DIR"

if [[ -e "$SERVER_CONFIG" ]]; then
  [[ "$WG_OVERWRITE" == 1 ]] || die "$SERVER_CONFIG exists. Set WG_OVERWRITE=1 to back it up and replace it."
  BACKUP_FILE="${SERVER_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$SERVER_CONFIG" "$BACKUP_FILE"
  systemctl stop "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
  log "Existing configuration backed up to $BACKUP_FILE"
fi

if [[ -n "$VPS_PRIVATE_KEY_CUSTOM" ]]; then
  SERVER_PRIVATE_KEY="$VPS_PRIVATE_KEY_CUSTOM"
else
  SERVER_PRIVATE_KEY="$(wg genkey)"
fi

if ! DERIVED_SERVER_PUBLIC_KEY="$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey 2>/dev/null)"; then
  die "Invalid VPS private key."
fi
if [[ -n "$VPS_PUBLIC_KEY_CUSTOM" ]]; then
  if [[ "$VALIDATE_CUSTOM_KEY_PAIRS" == 1 && "$VPS_PUBLIC_KEY_CUSTOM" != "$DERIVED_SERVER_PUBLIC_KEY" ]]; then
    die "VPS_PUBLIC_KEY_CUSTOM does not match VPS_PRIVATE_KEY_CUSTOM. Set VALIDATE_CUSTOM_KEY_PAIRS=0 only if intentional."
  fi
  SERVER_PUBLIC_KEY="$VPS_PUBLIC_KEY_CUSTOM"
else
  SERVER_PUBLIC_KEY="$DERIVED_SERVER_PUBLIC_KEY"
  fi

# Reuse one RouterOS private key for every generated WG ID. To use an existing
# key, place only that key in ROS_PRIVATE_KEY_FILE before the first run and set
# permissions to 600. If absent, a key is generated once and persisted.
if [[ -n "$ROS_PRIVATE_KEY_CUSTOM" ]]; then
  ROS_PRIVATE_KEY="$ROS_PRIVATE_KEY_CUSTOM"
  mkdir -p "$(dirname "$ROS_PRIVATE_KEY_FILE")"
  printf '%s\n' "$ROS_PRIVATE_KEY" >"$ROS_PRIVATE_KEY_FILE"
  chmod 600 "$ROS_PRIVATE_KEY_FILE"
  log "Saved the custom RouterOS private key to $ROS_PRIVATE_KEY_FILE"
elif [[ -s "$ROS_PRIVATE_KEY_FILE" ]]; then
  IFS= read -r ROS_PRIVATE_KEY <"$ROS_PRIVATE_KEY_FILE"
  chmod 600 "$ROS_PRIVATE_KEY_FILE"
  log "Reusing RouterOS private key from $ROS_PRIVATE_KEY_FILE"
else
  mkdir -p "$(dirname "$ROS_PRIVATE_KEY_FILE")"
  ROS_PRIVATE_KEY="$(wg genkey)"
  printf '%s\n' "$ROS_PRIVATE_KEY" >"$ROS_PRIVATE_KEY_FILE"
  chmod 600 "$ROS_PRIVATE_KEY_FILE"
  log "Generated persistent RouterOS private key: $ROS_PRIVATE_KEY_FILE"
fi

if ! DERIVED_ROS_PUBLIC_KEY="$(printf '%s' "$ROS_PRIVATE_KEY" | wg pubkey 2>/dev/null)"; then
  die "Invalid RouterOS private key in $ROS_PRIVATE_KEY_FILE"
fi
if [[ -n "$ROS_PUBLIC_KEY_CUSTOM" ]]; then
  if [[ "$VALIDATE_CUSTOM_KEY_PAIRS" == 1 && "$ROS_PUBLIC_KEY_CUSTOM" != "$DERIVED_ROS_PUBLIC_KEY" ]]; then
    die "ROS_PUBLIC_KEY_CUSTOM does not match the RouterOS private key. Set VALIDATE_CUSTOM_KEY_PAIRS=0 only if intentional."
  fi
  ROS_PUBLIC_KEY="$ROS_PUBLIC_KEY_CUSTOM"
else
  ROS_PUBLIC_KEY="$DERIVED_ROS_PUBLIC_KEY"
  fi

cat >"$SERVER_CONFIG" <<EOF
[Interface]
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
MTU = ${WG_MTU}

PostUp = iptables -C INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD -i %i -j ACCEPT
PostUp = iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s ${WG_NETWORK} -o ${WG_OUT_INTERFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o ${WG_OUT_INTERFACE} -j MASQUERADE

PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o ${WG_OUT_INTERFACE} -j MASQUERADE 2>/dev/null || true

[Peer]
# ${ROS_INTERFACE}--${LOCATION_TEXT}
PublicKey = ${ROS_PUBLIC_KEY}
AllowedIPs = ${ROS_ADDRESS}/32
EOF
chmod 600 "$SERVER_CONFIG"

cat >"$ROS_CONFIG" <<EOF
# Generated RouterOS v7 configuration for WG_ID=${WG_ID}
# Linux server interface: ${WG_INTERFACE}
# Linux server tunnel IP: ${WG_SERVER_ADDRESS}
# RouterOS tunnel IP: ${ROS_ADDRESS}
# VPS listen/RouterOS endpoint port: ${WG_PORT}
# RouterOS listen port: ${ROS_LISTEN_PORT}

/interface wireguard
add listen-port=${ROS_LISTEN_PORT} private-key="${ROS_PRIVATE_KEY}" mtu=${WG_MTU} name=${ROS_INTERFACE}

:if ([:len [/routing table find where name="${ROS_TABLE_NAME}"]] = 0) do={
    /routing table add fib name=${ROS_TABLE_NAME}
}

:if ([:len [/interface list find where name="WG"]] = 0) do={
    /interface list add name=WG
}

/interface list member
add interface=${ROS_INTERFACE} list=WG

/interface wireguard peers
add allowed-address=0.0.0.0/0 endpoint-address=${WG_SERVER_ENDPOINT} endpoint-port=${WG_PORT} interface=${ROS_INTERFACE} name=${ROS_PEER_NAME} persistent-keepalive=15s public-key="${SERVER_PUBLIC_KEY}"

/ip address
add address=${ROS_CIDR} interface=${ROS_INTERFACE} network=${WG_NETWORK_BASE}.0

/ip firewall nat
add action=src-nat chain=srcnat out-interface=${ROS_INTERFACE} to-addresses=${ROS_ADDRESS} comment="WireGuard ${ROS_INTERFACE}"

/ip route
add dst-address=0.0.0.0/0 gateway=${WG_SERVER_ADDRESS} routing-table=${ROS_TABLE_NAME}

/tool netwatch
add host=${WG_SERVER_ADDRESS} interval=10s timeout=5s type=simple name="${ROS_NETWATCH_NAME}" down-script="/log warning \"WireGuard ${ROS_INTERFACE} is DOWN\"" up-script="/log info \"WireGuard ${ROS_INTERFACE} is UP\""
EOF
chmod 600 "$ROS_CONFIG"

cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# UFW rules are written once and remain persistent across reboots. If UFW is
# inactive, the rules are saved now and can be activated once with:
#   ufw --force enable
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${WG_PORT}/udp" comment "WireGuard ${WG_INTERFACE}"
  ufw route allow in on "$WG_INTERFACE" out on "$WG_OUT_INTERFACE" || true
  if ufw status | grep -q '^Status: active'; then
    log "UFW rules are active and persistent after reboot."
  else
    warn "UFW rules are saved but inactive. Enable UFW once with: ufw --force enable"
  fi
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${WG_PORT}/udp"
  firewall-cmd --permanent --add-masquerade
  firewall-cmd --reload
else
  warn "No UFW/firewalld detected; wg-quick will still install iptables rules."
fi

systemctl enable --now "wg-quick@${WG_INTERFACE}"

# Record only successful installations. The next run uses these values +1.
STATE_TMP="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
printf 'LAST_WG_ID=%s\nLAST_WG_PORT=%s\nLAST_ROS_LISTEN_PORT=%s\nLAST_SERVER_ENDPOINT=%s\n' "$WG_ID" "$WG_PORT" "$ROS_LISTEN_PORT" "$WG_SERVER_ENDPOINT" >"$STATE_TMP"
chmod 600 "$STATE_TMP"
mv -f "$STATE_TMP" "$STATE_FILE"

log "Installation complete."
printf '\nLinux config: %s\n' "$SERVER_CONFIG"
printf 'RouterOS import file: %s\n' "$ROS_CONFIG"
printf 'Linux interface/address: %s / %s\n' "$WG_INTERFACE" "$WG_SERVER_CIDR"
printf 'RouterOS interface/address: %s / %s\n' "$ROS_INTERFACE" "$ROS_CIDR"
printf 'VPS listen / RouterOS endpoint port: %s\n' "$WG_PORT"
printf 'RouterOS listen port: %s\n' "$ROS_LISTEN_PORT"
printf 'Server endpoint: %s\n\n' "$WG_SERVER_ENDPOINT"
if (( WG_ID < 254 && WG_PORT < 65535 && ROS_LISTEN_PORT < 65535 )); then
  printf 'Next automatic run: WG_ID=%s, VPS port=%s, RouterOS listen port=%s\n\n' "$((WG_ID + 1))" "$((WG_PORT + 1))" "$((ROS_LISTEN_PORT + 1))"
else
  warn "Automatic ID/port increment reached its limit; set overrides explicitly next time."
fi
wg show "$WG_INTERFACE"
printf '\nCopy or import this RouterOS configuration:\n\n'
cat "$ROS_CONFIG"
