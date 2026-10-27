include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netdevices
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=netdevices

LUCI_TITLE:=LuCI support for Online Devices (IPv4/IPv6/MAC/uptime/static lease/kick/limit/traffic)
LUCI_PKGARCH:=all
# 注意：**不能**写 +kmod-sch-htb / +kmod-cls-u32 —— 它们在多数目标上是
#   CONFIG_NET_SCH_HTB=y / CONFIG_NET_CLS_U32=y 编进内核的，不生成独立包，
#   硬依赖会直接报 “no such package” 装不上。改由运行时探测，UI 里给安装指引。
LUCI_DEPENDS:=+luci-base +jsonfilter +tc +ip-full

include $(TOPDIR)/feeds/luci/luci.mk

# 安装后强制保证 rpcd 后端脚本可执行，并重新加载 rpcd
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/libexec/rpcd/netdevices 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature