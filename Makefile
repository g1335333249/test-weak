export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EDTProbe
EDTProbe_FILES = Tweak.xm
EDTProbe_CFLAGS = -fobjc-arc
EDTProbe_FRAMEWORKS = Foundation UIKit CoreLocation MapKit

include $(THEOS_MAKE_PATH)/tweak.mk
