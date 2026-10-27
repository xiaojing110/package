# luci-app-netdevices —— 在线设备

LuCI 插件：读取局域网在线设备，支持 **IPv4 / IPv6 / MAC / 在线时长 / 上线时间 / 设备名**，
并可直接**设置 DHCP 静态地址**。

兼容 **OpenWrt 23.05 / 24.10 / 25.12 / snapshot**（JS LuCI）。

---

## 界面

**状态 → 在线设备**

| 列 | 说明 |
|---|---|
| 设备名 | 优先取 dnsmasq 租约主机名 → 静态 `name` → `/etc/hosts` |
| IPv4 地址 | 来自邻居表 + DHCP 租约，同一 MAC 可有多个 |
| IPv6 地址 | 来自 `ip -6 neigh`（NDP 邻居表） |
| MAC 地址 | 小写，作为设备主键 |
| 在线时长 | 当前时间 − 首次发现时间 |
| 上线时间 | 首次发现时间（无记录时回退到 DHCP 租约起始） |
| 状态 | 在线/离线 + 邻居状态（REACHABLE/STALE/DELAY/PROBE/PERMANENT…） |
| 操作 | 设置静态地址 / 修改 / 移除 |

顶部有在线数、总数、静态地址数统计，以及刷新按钮；**每 30 秒自动刷新**。

---

## 数据来源

| 数据 | 来源 |
|---|---|
| IPv4 邻居 | `ip neigh show`（ARP 表） |
| IPv6 邻居 | `ip -6 neigh show`（NDP 表） |
| IP / 主机名 / 租约期 | `/tmp/dhcp.leases`（dnsmasq） |
| 静态地址 | `/etc/config/dhcp` 的 `config host` |
| 设备名 | 租约 hostname → 静态 name → `/etc/hosts` |
| 首次发现时间 | `/tmp/netdevices/first_seen`（自动维护，30 天未见自动清理） |

**在线时长**是真实「已在线多久」，不是租约剩余时间 —— 靠首次发现时间戳推算，
对静态地址设备、无 DHCP 的设备同样准确。

---

## 架构

```
luci-app-netdevices/
├── Makefile
├── htdocs/luci-static/resources/view/netdevices/overview.js   # LuCI 前端（JS）
├── po/{zh_Hans,zh-cn}/netdevices.po                            # 中文语言包
└── root/
    ├── usr/libexec/rpcd/netdevices                            # rpcd 后端（数据源+写入）
    ├── usr/share/rpcd/acl.d/luci-app-netdevices.json          # LuCI 权限
    └── usr/share/luci/menu.d/luci-app-netdevices.json         # 菜单注册
```

前端通过 **ubus** 调 `netdevices.status` 拿数据、`netdevices.set_static` / `remove_static` 写配置，
不直接碰 shell，符合 LuCI 的权限模型。

### ubus 接口

```bash
ubus call netdevices status          # 设备列表
ubus call netdevices set_static '{"mac":"aa:bb:cc:dd:ee:ff","ip":"192.168.1.100","name":"my-pc"}'
ubus call netdevices remove_static '{"mac":"aa:bb:cc:dd:ee:ff"}'
```

`status` 返回：

```json
[{
  "mac": "aa:bb:cc:dd:ee:ff",
  "name": "my-pc",
  "ip4": "192.168.1.100",
  "ip6": "fd00::100,fe80::100",
  "interface": "br-lan",
  "state": "REACHABLE",
  "online": true,
  "first_seen": 1730000000,
  "uptime": 3600,
  "is_static": false
}]
```

---

## 兼容性

| OpenWrt | LuCI | 支持 |
|---|---|---|
| snapshot | JS (23.05+) | ✅ |
| 25.12 | JS | ✅ |
| 24.10 | JS | ✅ |
| 23.05 | JS | ✅ |
| 22.03 及更早 | Lua | ❌（需改写为 Lua 版） |

前端用的是 LuCI 23.05+ 的 **JS view**（`menu.d` + `acl.d` + `view.extend`），
23.05 之后所有版本通用；后端是 POSIX sh + busybox awk，无 bash 依赖。

---

## 编译

```bash
cp -a luci-app-netdevices <openwrt>/package/
make menuconfig        # LuCI -> Applications -> 选 "Online Devices"
make package/luci-app-netdevices/compile V=s
```

或在本仓库的 GitHub Actions `Build Packages` 里选 `luci-app-netdevices`。
