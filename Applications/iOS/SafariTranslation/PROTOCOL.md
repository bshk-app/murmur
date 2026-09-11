# Progressive Safari translation protocol (implementation contract)

Production implementation for the user's requested page UI. Root owns Project.swift, Share Action handoff and main-app settings/help. Frontend agent owns `SafariTranslation/Resources/**` and its JS tests. Native agent owns `SafariTranslation/SafariWebExtensionHandler.swift` and `Shared/SafariTranslationHandoff.swift` plus its tests. Coordinate changes to this protocol before altering field names.

## Web content activation

Manifest v3, background module, permissions `nativeMessaging`, `activeTab`, `scripting`. Content script at document_idle in top frame only, matching HTTP and HTTPS pages, installs an inert listener; **no page collection or inference until explicit activation**. A Safari extension action click injects/reuses the script and sends `{type:"open"}`. The existing Share Action performs the DOM handshake below, creates an authenticated one-use ticket through shared native code, then immediately completes. It never translates the page in its modal.

Action preprocessing dispatches event `murmator-stream-probe` on `document.documentElement`; an installed content listener sets `data-murmator-stream-ready="1"` synchronously. Action reads and removes that attribute. Handoff finalize sets `data-murmator-stream-ticket` to a UUID, dispatches `murmator-stream-start`, then removes the attribute. Content reads the ticket synchronously, asynchronously claims it using native config, then opens the page header and starts translation. A webpage-forged start event without a valid ticket must not translate. Script listeners must be idempotent. Regular popup/action activation is a trusted background message, not a DOM event.

## Native requests via background

All responses use `{ok:true,...}` or `{ok:false,code,message?}`. Error codes: `notReady`, `invalidRequest`, `invalidTicket`, `busy`, `cancelled`, `translationFailed`.

- Config: `{type:"config",sample:string<=1500,documentLanguage:string<=64,url:string<=16384,ticket?:UUID}`. If ticket is supplied, native MUST validate and consume it against page URL before returning config. Response: `{ok:true,ready:boolean,source:string,target:string,languages:[{code,name}],targets:{[sourceCode]:[targetCode]}}`. Detect from sample/documentLanguage with the existing quality language allowlist; preserve a supported remembered target different from source. Names localized through Locale.current. Native uses TranslationPaths/TranslationPreferences and the same installed model packs as the app.
- Translate: `{type:"translate",runId:string<=128,requestId:string<=128,source:string,target:string,groups:[{id,runs:[{id,text}]}],totalCharacters:integer}`. Maximum 8 groups, 32 runs, 4800 UTF-16 units per request. Input must also pass existing PageTranslationRequest.validate. Response: `{ok:true,runId,requestId,translations:[{id,text}],fallbackGroups:number}`. Use the production PageTranslationProcessor + PageTranslationSession, including model downloads, bounded calls, cancellation checks and file read leases. Unload per request so correctness does not depend on native process persistence. Max output 24000 UTF-16 units.
- Progress: `{type:"progress",runId,requestId}`. Response `{ok:true,phase:"idle"|"preparing"|"translating"|"cancelling",fraction?:number,completed?:number,total?:number}`. Must be serviceable while native translation/download is active, without waiting behind it. No other tab's text is exposed.
- Cancel: `{type:"cancel",runId,requestId}`. Cancels only matching active work; benign success when no matching work remains. Normal reply `{ok:true}`. One active native translation at a time; another request gets `busy`, which the client can retry with bounded backoff. Do not allow actor reentrancy to overlap model work.

Background validates own extension sender and HTTP(S) top-frame/tab context. No externally_connectable permission or arbitrary webpage native-message relay. Content holds the run generation and ignores stale results after close, language change or navigation.

## Shared handoff helper

`enum SafariTranslationHandoff` provides `static func create(pageURL: String) throws -> String` and `static func consume(token: String, pageURL: String) throws`. UUID tokens, expiry around 60 seconds, single consumption, URL match ignoring fragment. Use a small separate ticket directory in TranslationPaths.shared with atomic operations/locking; store no page text, prune expired tickets, cap files. Never use the model read/write lock for ticket operations. The helper is included in Action and Web Extension targets.

## Page controller behavior

Retain safe DOM collection/grouping from the current Page.js: inputs/forms/editable/code/hidden/translate=no excluded, snapshots use original node references and ancestor paths, changed/moved blocks skipped. Collect originals only on explicit activation. For native message bounds, split large groups into bounded jobs and apply each original DOM group atomically when all its jobs are complete; preserve whitespace. Small formatted groups can use native marker preservation/fallback. Native APIs never return HTML.

Header stays on the page, shows actual completed-work percentage, target language selector (and source override), original toggle, Stop and Close. First completed blocks appear before the remaining queue finishes. Stop retains translated blocks; Close cancels and restores all unchanged originals. Target change cancels old work, uses saved originals and starts a new generation. Original toggle must also work during translation. Excluded/page-mutated text remains untouched. Page text is never sent to a translation server or stored on disk. JS uses browser.i18n with six localizations en/ru/de/es/fr/fi.

Missing first-run setup or model failures are shown in the page header; model download progress is distinct from page-translation progress. Native model preparation may take time, so content polls Progress while awaiting Translate. Do not fake progress or require keeping the native Share sheet open.

The background entry point injects `content.js`, the frontend's complete self-contained bundle. Manifest icon paths should use existing template cat assets or a code-native SVG. Root supplies project integration. Testing must use real production shared models and the actual Safari bridge in addition to focused DOM tests; no production test-fixture paths.
