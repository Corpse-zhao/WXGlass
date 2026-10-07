TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# roothide 设备必须用 roothide 方案（rootless 会被 Sileo 拒装）
# 且必须使用 roothide/theos 分支的 Theos
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXGlass
WXGlass_FILES = Tweak.x WXGCommon.m WXGRecon.m WXGGlassView.m
WXGlass_CFLAGS = -fobjc-arc -Wall

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
