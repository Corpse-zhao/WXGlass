include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WXGlassPrefs
WXGlassPrefs_FILES = WXGlassPrefs.mm
WXGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
WXGlassPrefs_FRAMEWORKS = UIKit
WXGlassPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp WXGlassEntry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/WXGlass.plist$(ECHO_END)
