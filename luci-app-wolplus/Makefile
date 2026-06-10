# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_VERSION:=1.1
PKG_RELEASE:=20260609
PKG_MAINTAINER:=sundaqiang
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI support for Wake on LAN +
LUCI_DEPENDS:=+luci-base +etherwake
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
