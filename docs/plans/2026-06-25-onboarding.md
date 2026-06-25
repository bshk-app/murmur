# Onboarding Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the first-run onboarding window from the design handoff (`design/handoff-2026-06-25/MurMur Onboarding.dc.html`) — a 6-step wizard (Welcome → Permissions → Shortcut → Download → Try it → Done) wired to **real** mic/Accessibility permissions, a **real** Hugging Face model download with live progress, and a **real** in-window dictation, fully localized EN+RU.

**Architecture:** Pure flow logic (step navigation, Continue-gating, download math) lives in **MurmurKit** as `OnboardingFlow` (Foundation-only, unit-tested). The UI is a SwiftUI `Window` scene in the app target driven by an `@Observable OnboardingModel` that wraps `OnboardingFlow` and glues the real subsystems (`DictationSession`, `AVCaptureDevice`, `AXIsProcessTrusted`, `KeyboardShortcuts`, a new `OnboardingDownloader`). All user-facing strings go through a String Catalog (`Localizable.xcstrings`, English keys → RU translations). Real download progress reuses `MLXAudioCore.ModelUtils.resolveOrDownloadModel(progressHandler:)` — **no fork changes**.

**Tech Stack:** SwiftUI (macOS 15+/26), Tuist app target, MurmurKit SPM package, MLX (via fork `mlx-audio-swift`), `MLXAudioCore` + `HuggingFace` (swift-huggingface 0.8.1) for download progress, `KeyboardShortcuts`, XCTest (`swift test`) for the pure flow logic, String Catalog for localization.

**Design decisions already settled (brainstorming 2026-06-25):**
- Download installs **both** models (3.6 GB, default Hybrid). Lazy-by-mode lets the user switch later without re-onboarding.
- **Mic** is a hard gate; **Accessibility** is skippable (HUD-only works without it; `insertFinal` already clipboard-falls-back).
- Real download progress via `ModelUtils` (no fork edit); GB/ETA/speed derived from each repo's `Progress.fractionCompleted` × known size.
- **Try it** is a real dictation (`DictationSession`, Hybrid) rendered into an in-window field (typing into our own field needs no Accessibility).
- Window opens on first run (`@AppStorage murmur.didOnboard == false`); re-openable via "Replay the setup tour".
- Headings use system serif (`.serif` design) — Fraunces bundling is optional polish (YAGNI now).

**Reference files (read before starting):**
- Mock: `design/handoff-2026-06-25/MurMur Onboarding.dc.html` (exact copy, states, colours).
- Token system + glass/pill patterns to reuse: `Sources/Murmur/Theme.swift`, `Sources/Murmur/HUDOverlay.swift`, `Sources/Murmur/MenuPopover.swift`.
- Lazy loader this builds on: `MurmurKit/Sources/MurmurKit/TwoTierEngine.swift`, `STTEngine.swift`, `DictationSession.swift`.

**Branch:** `feat/onboarding` (Murmur repo). Frequent commits, one per task step-group. Sign with 1Password (`git commit -S`).

---

## Testing strategy (read this first)

macOS UI + system permission dialogs + live mic/MLX are **not** classically unit-testable. So:

- **TDD (real XCTest via `swift test`)** for the pure, Foundation-only logic in `OnboardingFlow` — step transitions, Continue-gating, download math (GB/remaining/done/ETA). This is where the bugs hide; test it hard.
- **Implement → build → manual-verify** for everything UI/system (window, screens, permission prompts, real download, real try-it, localization rendering). Each such task ends with an explicit **Manual verification checklist** to run in Xcode (`make build` regenerates the project — only run when Xcode is closed, or build with ⌘B inside Xcode).

`swift test` caveat: MurmurKit links MLX, whose metallib isn't emitted by `swift build` in a fresh checkout. `OnboardingFlow` imports **only Foundation** and triggers no MLX op, so its tests load fine. If `swift test` ever fails to load the bundle, run the single test (`swift test --filter OnboardingFlowTests`) — pure-logic tests don't need the metallib.

---

## Phase 0 — Foundations

### Task 0.1: Branch

