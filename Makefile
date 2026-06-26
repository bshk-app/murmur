# Murmur — build helpers.
#
# Builds are RELEASE: MLX-Swift in Debug is ~4-5x slower (RTF 2.6 vs 0.59 on the
# same clip) because every MLXArray call goes through unoptimised Swift wrappers
# → not realtime. Xcode 26 also breaks explicitly-built modules for some SPM deps
# (swift-algorithms → RealModule), so builds disable them; arm64-only keeps the
# heavy MLX build short.

WORKSPACE = Murmur.xcworkspace
SCHEME    = Murmur
XCB = tuist xcodebuild build -workspace $(WORKSPACE) -scheme $(SCHEME) \
	-configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO

.PHONY: gen build run clean cli run-cli bench

gen:
	tuist generate --no-open

build: gen
	$(XCB)

run: build
	-killall Murmur 2>/dev/null          # quit a stale background agent so `open` launches the fresh build
	@sleep 1                             # let it fully die — else `open` races LaunchServices (-600)
	open "$$(find $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Release -maxdepth 1 -name Murmur.app | head -1)"

# murmur-cli — same MurmurKit core as the app, RELEASE. `swift build` is flaky at
# emitting mlx-swift's Cmlx metallib bundle in a fresh checkout, so copy a
# known-good one next to the binary (app DerivedData, else main mlx-audio-swift).
KIT_REL     = MurmurKit/.build/release
CMLX_BUNDLE = mlx-swift_Cmlx.bundle
CMLX_SRC := $(firstword \
	$(wildcard $(HOME)/Library/Developer/Xcode/DerivedData/Murmur-*/Build/Products/Release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/release/$(CMLX_BUNDLE)) \
	$(wildcard /Volumes/DATA/mlx-audio-swift/.build/arm64-apple-macosx/debug/$(CMLX_BUNDLE)))

cli:
	cd MurmurKit && swift build -c release --product murmur-cli
	@if [ ! -e "$(KIT_REL)/$(CMLX_BUNDLE)/Contents/Resources/default.metallib" ]; then \
		if [ -n "$(CMLX_SRC)" ]; then cp -R "$(CMLX_SRC)" "$(KIT_REL)/" && echo "→ copied metallib bundle next to murmur-cli"; \
		else echo "WARN: no metallib bundle found — run 'make build' (the app) once to produce it"; fi; \
	fi

run-cli: cli
	"$(KIT_REL)/murmur-cli"

# Offline timing on a fixed file: make bench WAV=/path/to/clip.wav
WAV ?= /path/to/clip.wav
bench: cli
	"$(KIT_REL)/murmur-cli" --wav "$(WAV)"

clean:
	rm -rf build Murmur.xcodeproj Murmur.xcworkspace Derived MurmurKit/.build
