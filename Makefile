# Murmur — build helpers.
#
# Xcode 26 breaks explicitly-built modules for some SPM deps (swift-algorithms →
# RealModule), so builds disable them. arm64-only keeps the heavy MLX build short.

WORKSPACE = Murmur.xcworkspace
SCHEME    = Murmur
XCB = tuist xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) \
	-configuration Debug -destination 'generic/platform=macOS' -allowProvisioningUpdates \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO

.PHONY: gen build run clean cli run-cli

gen:
	tuist generate --no-open

build: gen
	$(XCB)

run: build
	open "$$(find $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Debug -maxdepth 1 -name Murmur.app | head -1)"

# murmur-cli — same MurmurKit core as the app, easy to run/profile from a terminal.
cli:
	cd MurmurKit && swift build --product murmur-cli
run-cli:
	cd MurmurKit && swift run murmur-cli

clean:
	rm -rf build Murmur.xcodeproj Murmur.xcworkspace Derived MurmurKit/.build