**Step 1:** Create the feature branch.
```bash
cd /Volumes/DATA/Murmur
git checkout -b feat/onboarding
```

**Step 2:** Commit this plan.
```bash
git add docs/plans/2026-06-25-onboarding.md
git commit -S -m "docs(onboarding): implementation plan"
```

---

### Task 0.2: Localization infrastructure (String Catalog, EN base + RU)

The app is bilingual EN+RU. Set up a String Catalog so every `Text("…")` literal becomes a localizable key, add RU translations, and fix the one already-hardcoded RU string (`insertFinal`).

**Files:**
- Create: `Sources/Murmur/Resources/Localizable.xcstrings`
- Modify: `Project.swift` (ensure `Resources/**` is in `resources:` — already is; confirm `.xcstrings` is bundled)
- Modify: `Sources/Murmur/DictationController.swift:166` (secure-input message → English key)

**Step 1: Create the String Catalog seed.** `Localizable.xcstrings` is JSON. Seed it with the strings that exist today plus a `sourceLanguage` of `en` and a `ru` entry for each. Minimal valid seed:
```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "Field is protected — press ⌘V" : {
      "localizations" : {
        "ru" : { "stringUnit" : { "state" : "translated", "value" : "Поле защищено — нажмите ⌘V" } }
      }
    }
  }
}
```
(Onboarding strings are added per-screen in later tasks; Xcode also auto-extracts new `Text` keys on build.)

**Step 2: Replace the hardcoded RU string with its English key.**
In `DictationController.insertFinal`:
```swift
        case .copiedSecureInput:
            hud.error(String(localized: "Field is protected — press ⌘V"))
```

**Step 3: Add `ru` to the project's known regions.** In `Project.swift`, ensure the app target sets `"CFBundleLocalizations"` (or Tuist `Project`/`Target` development-region + the catalog provides `ru`). Add to the app target `infoPlist`:
```swift
"CFBundleLocalizations": ["en", "ru"],
"CFBundleDevelopmentRegion": "en",
```

**Step 4: Build + manual verify.**
- `make build` (Xcode closed) or ⌘B in Xcode.
- Run, trigger the secure-input path (focus a password field, dictate) → HUD shows the EN string by default.
- Set System Settings → General → Language to Russian (or run with `-AppleLanguages '(ru)'` scheme arg) → string shows in RU.

**Step 5: Commit.**
```bash
git add Sources/Murmur/Resources/Localizable.xcstrings Sources/Murmur/DictationController.swift Project.swift
git commit -S -m "i18n: add String Catalog (en+ru), localize secure-input notice"
```

---

### Task 0.3: `OnboardingFlow` pure logic + tests (TDD)

The single source of truth for step order, Continue-gating, and download math. Foundation-only, fully unit-tested.

**Files:**
- Create: `MurmurKit/Sources/MurmurKit/OnboardingFlow.swift`
- Create: `MurmurKit/Tests/MurmurKitTests/OnboardingFlowTests.swift`
- Modify: `MurmurKit/Package.swift` (add a test target)

**Step 1: Add the test target** to `MurmurKit/Package.swift` `targets:`:
```swift
        .testTarget(
            name: "MurmurKitTests",
            dependencies: ["MurmurKit"]
        ),
```

