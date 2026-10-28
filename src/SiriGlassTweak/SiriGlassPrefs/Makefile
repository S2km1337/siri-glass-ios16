export THEOS ?= $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SiriGlassPrefs
SiriGlassPrefs_FILES = SiriGlassPrefsRootListController.m
SiriGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
SiriGlassPrefs_FRAMEWORKS = UIKit
SiriGlassPrefs_CFLAGS = -fobjc-arc
SiriGlassPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
