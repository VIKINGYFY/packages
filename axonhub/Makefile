include $(TOPDIR)/rules.mk

PKG_NAME:=axonhub
PKG_VERSION:=20260820
PKG_RELEASE:=1

# Updated by Build-AxonHub.yml only after a successful daily release.
AXONHUB_BUILD_VERSION:=unstable-20260820
AXONHUB_UPSTREAM_COMMIT:=34d344d1d5c49f01d26ed114372a7d30de102b26

ifeq ($(ARCH),aarch64)
  AXONHUB_ARCH:=arm64
  PKG_HASH:=0c88d5ff3fd1e1df6252d2872ff9486286a7c295d0c80d91a39f4286c3117c0f
else ifeq ($(ARCH),x86_64)
  AXONHUB_ARCH:=amd64
  PKG_HASH:=a05239bcb38e2ffa65ff58c0ce0c21e96c9f13c618bcbcfc38edc61c3bfa59b8
else ifeq ($(ARCH),loongarch64)
  AXONHUB_ARCH:=loong64
  PKG_HASH:=c990651f130c34e25db7a4f666aa2759278fd1dfb59e9037cde88c88a11687ab
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