**Step 2: Write the failing tests.** `MurmurKit/Tests/MurmurKitTests/OnboardingFlowTests.swift`:
```swift
import XCTest
@testable import MurmurKit

final class OnboardingFlowTests: XCTestCase {
    func test_steps_are_six_in_order() {
        XCTAssertEqual(OnboardingFlow.Step.allCases,
                       [.welcome, .permissions, .shortcut, .download, .tryIt, .done])
    }

    func test_permissions_gate_requires_mic_only() {
        var s = OnboardingFlow.State()
        s.step = .permissions
        XCTAssertFalse(OnboardingFlow.canContinue(s))     // no mic
        s.micGranted = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))       // mic alone unblocks (accessibility skippable)
    }

    func test_download_gate_requires_both_models() {
        var s = OnboardingFlow.State()
        s.step = .download
        s.fastFraction = 1; s.accurateFraction = 0.5
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.accurateFraction = 1
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_tryit_gate_requires_a_success() {
        var s = OnboardingFlow.State()
        s.step = .tryIt
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.didTry = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_other_steps_never_block() {
        for step in [OnboardingFlow.Step.welcome, .shortcut, .done] {
            var s = OnboardingFlow.State(); s.step = step
            XCTAssertTrue(OnboardingFlow.canContinue(s))
        }
    }

    func test_download_math() {
        let m = OnboardingFlow.downloadMetrics(fast: 1.0, accurate: 0.5)
        XCTAssertEqual(m.downloadedGB, 0.6 * 1.0 + 3.0 * 0.5, accuracy: 0.001)   // 2.1
        XCTAssertEqual(m.totalGB, 3.6, accuracy: 0.001)
        XCTAssertFalse(m.done)
        let done = OnboardingFlow.downloadMetrics(fast: 1, accurate: 1)
        XCTAssertTrue(done.done)
        XCTAssertEqual(done.remainingGB, 0, accuracy: 0.001)
    }

    func test_next_and_back_clamp() {
        XCTAssertEqual(OnboardingFlow.next(.welcome), .permissions)
        XCTAssertEqual(OnboardingFlow.next(.done), .done)        // clamps
        XCTAssertEqual(OnboardingFlow.back(.permissions), .welcome)
        XCTAssertEqual(OnboardingFlow.back(.welcome), .welcome)  // clamps
    }
}
```

**Step 3: Run tests, verify they fail.**
```bash
cd /Volumes/DATA/Murmur/MurmurKit && swift test --filter OnboardingFlowTests
```
Expected: FAIL (no such type `OnboardingFlow`).

**Step 4: Implement `OnboardingFlow`.** `MurmurKit/Sources/MurmurKit/OnboardingFlow.swift`:
```swift
import Foundation

/// Pure, UI-agnostic state + rules for the first-run onboarding wizard. The app's
/// `OnboardingModel` owns the real subsystems and consults this for every
/// transition and gate. Foundation-only so it unit-tests without MLX.
public enum OnboardingFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, shortcut, download, tryIt, done
    }

    /// Known on-disk sizes (GB) of the two quantized models — for the progress UI.
    public static let fastGB = 0.6
    public static let accurateGB = 3.0
    public static var totalGB: Double { fastGB + accurateGB }   // 3.6

    public struct State: Sendable {
        public var step: Step = .welcome
        public var micGranted = false
        public var accessibilityGranted = false
        public var fastFraction = 0.0       // 0…1
        public var accurateFraction = 0.0   // 0…1
        public var didTry = false           // ≥1 successful try-it dictation
        public init() {}
    }

    /// Continue is allowed unless the current step has an unmet requirement.
    /// Mic is required (no dictation without it); Accessibility is *not* gated
    /// (skippable — HUD-only works without it).
    public static func canContinue(_ s: State) -> Bool {
        switch s.step {
        case .permissions: return s.micGranted
        case .download:    return s.fastFraction >= 1 && s.accurateFraction >= 1
        case .tryIt:       return s.didTry
        case .welcome, .shortcut, .done: return true
        }
    }

    public static func next(_ step: Step) -> Step {
        Step(rawValue: min(step.rawValue + 1, Step.done.rawValue)) ?? .done
    }
    public static func back(_ step: Step) -> Step {
        Step(rawValue: max(step.rawValue - 1, 0)) ?? .welcome
    }

    public struct DownloadMetrics: Sendable {
        public let downloadedGB: Double
        public let totalGB: Double
        public let remainingGB: Double
        public let done: Bool
    }
    public static func downloadMetrics(fast: Double, accurate: Double) -> DownloadMetrics {
        let dl = fastGB * fast + accurateGB * accurate
        let done = fast >= 1 && accurate >= 1
        return DownloadMetrics(downloadedGB: dl, totalGB: totalGB,
                               remainingGB: max(0, totalGB - dl), done: done)
    }
}
```

