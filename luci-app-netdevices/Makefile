include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netdevices
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=netdevices

LUCI_TITLE:=LuCI support for Online Devices (IPv4/IPv6/MAC/uptime/static lease/kick/limit/traffic)
LUCI_PKGARCH:=all
# 不依赖 tc / kmod-ifb / iptables-nft / kmod-sch-htb / kmod-cls-u32。
# 防火墙仅用 fw4(nft)；限速有 tc 则用，无则代码层降级。
LUCI_DEPENDS:=+luci-base +jsonfilter

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/libexec/rpcd/netdevices 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
