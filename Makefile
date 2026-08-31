include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mysub
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-mysub
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Advanced Subscription Parser for Momo
  DEPENDS:=+luci-compat +jq +curl +coreutils-base64
  PKGARCH:=all
endef

define Package/luci-app-mysub/description
  LuCI interface and subscription parser using the marker method ({all_subs}).
endef

define Build/Compile
endef

define Package/luci-app-mysub/install
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-mysub.json $(1)/usr/share/rpcd/acl.d/luci-app-mysub.json
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/mysub $(1)/etc/config/mysub
	$(INSTALL_DIR) $(1)/etc/mysub
	$(INSTALL_DATA) ./files/etc/mysub/template.json.example $(1)/etc/mysub/template.json.example
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/mysub.lua $(1)/usr/lib/lua/luci/controller/mysub.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/mysub.lua $(1)/usr/lib/lua/luci/model/cbi/mysub.lua
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/mysub-update.sh $(1)/usr/libexec/mysub-update.sh
endef

$(eval $(call BuildPackage,luci-app-mysub))