**Step 5: Run tests, verify they pass.**
```bash
cd /Volumes/DATA/Murmur/MurmurKit && swift test --filter OnboardingFlowTests
```
Expected: PASS (all).

**Step 6: Commit.**
```bash
git add MurmurKit/Package.swift MurmurKit/Sources/MurmurKit/OnboardingFlow.swift MurmurKit/Tests/MurmurKitTests/OnboardingFlowTests.swift
git commit -S -m "feat(onboarding): pure OnboardingFlow logic + tests"
```

---

## Phase 1 — Window shell, navigation, static screens

### Task 1.1: `OnboardingModel` (app `@Observable`)

Wraps `OnboardingFlow.State`, exposes the real-subsystem hooks (filled in later phases), and the `didOnboard` flag.

**Files:**
- Create: `Sources/Murmur/Onboarding/OnboardingModel.swift`

**Step 1: Implement the model (transitions + gating delegate to `OnboardingFlow`; subsystem methods are stubs now, wired in Phases 2–4).**
```swift
import Foundation
import MurmurKit
import Observation
import SwiftUI

@MainActor
@Observable
final class OnboardingModel {
    static let didOnboardKey = "murmur.didOnboard"

    var flow = OnboardingFlow.State()
    var finished = false
    var downloadError: String?

    private let session: DictationSession

    init(session: DictationSession) { self.session = session }

    // MARK: navigation
    var canContinue: Bool { OnboardingFlow.canContinue(flow) }
    var showBack: Bool { flow.step != .welcome && !finished }

    func next() {
        guard canContinue else { return }
        if flow.step == .welcome { startDownload() }          // overlap download with later steps
        if flow.step == .done { finish(); return }
        flow.step = OnboardingFlow.next(flow.step)
    }
    func back() { flow.step = OnboardingFlow.back(flow.step) }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        finished = true
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
    }

    // MARK: subsystem hooks — implemented in later phases
    func requestMic() {}            // Task 2.1
    func promptAccessibility() {}   // Task 2.1
    func startDownload() {}         // Task 3.2
    func tryStart() {}              // Task 4.1
    func tryEnd() {}                // Task 4.1

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
```

**Step 2: Build** (⌘B in Xcode after adding the file via Tuist `make gen`, or `make build` with Xcode closed). Expected: compiles (no UI yet). Commit.
```bash
git add Sources/Murmur/Onboarding/OnboardingModel.swift
git commit -S -m "feat(onboarding): OnboardingModel skeleton"
```

---

### Task 1.2: Window scene + open-on-first-run

**Files:**
- Modify: `Sources/Murmur/MurmurApp.swift`
- Modify: `Sources/Murmur/AppDelegate.swift` (open the window on first launch)

**Step 1: Add the `Window` scene + own the model.** In `MurmurApp.body`:
```swift
        Window("MurMur Setup", id: "onboarding") {
            OnboardingView(model: appDelegate.onboarding)
                .frame(width: 880, height: 580)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
```
And in `AppDelegate`, add `lazy var onboarding = OnboardingModel(session: dictation.session)` — expose the `DictationSession` from `DictationController` (add an internal accessor) so the try-it step reuses the already-warmed pipeline.

**Step 2: Open on first run.** In `AppDelegate.applicationDidFinishLaunching` (or `DictationController.bootstrap`), after setup:
```swift
        if OnboardingModel.shouldShow {
            NSApp.activate(ignoringOtherApps: true)
            // openWindow is SwiftUI; from AppKit use the env via a tiny bridge or
            // post to the App scene. Simplest: an @Environment(\.openWindow) call
            // from a no-op view, or NSApp.sendAction to the scene. See Step 3.
        }
```

**Step 3: Bridge AppKit → openWindow.** The robust pattern for a menu-bar (`LSUIElement`) app: keep an `@Environment(\.openWindow) var openWindow` inside a hidden helper view, or trigger via a published flag the App scene observes. Implement a small `@Observable AppRouter { var showOnboarding = false }`, observe it in a `.onChange` at the top of `MenuBarExtra`'s content, and call `openWindow(id: "onboarding")`. Set `router.showOnboarding = true` from the AppDelegate when `shouldShow`.

