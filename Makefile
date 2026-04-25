TARGET := iphone:clang:latest:7.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Lanxin

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = lanxincrack

lanxincrack_FILES = Tweak.x
lanxincrack_CFLAGS = -fobjc-arc
iCost_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
