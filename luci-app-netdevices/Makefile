include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netdevices
PKG_VERSION:=1.1.0
PKG_RELEASE:=2

PKG_LICENSE:=MIT
PKG_MAINTAINER:=netdevices

LUCI_TITLE:=LuCI support for Online Devices (IPv4/IPv6/MAC/uptime/static lease/kick/limit/traffic)
LUCI_PKGARCH:=all
# 注意：**不能**写 +kmod-sch-htb / +kmod-cls-u32 —— 它们在多数目标上是
#   CONFIG_NET_SCH_HTB=y / CONFIG_NET_CLS_U32=y 编进内核的，不生成独立包，
#   硬依赖会直接报 “no such package” 装不上。改由运行时探测，UI 里给安装指引。
LUCI_DEPENDS:=+luci-base +jsonfilter +tc +ip-full

# ⚠️ 必须 chmod + **restart**（不是 reload）rpcd：
#   1) 可执行位在打包/传输途中可能丢，丢了 rpcd 就静默不加载插件
#   2) `rpcd reload` 只重读配置，**不重新扫描 /usr/libexec/rpcd/**；
#      只有 `restart` 才会把新插件注册成 ubus 对象。
#   否则前端报 "Object not found"，界面读不到设备。
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod 755 /usr/libexec/rpcd/netdevices 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
endef

# 实验功能开关（流量统计 / App 使用记录）持久化在这里，
# 这样 LuCI 里点「保存 / 应用与保存」后重启仍然生效。
define Package/$(PKG_NAME)/conffiles
/etc/config/netdevices
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
