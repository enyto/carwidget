ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsCarWidgetPrefs
AxsCarWidgetPrefs_FILES = $(wildcard *.m)
AxsCarWidgetPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsCarWidgetPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsCarWidgetPrefs_PRIVATE_FRAMEWORKS = Preferences
# Ships inside Library/Airaw/Widgets/Controls/AxsCarWidget.bundle, which Airaw loads as the
# module settings panel. No PreferenceLoader entry: Airaw is the entry point.
AxsCarWidgetPrefs_INSTALL_PATH = /Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/Prefs

# The panel is loaded lazily by Airaw; no PreferenceLoader host is involved.
AxsCarWidgetPrefs_CFLAGS += -Wno-objc-missing-super-calls

include $(THEOS_MAKE_PATH)/bundle.mk
