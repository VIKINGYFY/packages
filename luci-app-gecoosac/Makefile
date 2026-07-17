# Copyright (C) 2024 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-gecoosac
PKG_VERSION:=20260717
PKG_RELEASE:=2
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

LUCI_TITLE:=LuCI Support for gecoosac
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +gecoosac
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/gecoosac
/etc/gecoosac
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
