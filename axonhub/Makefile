include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=20261028
PKG_RELEASE:=1
PKG_SOURCE_VERSION:=0896305eeee89435049575d55a813f72901f703b

PKG_SOURCE:=$(PKG_NAME)-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/looplj/axonhub/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=e3d7fc80a305643793d01d4c82c44d33d1f7df7ffe7c1e08a51f882fa5a6960b
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_SOURCE_VERSION)

PKG_LICENSE:=Apache-2.0 AND LGPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=VIKINGYFY

PKG_BUILD_DEPENDS:=golang/host node/host node-pnpm/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/looplj/axonhub
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/axonhub
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG)/internal/build.Version=$(PKG_VERSION)-r$(PKG_RELEASE) \
	$(GO_PKG)/internal/build.Commit=$(PKG_SOURCE_VERSION)
GO_PKG_TAGS:=nomsgpack

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=AxonHub AI gateway ($(PKG_VERSION))
  URL:=https://github.com/looplj/axonhub
  DEPENDS:=@(aarch64||x86_64||loongarch64) +ca-bundle +zoneinfo-core +zoneinfo-asia
endef

define Package/$(PKG_NAME)/description
  AxonHub is an all-in-one AI gateway with an embedded management interface,
  API format translation, request tracing and provider load balancing.
endef

# Upstream frontend sources use CRLF; OpenWrt patch(1) cannot apply content
# hunks reliably. Normalize line endings and align UI cleanup defaults here
# (server-side defaults are applied by patches/170-*.patch).
FE_STORAGE_POLICY:=$(PKG_BUILD_DIR)/frontend/src/features/system/components/storage-policy-settings.tsx

define Build/Prepare
	$(call Build/Prepare/Default)
	tr -d '\r' < $(FE_STORAGE_POLICY) > $(FE_STORAGE_POLICY).tmp
	mv $(FE_STORAGE_POLICY).tmp $(FE_STORAGE_POLICY)
	sed -i \
		-e "s/{ resourceType: 'requests', enabled: false, cleanupDays: 3 }/{ resourceType: 'requests', enabled: true, cleanupDays: 1 }/" \
		-e "s/{ resourceType: 'usage_logs', enabled: false, cleanupDays: 30 }/{ resourceType: 'usage_logs', enabled: true, cleanupDays: 1 }/" \
		-e "s/{ resourceType: 'request_bodies', enabled: false, cleanupDays: 7 }/{ resourceType: 'request_bodies', enabled: true, cleanupDays: 1 }/" \
		-e "s/{ resourceType: 'response_bodies', enabled: false, cleanupDays: 7 }/{ resourceType: 'response_bodies', enabled: true, cleanupDays: 1 }/" \
		-e "s/{ resourceType: 'response_chunks', enabled: false, cleanupDays: 3 }/{ resourceType: 'response_chunks', enabled: true, cleanupDays: 1 }/" \
		-e "s/{ resourceType, enabled: false, cleanupDays: 7, ...patch }/{ resourceType, enabled: true, cleanupDays: 1, ...patch }/" \
		-e 's/useState(30)/useState(1)/g' \
		-e 's/useState(7)/useState(1)/g' \
		-e 's/useState(3)/useState(1)/g' \
		-e 's/?\.cleanupDays || 30/!.cleanupDays/g' \
		-e 's/?\.cleanupDays || 7/!.cleanupDays/g' \
		-e 's/?\.cleanupDays || 3/!.cleanupDays/g' \
		$(FE_STORAGE_POLICY)
endef

define Build/Compile
	( \
		set -e; \
		export PNPM_HOME="$(PKG_BUILD_DIR)/.pnpm-home"; \
		cd "$(PKG_BUILD_DIR)/frontend"; \
		pnpm install --frozen-lockfile; \
		pnpm run build; \
		cd "$(PKG_BUILD_DIR)"; \
		rm -rf internal/server/static/dist; \
		mkdir -p internal/server/static/dist; \
		cp -a frontend/dist/. internal/server/static/dist/; \
	)
	$(call GoPackage/Build/Compile)
endef

define Package/$(PKG_NAME)/install
	$(call GoPackage/Package/Install/Bin,$(1))
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
