# MurmurSession

The foreground voice workflow used by both the macOS app and iOS AppModel.
It depends on MurmurCore, MurmurSpeech and MurmurTranslation. It does not import
UI frameworks, read UserDefaults, choose storage directories or insert text.
MurmurKit re-exports it for desktop callers; legacy CLI APIs remain available.

`RecordingSession.Configuration` selects a resolved speech profile, optional
translation target and translation quality. Call `prepare` before `start`.
Preparation reuses a matching speech profile and warms the selected translation
route. `onEvent` is delivered on the main actor; the session's transcript has
already been updated when a snapshot or translation event is delivered.

```swift
let session = RecordingSession(modelsRoot: speechDirectory,
                               translationRoot: translationDirectory,
                               memoryLimit: memoryBudget)
let profile = try SpeechRecognitionProfile.resolve(language: "ru", mode: .hybrid)
try await session.prepare(.init(profile: profile, target: "en"))
try await session.start(microphoneUID: selectedMicrophone, recordingURL: nil)
// ... present events ...
let source = try await session.stopSource()
// Save source.transcript using the application's NoteRepository before translation.
let final = try await session.finishTranslation()
await session.unload()
```

`stop()` combines both finalization steps for consumers without an intermediate
save. `setTranslation` changes only the translation route, including after source
finalization; the spoken language remains pinned. An unfinished target change is
cancelled and drained before another target change or source stop. Starting or
preparing while another lifecycle operation is active throws `LifecycleError.busy`.
`cancel`/`unload` invalidate callbacks, wait for active work and release models.
They retain the last transcript for recovery until the next recording starts.

Translation and recognition-correction failures preserve the original text.
`Failure.recording` reports an optional WAV write failure; `Failure.capture`
reports a stopped microphone or audio backlog overflow. Capture failures finalize
accepted audio before notification, so recovery handlers can safely unload.
Storage policy belongs to the consumer: MurmurCore's existing NoteRepository
provides shared atomic persistence; paths and saving preferences stay in apps.

Tests inject speech/translation drivers and require no microphone or model
weights. Real model validation must use Release builds on Apple Silicon with
Metal resources; compilation and deterministic tests do not establish latency,
quality, physical-device routing or hour-long endurance.