**Step 4: Build + manual verify.**
- Delete the flag to simulate first run: `defaults delete <bundleid> murmur.didOnboard` (bundle id from `Project.swift`).
- Launch → onboarding window appears, centered, focused, 880×580.
- Quit + relaunch → window does **not** reappear (flag set only on finish; until finish it should still show — confirm desired: until finished, `shouldShow` stays true, so it reappears every launch until completed. That's intended).

**Step 5: Commit.**
```bash
git add Sources/Murmur/MurmurApp.swift Sources/Murmur/AppDelegate.swift Sources/Murmur/Onboarding/
git commit -S -m "feat(onboarding): window scene + first-run trigger"
```

---

### Task 1.3: `OnboardingView` scaffold + static screens (Welcome, Done, finished overlay)

Translate the mock to SwiftUI using the existing `Mur` token system. The mock HTML (`design/handoff-2026-06-25/MurMur Onboarding.dc.html`) is the exact visual reference — colours, spacing, copy.

**Files:**
- Create: `Sources/Murmur/Onboarding/OnboardingView.swift`
- Create: `Sources/Murmur/Onboarding/OnboardingChrome.swift` (left rail: cat + stepper + narrator bubble; titlebar; footer)

**Step 1: Layout skeleton.**
```swift
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                OnboardingRail(model: model)            // 296pt left
                VStack(spacing: 0) {
                    ScrollView { content.padding(.init(top: 30, leading: 36, bottom: 26, trailing: 36)) }
                    OnboardingFooter(model: model)
                }
            }
            if model.finished { FinishedOverlay(model: model) }
        }
        .background(scheme == .dark ? Color(red: 27/255, green: 21/255, blue: 17/255) : Mur.cream)
    }

    @ViewBuilder private var content: some View {
        switch model.flow.step {
        case .welcome:     WelcomeScreen()
        case .permissions: PermissionsScreen(model: model)   // Phase 2
        case .shortcut:    ShortcutScreen(model: model)       // Phase 2
        case .download:    DownloadScreen(model: model)       // Phase 3
        case .tryIt:       TryItScreen(model: model)          // Phase 4
        case .done:        DoneScreen(model: model)
        }
    }
}
```
Provide placeholder `Text("…")` screens for permissions/shortcut/download/tryIt now (filled in later phases) so it compiles.

**Step 2: Left rail** — `OnboardingRail`: `cat_full` image (float animation optional), narrator bubble showing `narration[step]` (localized), and the 6-step stepper with done/active/upcoming dot styles per the mock's `steppers()`. Strings localized.

**Step 3: Footer** — Back (when `showBack`), spacer, optional block hint (e.g. "Grant the microphone to continue"), Continue button styled via `model.canContinue` (accent when enabled, muted when not). Continue label per step: Get started / Continue / Continue / Downloading… or Continue / I've got it / Start using MurMur. All localized.

**Step 4: Welcome screen** — h1 "Just talk. I'll type it." (system serif), subtitle, the 3 feature cards (⌥-keys / speak / typed), and the "Two models, one trick … about 3.6 GB" note. Use `OnboardingFlow.totalGB` for the size string. All localized.

**Step 5: Done screen + finished overlay** — checklist (models installed `3.6 GB · on-device`, perms granted, shortcut set) reading real `model.flow`; finished overlay "MurMur is live" + "Replay the setup tour" (calls `model.replay()`). The "I live up here ↑" menu-bar pointer can be a `.overlay` on finish.

**Step 6: Build + manual verify checklist.**
- Window shows Welcome with cat, stepper (step 1 active), narrator text.
- Footer Continue ("Get started") is enabled; clicking advances step → stepper updates, placeholder screens render, Back appears.
- Navigate to Done (temporarily allow skipping gates for this check), "Start using MurMur" → finished overlay; "Replay" resets to Welcome.
- Toggle system appearance → dark/light both look right.

**Step 7: Commit.**
```bash
git add Sources/Murmur/Onboarding/
git commit -S -m "feat(onboarding): window chrome, rail, footer, Welcome/Done screens"
```

---

### Task 1.4: Replay entry point in the menu popover

**Files:**
- Modify: `Sources/Murmur/MenuPopover.swift` (footer), `Sources/Murmur/Onboarding/OnboardingModel.swift` (expose open)

**Step 1:** Add a footer row "Setup tour…" in `MenuPopover.footer` that sets `router.showOnboarding = true` (reuse the Task 1.2 router) and re-opens the window. Reset `model.replay()` first so it starts at Welcome.

**Step 2: Build + manual verify** — menu → "Setup tour…" opens the onboarding at Welcome even after completion. **Commit.**

---

## Phase 2 — Permissions + Shortcut (real)

### Task 2.1: Permissions screen (Mic hard-gate, Accessibility skippable)

**Files:**
- Modify: `Sources/Murmur/Onboarding/OnboardingModel.swift`
- Create: `Sources/Murmur/Onboarding/PermissionsScreen.swift`

**Step 1: Wire mic + accessibility in the model.**
```swift
    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in self.flow.micGranted = ok }
        }
    }
    func promptAccessibility() {
        _ = Accessibility.prompt()            // MurmurKit — shows the system prompt
        startAccessibilityPolling()
    }
    private func startAccessibilityPolling() {
        // No notification for AX trust → poll until granted or the step is left.
        guard accPollTimer == nil else { return }
        accPollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                self.flow.accessibilityGranted = Accessibility.isTrusted
                if self.flow.accessibilityGranted { self.stopAccessibilityPolling() }
            }
        }
    }
```
Also reflect already-granted state on appear (`flow.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`, `flow.accessibilityGranted = Accessibility.isTrusted`).

**Step 2: Screen UI** — two permission cards (Microphone, Accessibility) per the mock: icon, title, why-text, and a **Grant** button (→ `requestMic` / `promptAccessibility`) that flips to a green "Granted" pill when the flag is set. Under them, the "change anytime in System Settings" note. All strings localized. The footer's block hint shows "Grant the microphone to continue" only while `!flow.micGranted` (Accessibility omitted from the gate).

**Step 3: Build + manual verify checklist.**
- First run (reset TCC if needed: `tccutil reset Microphone <bundleid>`): Grant → system mic dialog → card shows Granted; Continue unlocks.
- Accessibility Grant → system propmt + Settings deep-link; toggle on → within ~1s card shows Granted (polling). Leaving it OFF still lets Continue (skippable).
- Commit.

---

### Task 2.2: Shortcut screen

**Files:**
- Create: `Sources/Murmur/Onboarding/ShortcutScreen.swift`

**Step 1:** Use `KeyboardShortcuts.Recorder(for: .dictate)` for the recorder box, styled to match the mock's dashed record area. Below it, preset chips (⌃⌥Space [our default], ⌥Space, ⌃⌘, Fn, ⌃Space, ⌘⇧D) that call `KeyboardShortcuts.setShortcut(_, for: .dictate)` when tapped. Show the current shortcut from `KeyboardShortcuts.getShortcut(for: .dictate)`.

> Note: our real default is **⌃⌥Space** (`Shortcuts.swift`), not the mock's ⌥ Space — keep our default; presets may offer ⌥ Space.

**Step 2: Build + manual verify** — recording a combo updates the chip + persists; presets set it; the global hotkey reflects the change. Continue always enabled. **Commit.**

---

## Phase 3 — Download (real progress)

### Task 3.1: Add `MLXAudioCore` + `HuggingFace` product deps

**Files:**
- Modify: `MurmurKit/Package.swift`

**Step 1:** Add the swift-huggingface package + both products (coordinates mirror the fork: swift-huggingface `0.8.1`).
```swift
    dependencies: [
        .package(url: "https://github.com/beshkenadze/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    // MurmurKit target dependencies += :
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
```

**Step 2:** `cd MurmurKit && swift build --target MurmurKit` → resolves + compiles. **Commit.**

---

### Task 3.2: `OnboardingDownloader` (real progress, no fork change)

**Files:**
- Create: `MurmurKit/Sources/MurmurKit/OnboardingDownloader.swift`

**Step 1: Implement** — pre-download each repo with a progress handler, into the **same** cache `fromPretrained` reads (so no re-download on load).
```swift
import Foundation
import HuggingFace
import MLXAudioCore

/// Downloads the two model repos up front with live per-repo progress, into the
/// HF cache that `*.fromPretrained` later reads (so loading does not re-download).
/// Progress mechanism reuses MLXAudioCore — no fork changes.
public actor OnboardingDownloader {
    public struct Progress: Sendable { public var fast = 0.0; public var accurate = 0.0 }

    public static let fastRepo = TwoTierEngine.defaultNemotronRepo
    public static let accurateRepo = TwoTierEngine.defaultVoxtralRepo

    /// Download both, reporting `(fast, accurate)` fractions on the main actor.
    public static func download(onProgress: @escaping @MainActor @Sendable (Progress) -> Void) async throws {
        var p = Progress()
        func report() { let snap = p; Task { @MainActor in onProgress(snap) } }

        try await fetch(fastRepo) { f in p.fast = f; report() }
        try await fetch(accurateRepo) { f in p.accurate = f; report() }
    }

    private static func fetch(_ repo: String, _ onFraction: @escaping (Double) -> Void) async throws {
        guard let id = Repo.ID(rawValue: repo) else { throw Err.badRepo(repo) }
        _ = try await ModelUtils.resolveOrDownloadModel(
            client: HubClient(),
            repoID: id,
            requiredExtension: "safetensors",
            progressHandler: { progress in
                onFraction(progress.fractionCompleted)     // 0…1
            }
        )
        onFraction(1.0)
    }

    enum Err: Error { case badRepo(String) }
}
```
> Verify at build time that the `client:`/`progressHandler:` overload is the right one (see `MLXAudioCore/ModelUtils.swift:64`). If `Repo.ID`/`HubClient` aren't found, the import is `HuggingFace` (confirmed: swift-huggingface).
> Granularity: if `fractionCompleted` proves too steppy (file-count, not bytes), supplement by polling the size of the in-progress `*.safetensors` in the repo's cache dir against `OnboardingFlow.fastGB/accurateGB`. Keep the public API the same.

**Step 2:** `swift build --target MurmurKit` → compiles. Commit.

**Step 3: Wire into the model.** In `OnboardingModel.startDownload()`:
```swift
    func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        Task {
            do {
                try await OnboardingDownloader.download { p in
                    self.flow.fastFraction = p.fast
                    self.flow.accurateFraction = p.accurate
                }
                try await self.session.load(mode: .hybrid)   // warm both (cache hit, no re-download)
            } catch {
                self.downloadError = error.localizedDescription
            }
        }
    }
```

**Step 4: Commit.**
```bash
git add MurmurKit/Sources/MurmurKit/OnboardingDownloader.swift Sources/Murmur/Onboarding/OnboardingModel.swift
git commit -S -m "feat(onboarding): real model download with per-repo progress"
```

---

### Task 3.3: Download screen

**Files:**
- Create: `Sources/Murmur/Onboarding/DownloadScreen.swift`

**Step 1:** Two cards (Fast 0.6 GB / Accurate 3.0 GB) with progress bars bound to `flow.fastFraction` / `flow.accurateFraction`, each showing `%` or a green "Ready". Below: `OnboardingFlow.downloadMetrics(...)` → "{downloadedGB} / 3.6 GB · {eta} · {speed}". ETA/speed derived in the view (track previous bytes + timestamp; speed = Δbytes/Δt; eta = remaining/speed). Done banner when both 100%. Error → red note + "Retry" (`model.startDownload()` after resetting `downloadStarted`/error). Gate: Continue enabled only when `downloadMetrics.done`. All strings localized.

**Step 2: Build + manual verify checklist.**
- Reset cache to force a real download: `rm -rf "$(getconf DARWIN_USER_CACHE_DIR)"/…/mlx-audio` (or the resolved `HubCache.default` dir — confirm path on first run via the `print("Downloading model …")` log).
- Onboarding past Welcome → bars advance with real % (started during Welcome→Permissions per the overlap); GB/ETA/speed update; both reach Ready; Continue unlocks; subsequent `session.load` is a cache hit (instant).
- Kill network mid-download → error + Retry resumes.

**Step 3: Commit.**

---

## Phase 4 — Try it (real dictation)

### Task 4.1: Try-it screen + real session

Reuses the warmed `DictationSession` (loaded in Task 3.2). Hold the in-window button → start a Hybrid dictation → render the two-tier text into the window's own field (no Accessibility needed — it's our field). Release → finish → mark `didTry`.

