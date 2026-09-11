# Live keyboard dictation

Enable Full Access for MurMur in iOS keyboard settings. Choose the spoken language and, optionally, a translation target on the keyboard. **Prepare dictation** opens MurMur and immediately enables the requested audio session. CPU/ANE model preparation can continue after returning to the receiving app; the keyboard shows progress until Hold to talk is ready. Return using iOS's app-back control, hold the microphone while speaking and release to finish and insert.

The keyboard has no saved-note insertion button. It provides hold-to-talk (VoiceOver activation toggles), language and translation menus, deletion with hold-to-repeat, the receiving field's Send/Return action, and microphone shutdown. Draft text stays in the preview. A finished utterance is inserted automatically only into the same unchanged field; otherwise an explicit Insert text action preserves the user's edits. A failed translation offers the original text. Recognition results are also saved as voice notes.

The microphone remains explicitly enabled between utterances; idle audio is discarded. It ends after five minutes without another recording, after one minute without keyboard presence while backgrounded, on interruption/locking, or with the microphone-off button. An utterance is bounded to three minutes. Changing languages ends the session and opens MurMur to enable the session for the new configuration.

Audio capture and inference run in the main app. The extension only exchanges local App Group messages and inserts text through UITextDocumentProxy; it makes no network requests. Model downloads happen in MurMur. Each command is tied to a fresh session and utterance ID. Final text is never inserted in response to an expired or duplicate command.

Implementation: KeyboardSession in MurmurCore, KeyboardSessionStore in Shared, KeyboardDictationController in the main app, and BackgroundSpeechSession in MurmurSpeech. The background recognizer uses one CPU/ANE Core ML lane, CPU Silero VAD in its native 4096-sample blocks, coalesced provisional passes and preserved final phrases. Normal in-app hybrid dictation is separate.

The simulator host verifies the real settings UI but does not emulate successful inference. The device-only KeyboardLiveDictationTests uses a local receiving app and an acoustic fixture played through the phone's output into its real microphone. It never sends a message to an external service. The volume is temporarily adjusted and restored by teardown. The test is enabled with TEST_RUNNER_MURMUR_LIVE_KEYBOARD_TEST=1. Device test results are documented after completion.

## Validation on 2026-09-06

Signed Release built successfully. Core: 57 tests passed. All nine distinct Maestro flows passed (the new keyboard setup flow was rerun after fixing its language label). On the physical iPhone, cold activation, language selection, 13-second capture, start/stop, local Send and microphone shutdown were exercised. A five-minute idle session also shut down automatically.

The exact new speech processor recognized the known 6.96-second Russian file correctly (24 speech windows, VAD peak 1.0, 2 ASR passes). This is a file replay, not a microphone test. The phone-speaker acoustic trial supplied only a quiet input (peak 0.015, VAD peak 0.25) and produced no text. A positive human-voice-to-insertion check remains pending; it is not reported as passed. The accurate mode uses the previously probed Parakeet lane, but the new full streaming path was replayed only in Fast mode so far.

Preparation regression fixed: fresh preparing state never shows Enable, delayed preparation survives returning to the keyboard, and selecting the current language is a no-op. Core suite: 58 passing tests; physical device regression: /tmp/murmur-enable-sync-green.xcresult.

## Model controls, 2026-09-07

The user confirmed ordinary keyboard dictation works. The activation button now names model preparation, with a separate preparation stage and translation download percentage. Microphone permission failures remain distinct from model failures. Main-app preparation continues while the keyboard is visible.

Settings → Memory and the Home Screen widget can unload the ready keyboard session, speech models, translation models, and unused MLX buffers. Active recording/finalization and preparation block unloading. The device probe verified keyboard ready → unload → ready again; see ../results/model-controls/finnish-translation-and-memory.json. Downloaded files are preserved.
