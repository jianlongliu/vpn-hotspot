# vpn-hotspot：把系统 mihomo 共享成 WiFi 热点（ap0）

把本机的 `mihomo` 代理出口共享给手表/手机用。**全部是运行时改动**：新建 `ap0` 接口、iptables NAT、firewalld 的 runtime 区、两个 sysctl，`stop` 能完全撤回；不写任何 `/etc`（唯一例外是 `iwd-2g.sh` 的 2.4GHz 钉住，它有独立的还原动作，见下）。

2026-09-24 成文。曾作为 `scripts/vpn-hotspot/` 短暂进过 `onarchi` 仓（2026-10-14），当天撤出、独立成仓 —— 它是本机网络设施，与 omarchy 移植无关。更早的 FlClash 时代那套（`vpn-hotspot.service` + `/usr/local/bin/vpn-hotspot` + `/etc/hostapd/hostapd.conf`）2026-09-21 已删，备份在 `~/.local/state/backups/`。

## 文件

| 文件 | 作用 |
|---|---|
| `run.sh` | `start` / `stop` / `status`：生成 hostapd 配置、建 `ap0`、起 hostapd + dnsmasq、加 NAT 与转发 |
| `iwd-2g.sh` | `2g` / `restore`：把 iwd 临时钉在 2.4GHz（**用完必须 restore**，见下） |
| `selftest.sh` | 用 netns 冒充客户端，端到端验 DHCP/DNS → 转发 → mihomo TUN → 代理 |
| `dnsmasq.conf` | `interface=ap0` + `server=198.18.0.2`（mihomo fake-ip，靠 TUN 劫持）+ DHCP 池 `10.42.0.0/24` |
| `hostapd.conf.example` | `run.sh start` 生成的 hostapd 配置长什么样（真值在机器上，含密码，不入库） |

运行时状态都落在 `~/.local/state/vpn-hotspot/`：`hostapd.conf`（含密码，`chmod 600`）、`hotspot.env`（SSID/密码，`chmod 600`）、两个 pid 文件；测试期还会临时出现 `dnsmasq.test.conf`。

## 为什么必须先把 STA 钉到 2.4GHz

1. 本机网卡是 **Intel Wi-Fi 6 AX201**（`lspci` = `8086:a0f0` rev 20，驱动 `iwlwifi`），而且是 **自管管制域**（`iw phy phy0 info` 里标 `self-managed`，国家恒为 `00`）：5GHz 的 149–165 全是 `no IR`，hostapd 直接以 `NO-IR ... not allowed for AP mode` 拒绝 ⇒ **AP 起不来 5GHz**。`iw reg set CN` 与 hostapd 的 `country_code=CN` 都改不动自管域。
2. 驱动的接口组合是 `#{managed}<=1, #{AP}<=1, #channels<=1` ⇒ **AP 必须与 STA 同信道**。STA 在 5GHz 时建 2.4GHz AP 会 `-EBUSY`。
3. 两条合起来只剩一条路：把 STA 先钉到 2.4GHz（`iwd-2g.sh 2g`），AP 才能在同一个 2.4GHz 信道上起来。

⇒ **「5GHz 不能用」只限定在 AP 这一侧**：AX201 作为 STA 连 5GHz 完全正常（本机日常就落在 5300 MHz / ch60、rx 2400 Mbit/s 档），**别为此把 5GHz 屏蔽掉**——那既没必要，又会顺带废掉 STA 侧的 5GHz（`BandModifier5GHz` 就是反例，见下）。开热点期间把 STA 钉到 2.4GHz 只是"临时代价"，用完 `restore` 就还。

**`BandModifier5GHz=0.0` 的副作用比"降权"严重得多**：因子为 0 时 iwd 的周期性扫描根本不把 5GHz 放进扫描频点集（iwd 3.12 `scan_periodic_get_freqs()` 按因子拼 band mask），于是同名双频 SSID 永远只连 2.4G，而且**扫描列表里一个 5GHz SSID 都不出现**（`iwctl station wlan0 scan` 也一样）。2026-09-24 那次漏跑 `restore`，一直挂到 2026-10-14 才被当成"连不上 5G"发现。`run.sh status` 末尾会检查这一条，钉住未还原时会打警告。

## 用法

都假定你在本仓库目录里执行（脚本按自己的路径找 `dnsmasq.conf`，从哪儿调用都行）。

```bash
# 1. 先把 STA 钉到 2.4GHz（会重启 iwd，短暂断网；记得第 4 步还原）
pkexec bash iwd-2g.sh 2g

# 2. 准备凭据（一次性；不入库）
printf 'HOTSPOT_SSID=%s\nHOTSPOT_PSK=%s\n' "你的SSID" "你的密码" > ~/.local/state/vpn-hotspot/hotspot.env
chmod 600 ~/.local/state/vpn-hotspot/hotspot.env

# 3. 开热点
pkexec bash run.sh start
pkexec bash selftest.sh          # 端到端自检（可选但推荐）
pkexec bash run.sh status

# 4. 关热点，并把 5GHz 放回来（两步都要）
pkexec bash run.sh stop
pkexec bash iwd-2g.sh restore
```

`iwd-2g.sh restore` 从 `~/.local/state/backups/etc/iwd/main.conf.bak-*-pre2ghotspot`（最新的那份）还原；找不到备份时它报错退出，不会盲写配置。

## 验法

- **STA 侧**：`iwd-2g.sh` 结束时打印 `iwd: active` 与 "N 个 5GHz BSS" —— 钉住时是 `0 个`，`restore` 后应恢复成两位数（本机实测：有同名 5GHz BSS 时 5–6 个）。
- **AP 侧**：`run.sh status` 的 hostapd 段应有进程、`ap0` 有 `10.42.0.1/24`、NAT 段能看到 MASQUERADE、转发段 `net.ipv4.ip_forward=1`；`journalctl -t hostapd` 里应有 `AP-ENABLED`。
- **端到端**：`selftest.sh` 打印 gstatic `-> 204`、google `-> 200`，并在 mihomo 面板（`127.0.0.1:9090`）里能看到假客户端的连接数 ≥1。
- **真机**：手表/手机连上后看 `/var/lib/misc/dnsmasq.leases` 有没有租约。

## 回退

- 关热点：`run.sh stop`（撤 iptables、杀 hostapd/dnsmasq、删 `ap0`、摘 trusted 区）。
- 5GHz：`iwd-2g.sh restore`。若脚本与备份都丢了，手工删掉 `/etc/iwd/main.conf` 里的 `[Rank]` 段再 `systemctl restart iwd`（症状辨识：`pkexec iw dev wlan0 scan` 看得见 5GHz 而 iwd/NM 列表里没有 ⇒ 查这个文件，不是驱动问题）。
- **手表/手机更新期间别合盖、别挂起**：suspend 会掐掉热点。

## 不入库的东西

`~/.local/state/vpn-hotspot/` 下的 `hostapd.conf`、`hotspot.env`、pid 文件，以及 `iwd-2g.sh` 写的 iwd 备份 —— 前者含 WiFi 密码，后者是机器状态（`.gitignore` 已兜底 `hostapd.conf` 与 `*.env`）。脚本本身零密码、零家目录字面量（pkexec 下 `$HOME` 是 `/root`，脚本用 `PKEXEC_UID` 反查发起提权用户的家目录）。
