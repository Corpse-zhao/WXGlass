include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WXGlassPrefs
WXGlassPrefs_FILES = WXGlassPrefs.mm
WXGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
WXGlassPrefs_FRAMEWORKS = UIKit
WXGlassPrefs_PRIVATE_FRAMEWORKS = Preferences
WXGlassPrefs_CFLAGS = -fobjc-arc -Wall
# ⭐ Apple ld 不搜 SDK 的 PrivateFrameworks —— 私有框架必须显式 -F（血坑）
WXGlassPrefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
# Settings.plist 放进 bundle 的 Resources，供 loadSpecifiersFromPlistName 读取
WXGlassPrefs_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk

# 入口 plist 装到 PreferenceLoader 扫描目录（文件名任意，必须含 entry 包裹）
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp WXGlassEntry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/WXGlass.plist$(ECHO_END)
