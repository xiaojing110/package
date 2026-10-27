include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netdevices
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=netdevices

LUCI_TITLE:=LuCI support for Online Devices (IPv4/IPv6/MAC/uptime/static lease)
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +jsonfilter

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