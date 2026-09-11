# Keyboard dictation: platform constraints and MurMur findings

Research on 2026-09-07, prompted by the user's rejection of the previous UX fix. This is a research result, not a claim that the reported screen sequence has now been fixed or reproduced by UI automation. No new app build was installed during this investigation.

## Primary sources

- Apple, Configuring open access for a custom keyboard: https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard . A keyboard is an isolated process. Full Access permits network and shared-container writes; the no-microphone restriction remains among the inherited restrictions.
- Apple, Creating a custom keyboard: https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard . Keyboard processes have a memory limit and are terminated if they exceed it. Do not invent a universal 30/48/50 MB value. This is not a blanket ban on computation or model inference inside an extension.
- Apple, Configuring a custom keyboard interface: https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface . Set hasDictationKey when providing dictation, so the system does not show a second dictation button. This property does not provide microphone access or an API to start Apple's dictation engine.
- Apple DTS, reply by Quinn, June 2026: https://developer.apple.com/forums/thread/826851 . No public API identifies the app hosting a keyboard. The keyboard→containing app→original app round trip is an open enhancement request. Do not promise automatic return by relying on private host identification.
- Wispr Flow official iPhone setup, updated September 3, 2026: https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone . On iOS 26.4+, microphone activation may open Flow; the user swipes the bottom bar to return. Permission prompts come from the main app. Flow requires networking, so its startup timings are not evidence for local ASR startup performance.
- Wispr Flow official session settings: https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios . Session duration is configurable. The article also says microphone resources are released after dictations; do not infer an undocumented low-level implementation from these user-facing descriptions.

The unanswered forum question https://developer.apple.com/forums/thread/843118 is not an Apple endorsement of any activation technique. Other developers' reports of numeric extension limits or private return methods are not authoritative platform specifications.

## What is verifiable in MurMur's source

1. NotesView shows “Keyboard microphone enabled” whenever keyboard.isActive is true (line 34 at investigation). KeyboardDictationController.enable sets isActive true immediately, in phase preparing, before requesting permission or arming audio (line 51). The headline can therefore precede actual microphone activation and model readiness.
2. The keyboard URL always opens the full KeyboardDictationView setup sheet through MurMurApp.onOpenURL, even for someone whose permissions and languages are already configured. Renaming the extension's button did not remove this setup-shaped round trip.
3. Background session termination and model eviction are coupled. KeyboardDictationController.end closes/nils BackgroundSpeechSession and evicts translators. The timer invokes this after 5 minutes of idle use or 60 seconds without a keyboard heartbeat while backgrounded. A later enable constructs a new recognition session and calls prepare. The repeated preparation is application policy, not a requirement to request permission again.
4. AppModel.enableKeyboard closes the ordinary in-app speech session and unloads its translators before activating the separate keyboard session. Preparing an in-app model is therefore not equivalent to having the background-capable keyboard engine ready.
5. KeyboardViewController currently does not set hasDictationKey despite providing its own dictation button.

These are source findings. They explain possible misleading states, but should not be presented as proof of which exact screen the user saw.

## Design conclusion

Permission, capture-session activity, downloaded files, and resident/prepared models need separate lifecycles. “Microphone allowed” is a permission fact and cannot be used as “ready to dictate.”

A configured user should enter a brief session-activation view, not setup. First-time permission and download work belongs to setup. The keyboard should show a usable dictation control only when the active capture session and requested model configuration are ready. While a session is already active, keyboard commands should not navigate to the main app.

Stopping audio should not implicitly mean unloading the model cache. Explicit unload, memory pressure, configuration changes, process termination and an explicit residency policy are separate reasons to evict. Preserving models can reduce reload latency, but cannot keep a terminated process alive or remove the foreground activation requirement for a new audio session.

Before claiming the next fix: reproduce the user's activation path with already-granted permission; assert that no readiness headline is shown while models load; exercise keyboard hide/show and the idle boundary; count actual model loads; distinguish an existing live session from a cold/restarted app. Prior engine-level translation/unload probes did not validate this UX.
