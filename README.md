# vpn-hotspot：把系统 mihomo 共享成 WiFi 热点（ap0）

把本机的 `mihomo` 代理出口共享给手表/手机用。全部改动都是**运行时的**：新建 `ap0` 接口、iptables NAT、firewalld 的 runtime 区、两个 sysctl，`run.sh stop` 能完全撤回；不写 `/etc`（唯一例外是 `iwd-2g.sh` 对 `/etc/iwd/main.conf` 的 2.4GHz 钉住，它有独立的还原动作）。

## 前提

- **`mihomo` 得在跑** —— 热点出口就是它的 TUN（`run.sh start` 会检查，不在直接退出）。
- **用 `pkexec` 跑，别用 `sudo`**：脚本按 `PKEXEC_UID` 反查"发起提权那个用户"的家目录来定位状态目录，裸 `sudo` 会把状态指到 `/root` 下。
- 接口名写死在脚本里：STA `wlan0`、AP `ap0`、出口 TUN `mihomo`；网段 `10.42.0.0/24`、AP 网关 `10.42.0.1`。
- 凭据（SSID/密码）放在 `~/.local/state/vpn-hotspot/hotspot.env`（`chmod 600`，不入库）——脚本里零密码，仓库里也不该有。

## 为什么必须先把 STA 钉到 2.4GHz

1. 本机网卡是 **Intel Wi-Fi 6 AX201**（`lspci` = `8086:a0f0` rev 20，驱动 `iwlwifi`），而且是**自管管制域**（`iw phy phy0 info` 标 `self-managed`，国家恒为 `00`）：5GHz 的 149–165 全是 `no IR`，hostapd 直接以 `NO-IR ... not allowed for AP mode` 拒绝 ⇒ **AP 起不来 5GHz**。`iw reg set CN` 与 hostapd 的 `country_code=CN` 都改不动自管域。
2. 驱动的接口组合是 `#{managed}<=1, #{AP}<=1, #channels<=1` ⇒ **AP 必须与 STA 同信道**：STA 在 5GHz 时建 2.4GHz AP 会 `-EBUSY`。
3. 两条合起来只剩一条路：把 STA 先钉到 2.4GHz（`iwd-2g.sh 2g`），AP 才能在同一条 2.4GHz 信道上起来。

两条边界，别搞反：

- **「5GHz 用不了」只限 AP 这一侧**。AX201 作为 STA 连 5GHz 完全正常（本机日常就落在 5300 MHz / ch60）。开热点期间钉 2.4GHz 是临时代价，用完 `restore` 就还 —— **不要为此把 5GHz 永久屏蔽**。
- **`BandModifier5GHz=0.0` 的副作用比"降权"严重**：因子为 0 时 iwd 的周期性扫描**根本不把 5GHz 放进扫描频点集**（iwd 3.12 `scan_periodic_get_freqs()` 按因子拼 band mask），症状是"同名双频永远只连 2.4G、`iwctl station wlan0 scan` 里 0 个 5GHz BSS"。2026-09-24 那轮漏跑 `restore`，一直挂到 2026-10-14 才被当成"连不上 5G"查出来。`run.sh status` 末尾专门检查这一条。

## 文件

| 文件 | 作用 |
|---|---|
| `run.sh` | 入口。`start` 生成 hostapd 配置、建 `ap0`、起 hostapd + dnsmasq、加 NAT 与转发；`stop` 逆操作；`status` 打全套现场（接口 / 进程 / 租约 / NAT / 转发 / 防火墙 / iwd 频段） |
| `iwd-2g.sh` | `2g` 把 iwd 钉在 2.4GHz（改 `/etc/iwd/main.conf` + 重启 iwd，先存备份）；`restore` 还原。**开热点前必须 `2g`，关热点后必须 `restore`** |
| `selftest.sh` | 用 netns + veth 冒充 `ap0` 上的客户端，端到端验 DHCP/DNS → 转发 → mihomo TUN → 代理（`start` 之后跑） |
| `dnsmasq.conf` | `interface=ap0` + `server=198.18.0.2`（mihomo 的 fake-ip，靠 TUN 劫持）+ DHCP 池 `10.42.0.0/24`、网关/DNS 都指向 `10.42.0.1` |
| `hostapd.conf.example` | `run.sh start` 现生成的 hostapd 配置长什么样（真值在机器上、含密码，不入库） |

