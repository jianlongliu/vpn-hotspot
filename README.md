# vpn-hotspot

把本机 [mihomo](https://github.com/MetaCubeX/mihomo) 的代理出口共享成一个 WiFi 热点（`ap0`），让手表、手机这类不方便单独配代理的设备连上就能用。

- 只开 2.4GHz：本机网卡（Intel AX201）在自管管制域下起不了 5GHz AP，原因见 [docs/why-2.4ghz.md](docs/why-2.4ghz.md)
- 客户端零配置：DHCP 与 DNS 都指向热点网关，出口是 mihomo 的 TUN，走代理是透明的
- 所有改动都是运行时的（`ap0` 接口、iptables、firewalld runtime 区、两个 sysctl），停止即撤，不写 `/etc`

## 安装

```bash
# 依赖（Arch 系；本机已随系统装好）
sudo pacman -S hostapd dnsmasq iwd iw iptables firewalld

# 本仓库
git clone https://github.com/jianlongliu/vpn-hotspot.git
cd vpn-hotspot
```

另需系统级 `mihomo` 在跑（热点出口就是它的 TUN 接口）。其余命令（`ip`、`sysctl`、`pkill`、`curl`、`systemctl`）来自 Arch 基础包。脚本按自身路径找配置文件，仓库放哪都行；所有操作都用 `pkexec` 提权。

## 配置

| 项 | 位置 | 说明 |
|---|---|---|
| SSID / 密码 | `~/.local/state/vpn-hotspot/hotspot.env` | `HOTSPOT_SSID=…`、`HOTSPOT_PSK=…`（≥8 位），`chmod 600`；脚本里不含密码 |
| 接口名 / 网段 | `run.sh` 顶部变量 | `WLAN_IFACE=wlan0`、`AP_IFACE=ap0`、`VPN_IFACE=mihomo`、`SUBNET=10.42.0.0/24`、`GW=10.42.0.1/24` |
| DHCP / DNS | `dnsmasq.conf` | 地址池 `10.42.0.2–254`，网关与 DNS 都是 `10.42.0.1`，上游 DNS `198.18.0.2`（mihomo 的 fake-ip，靠 TUN 劫持） |
| 加密 | 运行时生成 | `run.sh start` 按 STA 当前信道生成 `~/.local/state/vpn-hotspot/hostapd.conf`（WPA2-PSK）；模板见 `hostapd.conf.example` |

首次使用前写一次凭据：

```bash
mkdir -p ~/.local/state/vpn-hotspot
printf 'HOTSPOT_SSID="%s"\nHOTSPOT_PSK="%s"\n' "SSID" "密码" > ~/.local/state/vpn-hotspot/hotspot.env
chmod 600 ~/.local/state/vpn-hotspot/hotspot.env
```

## 用法

```bash
pkexec bash iwd-2g.sh 2g       # 把 STA 钉到 2.4GHz（会重启 iwd，短暂断网）
pkexec bash run.sh start       # 开热点
pkexec bash run.sh status      # 现场：接口 / 进程 / 租约 / NAT / 转发 / 防火墙 / 频段
pkexec bash selftest.sh        # 端到端自检（可选）

pkexec bash run.sh stop        # 关热点
pkexec bash iwd-2g.sh restore  # 还原 iwd，5GHz 回到可用
```

`run.sh start` 在下列情况会直接退出、不做任何改动：`mihomo` 未运行、凭据缺失或密码短于 8 位、`ap0` 已存在、STA 仍落在 5GHz（会提示先跑 `iwd-2g.sh 2g`）。

钉频原因、验证方法与排障见 [docs/](docs/)。

## 卸载 / 移除

```bash
pkexec bash run.sh stop                     # 1. 关热点（撤 iptables、删 ap0、摘 trusted 区）
pkexec bash iwd-2g.sh restore               # 2. 还原 iwd（若没用过 2g，可跳过）
rm -rf ~/.local/state/vpn-hotspot           # 3. 删运行时状态与凭据
rm -rf ~/.local/state/backups/etc/iwd       # 4. 可选：删 iwd 备份
cd .. && rm -rf vpn-hotspot                 # 5. 删仓库
```

`ap0`、iptables 与 firewalld 的改动都只存在于运行时，重启即净；系统服务 `hostapd`、`dnsmasq` 全程没被启用，无需处理。

## 文档

- [docs/why-2.4ghz.md](docs/why-2.4ghz.md) —— 为什么必须先降 2.4GHz、`BandModifier5GHz` 的坑与症状辨识
- [docs/operations.md](docs/operations.md) —— 状态文件与备份、验证清单、故障排查与回退细节、使用注意

## 致谢

本仓库没有引入第三方代码，功能全部建立在这些上游项目上：[mihomo](https://github.com/MetaCubeX/mihomo)、[hostapd](https://w1.fi/hostapd/)、[dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html)、[iwd](https://iwd.wiki.kernel.org/)、[iptables](https://www.netfilter.org/projects/iptables/)、[firewalld](https://firewalld.org/)。
