ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FPSBooster

FPSBooster_FILES = FPSBooster.x
FPSBooster_CFLAGS = -fobjc-arc -O3 -Wno-error -DOBJC_OLD_DISPATCH_PROTOTYPES=1
FPSBooster_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
