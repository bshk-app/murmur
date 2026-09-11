# Progressive translation in Safari

**Build 18:** the progressive Safari Web Extension was withdrawn at the user’s request. Production Share → Murmator again uses the separate translation window (`ActionViewController`, `PageTranslationView`, `Page.js`). No Safari Web Extension activation or website permission is required. The progressive material below is historical.

Status: implemented in build 15 and verified with the production extensions and real local CPU inference in Safari on the iOS 26.5 Simulator on September 9, 2026. [Runtime evidence](../results/safari-streaming/README.md) covers Share handoff, incremental page updates, stopping, reentry, language changes, restoration and DOM preservation. [Release status](../Release/1.0.0-15/README.md) records distribution separately. Builds 12–14 retain the earlier modal Action workflow.

The requested experience is to return to the page immediately, display completed translations while later blocks are still running, and keep progress and language controls in a page header. Existing local models should continue to process the text; the feature should not introduce a translation server.

## Why the previous Action waited

The Action collects text using Safari's preprocessing JavaScript and returns one result through `NSExtensionContext.completeRequest`. Safari invokes `finalize` at that point. Native inference is already split into bounded pieces, but the Action does not have a supported repeated native-to-page result channel during the operation. Completing the request early also permits iOS to terminate the extension.

Apple documents the lifecycle under [Accessing a Webpage](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html). This explains the current implementation; it does not establish which transport another translator uses.

## Implemented Safari Web Extension

The user enables the extension once in Safari and grants website access. A dormant content script installs the Share handoff listener on allowed HTTP(S) pages; it collects no text until the user activates translation. Safari's Murmator action starts directly. Share → Murmator creates a short-lived, single-use, URL-bound ticket; finalization sends it to the listener before the action ends. The content controller claims the ticket before collecting page text. The manifest uses `activeTab`, `scripting`, `nativeMessaging` and HTTP(S) host permissions; Safari controls the allowed sites.

The content script sends one bounded batch to its background script, which calls `browser.runtime.sendNativeMessage`. A native handler runs the existing local engine and replies. The content script applies complete, unchanged DOM groups immediately and then requests the next batch. This is progressive delivery of completed text blocks, not a promise of token-by-token output.

The installed Xcode 26.5 template uses manifest version 3, a module background script, and `com.apple.Safari.web-extension` as its extension point. Apple describes the [native messaging bridge](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension); content scripts must go through the extension's background script. The containing iOS app cannot push messages into the web extension directly.

## Page behavior

- The header shows the source language, target language, translated-block count, progress, Stop, Show original and Close.
- The first completed block appears immediately. A slow later block does not hide earlier results or require reopening a native sheet.
- Stop halts new work and retains already displayed translations. Close restores the original text where the original DOM nodes are still intact.
- Changing language starts a fresh generation from the saved originals. Late responses from the previous generation are ignored.
- Original/translation toggling also works on a partially translated page. Untranslated content remains readable in its source language.
- Model preparation and translation have distinct progress states. Translation progress is based on actual completed work.
- Inputs, editable content, code, excluded content and changed/replaced DOM nodes remain protected. No translated string is treated as HTML.
- Navigation ends the old operation. Dynamically replaced blocks are skipped; new page content can be translated by another explicit run.

## Native execution requirements

Native requests must remain independently recoverable: iOS may terminate a native handler between messages. The page owns its run ID, original text and completed-block map. It must not depend on a native task continuing after its request is completed.

Model calls must be serialized to avoid concurrent model preparation or unloading across tabs. Each operation needs a read lease for its model files. No page text should be written to the shared model directory. An active batch must have strict input and output limits; cancellation stops scheduling further work and rejects stale replies.

The memory-mapped CPU runtime is used in production. Simulator tests establish the native-message/DOM lifecycle; physical iPhone memory limits and sustained scheduling still require device measurements.

## Acceptance evidence

1. Real local inference through the Safari native-message bridge, showing block 1 while later blocks are still pending.
2. Header progress matching completed blocks; no stale output after changing languages or navigating.
3. Stop, original toggle, close and exact restoration of unchanged original nodes.
4. Working links, preserved inline markup and untouched editable/protected content.
5. Usable scrolling and reading position while results arrive, plus narrow-screen and accessibility checks.
6. Physical iPhone measurements for model loading, memory and sustained translation, including extension restart between batches.

Items 1–4 have production simulator and DOM/native test evidence linked above. Light/dark header appearance is checked. Broad website accessibility coverage, physical-device stress measurements and native process termination between batches remain follow-up verification. The Share action template icon was fixed in build 14 and is retained in build 15.

## Prototype evidence

`Prototypes/SafariStreamingProbe` demonstrated content-script → background-script → Swift native handler → CTranslate2 CPU → page updates with the real EN→FI model. The first screenshot shows one translated paragraph and two original English paragraphs; the timeline later reaches three completed translations. No translation server supplies the output.

An intentional eight-second delay after the first result makes the intermediate screenshot reproducible. It is not inference time. Each native request explicitly loads and unloads the model. The three observed requests used the same native process; process restart between requests has not been exercised.

This probe uses the direct CTranslate2 C API and a model bundled only into the probe. It does not yet verify the production shared-pack service, arbitrary page grouping, language switching, cancellation, restoration or physical-device limits. See [probe results](../../../Prototypes/SafariStreamingProbe/README.md).
