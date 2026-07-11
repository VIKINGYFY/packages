# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wolultra
PKG_VERSION:=1.0
PKG_RELEASE:=4
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

LUCI_TITLE:=LuCI support for WOL Ultra
LUCI_DEPENDS:=+luci-base +etherwake
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/wolultra
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
