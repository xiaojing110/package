# github-release-sync

**GitHub 上游同步 + OpenWrt 插件包版本/哈希自动维护工具**

两层能力：

| 层 | 作用 | 说明 |
|---|---|---|
| **A. `sources`** | 同步上游源码 | 把 `luci-app-XXX`、依赖包源码从上游仓库拉到本地，支持**多个上游**，按 commit 变化增量同步 |
| **B. `packages`** | 自动更新版本/校验值 | 在本地 Makefile 上自动写 `PKG_VERSION` / `PKG_HASH`，支持**三种策略** |

外加**版本闸门**：上游版本不高于本地已算出的版本就**忽略同步**，不会把你的包降级。

支持 **GitHub Actions 定时自动同步**，可选 **Telegram / WxPusher** 推送。

---

## 目录布局

**插件包 / 软件包目录直接放在仓库根目录**，不嵌套二级目录
（与 [`VIKINGYFY/packages`](https://github.com/VIKINGYFY/packages) 同布局）：

```
your-repo/                        ← 仓库根目录 = 一个 OpenWrt package feed
├── luci-app-passwall/            # ┐
├── luci-app-passwall2/           # │
├── luci-app-nikki/               # │ 插件 + 软件包全部在根目录
├── xray-core/  sing-box/  ...    # │
├── chinadns-ng/  naiveproxy/ ... # ┘
├── update.sh  config/  lib/      #   同步工具（无 Makefile，OpenWrt 自动忽略）
├── test/  .github/  README.md
└── .state/                       # 运行状态（已 .gitignore）
```

OpenWrt 直接拉取：见下文 **「📦 拉库」** 一节（本仓库：`https://github.com/xiaojing110/package`）。

---

## 📦 拉库 —— 在 OpenWrt 中使用本仓库

**本仓库地址：`https://github.com/xiaojing110/package`**

### 方式一：当 feed 拉取（推荐）

编辑 OpenWrt 源码树根目录的 `feeds.conf.default`（或 `feeds.conf`），加一行：

```
src-git package https://github.com/xiaojing110/package
```

然后：

```bash
cd <openwrt>
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig        # LuCI -> Applications / Themes 里勾选需要的包
make -j$(nproc)
```

### 方式二：只拉某几个包

```bash
cd <openwrt>/package
git clone --depth=1 https://github.com/xiaojing110/package xiaojing110
cp -a xiaojing110/luci-app-passwall xiaojing110/xray-core .
# 或者全部：cp -a xiaojing110/* .
```

### 方式三：src-link（本地已克隆本仓库时）

```
src-link package /path/to/xiaojing110/package
```

> 布局是扁平的（包目录直接在仓库根），所以拉下来就是现成的 feed，
> 不需要再往里套一层 `packages/`。工具自身的 `update.sh` `config/` `lib/`
> `test/` 没有 `Makefile`，OpenWrt 会自动忽略。

---

## 快速开始（维护本仓库时）

```bash
# 依赖
sudo apt-get install -y curl jq coreutils tar     # macOS: brew install curl jq gnu-tar

bash update.sh                # 全量：同步源码 + 更新版本哈希
bash update.sh --dry-run      # 只看会改什么，不动文件
bash update.sh --force        # 忽略缓存与版本闸门，强制重新拉取 / 重算
bash update.sh --only xray-core
bash update.sh --sync-source  # 只同步上游源码
bash update.sh --skip-source  # 只更新版本哈希
```

---

## A. 上游源码同步（`sources`）

已配置 5 个上游：

| name | 上游 | 同步内容 |
|---|---|---|
| `luci-app-passwall` | `Openwrt-Passwall/openwrt-passwall` | `luci-app-passwall/` |
| `luci-app-passwall2` | `Openwrt-Passwall/openwrt-passwall2` | `luci-app-passwall2/` |
| `passwall-packages` | `Openwrt-Passwall/openwrt-passwall-packages` | 17 个依赖包（**不含 `sing-box`**） |
| `nikki` | `nikkinikki-org/OpenWrt-nikki` | `luci-app-nikki/` `nikki/` `mihomo-meta/`（**已停用 `mihomo-alpha`**） |
| `vikingyfy-packages` | `VIKINGYFY/packages` | `sing-box/` `axonhub/` `gecoosac/` `luci-app-homeproxy/` `luci-app-wolultra/` `luci-app-axonhub/` `luci-app-gecoosac/` |
| `luci-theme-material3` | `KawaiiHachimi/luci-theme-material3` | **整个仓库** → `luci-theme-material3/`（`as_package` 模式） |
| `mosdns` | `sbwml/luci-app-mosdns`@**`v5`** | `luci-app-mosdns/` `mosdns/` `geo2txt/` |
| `luci-app-eqosplus` | `sirpdboy/luci-app-eqosplus` | **整个仓库** → `luci-app-eqosplus/`（`as_package` 模式） |
| `dae-box` | `hhCodingCat/dae-box` | `openwrt/dae-box` → **`dae-box/`**（`src=>dst` 改名） |
| `luci-app-dae-box` | `hhCodingCat/luci-app-dae-box` | **整个仓库** → `luci-app-dae-box/`（`as_package` + `replace` 改名） |

> ⚠️ **目录名必须和 `PKG_NAME` 一致**，否则本地编译会“找不到包”——
> OpenWrt 是**按 `PKG_NAME` 注册**的（`luci.mk` 用它定义 `Package/$(PKG_NAME)`），
> `make menuconfig` 搜的是包名，不是目录名。
>
> 上游 `luci-app-dae-box` 的 Makefile 里写的是 `PKG_NAME:=luci-app-dae-box`，
> 而目录叫 `luci-app-dae-box`（差一个连字符），搜 `luci-app-dae-box` 就是搜不到。
> 现在用 `replace` 在同步后自动改写，**而且不会被后续上游同步冲掉**：
>
> ```json
> { "name": "luci-app-dae-box",
>   "repo": "hhCodingCat/luci-app-dae-box",
>   "as_package": true, "target": "luci-app-dae-box",
>   "replace": ["PKG_NAME:=luci-app-dae-box=>PKG_NAME:=luci-app-dae-box"] }
> ```
>
> 同步日志会打一行确认：
> `✏️ luci-app-dae-box/Makefile  「PKG_NAME:=luci-app-dae-box」⇒「PKG_NAME:=luci-app-dae-box」`

> **`sing-box` 取自 `VIKINGYFY/packages`**（`passwall-packages` 的 `sing-box` 已加进 `exclude`）。
> VIKINGYFY 的版本用 `PKG_UPSTREAM_VERSION` 承载（`PKG_VERSION` 由 `$(subst)` 派生），
> 已通过 `version_var: "PKG_UPSTREAM_VERSION"` 适配，不会破坏派生式。

```json
{
  "name": "vikingyfy-packages",
  "repo": "VIKINGYFY/packages",
  "ref": "main",
  "dirs": ["*"],
  "exclude": [".github", ".gitattributes", "LICENSE", "README.md"],
  "target": "."
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `name` | — | 名称，同时是状态文件名 |
| `repo` | — | 上游仓库 `owner/repo` |
| `ref` | `main` | 分支 / tag / commit |
| `dirs` | `["*"]` | 要拷贝的条目；`"*"` = 顶层全部；支持 **`"src=>dst"`** 改名（上游包嵌套在子目录时用） |
| **`replace`** | `[]` | **同步后改写 Makefile**，每项 `"原串=>新串"`（字面量替换） |
| `exclude` | `[]` | `dirs` 含 `"*"` 时排除的条目 |
| `target` | `.` | 落地目录（`.` = 仓库根目录） |
| `as_package` | `false` | **上游整棵树就是一个包**，全部落到 `target` 目录内（先清空再拷） |
| `skip_if_not_newer` | `true` | **版本闸门**，见下 |
| `version_vars` | `["PKG_VERSION","PKG_UPSTREAM_VERSION","GEOIP_VER","GEOSITE_VER"]` | 参与版本比较的变量 |

**行为**：按 `ref` 拉上游 commit SHA，SHA 没变就跳过；变了才下载。

* **默认模式**（`as_package: false`）：每个条目落到 `target/<条目>`，逐条 `rm -rf` 后重拷，
  保证上游删除的文件不残留。
* **`as_package: true`**：上游仓库**本身就是一个 OpenWrt 包**（如 LuCI 主题），
  整棵树落到 `target` 目录内，**先清空 `target` 再拷**。
  版本闸门以 `target/Makefile` 整包判定一次，
  **判定为“忽略”时不会动本地目录**（不会先删再跳）。

```json
{
  "name": "luci-theme-material3",
  "repo": "KawaiiHachimi/luci-theme-material3",
  "ref": "main",
  "as_package": true,
  "target": "luci-theme-material3",
  "exclude": [".github", "Readme.md", "imgs"]
}
```

---

## B. 版本 / 哈希自动更新（`packages`）

### 策略 1：`tarball` —— 源码包（最常见）

> `source: "release"` 时若取不到 Release，**自动回退到 tag**。
> `XTLS/Xray-core` 这类只打 tag 的仓库必须靠回退。

```json
{
  "name": "sing-box",
  "repo": "SagerNet/sing-box",
  "makefile": "sing-box/Makefile",
  "strategy": "tarball",
  "source": "release",
  "include_prerelease": true,
  "tag_prefix": "v",
  "version_var": "PKG_UPSTREAM_VERSION",
  "hash_var": "PKG_HASH",
  "source_url": "https://codeload.github.com/SagerNet/sing-box/tar.gz/v${VERSION}?"
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `makefile` | `<name>/Makefile` | 目标 Makefile |
| `source` | `release` | `release` = 跟 Release；`tag` = 跟 Tag |
| `include_prerelease` | `true` | 是否包含 pre-release |
| `tag_prefix` | `""` | 剥掉的前缀，`v26.10.21` → `26.10.21` |
| `version_regex` | — | bash 正则，**组1 = 版本，组2（可选）= `PKG_RELEASE`**；优先于 `tag_prefix` |
| `version_var` | `PKG_VERSION` | 版本写到哪个变量（VIKINGYFY 的 sing-box 用 `PKG_UPSTREAM_VERSION`） |
| `hash_var` | `PKG_HASH` | 校验值写到哪个变量 |
| `source_url` | `https://codeload.github.com/${REPO}/tar.gz/${TAG}` | 下载地址模板 |
| `reset_release_on_change` | `false` | 版本变化时把 `PKG_RELEASE` 归 1 |
| `skip_if_not_newer` | `true` | 版本闸门 |

> ⚠️ `source_url` **必须和 Makefile 里 `PKG_SOURCE_URL` 的实际下载地址一致**，
> 否则算出的 `PKG_HASH` 和 OpenWrt 校验值对不上。
>
> ⚠️ `version_var` 指到的变量**只改第一处赋值**，后续的
> `PKG_VERSION:=$(subst …)` 这类派生式不会被碰。

**已配置（12 个）**：`xray-core` `xray-plugin` `v2ray-plugin` `sing-box` `hysteria`
`geoview` `ipt2socks` `microsocks` `mosdns` `geo2txt`

> 已移除 `shadow-tls` / `shadowsocks-rust` —— sing-box 与 xray-core 默认已内置同类能力，无需重复。

> `mosdns` ← `IrineSistiana/mosdns`；`geo2txt` ← `sbwml/geo2txt`（注意它无 `v` 前缀，
> `tag_prefix: ""`）。

### 策略 2：`assets` —— 多架构预编译 / geodata

一次性下载多个资源，**逐个算 SHA256**，按 `anchor` 定位写回对应的 `PKG_HASH` / `HASH` 行。

```json
{
  "name": "chinadns-ng",
  "repo": "zfl9/chinadns-ng",
  "makefile": "chinadns-ng/Makefile",
  "strategy": "assets",
  "version": { "repo": "zfl9/chinadns-ng", "source": "release", "tag_prefix": "" },
  "assets": [
    {
      "id": "chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "anchor": "PKG_ARCH:=chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "asset": "chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto",
      "url": "https://github.com/zfl9/chinadns-ng/releases/download/${VERSION}/${ASSET}?",
      "hash_var": "PKG_HASH"
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `version` | 包级版本来源；也可用 `version_var` 指定写入的变量 |
| `assets[].id` | 资源标识，用于日志与状态 |
| `assets[].anchor` | **字面量锚点**，定位到该资源所在块的起始行 |
| `assets[].asset` | 文件名，用于 `${ASSET}`；省略时取 `id` |
| `assets[].url` | 下载地址模板 |
| `assets[].hash_var` | 校验变量名，默认 `PKG_HASH`（geodata 用 `HASH`） |
| `assets[].ver_anchor` / `ver_line` | 可选，顺带更新版本变量（如 `GEOIP_VER`） |
| `assets[].version` | 可选，该资源单独的版本来源 |

**已配置（3 个）**：`chinadns-ng`（14 个唯一资源） `naiveproxy`（21 个架构）
`v2ray-geodata`（`geoip.dat` / `geosite.dat`）

### 策略 3：`notify` —— 只提醒，不自动改

用于**源码内嵌**（`dns2socks`、`shadowsocksr-libev`）或 **git-commit 型**
（`simple-obfs` `tcping` `smartdns` `mihomo-meta` `axonhub`）
以及 **`luci.mk` 型 LuCI 插件/主题**（`luci-app-*` / `luci-theme-*`，无 `PKG_HASH`）。
`PKG_MIRROR_HASH` 是 OpenWrt 对 git 仓库打包后的镜像哈希，本地无法可靠复现，
硬写会让构建失败，所以只做提醒。

`repo` 留空 = 不轮询上游（由 `sources` 的源码同步维护），仅登记一笔。

---

## ⚠️ 版本闸门（`skip_if_not_newer`）

> **上游版本没有本地已算出的版本高，就忽略这个包的同步。**

这是为了避免上游回退 / 上游滞后 / 你自己抬过版本时被覆盖。

| 场景 | 行为 |
|---|---|
| 上游 `2.0.1` vs 本地 `2.0.0` | ✅ 同步 |
| 上游 `2.0.0` vs 本地 `2.0.0` | ⏭️ 忽略（不重复拉取） |
| 上游 `1.9.9` vs 本地 `2.0.0` | ⏭️ **忽略，不降级** |
| 本地无版本号 | ✅ 同步 |
| 值是 `$(subst …)` 派生式 | ✅ 同步（无法比较则放行） |

**多版本变量**（源码同步）：比较 `PKG_VERSION` / `PKG_UPSTREAM_VERSION` /
`GEOIP_VER` / `GEOSITE_VER` 一组变量 —— **只要有一个上游严格更新就同步**，
全部不更高才忽略。这样 `v2ray-geodata`（靠 `GEOIP_VER`/`GEOSITE_VER` 版本化）
也能正确判定。

* 想强制覆盖：`bash update.sh --force`
* 想关掉某个包的闸门：配置里写 `"skip_if_not_newer": false`

### 版本比较规则

点分段逐段数字比较（`26.10.21 > 26.9.15`，`1.14.3 > 1.9.9`）；
遇到非数字段退化为字符串比较。

---

## 🛡️ 容错（CI 里很重要）

* **Release 拿不到就回退到 tag**：有些仓库**只打 tag 不发 GitHub Release**
  （如 `XTLS/Xray-core`，`/releases` 返回空数组）。以前这会让包失败；
  现在 `source: "release"` 会先取 Release，取不到自动回退 `/tags`。
  实测 `xray-core` `hysteria` `geoview` `naiveproxy`
  六个仓库都靠回退才能解析。
* **单包失败不拖垮整次同步**：拿不到版本、下载失败、Makefile 缺失都只告警并跳过，
  其余包照常更新、照常 commit。需要硬失败（比如在 release 流水线里）加 `--strict`。
* **`version_regex` 未命中就跳过**：不把错误版本写进状态或推送
  （如 `gecoosac` 的 `^gecoosac-(.+)$` 碰上 `apk-packages-arm64`）。
* **`git push` 重试 3 次**：同步期间上游可能有新提交，先 `pull --rebase` 再推。

---

## 模板占位符

| 占位符 | 含义 |
|---|---|
| `${REPO}` | `owner/repo` |
| `${TAG}` | 上游 tag 原文（如 `v26.10.21`） |
| `${VERSION}` | 推导出的版本号（如 `26.10.21`） |
| `${RELEASE}` | `version_regex` 第 2 捕获组（如 `PKG_RELEASE`） |
| `${ASSET}` | 资源文件名 |
| `$(PKG_VERSION)` | 同 `${VERSION}`，方便直接抄 Makefile 写法 |

---

## 推送通知（可选）

配置即生效，留空则跳过。**建议用环境变量，不要写死在脚本里。**

```bash
export TELEGRAM_BOT_TOKEN="***"
export TELEGRAM_CHAT_ID="123456789"

export WXPUSHER_APP_TOKEN="***"
export WXPUSHER_UIDS="UID_xxx,UID_yyy"
export WXPUSHER_TOPIC_IDS="123,456"
```

---

## GitHub Actions 自动同步

1. **推到 GitHub**：`git init && git add . && git commit -m init && git push`
2. **（可选）Secrets**：`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` /
   `WXPUSHER_APP_TOKEN` / `WXPUSHER_UIDS` / `WXPUSHER_TOPIC_IDS`
   （`GITHUB_TOKEN` 自动提供）
3. **触发**：`schedule`（每 6 小时）/ `workflow_dispatch`（手动，可选 force/only/commit|pr）/
   `push`（改 `config/` 或脚本时）
4. **落地**：`commit` 直推（带 `[skip ci]` 防递归）或 `pr` 开分支审核

---

## 🔨 GitHub Actions 编译插件

`.github/workflows/build.yml` —— 用 **OpenWrt SDK** 在 Actions 里交叉编译插件，
产物（`.ipk` / `.apk`）作为 artifact 下载。

仓库 → **Actions → Build Packages → Run workflow**

### 选平台（默认 X86_64）

| 选项 | 说明 |
|---|---|
| **`x86/64`** | **X86_64（默认）** |
| `x86/generic` | X86 32 位 |
| `armsr/armv8` | AArch64 通用 |
| `armsr/armv7` | ARMv7 通用 |
| `rockchip/armv8` | Rockchip RK33xx / RK35xx |
| `bcm27xx/bcm2711` | 树莓派 4 / 5 (aarch64) |
| `bcm27xx/bcm2710` | 树莓派 2 / 3 |
| `mediatek/filogic` | MTK Filogic (aarch64) |
| `ramips/mt7621` | MTK MT7621 (mipsel) |
| `ramips/mt76x8` | MTK MT76x8 (mipsel) |
| `ath79/generic` | Atheros AR7xxx (mips) |
| `qualcommax/ipq807x` | 高通 IPQ807x (aarch64) |
| `qualcommax/ipq60xx` | 高通 IPQ60xx (aarch64) |
| `sunxi/cortexa8` | 全志 H3 |

> ⚠️ 旧名 `ipq807x/generic` 在新 OpenWrt 已废弃（并入 `qualcommax`），
> snapshot 与 25.12.x 都没有该 target 的 SDK，选它必失败。已改成 `qualcommax/ipq807x`。

### 选编译哪些插件

**① `plugin` —— 下拉直接点名（35 项）**

下拉里是仓库内**全部 34 个插件** + `all`（默认）。选中某一个就只编它。

**② `preset` —— `plugin=all` 时按组批量**

| preset | 内容 |
|---|---|
| **`all`** | **全部（默认，再减去 `exclude`）** |
| `luci-app` | 所有 `luci-app-*` |
| `theme` | 所有 `luci-theme-*` |
| `proxy-core` | `xray-core` `sing-box` `hysteria` `mihomo-meta` `naiveproxy` `chinadns-ng` `mosdns` `dae-box` 等 15 个 |
| `passwall` | passwall 全家桶 19 个（luci-app + 全部依赖） |
| `nikki` | nikki 全家桶 3 个 |
| `mosdns` | `luci-app-mosdns` `mosdns` `geo2txt` |
| `custom` | 自己填，用 `packages` 输入 |

**③ `exclude` —— 默认不编译的包**

```
axonhub  luci-app-axonhub
```

> 这 2 个默认跳过（`axonhub` / `luci-app-axonhub` 要跑 Node.js + pnpm 前端构建，很慢）。
>
> **只对批量 preset 生效** —— 你显式点名就不拦：
> * 在 `plugin` 下拉里选中它们 → 照常编译
> * 在 `custom` 的 `packages` 里写上它们 → 照常编译
>
> 想让它们回到默认编译，把 `exclude` 留空即可。

`custom` 时在 `packages` 里填包名，**空格或逗号分隔**，例如：

```
luci-app-passwall, xray-core, sing-box
```

### 其他参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `openwrt_version` | `snapshot` | 也可填 `25.12.6` / `24.10.5` |
| **`mirror`** | 空 | **下载镜像**，留空则自动依次尝试官方 + 国内镜像 |
| `upload_all` | `false` | 开启则连 `-dbg` / `-dev` 一起上传 |
| **`build_mode`** | `full` | **编译范围**：`full` 完整编译 / `new-commits` 只编新提交改动的包 |
| **`upload_release`** | `true` | **把产物上传到 GitHub Releases**（滚动 tag，每次覆盖） |

### `build_mode`：完整编译 vs 新提交编译

* **`full`** —— 把 `plugin`/`preset`/`exclude` 解析出来的包全编一遍。
* **`new-commits`** —— 只编**新提交改动到的包**。
  1. 读上一次 Release 里 `build-info.txt` 的 `commit=<sha>`
  2. `git diff --name-only <sha>..HEAD` 取改动到的第一级目录（即包目录）
  3. 跟本次解析出的列表求交集，只编交集
  * 首次构建 / 拿不到上次 commit / 该 commit 不在本地历史 → **自动退回完整编译**
  * 没有任何改动 → 直接跳过，不浪费机器
  * checkout 用了 `fetch-depth: 0`，不然 git diff 拿不到历史

### 产物发布到 GitHub Releases

每次编译完把 `.ipk`/`.apk` 传到**按平台滚动的 Release**：

```
tag   packages-<openwrt>-<target>-<subtarget>
例     packages-snapshot-x86-64
       packages-25.12.6-armsr-armv8
```

同名 tag 每次覆盖（`gh release upload --clobber`），用户永远拿最新。
Release 正文是 `build-info.txt`：commit、时间、平台、编译了哪些包、各自成败。
那个 `commit=` 就是 `new-commits` 模式的 diff 基准。

不需要就把 `upload_release` 设为 `false`（仍然会传 Actions 的 artifact）。

> `snapshot` 的 SDK 文件名**不带版本号**（`openwrt-sdk-x86-64_gcc-…`），
> 正式版则带（`openwrt-sdk-25.12.6-x86-64_gcc-…`）。脚本从目录列表正则匹配，
> 两种写法都能解析。

### 实现要点

* **`axonhub` / `luci-app-axonhub` 的依赖自动补全**：
  `axonhub` 的 `PKG_BUILD_DEPENDS:=golang/host node/host node-pnpm/host`，
  但 **openwrt/packages 的 `lang/` 下没有 `node-pnpm`**（只有 `node` / `node-yarn`），
  make 直接 `No rule to make target`。而且它的前端要跑 `pnpm install` / `pnpm run build`。
  两步解决：
  1. **主动装工具链**：列表里有 axonhub 就装 `nodejs npm` + `sudo npm install -g pnpm`
  2. **`tools/auto-deps.sh` 自动生成宿主包存根**：扫描所有 `PKG_BUILD_DEPENDS` 里的
     `<name>/host`，发现 SDK 里没有就生成 `package/<name>/Makefile`（`HostBuild`），
     存根的 `Host/Compile` 按 hint 表装真工具（`node-pnpm`→`npm i -g pnpm`，
     `yarn`→`npm i -g yarn`，`rust`→rustup，…）。
     **其它包缺宿主工具也会被同样补齐**，不只 axonhub。
  * 还有一层**失败自愈**：编译失败时扫日志（`pnpm: not found` / `node: not found` /
    `cargo: not found` / `No rule to make target.*node-pnpm`），装完自动重试一次。
* **SDK 下载容灾**：`downloads.openwrt.org` **会偶发 502 Bad Gateway**（实测碰上过），
  只拉它一个就会直接挂。现在：
  1. **镜像兑底**：依次试 `downloads.openwrt.org` → `mirrors.tuna.tsinghua.edu.cn/openwrt`
     → `mirrors.ustc.edu.cn/openwrt`，哪个先给出 SDK 就用哪个
  2. **每个镜像重试 3 次**（带退避），下载本身再重试 5 次
  3. **可用 `mirror` 输入指定镜像**，跳过自动探测
  4. 全部失败时**打印试过的地址 + 可能原因**（旧名 `ipq807x`→`qualcommax` 等）
* **修了一个 bash 大坑**：原写法
  ```bash
  SDK_FILE=$(curl … | grep … | sort -u | head -1)
  ```
  在 `set -euo pipefail` 下有两处会**先杀进程、连报错都没机会打**：
  * `curl --fail` 遇 5xx 返回非零 → 赋值语句返回非零 → `set -e` 直接退出
  * `head -1` 提前关管道 → 上游 `sort` 收 SIGPIPE 退 141 → `pipefail` 把它带出来
  现改为 `| sed -n '1p'`（不关管道）+ `|| true` + 独立判空后 `exit 1`，
  **错误信息一定能打出来**。
* **SDK 文件名动态解析**：`openwrt-sdk-<ver>-<target>-<subtarget>_gcc-<gcc>_musl.Linux-x86_64.tar.zst`
  里的 GCC 版本会随 OpenWrt 版本变（25.12 是 `gcc-14.3.0`，24.10 是 `gcc-13.3.0`），
  硬编码必失效。改为**拉目录列表正则匹配**，任何版本/平台都能解析。
  snapshot 的文件名**不带版本号**（`openwrt-sdk-x86-64_gcc-…`），两种写法都吃得下。
* **make target 名回退**：make 的 target 用 build target 名（通常是目录名），
  但少数包 `PKG_NAME` 与目录不一致（如 `xray-core` 目录 vs `PKG_NAME:=Xray-core`）。
  拿到 `No rule to make target` 时自动改用 `PKG_NAME` 重试。
  遇到**派生式**（如 `luci-app-eqosplus` 的 `PKG_NAME:=luci-app-$(THEME_NAME)`，含 `$`）
  则跳过回退，避免拿 `luci-app-$(THEME_NAME)` 去当 make target。
* **feed 去重要清两层**：`./scripts/feeds install -a` 装出来的是**符号链接**，
  早期用 `find -type d` 过滤导致删不掉，同名包会报 "redefining package"。
  现在两层都清，保证**一律用本仓库的版本**：
  1. `package/feeds/<feed>/<name>` —— feeds 装出来的符号链接
  2. `feeds/<feed>/<cat>/<name>` —— **feed 源目录本身**
     （如 `feeds/packages/net/sing-box`，不删的话 make 仍会扫到 OpenWrt 自带的那份）
* **sing-box 专项检查**：注入后会打印 `feeds/packages/net/sing-box` 是否已删、
  扫描路径里是否只剩本仓库那份，并对**每个**注入的包做唯一性校验。
* **产物只留本仓库的插件（含语言包）**：SDK 编译会把 feed 依赖（`coreutils` / `golang` / `lua` /
  `luci-base`…）也顺带编出来，那些不属于本仓库。打包与 Release 上传前会用
  包目录做**白名单过滤**，非本仓库的依赖包一律丢弃。
  **语言包 `luci-i18n-<名>-<lang>` 会一并保留** —— `luci.mk` 生成语言包时把
  `luci-app-` / `luci-theme-` 前缀去掉（`luci-app-passwall2` → `luci-i18n-passwall2-zh-cn`），
  所以白名单要按「去前缀后的名字」多匹配一次，否则语言包会被整批误丢。
  日志会报 `保留本仓库插件 N 个，丢弃非本仓库依赖包 M 个`。
* **`.ipk` / `.apk` 都收**：OpenWrt 25.x 换成 `apk` 包管理，24.x 及以前是 `ipk`。
* **单包失败不拖垮整个 job**：逐包编译，失败的记进 `build-result.txt` 并在
  Summary 里列出，产物与日志仍会上传；全部失败则 job 标红。
* **失败早退**：包列表解析放在下载 SDK **之前**，填错包名不会浪费十分钟。
* **产物**：
  * `packages` —— 编译出的 `.ipk`/`.apk`
  * `build-logs` —— 每个包一份完整 `V=s` 编译日志（失败时排查用）

### 本地跑同样的事

```bash
# 1. 下 SDK（以 x86/64 + 25.12.6 为例）
BASE=https://downloads.openwrt.org/releases/25.12.6/targets/x86/64
SDK=$(curl -sL "$BASE/" | grep -oE 'openwrt-sdk-[^"<]+\.Linux-x86_64\.tar\.(zst|xz)' | sort -u | head -1)
curl -LO "$BASE/$SDK"

# 2. 解压 + feeds
mkdir sdk && tar --zstd -xf "$SDK" -C sdk --strip-components=1
cd sdk && ./scripts/feeds update -a && ./scripts/feeds install -a

# 3. 放包 + 编译
cp -a ../xray-core ../sing-box package/
make defconfig
make package/xray-core/compile -j$(nproc) V=s

# 4. 产物
ls bin/packages/*/*/*.ipk bin/packages/*/*/*.apk 2>/dev/null
```

---

## 状态文件

```
.state/
├── source-<name>.json     # 上游 commit + 已同步 / 已忽略的条目
└── pkg-<name>.json        # tag / version / hash 明细
```

---

## 自测

```bash
bash test/test-write.sh
```

覆盖：Makefile 写入（缩进保留、只改第一处、不碰 `$(subst)` 派生式）、
多架构锚点替换（含重复锚点）、**原值写回逐字节一致的回环测试**、
版本比较、版本闸门、字面量判定、模板展开。

---

## FAQ

**Q：`chinadns-ng` / `naiveproxy` 这种多架构的怎么办？**
A：`assets` 策略逐个下载每个 `PKG_ARCH` / `ARCH_PREBUILT` 对应文件算 hash。
同一 `PKG_ARCH` 出现多次（如 arm v6 与 v7 无 FPU 共用一个二进制）会全部一起更新。

**Q：为什么 `sing-box` 的 `PKG_VERSION` 是 `$(subst …)`？**
A：那是 VIKINGYFY 的写法 —— `PKG_UPSTREAM_VERSION` 存上游原版（如 `1.15.0-alpha.12`），
`PKG_VERSION` 在 make 时把 `-alpha.` 转成 `_alpha` 以满足 APK 的预发布后缀格式。
工具通过 `version_var: "PKG_UPSTREAM_VERSION"` 只写上游版本变量，派生式原样保留。

**Q：`simple-obfs` / `tcping` / `smartdns` / `mihomo-*` 为什么不自动更新？**
A：`PKG_SOURCE_PROTO:=git` + `PKG_MIRROR_HASH` / `PKG_SOURCE_VERSION` 型。
镜像哈希本地无法可靠复现，只做版本提醒，避免写错哈希导致构建失败。

**Q：想再加一个上游？**
A：`sources` 里加一条即可：

```json
{ "name": "luci-app-xxx", "repo": "someone/luci-app-xxx",
  "ref": "main", "dirs": ["luci-app-xxx"], "target": "." }
```

**Q：GitHub API 限流？**
A：设置 `GITHUB_TOKEN`。Actions 已自动用 `secrets.GITHUB_TOKEN`，
本地建议用 PAT（勾 `public_repo` 即可）。

**Q：能只跑一半吗？**
A：`--sync-source` 只同步源码，`--skip-source` 只更新版本哈希，
`--only <name>` 处理单项，`--force` 绕过缓存与版本闸门。
