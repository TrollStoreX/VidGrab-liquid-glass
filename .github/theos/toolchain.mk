# Linux 上用系统 clang + lld，而不是 theos 自带的 Darwin 交叉工具链
TARGET = iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS_MAKE_PATH)/null.mk
