#
# OpenWrt package: vmlinux-btf-builtin
#
# dae and honk depend on vmlinux-btf, which only installs on the exact kernel
# it was built for (official OpenWrt). A kernel that carries its own BTF, such
# as ImmortalWrt's, needs no blob and refuses that package; this empty one
# provides vmlinux-btf there instead. apk takes the real package wherever it
# installs, and this one only where it does not; once the real one becomes
# available, "apk upgrade vmlinux-btf-builtin" replaces this one with it. The
# pre-install check reports a kernel without BTF (a missing kmods repository)
# with that command; apk installs the package anyway, so the init scripts
# check again.
#
# This file is free software, licensed under the GNU General Public License v3
# or later.

include $(TOPDIR)/rules.mk

PKG_NAME:=vmlinux-btf-builtin
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/vmlinux-btf-builtin
  SECTION:=kernel
  CATEGORY:=Kernel
  TITLE:=Stands in for vmlinux-btf on a kernel with its own BTF
  PKGARCH:=all
  # A virtual provide with a priority: the real package wins wherever it
  # installs, and priority 0 is never picked by itself
  PROVIDES:=@vmlinux-btf
  DEFAULT_VARIANT:=1
endef

define Package/vmlinux-btf-builtin/description
 Satisfies the vmlinux-btf dependency of dae and honk on a kernel that
 carries its own BTF (/sys/kernel/btf/vmlinux), such as ImmortalWrt's.
 Its pre-install check reports a kernel without BTF.
endef

# Only the running kernel can be checked, not the one of an image being built
define Package/vmlinux-btf-builtin/preinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
[ -e /sys/kernel/btf/vmlinux ] && exit 0
echo "This kernel has no BTF of its own: add the kmods repository of this release and target, then run 'apk update && apk upgrade vmlinux-btf-builtin', which replaces it with vmlinux-btf." >&2
exit 1
endef

define Build/Compile
endef

define Package/vmlinux-btf-builtin/install
	true
endef

$(eval $(call BuildPackage,vmlinux-btf-builtin))