运行时状态都在 `~/.local/state/vpn-hotspot/`：`hostapd.conf`（含密码，600）、`hotspot.env`（SSID/PSK，600）、`hostapd.pid`、`dnsmasq.pid`；自检期间还会临时多一个 `dnsmasq.test.conf`。`.gitignore` 兜底 `hostapd.conf`、`*.env`、`*.pid`、`*.bak*`。

## 用法

```bash
# 0. 一次性：建状态目录 + 写凭据（值用引号包住，SSID 带空格也不会被 source 拆断）
mkdir -p ~/.local/state/vpn-hotspot
printf 'HOTSPOT_SSID="%s"\nHOTSPOT_PSK="%s"\n' "你的SSID" "你的密码" > ~/.local/state/vpn-hotspot/hotspot.env
chmod 600 ~/.local/state/vpn-hotspot/hotspot.env

# 1. 把 STA 钉到 2.4GHz（会重启 iwd，短暂断网）
pkexec bash iwd-2g.sh 2g

# 2. 开热点（脚本在仓库目录里，按自身路径找 dnsmasq.conf，从哪儿调用都行）
pkexec bash run.sh start
pkexec bash run.sh status
pkexec bash selftest.sh          # 端到端自检（可选但推荐）

# 3. 关热点，再把 5GHz 放回来（两步都要）
pkexec bash run.sh stop
pkexec bash iwd-2g.sh restore
```

- `run.sh start` 若发现 STA 还落在 5GHz，会**直接报错退出**并提示先跑 `iwd-2g.sh 2g`（不让 hostapd 抛那句难懂的 `NO-IR`）；`mihomo` 没跑、缺凭据、`ap0` 已存在，同样当场退出。
- `iwd-2g.sh restore` 取 `~/.local/state/backups/etc/iwd/main.conf.bak-*pre2ghotspot` 里**最新那份**还原；一份都找不到就报错退出，不盲写配置。

## 验法

- **STA 侧**：`iwd-2g.sh` 跑完自己打一遍现场 —— `iwd` 状态、`wlan0` 的 ssid/channel、**5GHz BSS 计数**（钉住时应为 `0 个`，`restore` 后应变成非 0）、默认路由、一次 gstatic 204 自检。
- **AP 侧**：`run.sh status` —— hostapd 有进程、`ap0` 有 `10.42.0.1/24`、NAT 段出现 MASQUERADE、`ip_forward=1`、trusted 区含 `ap0`；`journalctl -t hostapd` 里应有 `AP-ENABLED`（真机连上才有关联日志）。
- **端到端**：`selftest.sh` 应打 gstatic `-> 204`、google `-> 200`，并在 mihomo 面板（`127.0.0.1:9090`）里看到假客户端的连接数 ≥1。
- **真机**：手表/手机连上后看 `/var/lib/misc/dnsmasq.leases` 有没有租约。

## 回退

| 想撤销 | 命令 |
|---|---|
| 热点 | `pkexec bash run.sh stop`（撤 iptables、杀 hostapd/dnsmasq、删 `ap0`、摘 trusted 区）；现场不对先 `run.sh status` 看是哪段残留 |
| 5GHz 被钉住 | `pkexec bash iwd-2g.sh restore`。脚本和备份都丢了：手工删掉 `/etc/iwd/main.conf` 里的 `[Rank]` 段 → `systemctl restart iwd`。辨识症状：root 的 `iw dev wlan0 scan` 看得见 5GHz、而 iwd/NM 列表里一个都没有 |
| 全部（回到没这套件） | 机器上只留 `~/.local/state/vpn-hotspot/`（删掉即可）与上面那条 iwd 还原；`ap0` 没了、iptables/firewalld 的改动是 runtime 的、重启即净 |

⚠ **手表/手机更新期间别合盖、别挂起**：suspend 会掐掉热点。

更早的 FlClash 时代那套（`vpn-hotspot.service` + `/usr/local/bin/vpn-hotspot` + `/etc/hostapd/hostapd.conf`）2026-09-21 已删，备份在 `~/.local/state/backups/`。
