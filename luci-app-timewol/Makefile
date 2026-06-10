# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-timewol
PKG_VERSION:=2.0
PKG_RELEASE:=20260610

LUCI_TITLE:=LuCI support for Timewol
LUCI_DEPENDS:=+luci-base +etherwake
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
