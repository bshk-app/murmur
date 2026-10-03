# Photo translation design import and native implementation

Imported `Murmator Photo Translate Prototype.dc.html` from Claude Design project `71b76ff3-1995-4810-8583-36908c45101d` through Claude CLI and the `claude_design` MCP. Existing authentication worked; no design project content was modified. HTML, support runtime and both mascot images are preserved beside this file. `import.json` records local checksums and file sizes. `handoff.md` describes the original prototype.

The native screen is `Applications/iOS/Sources/PhotoTranslation/PhotoTranslationView.swift`, shared by the main app and Murmator Photo preview. It adopts the warm light/dark palette, dark photo area, floating language/original controls, translation plaques, dashed error plaques, numbered full-text panel, error review sheet and correction flow. The full-text panel can be expanded. Progress and individual-block retry use actual engine state; successful retries produce a brief confirmation. Successful translations remain visible while another block is processed.

Intentional native adaptations:

- Capture opens the system iOS camera. The landing view offers gallery/camera rather than pretending to show a live preview. The prototype's in-screen camera and flash control are not implemented here.
- The native keyboard replaces the drawn keyboard. Native share and language menus replace nonfunctional prototype controls.
- The prototype's hard-coded suggestion to remove a specific letter is omitted: OCR does not provide evidence for that suggestion. Users can edit any text themselves.
- Cancellation ends real work; there are no fake inference timers. Cancellation remains available during retries too.
- Photos are aspect-fitted so text coordinates remain aligned, rather than forcing every photo into the example scene. Full text stays available when an overlay is too small.
- Failure review offers Edit, Retry and Skip; Skip closes review without mislabeling the block as translated. Editing supports both Save correction and Translate block.

No changes to OCR defaults, model selection or translation engines were part of this visual implementation. The physical iPhone was not updated.

Simulator screenshot: `Prototypes/OCRBenchmark/results/photo-design-light.png`. The screenshot uses a real Finnish source photo and actual English translation, not the prototype's fixed example text.

Validation: arm64 simulator preview/main builds passed. Opening/closing from Notes and ordinary translation/correction/cancellation UI tests passed. The partial-failure test initially overscrolled the new compact panel; after switching the test to target the exact row it passed (42.71 s), including actual OCR/MT, failure review, editing and retry. Real Finnish-photo checks passed in both themes; the dark screenshot is `Prototypes/OCRBenchmark/results/photo-design-dark.png`. Simulator appearance was restored to light after capture. Localization generation validated 527 keys across six languages, and whitespace checks passed. Device camera capture and very large Dynamic Type still need visual/device qualification.