**Files:**
- Modify: `Sources/Murmur/Onboarding/OnboardingModel.swift`
- Create: `Sources/Murmur/Onboarding/TryItScreen.swift`

**Step 1: Model hooks.**
```swift
    var tryConfirmed = ""
    var tryPartial = ""
    var tryListening = false

    func tryStart() {
        guard session.isReady(.hybrid) else { return }
        tryConfirmed = ""; tryPartial = ""; tryListening = true
        session.onUpdate = { c, p in Task { @MainActor in self.tryConfirmed = c; self.tryPartial = p } }
        try? session.start(mode: .hybrid)
    }
    func tryEnd() {
        guard tryListening else { return }
        tryListening = false
        Task.detached {
            let final = self.session.stop()
            await MainActor.run {
                self.tryConfirmed = final; self.tryPartial = ""
                self.flow.didTry = !final.isEmpty
            }
        }
    }
```
> Restore `session.onUpdate` to the `DictationController` handler when the try-it step is left / window closes, so the main app keeps driving the HUD afterwards. Do this in `OnboardingModel` on step-change and on `finish()`/`replay()`.

**Step 2: Screen UI** — the bordered test field rendering the two-tier text with the same colour rule as the HUD (`Mur.draft` provisional → accent flash on newest confirmed → `Mur.crisp`), a press-and-hold "Hold to talk" button (`onLongPressGesture` / `DragGesture(minimumDistance:0)` for press+release → `tryStart`/`tryEnd`), and a status line (Listening… / Refining… / "Got it"). "Try again" resets. Gate: Continue enabled once `flow.didTry`.

