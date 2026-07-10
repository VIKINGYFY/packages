# Copyright (C) 2026
#
# This is free software, licensed under the Apache License, Version 2.0.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-axonhub
PKG_VERSION:=1.0.0
PKG_RELEASE:=6

LUCI_TITLE:=LuCI support for AxonHub
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +axonhub
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/axonhub
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
