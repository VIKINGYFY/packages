include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=20260909
PKG_RELEASE:=1

# Updated by Build-AxonHub.yml only after a successful daily release.
AXONHUB_BUILD_VERSION:=unstable-20260909
AXONHUB_UPSTREAM_COMMIT:=0786bb37940be9679ba0f48c536b2addabd53df8

ifeq ($(ARCH),aarch64)
  AXONHUB_ARCH:=arm64
  PKG_HASH:=ee3ee5e6492adfe1624cc5858ba709c3c70f9666f7530fab092d8de6c9292511
else ifeq ($(ARCH),x86_64)
  AXONHUB_ARCH:=amd64
  PKG_HASH:=78cd3767bdf2ebe0469b01b834fd655e935217c84464ae7a4ac620661c552008
else ifeq ($(ARCH),loongarch64)
  AXONHUB_ARCH:=loong64
  PKG_HASH:=a1274c9d32bc2a708c82240bc64d742b8bb6ab1d3f3d3af8bd2a1b3155a67eaf
else
  AXONHUB_ARCH:=unsupported
  PKG_HASH:=skip
endif

PKG_SOURCE:=$(PKG_NAME)-$(AXONHUB_BUILD_VERSION)-$(AXONHUB_UPSTREAM_COMMIT)-$(ARCH_PACKAGES)
PKG_SOURCE_URL:=https://github.com/VIKINGYFY/packages/releases/download/$(PKG_NAME)-$(AXONHUB_BUILD_VERSION)/$(PKG_NAME)_linux_$(AXONHUB_ARCH)?
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(AXONHUB_BUILD_VERSION)-$(AXONHUB_UPSTREAM_COMMIT)-$(ARCH)
UNPACK_CMD=mkdir -p $(1) && $(CP) $(DL_DIR)/$(PKG_SOURCE) $(1)/$(PKG_NAME)

PKG_LICENSE:=Apache-2.0 AND LGPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=VIKINGYFY

# The release binary is already stripped. Preserve it byte-for-byte because
# OpenWrt's sstrip corrupts the section table of this large static Go ELF.
RSTRIP:=:

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=AxonHub AI gateway ($(AXONHUB_BUILD_VERSION))
  URL:=https://github.com/looplj/axonhub
  DEPENDS:=@(aarch64||x86_64||loongarch64) +ca-bundle +zoneinfo-core +zoneinfo-asia
endef

define Package/$(PKG_NAME)/description
 AxonHub is an all-in-one AI gateway with an embedded management interface,
 API format translation, request tracing and provider load balancing.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/axonhub $(1)/usr/bin/axonhub
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
