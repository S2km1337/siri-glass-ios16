export THEOS ?= $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Siri

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriGlassTweak
SiriGlassTweak_FILES = Tweak.x
SiriGlassTweak_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
SiriGlassTweak_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
