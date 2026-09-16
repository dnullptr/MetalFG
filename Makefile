THEOS_PACKAGE_SCHEME ?= rootless
TARGET ?= iphone:clang:latest:16.0
ARCHS ?= arm64 arm64e
DEBUG ?= 0
FINALPACKAGE ?= 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MetalFG

MetalFG_FILES = Source/Tweak.xm \
                Source/CoreMotionTracker.mm \
                Source/MetalFGWarper.mm \
                Source/MetalFGSynchronizer.mm \
                Source/MetalFGOverlay.mm

MetalFG_CFLAGS = -fobjc-arc -IHeaders -std=c++17 -O3 -Wall -Wno-unused-variable
MetalFG_FRAMEWORKS = Metal QuartzCore CoreMotion UIKit CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

# Post-processing: Compile Metal Shaders into default.metallib if the Metal compiler is available
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
METALLIB_DIR = $(THEOS_STAGING_DIR)/var/jb/Library/Application\ Support/MetalFG
else
METALLIB_DIR = $(THEOS_STAGING_DIR)/Library/Application\ Support/MetalFG
endif

before-package::
	@if command -v xcrun >/dev/null 2>&1 && xcrun -sdk iphoneos -find metal >/dev/null 2>&1; then \
		echo "[MetalFG] Compiling Shaders.metal into default.metallib..."; \
		mkdir -p "$(METALLIB_DIR)" "$(THEOS_PROJECT_DIR)/.theos/obj"; \
		(xcrun -sdk iphoneos metal -c Shaders/Shaders.metal -IHeaders -o "$(THEOS_PROJECT_DIR)/.theos/obj/Shaders.air" 2>/dev/null && \
		 xcrun -sdk iphoneos metallib "$(THEOS_PROJECT_DIR)/.theos/obj/Shaders.air" -o "$(METALLIB_DIR)/default.metallib" 2>/dev/null && \
		 echo "[MetalFG] Successfully generated $(METALLIB_DIR)/default.metallib") || \
		 echo "[MetalFG] Precompilation skipped; fallback embedded runtime MSL shaders will be used."; \
	else \
		echo "[MetalFG] Notice: Xcode metal compiler not found. Tweak will use embedded runtime MSL shaders."; \
	fi
