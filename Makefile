THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
THEOS_DEVICE_IP = 192.168.1.145

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iosrecorder
iosrecorder_FILES = $(wildcard src/*.m) $(wildcard src/*.xm)
iosrecorder_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox AudioToolbox Metal QuartzCore Foundation UIKit
iosrecorder_PRIVATE_FRAMEWORKS = IOSurface
iosrecorder_CFLAGS = -fobjc-arc -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

# --- Custom install targets ---
SSH_HOST ?= ipad
DEB = $(lastword $(sort $(wildcard packages/*.deb)))

.PHONY: deploy remove
remove:
	ssh $(SSH_HOST) "dpkg -r com.local.iosrecorder"
	@echo "[*] Uninstalled. Respring to take effect."
