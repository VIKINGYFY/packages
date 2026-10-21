include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=20261022
PKG_RELEASE:=1
PKG_SOURCE_VERSION:=8bd3e9317811318e4c977d35053aec2bb5a135b7

PKG_SOURCE:=$(PKG_NAME)-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/looplj/axonhub/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=a39316a3ebd624c8b40176b9071919e93d619ae04670f2d6cc72cbe61132ae39
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
