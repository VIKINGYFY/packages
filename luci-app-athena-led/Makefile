include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-athena-led
PKG_VERSION:=0.4.0
PKG_RELEASE:=20260609

PKG_MAINTAINER:=Athena LED <https://github.com/haipengno1/athena-led>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI Support for JDCloud AX6600 LED Screen Control
LUCI_MAINTAINER:=$(PKG_MAINTAINER)
LUCI_DEPENDS:=+luci-base @aarch64
LUCI_DESCRIPTION:=LuCI support for JDCloud AX6600 LED Screen Control.

# Keep target package arch because root/usr/sbin/athena-led is a bundled aarch64 ELF.
LUCI_PKGARCH:=

define Package/$(PKG_NAME)/conffiles
/etc/config/athena_led
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
