# System translation — verified September 8, 2026

Murmator 1.0.0 (11) now embeds its own TranslationUIProvider (app.bshk.murmur.ios.translation). It is registered under the real Murmator name and icon. The physical iPhone test selected Murmator, invoked Translate on selected text, received the translation and replaced the original selection with the exact displayed result. The test restored the prior Apple Translate default afterward.

## Confirmed cause and fix

On iPhone 15 Pro / iOS 26.6.1, the original process PID 28232 was killed by the kernel for per-process-limit. The log recorded 235521 KiB, immediately above the 230 MiB budget measured using the process memory API. This was a process memory limit, not a missing model or a general prohibition on translation extensions.

The corrected CTranslate2 runtime keeps INT8 weights in a read-only file mapping, bounds Ruy's matrix-packing scratch space by output-column tiling and processes one text batch at a time in the extension's low-memory mode. The model files, precision and decoding settings are unchanged. Six translation comparisons, including about 9000 characters, matched the original outputs exactly. 64 independent integer matrix tests checked transpose combinations, tile boundaries, alpha/beta and output canaries.

The corrected diagnostic extension loaded the same 249111077-byte RU→FI model and returned “Lähetän paperit huomenna.” The sampled peak in that diagnostic run was 36586584 bytes (34.9 MiB); the reported budget was 241172480 bytes (230 MiB). This sample describes that run, not a universal peak for every language or text.

A second integration bug was corrected: inputText is supplied asynchronously by the system. The production view now observes context changes and starts translation when the actual selection arrives, instead of capturing an initially empty value in its initializer.

## Shared data and lifecycle

Language packs and text-translation preferences use a dedicated App Group, group.app.bshk.murmur.ios.translation. The translation extension does not receive the notes/keyboard App Group. The containing app moves existing known packs into the shared store. Conflicting copies are preserved and remain visible to storage management. File locks coordinate reads, downloads, imports and deletions across processes. Closing the extension cancels its work and releases model owners.

## Validation

- Physical-device main-provider translation and replacement: PASS.
- Actual extension model load and inference with the optimized runtime: PASS.
- Existing text-translation UI regression: PASS.
- Core tests, including migration, preservation of conflicting copies and a separate-process file-lock check: 81 passed.
- 64 native integer matrix cases: PASS.
- Six old/new translation output comparisons: identical.
- Signed Release build and device installation: PASS.

Screenshots are in screenshots/: the default-app selection, the production translation UI and the replaced source field. The source field belongs to the disposable test host; the translating extension is the real Murmator extension. No user note was edited or deleted by the test.
