#!/bin/sh
# build-vmlinux-btf.sh —— 从 OpenWrt 源码树/SDK 的内核头生成 vmlinux-btf 需要的 BTF blob
#
# 原理与 daeuniverse/openwrt-packages 的 CI 一致（也即 QiuSimons/vmlinux-btf 的做法）：
# 不编内核，只用几个桩单元（tools/btf-stubs/shadow_btf_*.c）把关键内核头拉进来，
# 让编译器吐出目标内核的精确 struct 布局（DWARF），再用 pahole 转成 .BTF 数据。
#
# 用法：
#   bash tools/build-vmlinux-btf.sh <openwrt根目录 | 已解压的SDK目录> [输出目录]
#
# 依赖：宿主机的 pahole（Debian/Ubuntu: apt install dwarves）
#
# 产物：
#   <输出目录>/vmlinux           BTF blob（就是 vmlinux-btf 包要的 VMLINUX_BTF_SRC）
#   <输出目录>/build-vmlinux-btf.env  里面带好 make 的参数，直接 source 后 make
#
# 之后：
#   make package/vmlinux-btf/compile \
#        VMLINUX_BTF_SRC=<输出目录>/vmlinux \
#        VMLINUX_BTF_VERSION=<内核版本> \
#        VMLINUX_BTF_KERNEL_RELEASE=<内核 release>
#
set -eu

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[ $# -ge 1 ] || usage
ROOT=$(cd "$1" && pwd)
OUT=${2:-$ROOT/build_dir/btf-out}
STUBS=$(cd "$(dirname "$0")/btf-stubs" && pwd)

command -v pahole >/dev/null 2>&1 || {
  echo "错误: 找不到 pahole，请先安装 dwarves（Debian/Ubuntu: apt install dwarves）" >&2
  exit 1
}

# ---------- 1. 找内核树 KDIR ----------
KDIR=""
for d in "$ROOT"/build_dir/target-*/linux-*/*/; do
  [ -f "$d/Makefile" ] && [ -d "$d/include" ] && KDIR=$d && break
done
if [ -z "$KDIR" ]; then
  echo "错误: 在 $ROOT/build_dir 下找不到已准备好的内核树" >&2
  echo "      先跑一次 'make target/linux/prepare'（SDK 则用自带的内核树）" >&2
  exit 1
fi
KDIR=${KDIR%/}
echo "内核树: $KDIR"

# ---------- 2. 找交叉工具链 ----------
CROSS=""
for g in "$ROOT"/staging_dir/toolchain-*/bin/*-openwrt-linux-musl-gcc; do
  [ -x "$g" ] && CROSS=${g%gcc} && break
done
if [ -z "$CROSS" ]; then
  echo "错误: 在 $ROOT/staging_dir/toolchain-* 下找不到交叉 gcc" >&2
  echo "      先跑一次 'make toolchain/install'" >&2
  exit 1
fi
CC=${CROSS}gcc
LD=${CROSS}ld
READELF=${CROSS}readelf
OBJCOPY=${CROSS}objcopy
echo "工具链: ${CROSS}"

# ---------- 3. 定内核架构 ----------
MACHINE=$("$CC" -dumpmachine)
case "$MACHINE" in
  x86_64-*)  LINUX_KARCH=x86 ;;
  aarch64-*) LINUX_KARCH=arm64 ;;
  *) echo "错误: 不支持的架构 $MACHINE" >&2; exit 1 ;;
esac
echo "内核 arch/$LINUX_KARCH   (target: $MACHINE)"

# ---------- 4. 编译桩单元 ----------
mkdir -p "$OUT"
rm -f "$OUT"/*.o "$OUT"/*.err

btf_cflags="-nostdinc
-isystem $("$CC" -print-file-name=include)
-D__KERNEL__
-include $KDIR/include/linux/kconfig.h"
for extra in "$KDIR/include/linux/compiler-version.h" "$KDIR/include/linux/compiler_types.h"; do
  [ -f "$extra" ] && btf_cflags="$btf_cflags -include $extra"
done
btf_cflags="$btf_cflags
-I$KDIR/arch/$LINUX_KARCH/include
-I$KDIR/arch/$LINUX_KARCH/include/generated
-I$KDIR/include
-I$KDIR/include/generated
-I$KDIR/arch/$LINUX_KARCH/include/uapi
-I$KDIR/arch/$LINUX_KARCH/include/generated/uapi
-I$KDIR/include/uapi
-I$KDIR/include/generated/uapi
-I$KDIR
-std=gnu11 -funsigned-char -fshort-wchar -fno-common -fno-PIE
-O2 -g -gdwarf-4 -fno-eliminate-unused-debug-types
-Wno-error -Wno-unused-function -Wno-unused-variable"

echo "编译 shadow_btf_core.c"
# shellcheck disable=SC2086
"$CC" $btf_cflags -c "$STUBS/shadow_btf_core.c" -o "$OUT/shadow_btf_core.o"

# 上游允许这两个失败：哪些头存在取决于目标的 .config，
# core 那个单元已经带上最要紧的类型
for unit in modules private; do
  if "$CC" $btf_cflags -c "$STUBS/shadow_btf_$unit.c" \
       -o "$OUT/shadow_btf_$unit.o" 2> "$OUT/shadow_btf_$unit.err"; then
    echo "编译 shadow_btf_$unit.c"
  else
    echo "警告: shadow_btf_$unit.c 对该目标编不过，跳过（上游也容忍）"
    sed -n '1,10p' "$OUT/shadow_btf_$unit.err" || true
    rm -f "$OUT/shadow_btf_$unit.o"
  fi
done

objs=$(ls "$OUT"/shadow_btf_*.o 2>/dev/null || true)
[ -n "$objs" ] || { echo "错误: 一个桩单元都没编出来" >&2; exit 1; }
echo "链接 $(echo "$objs" | wc -l) 个桩目标"
# shellcheck disable=SC2086
"$LD" -r -o "$OUT/shadow_btf.o" $objs

"$READELF" -S "$OUT/shadow_btf.o" | grep -q '\.debug_info' || {
  echo "错误: 桩目标没有 .debug_info，pahole 无从转换（编译参数缺 -g？）" >&2
  exit 1
}

# ---------- 5. pahole 编出 BTF ----------
if pahole --help 2>&1 | grep -q -- '--btf_encode_detached'; then
  pahole --btf_encode_detached="$OUT/vmlinux" "$OUT/shadow_btf.o"
else
  pahole -J "$OUT/shadow_btf.o"
  "$OBJCOPY" --dump-section .BTF="$OUT/vmlinux" "$OUT/shadow_btf.o"
fi

[ -s "$OUT/vmlinux" ] || { echo "错误: pahole 没产出 BTF 数据" >&2; exit 1; }

# ---------- 6. 校验 ----------
python3 - "$OUT/vmlinux" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 24:
    sys.exit("BTF blob 太短 (%d 字节)" % len(d))
magic, version, flags, hdr_len, type_off, type_len, str_off, str_len = struct.unpack("<HBBIIIII", d[:24])
if magic != 0xEB9F:
    sys.exit("不是 BTF blob: magic %s" % hex(magic))
if type_len == 0:
    sys.exit("BTF blob 里没有类型")
print("BTF ok: version=%d flags=%d hdr_len=%d type_len=%d str_len=%d size=%d"
      % (version, flags, hdr_len, type_len, str_len, len(d)))
PY

pahole -C sk_buff "$OUT/shadow_btf.o" > /dev/null || {
  echo "错误: 桩目标里没有 sk_buff，说明 pahole 没拿到 DWARF 类型" >&2
  exit 1
}

# ---------- 7. 版本号 ----------
KERNEL_RELEASE=$(cat "$KDIR/include/config/kernel.release" 2>/dev/null || true)
[ -n "$KERNEL_RELEASE" ] || KERNEL_RELEASE=$(sed -n 's/^VERSION = //p' "$KDIR/Makefile" | head -1)
KERNEL_VERSION=${KERNEL_RELEASE%%-*}

cat > "$OUT/build-vmlinux-btf.env" <<EOF
# source 本文件后再 make，参数已经填好
VMLINUX_BTF_SRC=$OUT/vmlinux
VMLINUX_BTF_VERSION=$KERNEL_VERSION
VMLINUX_BTF_KERNEL_RELEASE=$KERNEL_RELEASE
EOF

echo ""
echo "完成: $OUT/vmlinux"
echo "内核版本: $KERNEL_VERSION   release: ${KERNEL_RELEASE:-未知}"
echo ""
echo "接下来编包："
echo "  source $OUT/build-vmlinux-btf.env"
echo "  make package/vmlinux-btf/compile VMLINUX_BTF_SRC=\$VMLINUX_BTF_SRC \\"
echo "       VMLINUX_BTF_VERSION=\$VMLINUX_BTF_VERSION \\"
echo "       VMLINUX_BTF_KERNEL_RELEASE=\$VMLINUX_BTF_KERNEL_RELEASE"
