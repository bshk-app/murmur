# Safari page translation

**Build 18:** the progressive Safari Web Extension was withdrawn at the user’s request. Production Share → Murmator again uses the separate translation window (`ActionViewController`, `PageTranslationView`, `Page.js`). No Safari Web Extension activation or website permission is required. The progressive material below is historical.

Build 15 replaces the modal translation flow described below with a non-UI Share handoff to the Safari Web Extension. See [current behavior](../Product/PROGRESSIVE_PAGE_TRANSLATION.md), [runtime evidence](../results/safari-streaming/README.md), and [release 15](../Release/1.0.0-15/README.md). The legacy controller and Page.js remain as historical/test sources but are excluded from the production Action target.

The production Action extension is included in Murmator **1.0.0 (12)**. Open Murmator once, then use Safari → Share → Murmator. Select source and target languages and translate. The extension uses the same installed quality language packages as text translation; missing packs download through the existing verified downloader.

The containing app and extension share only the dedicated translation App Group. Page text is processed locally and is not saved in that group. A shared read lease protects packages throughout a page operation, including gaps between chunks. Models unload before the operation completes or cancellation dismisses the extension.

## Behavior

- Source language detection, editable language choices, remembered target, preparation/translation progress and cancellation.
- Blocks group adjacent inline text while preserving original DOM nodes, links and formatting.
- Marker-preserving group translation is validated. If a model changes the markers, formatted runs fall back to separate translation. This protects markup but cannot guarantee fluent grammar across formatting boundaries.
- Native calls are bounded to 800-character pieces, with the existing engine's sentence and 200-token subdivision underneath. Cancellation is checked between bounded calls.
- No partial result is applied after a failed or cancelled native operation. A block changed by the website during translation is skipped atomically.
- The toolbar toggles original/translation and closes by restoring originals. Reopening Share on a translated page uses the first original text.
- Current limits: 200,000 UTF-16 units, 4,000 text runs and 2,000 blocks; exceeding them produces an explicit error. New dynamic content requires another invocation. PDF, embedded frames and closed shadow roots are outside this extension's page-text scope.

## Verified

- 86 core tests, including new page chunking, marker fallback, cancellation and validation tests.
- 25 DOM tests, including different wrappers for the same DOM nodes and loss of JavaScript globals between Action invocations.
- Six real Safari integration tests with real CPU models and the shared model directory. These cover small/long pages, exact restoration, toggle/close, early and in-progress cancellation with live page JavaScript, retry, and repeated invocation from a translated page.

See [simulator evidence](../results/page-translation/SIMULATOR-INTEGRATION.md). The physical iPhone was not connected; its memory limits and behavior still need verification.

Safari-specific fixes use `isSameNode` for underlying DOM identity, a retained-toolbar event relay for fresh JavaScript worlds, and an inert finalize round trip for cancellation. No test diagnostics remain in the production script.

The simulator host under `TestSupport` only installs fixture packages and opens Safari. Its resource models and test code are not bundled into the production application.

On September 9, the user reported that page translation works on their device and identified a blank Share-menu icon. Build 14 adds the correct template icon; [light and dark Safari checks](../results/share-icon/README.md) verify the fix. The requested progressive page translation is documented separately in [the proposal](../Product/PROGRESSIVE_PAGE_TRANSLATION.md); the current Action still applies its completed result through Safari's finalize callback.
