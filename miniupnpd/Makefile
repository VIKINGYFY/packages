# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2006-2014 OpenWrt.org
# OpenWrt integration derived from the ImmortalWrt packages feed.

include $(TOPDIR)/rules.mk

PKG_NAME:=miniupnpd
PKG_VERSION:=20261101
PKG_RELEASE:=1
PKG_SOURCE_VERSION:=d7b1860faa8e99386009570d0216bdc3b5e121a7

PKG_SOURCE:=miniupnp-$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/miniupnp/miniupnp/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=fab93f53be390107e9ad6a44c8501ea74bde483d122a3cffd9fcfee2ceaf006c
PKG_BUILD_DIR:=$(BUILD_DIR)/$(if $(BUILD_VARIANT),$(PKG_NAME)-$(BUILD_VARIANT)/)miniupnp-$(PKG_SOURCE_VERSION)

PKG_MAINTAINER:=VIKINGYFY
PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=miniupnpd/LICENSE
PKG_CPE_ID:=cpe:/a:miniupnp_project:miniupnpd
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/version.mk

define Package/miniupnpd/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  DEPENDS:=+libcap-ng +libmnl +libuuid
  PROVIDES:=miniupnpd
  TITLE:=Lightweight UPnP IGD & PCP/NAT-PMP daemon
  URL:=https://miniupnp.tuxfamily.org/
endef

define Package/miniupnpd-iptables
  $(call Package/miniupnpd/Default)
  DEPENDS+=+firewall +IPV6:ip6tables +IPV6:libip6tc +iptables +libip4tc +libnetfilter-conntrack
  TITLE+= (iptables)
  VARIANT:=iptables
endef

define Package/miniupnpd-nftables
  $(call Package/miniupnpd/Default)
  DEPENDS+=+firewall4 +libnftnl
  TITLE+= (nftables)
  VARIANT:=nftables
  DEFAULT_VARIANT:=1
  CONFLICTS:=miniupnpd-iptables
endef

define Package/miniupnpd/conffiles/Default
/etc/config/upnpd
endef

Package/miniupnpd-iptables/conffiles = $(Package/miniupnpd/conffiles/Default)
Package/miniupnpd-nftables/conffiles = $(Package/miniupnpd/conffiles/Default)

define Package/miniupnpd/preinst/Default
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/miniupnpd ]; then
	/etc/init.d/miniupnpd stop || exit 1
fi
exit 0
endef

Package/miniupnpd-iptables/preinst = $(Package/miniupnpd/preinst/Default)
Package/miniupnpd-nftables/preinst = $(Package/miniupnpd/preinst/Default)

define Build/Prepare
	$(call Build/Prepare/Default)
	printf '%s\n' '$(VERSION_NUMBER)' | tr '() ' '_' >$(PKG_BUILD_DIR)/miniupnpd/os.openwrt
	printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' >$(PKG_BUILD_DIR)/miniupnpd/VERSION
endef

CONFIGURE_PATH:=miniupnpd
MAKE_PATH:=miniupnpd
CONFIGURE_ARGS = \
	--disable-fork \
	--disable-pppconn \
	--firewall=$(BUILD_VARIANT) \
	--igd2 \
	$(if $(CONFIG_IPV6),--ipv6) \
	--leasefile \
	--portinuse \
	--regex \
	--vendorcfg

TARGET_CFLAGS += $(FPIC)
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed

ifeq ($(BUILD_VARIANT),iptables)
ifeq ($(filter $(ARCH),mips mipsel),)
TARGET_CFLAGS += -flto
endif
endif

define Package/miniupnpd/install/Default
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/share/miniupnpd
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/miniupnpd $(1)/usr/sbin/miniupnpd
	$(INSTALL_BIN) ./files/miniupnpd.init $(1)/etc/init.d/miniupnpd
	$(INSTALL_CONF) ./files/upnpd.config $(1)/etc/config/upnpd
	$(INSTALL_DATA) ./files/miniupnpd.hotplug $(1)/etc/hotplug.d/iface/50-miniupnpd
	$(INSTALL_BIN) ./files/miniupnpd.defaults.migration $(1)/etc/uci-defaults/99-miniupnpd-migration
	$(INSTALL_BIN) ./files/miniupnpd.defaults $(1)/etc/uci-defaults/99-miniupnpd
	$(INSTALL_DATA) ./files/functions.sh $(1)/usr/share/miniupnpd/functions.sh
	$(INSTALL_BIN) ./files/firewall.include $(1)/usr/share/miniupnpd/firewall.include
	printf '%s\n' '$(BUILD_VARIANT)' >$(1)/usr/share/miniupnpd/backend
endef

define Package/miniupnpd-iptables/install
	$(call Package/miniupnpd/install/Default,$1)
	$(INSTALL_BIN) ./files/firewall3.include $(1)/usr/share/miniupnpd/firewall3.include
endef

define Package/miniupnpd-nftables/install
	$(call Package/miniupnpd/install/Default,$1)
	$(INSTALL_DIR) $(1)/usr/share/nftables.d
	$(CP) ./files/nftables.d/* $(1)/usr/share/nftables.d/
endef

$(eval $(call BuildPackage,miniupnpd-iptables))
$(eval $(call BuildPackage,miniupnpd-nftables))
