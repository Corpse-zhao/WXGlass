include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WXGlass
WXGlass_FILES = Tweak.x
WXGlass_CFLAGS = -fobjc-arc

ADDITIONAL_CFLAGS = -std=c++11

include $(THEOS_MAKE_PATH)/tweak.mk

ifeq ($(SIMULATOR),1)
    export TARGET = simulator:clang:latest:latest
    export ARCHS = x86_64
else
    export TARGET = iphone:clang:latest:latest
    export ARCHS = arm64 arm64e
endif

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