**Step 3: Build + manual verify checklist.**
- On the Try-it step, press-hold the button and speak → live two-tier text appears in the field (gray draft → sharpened), release → final settles; status → done; Continue unlocks.
- Leave the step → main app dictation (global hotkey → HUD) still works (onUpdate restored).

**Step 4: Commit.**

---

## Phase 5 — Finalize

### Task 5.1: First-run edges + Done polish

**Step 1:** Confirm the trigger logic: show when `!didOnboard`. Edge — `didOnboard == true` but cache empty (user cleared it): do **not** force onboarding; the lazy loader silently re-downloads on first `prepare`. (No code beyond what exists; just verify.)

**Step 2:** Done screen reads the real `flow` (models done, mic/accessibility, shortcut). If Accessibility was skipped, show an honest "typing off — grant later" badge linking to the menu. Localized.

**Step 3:** Full manual run-through (reset `murmur.didOnboard` + caches): Welcome → grant mic → (skip accessibility) → set shortcut → watch real download → real try-it → Done → "Start using MurMur" → window closes, flag set, cat in the menu bar, global hotkey dictates into a real app. Switch system language to RU and re-run to verify localization.

**Step 4: Final commit + open PR (optional).**
```bash
git add -A
git commit -S -m "feat(onboarding): finalize first-run edges + localized Done"
```

---

## Definition of done
- 6-step wizard matches the mock visually (dark + light), all copy localized EN+RU.
- Mic hard-gated; Accessibility skippable; both reflect real system state.
- Shortcut recorder + presets persist to `.dictate`.
- Real 3.6 GB download with live per-repo progress; loading is a cache hit afterwards.
- Real in-window Hybrid try-it; main-app dictation unaffected after.
- `murmur.didOnboard` gates first run; "Setup tour…" + "Replay" re-open it.
- `OnboardingFlow` unit tests green (`swift test --filter OnboardingFlowTests`).
- `MurmurKit` + `murmur-cli` + app all build.
