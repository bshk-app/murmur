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

# murmur-cli — same MurmurKit core as the app. `swift build` is flaky at emitting
# mlx-swift's Cmlx metallib bundle in a fresh checkout, so copy a known-good one
# next to the binary (app DerivedData, else the main mlx-audio-swift .build).
KIT_DEBUG   = MurmurKit/.build/debug
CMLX_BUNDLE = mlx-swift_Cmlx.bundle
CMLX_SRC := $(firstword $(wildcard $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Debug/$(CMLX_BUNDLE)) $(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/debug/$(CMLX_BUNDLE)))

cli:
	cd MurmurKit && swift build --product murmur-cli
	@if [ ! -e "$(KIT_DEBUG)/$(CMLX_BUNDLE)/Contents/Resources/default.metallib" ]; then \
		if [ -n "$(CMLX_SRC)" ]; then cp -R "$(CMLX_SRC)" "$(KIT_DEBUG)/" && echo "→ copied metallib bundle next to murmur-cli"; \
		else echo "WARN: no metallib bundle found — run 'make build' (the app) once to produce it"; fi; \
	fi

run-cli: cli
	"$(KIT_DEBUG)/murmur-cli"

clean:
	rm -rf build Murmur.xcodeproj Murmur.xcworkspace Derived MurmurKit/.build
