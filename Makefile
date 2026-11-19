TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Arcaea
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FPSBooster

FPSBooster_FILES = FPSBooster.x
FPSBooster_FRAMEWORKS = Foundation UIKit QuartzCore Metal
FPSBooster_CFLAGS = -fobjc-arc -O3 -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
