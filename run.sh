#!/bin/bash
# 临时把系统 mihomo 代理共享成 WiFi 热点（ap0）：hostapd + dnsmasq + NAT。
# 所有改动都是运行时的（接口 / iptables / firewalld runtime 区 / sysctl），stop 可完全撤回，不碰 /etc。
# 用法： pkexec bash run.sh {start|stop|status}   （在本仓库目录里跑）
#
# SSID / 密码一律不写进脚本（曾因此无法入库，且让 2026-09-24 那次 iwd 改动瞒了 20 天）：
# 从 $STATE_DIR/hotspot.env 或同名环境变量读，见 README.md。
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# pkexec 下 $HOME 是 /root，要取"发起提权的那个用户"的家目录
CALLER_UID=${PKEXEC_UID:-$UID}
CALLER_HOME=$(getent passwd "$CALLER_UID" | cut -d: -f6)
STATE_DIR=${HOTSPOT_STATE_DIR:-$CALLER_HOME/.local/state/vpn-hotspot}
ENV_FILE=$STATE_DIR/hotspot.env

AP_IFACE=ap0
WLAN_IFACE=wlan0
VPN_IFACE=mihomo
SUBNET=10.42.0.0/24
GW=10.42.0.1/24
HOSTAPD_CONF=$STATE_DIR/hostapd.conf
DNSMASQ_CONF=$SCRIPT_DIR/dnsmasq.conf
HOSTAPD_PID=$STATE_DIR/hostapd.pid
DNSMASQ_PID=$STATE_DIR/dnsmasq.pid

log() { echo "[hotspot] $*"; }
die() { echo "[hotspot] ERROR: $*" >&2; exit 1; }

