ARCHS = arm64 arm64e
DEBUG = 0
FINALPACKAGE = 1

# The Airaw preference bundle hosts this panel, so it is installed inside a Control bundle.
# Plain `make package` therefore needs force mode, and scheme builds get a distinguishable
# file name because Theos would otherwise emit the same deb for every scheme.
FORCE_PACKAGE_NAME = yes
PACKAGE_BUILDNAME ?=

TARGET := iphone:clang:16.5:15.0
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsCarWidget

AxsCarWidget_FILES = $(wildcard Widget/Classes/*.m) $(wildcard Widget/Classes/*.x) $(wildcard Sources/*.m)
AxsCarWidget_CFLAGS = -fobjc-arc -I./Sources
AxsCarWidget_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore CoreLocation
AxsCarWidget_INSTALL_PATH = /Library/Airaw/Widgets/Controls
AxsCarWidget_INSTALL_NAME = AxsCarWidget
AxsCarWidget_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/bundle.mk

SUBPROJECTS += AxsCarWidgetPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	@install.exec "killall -9 Preferences 2>/dev/null || true"
