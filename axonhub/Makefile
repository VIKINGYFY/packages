include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=1.0.0_beta5
PKG_RELEASE:=1

AXONHUB_UPSTREAM_VERSION:=1.0.0-beta5

ifeq ($(ARCH),aarch64)
  AXONHUB_ARCH:=arm64
  PKG_HASH:=789f1ed8500604c29faed9f2def06d1022b696da849d35644191a6d96d46c1c7
else ifeq ($(ARCH),x86_64)
  AXONHUB_ARCH:=amd64
  PKG_HASH:=fa8f764c559965d84c92908a2fc973effce5c569a56843e4771c8fc9c6496bfb
else ifeq ($(ARCH),loongarch64)
  AXONHUB_ARCH:=loong64
  PKG_HASH:=becbe50109fe3d6a0fd55ea2224ea4739cb95f81a2315e179f1e6fda15d734f0
else
  AXONHUB_ARCH:=unsupported
  PKG_HASH:=skip
endif

PKG_SOURCE:=$(PKG_NAME)_$(AXONHUB_UPSTREAM_VERSION)_linux_$(AXONHUB_ARCH).zip
PKG_SOURCE_URL:=https://github.com/looplj/axonhub/releases/download/v$(AXONHUB_UPSTREAM_VERSION)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(AXONHUB_UPSTREAM_VERSION)-$(ARCH)
UNPACK_CMD=mkdir -p $(1) && unzip -q $(DL_DIR)/$(PKG_SOURCE) axonhub LICENSE -d $(1)

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
  TITLE:=AxonHub AI gateway ($(AXONHUB_UPSTREAM_VERSION))
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