load_credentials() {
  if [[ -f $ENV_FILE ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
  fi
  SSID=${HOTSPOT_SSID:-}
  PSK=${HOTSPOT_PSK:-}
  if [[ -z $SSID || -z $PSK ]]; then
    die "缺 SSID/密码：写 $ENV_FILE（HOTSPOT_SSID=… 与 HOTSPOT_PSK=…，chmod 600），或用同名环境变量传入"
  fi
  if (( ${#PSK} < 8 )); then
    die "密码至少 8 位（WPA2-PSK 的硬性要求）"
  fi
}

wlan_channel() { iw dev "$WLAN_IFACE" info 2>/dev/null | awk '/channel/ {print $2}'; }

write_hostapd_conf() {
  local ch=$1 mode
  if (( ch <= 14 )); then
    mode=g
  else
    mode=a
  fi
  cat > "$HOSTAPD_CONF" <<EOF
interface=$AP_IFACE
driver=nl80211
ssid=$SSID
hw_mode=$mode
channel=$ch
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  chmod 600 "$HOSTAPD_CONF"
  log "hostapd.conf: hw_mode=$mode channel=$ch"
}

start() {
  load_credentials
  mkdir -p -- "$STATE_DIR"
  if [[ -e /sys/class/net/$AP_IFACE ]]; then
    die "$AP_IFACE 已存在，先 stop"
  fi
  if ! systemctl is-active --quiet mihomo; then
    die "mihomo 没在跑（热点出口就是它的 TUN）"
  fi

  local ch
  ch=$(wlan_channel)
  if [[ -z $ch ]]; then
    die "读不到 $WLAN_IFACE 的信道（STA 没连上？）"
  fi
  log "$WLAN_IFACE 信道 $ch（AP 与 STA 必须同信道）"

  # 本机网卡是自管管制域：5GHz 149–165 全是 no IR，AP 起不来 5GHz。
  # 与其让 hostapd 抛 NO-IR，不如在这里把话说明白。
  if (( ch > 14 )); then
    die "$WLAN_IFACE 在 5GHz（信道 $ch）：本机起不来 5GHz AP，先 pkexec bash $SCRIPT_DIR/iwd-2g.sh 2g 把 STA 钉到 2.4GHz"
  fi

  write_hostapd_conf "$ch"

  log "创建 $AP_IFACE"
  iw dev "$WLAN_IFACE" interface add "$AP_IFACE" type __ap || die "建 $AP_IFACE 失败"
  ip link set "$AP_IFACE" up

  # firewalld：AP 与 mihomo 的 TUN 都在 trusted 区才允许互相转发（仅 runtime，reload 即失效）
  firewall-cmd --zone=trusted --add-interface="$AP_IFACE" >/dev/null || log "WARN: 加 trusted 区失败"

  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w "net.ipv4.conf.$AP_IFACE.rp_filter=0"

  log "启动 hostapd"
  hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF" || die "hostapd 启动失败"
  sleep 2
  if ! pgrep -x hostapd >/dev/null; then
    journalctl -t hostapd -n 20 --no-pager 2>/dev/null
    die "hostapd 没起来"
  fi

  # 必须在 hostapd 之后配地址：hostapd 初始化接口时会 down/up 一次，冲掉已有 IPv4
  ip addr flush dev "$AP_IFACE"
  ip addr add "$GW" dev "$AP_IFACE" || die "配 $GW 失败"

  log "启动 dnsmasq"
  dnsmasq -C "$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" || die "dnsmasq 启动失败"

  iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$VPN_IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$VPN_IFACE" -j MASQUERADE
  iptables -C FORWARD -i "$AP_IFACE" -o "$VPN_IFACE" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$AP_IFACE" -o "$VPN_IFACE" -j ACCEPT
  iptables -C FORWARD -i "$VPN_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$VPN_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

  echo
  log "热点已开："
  echo "    SSID:     $SSID"
  echo "    密码:     见 $ENV_FILE"
  echo "    信道:     $ch (2.4GHz, 与 $WLAN_IFACE 同信道)"
  echo "    AP 网关:  $GW"
  echo "    出口:     mihomo TUN（走代理）"
}

stop() {
  log "清理 iptables"
  iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$VPN_IFACE" -j MASQUERADE 2>/dev/null
  iptables -D FORWARD -i "$AP_IFACE" -o "$VPN_IFACE" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -i "$VPN_IFACE" -o "$AP_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

  if [[ -f $DNSMASQ_PID ]]; then
    kill "$(<"$DNSMASQ_PID")" 2>/dev/null
  else
    pkill -f "dnsmasq -C $DNSMASQ_CONF" 2>/dev/null
  fi
  if [[ -f $HOSTAPD_PID ]]; then
    kill "$(<"$HOSTAPD_PID")" 2>/dev/null
  fi
  sleep 1

  firewall-cmd --zone=trusted --remove-interface="$AP_IFACE" >/dev/null 2>&1
  iw dev "$AP_IFACE" del 2>/dev/null
  rm -f "$HOSTAPD_PID" "$DNSMASQ_PID"
  log "热点已关"
}

status() {
  echo "=== 接口 ==="      ; iw dev 2>/dev/null | grep -E 'Interface|type|ssid|channel'
  echo "=== hostapd ==="   ; pgrep -a hostapd || echo "未运行"
  echo "=== dnsmasq ==="   ; pgrep -a dnsmasq || echo "未运行"
  echo "=== 客户端 DHCP 租约 ===" ; cat /var/lib/misc/dnsmasq.leases 2>/dev/null || echo "（无）"
  echo "=== NAT ==="        ; iptables -t nat -S POSTROUTING | grep -E "$SUBNET" || echo "无"
  echo "=== 转发 ==="       ; sysctl -n net.ipv4.ip_forward
  echo "=== 防火墙 ==="     ; firewall-cmd --zone=trusted --list-interfaces 2>/dev/null
  echo "=== iwd 频段 ==="
  if grep -q '^BandModifier5GHz=0.0' /etc/iwd/main.conf 2>/dev/null; then
    echo "⚠ /etc/iwd/main.conf 里 BandModifier5GHz=0.0 还在：iwd 不会扫 5GHz，用完必须 iwd-2g.sh restore"
  else
    echo "5GHz 未被钉住（正常）"
  fi
}

case "${1:-}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *)      echo "用法: $0 {start|stop|status}"; exit 1 ;;
esac
