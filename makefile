ARCHS = arm64
TARGET = iphone:clang:14.5:11.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HungVnHack
HungVnHack_FILES = Tweak.xm
HungVnHack_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
