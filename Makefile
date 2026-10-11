ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WeChatFold

WeChatFold_FILES = WeChatFold.m
WeChatFold_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unsupported-availability-guard
WeChatFold_FRAMEWORKS = UIKit Foundation
WeChatFold_LDFLAGS = -Wl,-segalign,4000
WeChatFold_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
