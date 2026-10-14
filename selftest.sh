#!/bin/bash
# 用 network namespace 冒充 ap0 上的客户端，验证 DHCP/DNS → 转发 → mihomo TUN → 代理 整条链。
# 唯一没覆盖的是 wifi 关联与 eapol —— 那部分由 hostapd 报 AP-ENABLED + 真机拿到租约证明。
# 用法： pkexec bash selftest.sh   （热点 start 之后跑）
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CALLER_UID=${PKEXEC_UID:-$UID}
CALLER_HOME=$(getent passwd "$CALLER_UID" | cut -d: -f6)
STATE_DIR=${HOTSPOT_STATE_DIR:-$CALLER_HOME/.local/state/vpn-hotspot}

NS=ht-t2
HOSTV=10.42.0.251
CLIENT=10.42.0.98
DNS_CONF=$SCRIPT_DIR/dnsmasq.conf
DNS_CONF_T=$STATE_DIR/dnsmasq.test.conf

cleanup() {
  pkill -f "dnsmasq -C $DNS_CONF_T" 2>/dev/null
  sleep 0.5
  dnsmasq -C "$DNS_CONF" --pid-file="$STATE_DIR/dnsmasq.pid" 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  ip link del veth-ht2 2>/dev/null
  ip route del "$CLIENT/32" dev veth-ht2 2>/dev/null
  firewall-cmd --zone=trusted --remove-interface=veth-ht2 >/dev/null 2>&1
  rm -rf "/etc/netns/$NS" "$DNS_CONF_T"
}
trap cleanup EXIT

ip netns del "$NS" 2>/dev/null; ip link del veth-ht2 2>/dev/null

ip netns add "$NS"
ip link add veth-ht2 type veth peer name veth-ns2
ip link set veth-ns2 netns "$NS"
ip link set veth-ht2 up
ip addr add "$HOSTV/24" dev veth-ht2
sysctl -q -w net.ipv4.conf.veth-ht2.rp_filter=0
firewall-cmd --zone=trusted --add-interface=veth-ht2 >/dev/null

ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set veth-ns2 up
ip netns exec "$NS" ip addr add "$CLIENT/24" dev veth-ns2
# 假客户端必须有显式网关，否则 ARP 不到 host 侧
ip netns exec "$NS" ip route add default via "$HOSTV"
ip route add "$CLIENT/32" dev veth-ht2

# dnsmasq 只服务 ap0；测试期间额外允许 veth-ht2，让假客户端也能问到它
sed "s/^interface=.*/interface=ap0\ninterface=veth-ht2/" "$DNS_CONF" > "$DNS_CONF_T"
kill "$(<"$STATE_DIR/dnsmasq.pid" 2>/dev/null)" 2>/dev/null; sleep 1
dnsmasq -C "$DNS_CONF_T" --pid-file="$STATE_DIR/dnsmasq.pid"

mkdir -p "/etc/netns/$NS"
printf 'nameserver %s\n' "$HOSTV" > "/etc/netns/$NS/resolv.conf"

echo "=== DNS（假客户端 → dnsmasq → mihomo DNS）==="
ip netns exec "$NS" getent hosts www.gstatic.com || echo "DNS 失败"
echo "=== HTTPS：gstatic 204 ==="
ip netns exec "$NS" curl -s -o /dev/null -w "-> %{http_code}\n" --max-time 20 https://www.gstatic.com/generate_204 || echo "curl 失败"
echo "=== HTTPS：google.com（手表更新同源）==="
ip netns exec "$NS" curl -s -o /dev/null -w "-> %{http_code}\n" --max-time 20 https://www.google.com/ || echo "curl 失败"
echo "=== 代理面板里能不能看到源 $CLIENT ==="
curl -s --noproxy '*' http://127.0.0.1:9090/connections | grep -c "$CLIENT" || true
