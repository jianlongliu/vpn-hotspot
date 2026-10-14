#!/bin/bash
# 临时把 iwd 钉在 2.4GHz —— 热点必须与 STA 同信道，而本机（自管管制域）起不来 5GHz AP。
# 用法： pkexec bash iwd-2g.sh {2g|restore}
#
# ⚠ restore 不是可选项。BandModifier5GHz 不只给 5GHz 降权：因子为 0 时 iwd 的周期性扫描
#   根本不把 5GHz 放进扫描频点集（iwd 3.12 `scan_periodic_get_freqs()`），表现为"同名双频永远只连
#   2.4G、扫描列表里一个 5GHz SSID 都没有"。2026-09-24 那次漏跑 restore，一直挂到 2026-10-14 才被发现。
set -eu

CONF=/etc/iwd/main.conf
# pkexec 下 $HOME 是 /root，要取"发起提权的那个用户"的家目录
CALLER_UID=${PKEXEC_UID:-$UID}
CALLER_HOME=$(getent passwd "$CALLER_UID" | cut -d: -f6)
BAK_DIR=$CALLER_HOME/.local/state/backups/etc/iwd

# 备份名带日期，restore 时按最新的找回（跨天也能还原）
BAK=$BAK_DIR/main.conf.bak-$(date +%Y%m%d)-pre2ghotspot

find_backup() {
  local f
  if [[ -f $BAK ]]; then
    echo "$BAK"
    return 0
  fi
  f=$(ls -1t "$BAK_DIR"/main.conf.bak-*pre2ghotspot 2>/dev/null | head -1)
  if [[ -n $f ]]; then
    echo "$f"
    return 0
  fi
  return 1
}

case "${1:-}" in
2g)
  if ! f=$(find_backup); then
    f=$BAK
    mkdir -p -- "$BAK_DIR"
    cp -a -- "$CONF" "$f"
  fi
  cat > "$CONF" <<'EOF'
[General]
Country=CN
EnableNetworkConfiguration=true

[Rank]
BandModifier5GHz=0.0

[Network]
NameResolvingService=systemd
EOF
  chmod 644 "$CONF"
  systemctl restart iwd
  echo "已钉 2.4GHz（备份：$f）"
  ;;
restore)
  if ! f=$(find_backup); then
    echo "ERROR: $BAK_DIR 下找不到 main.conf.bak-*pre2ghotspot，拒绝盲还原" >&2
    echo "       手工做法：删掉 $CONF 里的 [Rank] 段 → systemctl restart iwd" >&2
    exit 1
  fi
  cp -a -- "$f" "$CONF"
  systemctl restart iwd
  echo "已还原（取自：$f）"
  ;;
*)
  echo "用法: $0 {2g|restore}"
  exit 1
  ;;
esac

sleep 8
echo "--- iwd ---"; systemctl is-active iwd
echo "--- wlan0 ---"; iw dev wlan0 info 2>&1 | grep -E "ssid|channel" || echo "未连接"
echo "--- 5GHz 是否可扫（钉住时为 0 个） ---"
iw dev wlan0 scan 2>/dev/null | awk '$1 == "freq:" && $2 > 5000 { n++ } END { print n+0 " 个 5GHz BSS" }'
echo "--- 默认路由 ---"; ip route show | grep '^default'
echo "--- 本机出口自检 ---"; curl -s -o /dev/null -w "google 204: %{http_code}\n" --max-time 12 https://www.gstatic.com/generate_204 || echo "curl 失败"
