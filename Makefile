# Murmur — build helpers.
#
# Xcode 26 breaks explicitly-built modules for some SPM deps (swift-algorithms →
# RealModule), so builds disable them. arm64-only keeps the heavy MLX build short.

WORKSPACE = Murmur.xcworkspace
SCHEME    = Murmur
XCB = tuist xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) \
	-configuration Debug -destination 'generic/platform=macOS' \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO

.PHONY: gen build run clean

gen:
	tuist generate --no-open

build: gen
	$(XCB)

run: build
	open "$$(find $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Debug -maxdepth 1 -name Murmur.app | head -1)"

clean:
	rm -rf build Murmur.xcodeproj Murmur.xcworkspace Derived
