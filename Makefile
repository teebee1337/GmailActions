TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Gmail

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GmailActions

GmailActions_FILES = Tweak.x
GmailActions_CFLAGS = -fobjc-arc -O2 -Wno-unused-function
GmailActions_LDFLAGS = -Wl,-no_fixup_chains
GmailActions_FRAMEWORKS = Foundation UIKit UserNotifications
GmailActions_CODESIGN_FLAGS = -S -Cadhoc -Icom.tb.gmailactions

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	find "$(THEOS_STAGING_DIR)" -type d -exec chmod 755 {} +
	find "$(THEOS_STAGING_DIR)" -type f \( -name "*.plist" -o -name "*.png" \) -exec chmod 644 {} +
	find "$(THEOS_STAGING_DIR)" -type f -name "*.dylib" -exec chmod 755 {} + -exec env CODESIGN_ALLOCATE="$(TARGET_CODESIGN_ALLOCATE)" "$(TARGET_CODESIGN)" -S -Cadhoc -Icom.tb.gmailactions {} +
