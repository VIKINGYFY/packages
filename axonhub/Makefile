include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=1.0.0_beta4
PKG_RELEASE:=1

AXONHUB_UPSTREAM_VERSION:=1.0.0-beta4

ifeq ($(ARCH),aarch64)
  AXONHUB_ARCH:=arm64
  PKG_HASH:=d93437c8f4ebd248aa0d84b4c017aa1b2cb590feee94ac71230046ecc6c21b57
else ifeq ($(ARCH),x86_64)
  AXONHUB_ARCH:=amd64
  PKG_HASH:=676ef59b75e6a41059563bcbfd1285980f8f6a63e4e7c03900c76afab746b0ed
else ifeq ($(ARCH),loongarch64)
  AXONHUB_ARCH:=loong64
  PKG_HASH:=f33f3b2249fd16494b4b27227739887aa920ab823d74ea88f37023a4c9f7ded3
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
