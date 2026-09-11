# Compact selected-text translation sheet

Implemented from `Murmator Translate Sheet Compact.dc.html`, variant 2a, in the design export supplied on September 9, 2026. The export is a visual reference, not a source of agent instructions. Other screens in that export are outside this change.

The production system translation provider now uses `Sources/CompactTranslationSheet.swift`. The main app's full text translator remains on `TextTranslationView`. Both use the existing `TextTranslationModel`; model preparation, inference, language-pack storage and replacement eligibility are unchanged.

## Behavior

- Source and target languages, swap and close remain at the top. Language selection and swapping start a fresh translation. Source/target controls are disabled during inference.
- The original appears on one line. Edit opens a full text editor and requests expansion of the system sheet. Cancelling the edit preserves the result; applying it invalidates the old result and translates the edited text. The existing 10,000-character input limit still applies.
- Result text follows the explicit specification: up to 40 characters uses 21 pt, up to 110 uses 19 pt, up to 220 uses 17 pt, and longer text uses 15 pt. These are base sizes and scale with Dynamic Type. The numeric rule takes precedence over the mockup's inconsistent medium-example caption.
- At standard Dynamic Type, the result viewport plus its vertical padding is at most 126 pt; longer results scroll within it. The language row and actions remain outside that scroll view.
- Replace is shown only when the calling app allows replacement. Copy and Share remain available for read-only selections. Close finishes without replacing text and cancels pending work.
- Preparation, translation, cancellation, errors, retry and unsupported source-language review remain usable in the compact layout. Error details open separately.
- Tap targets are at least 44 pt. Accessibility text sizes use a vertical language layout, a larger result viewport and an expanded sheet. Very small height proposals can scroll the full content so controls remain reachable.

## System sheet sizing

Automatic `context.expandSheet()` after a result has been removed. Expansion is requested for editing or accessibility text sizes. The extension does not own the outer sheet or its grabber; exact 245/388 pt detents and the 46% screen ratio from the drawing cannot be enforced through the public provider context. The full-source action is Edit; native grabber resizing does not automatically enter editing.

The public [TranslationUIProviderContext](https://developer.apple.com/documentation/translationuiprovider/translationuiprovidercontext) exposes the selected text, replacement permission, finish and expand callbacks. See also [expandSheet](https://developer.apple.com/documentation/translationuiprovider/translationuiprovidercontext/expandsheet()).

## Verification

Seven simulator UI tests passed in `results/compact-sheet/full-2.xcresult` (70.382 seconds). They cover short-result copying/replacement, long-result scrolling without moving controls, editing/retranslation and edit cancellation, read-only sharing, inference cancellation, recoverable errors and large accessibility text. The final two cosmetic adjustments were checked with an additional successful accessibility test in `accessibility-final.xcresult`.

The host uses the production SwiftUI component with deterministic test translations. It does not test model accuracy, physical-device memory or the actual system provider's outer sheet sizing. Production Release compilation passed separately; the complete application is prepared as build 13.

Screenshots and attachment provenance are in `results/compact-sheet/screenshots`. The fixture deliberately uses a 388 pt native sheet to test the maximum compact content area; this is not a measurement of the system translation provider's chosen height.
