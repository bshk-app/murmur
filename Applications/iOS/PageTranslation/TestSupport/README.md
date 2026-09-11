# Production Safari integration fixture

This simulator-only host embeds the real `MurMurPageTranslation` action extension. It prepares genuine bundled EN→FI and FI→EN CT2 packages in the dedicated translation App Group and opens Safari. It does not implement translation and contains no speech model substitutes.

- Host source: `Host/PageTestHost.swift` plus the app's `Shared/TranslationPaths.swift`.
- Host bundle ID: `app.bshk.murmur.ios`; simulator ad-hoc signing uses `TranslationProvider.entitlements`.
- Resources: folder references for `ct2-enfi` and `ct2-fien` (either at bundle root or under `TranslationModels`). Existing shared packages are validated and preserved.
- UI tests: `Tests/PageTranslationIntegrationTests.swift`.

Start the fixture before running the UI tests:

```sh
node Applications/iOS/PageTranslation/TestSupport/serve.mjs
```

The server binds to loopback port 18765. `/small` exercises block text and inline formatting; `/long` adds 64 paragraphs. `/health` confirms readiness. JSON observations are written to `/tmp/murmator-page-integration-results`, and `/reports` returns recent reports. `PAGE_FIXTURE_PORT` and `PAGE_FIXTURE_RESULTS` override these defaults; the host accepts `--fixture-server URL`.

Tests launch with `--test-fixture`, wait for package preparation, and invoke Safari → Share → Murmator. The page independently observes DOM text and `lang`, verifies Finnish output containing “huomenna”, element identity, link destination, protected inputs/editable/code text, exclusion handling, all long paragraphs, exact restoration, and toolbar dismissal. It does not read extension-private variables or fake an engine success signal. The UI test screenshots and the server's JSON reports are complementary evidence.

Cancellation coverage includes dismissal before starting and cancellation after native translation progress appears. The latter verifies the entire original page, including language and every long paragraph, then retries the same page to detect a stuck model lease or progress state. The harmless “Verify original page” fixture button reads the live DOM; it does not modify the application's translation state.

The runtime tests must execute against the real production extension. A JavaScript-only fixture self-check with synthetic text verifies the observer wiring only and is not an inference or end-to-end translation test.
