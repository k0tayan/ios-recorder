THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iosrecorder
iosrecorder_FILES = $(wildcard src/*.m) $(wildcard src/*.xm)
iosrecorder_FRAMEWORKS = AVFoundation CoreMedia CoreVideo VideoToolbox AudioToolbox Photos Metal QuartzCore Foundation UIKit
iosrecorder_PRIVATE_FRAMEWORKS = IOSurface
iosrecorder_CFLAGS = -fobjc-arc -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

# --- Custom install targets ---
SSH_HOST ?= ipad
DEB = $(lastword $(sort $(wildcard packages/*.deb)))

.PHONY: deploy deploy-respring remove

deploy:
	@echo "[*] Copying .deb to $(SSH_HOST)..."
	scp $(DEB) $(SSH_HOST):/tmp/iosrecorder.deb
	@echo "[*] Installing on $(SSH_HOST)..."
	ssh $(SSH_HOST) "dpkg -i /tmp/iosrecorder.deb && rm /tmp/iosrecorder.deb"
	@echo "[*] Done. Respring the device to load the tweak."

deploy-respring: deploy
	@echo "[*] Respringing..."
	ssh $(SSH_HOST) "killall -9 SpringBoard"

remove:
	ssh $(SSH_HOST) "dpkg -r com.local.iosrecorder"
	@echo "[*] Uninstalled. Respring to take effect."
