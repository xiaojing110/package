# luci-app-honk 集成说明

来源：`https://github.com/daeuniverse/openwrt-packages`（main 分支，2026-11-01）
目标：`https://github.com/xiaojing110/package`（OpenWrt package feed）

## 新增包目录（仓库根目录）

| 目录 | 包名 | 说明 |
|---|---|---|
| `luci-app-honk/` | luci-app-honk | LuCI 管理页（`luci.mk` 型，arch=all） |
| `luci-lib-daeuniverse/` | luci-lib-daeuniverse | honk/dae 共用的 LuCI 页面库（状态开关 / 配置编辑器 / 日志，含 zh_Hans、zh_Hant） |
| `honk/` | honk | eBPF 透明代理引擎 honk-core（Rust + eBPF 交叉编译） |
| `vmlinux-btf/` | vmlinux-btf | 内核 BTF blob 包（需 `VMLINUX_BTF_SRC`，默认不编） |
| `vmlinux-btf-builtin/` | vmlinux-btf-builtin | 空包，`PROVIDES @vmlinux-btf`，内核自带 BTF 时代替 vmlinux-btf |

依赖关系：

```
luci-app-honk
├── luci-lib-daeuniverse  → luci-base + jshn + flock + coreutils-timeout
└── honk                  → libstdcpp + kmod-veth + kmod-sched-core + kmod-sched-bpf
                            + kmod-nft-core + kmod-nft-queue + kmod-nfnetlink-queue
                            + kmod-nf-conntrack + vmlinux-btf + v2ray-geoip + v2ray-geosite
```

`v2ray-geoip` / `v2ray-geosite` 由仓库里已有的 `v2ray-geodata/` 提供，无需额外添加。

## honk 源码

`honk/Makefile` 要求源码位于 `honk/src`（上游 tag `v0.1.0-beta.4`）：

```sh
git clone --branch v0.1.0-beta.4 https://github.com/daeuniverse/honk honk/src
```

本 zip 里已经带上了 `honk/src`，**解压即可直接编译**。
按上游约定 `honk/src` 不进 git（`.gitignore` 已忽略），提交到 GitHub 时不会被跟踪。

## 配置 / CI 改动

1. `config/packages.json`
   - `sources` 新增 `daeuniverse-honk`（`daeuniverse/openwrt-packages@main`，只取
     `honk` / `luci-app-honk` / `luci-lib-daeuniverse` / `vmlinux-btf` / `vmlinux-btf-builtin`）
   - `packages` 新增 5 条 `notify` 记录，`honk` 跟踪 `daeuniverse/honk` 的 tag

2. `.github/workflows/build.yml`
   - `plugin` 下拉新增：`honk`、`luci-app-honk`、`luci-lib-daeuniverse`、
     `vmlinux-btf`、`vmlinux-btf-builtin`
   - 新增 preset `honk` = `luci-app-honk luci-lib-daeuniverse honk vmlinux-btf-builtin`
   - 默认 exclude 追加 `vmlinux-btf`（没有 BTF blob 编不出来，需要时手动点名）
   - 新增步骤 `Checkout honk sources`：编 honk 时按 tag 检出 `honk/src`
   - `Install host toolchains (auto)` 追加 honk 的宿主工具链：
     Rust stable + eBPF nightly（版本取自 `rust-toolchain.toml` /
     `crates/honk-ebpf/rust-toolchain.toml`）、预编译 `bpf-linker`（版本与校验取自
     `honk/src/.github/ci/pins.env`）、clang / llvm / cmake / libclang

3. `.gitignore`
   - 新增 `honk/src/`

## 编译提示

- OpenWrt 25.x 产出 `.apk`，24.x 及以前产出 `.ipk`
- **`vmlinux-btf` 不是源码包**，它只是把一份预生成的 BTF blob 打成包，
  不传 `VMLINUX_BTF_SRC` 必然报错：

  ```
  vmlinux-btf: the BTF blob is missing at ''
  ```

  三条路：

  1. **想让 honk 真的能跑（推荐）** —— 生成 blob 再编：

     ```sh
     # 宿主机需要 pahole：apt install dwarves
     bash tools/build-vmlinux-btf.sh /home/thatdream/openwrt
     source build_dir/btf-out/build-vmlinux-btf.env
     make package/vmlinux-btf/compile \
          VMLINUX_BTF_SRC=$VMLINUX_BTF_SRC \
          VMLINUX_BTF_VERSION=$VMLINUX_BTF_VERSION \
          VMLINUX_BTF_KERNEL_RELEASE=$VMLINUX_BTF_KERNEL_RELEASE
     ```

     `tools/build-vmlinux-btf.sh` + `tools/btf-stubs/` 就是上游 CI 用的那套桩单元
     （源自 QiuSimons/vmlinux-btf），不需要编内核，只用内核头 + pahole。

  2. **只想把编译跑过去** —— 关掉 `vmlinux-btf`，改用 `vmlinux-btf-builtin`：

     ```sh
     make menuconfig   # Kernel → vmlinux-btf =n，vmlinux-btf-builtin =y
     # 或一次性：
     make -j$(nproc) CONFIG_PACKAGE_vmlinux-btf=
     ```

     `honk` 的 `+vmlinux-btf` 在 kconfig 里生成的是
     `select PACKAGE_vmlinux-btf-builtin if PACKAGE_vmlinux-btf<PACKAGE_honk`
     （已用 SDK 的 `scripts/package-metadata.pl config` 验证），所以 builtin 能顶上。
     ⚠️ 但 OpenWrt 25.12/6.12 的内核默认 `# CONFIG_DEBUG_INFO_BTF is not set`
     （`target/linux/generic/config-6.12:1318`），内核不带 BTF，
     `vmlinux-btf-builtin` 的 preinst 会拒绝安装，honk 跑不起来。

  3. **让内核自带 BTF** —— `make kernel_menuconfig` 里开
     `Kernel hacking → BTF Type Information → BPF Type Information`
     （`CONFIG_DEBUG_INFO_BTF=y`），宿主机装 `dwarves`，重编内核。
     这样 `/sys/kernel/btf/vmlinux` 存在，`vmlinux-btf-builtin` 可用，也不用造 blob。
