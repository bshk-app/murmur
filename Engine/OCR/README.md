# MurmurOCR

Local, on-demand multilingual OCR for the iOS photo translator. `Scripts/prepare.sh` prepares pinned native binaries; CocoaPods, Ruby/xcodeproj, Xcode and uv are required. The iOS build.sh calls it before Tuist generation. Native artifacts are local build outputs and are not committed. Swift code is in MurmurOCR; the worker-only Objective-C++ bridge is in COCR.

The two bundled FP16 tiny detector graphs use fixed portrait/landscape shapes. Images are scaled with aspect ratio preserved, padded, and their detected coordinates mapped back to the upright original. This differs from the benchmark's five exact dataset shapes and needs its own quality validation. Recognizer weights download on demand from pinned RapidOCR v3.9.2 URLs and are SHA256-checked against model-provenance.json. No photo or recognized text is sent to the model host.

The OCR catalog covers the current 34 translation language codes: v6 tiny for Latin scripts, v5 Cyrillic for Cyrillic (including sr), and separate v5 Greek/Arabic models. This is declared model coverage, not real-photo qualification for all languages. Serbian source here uses Cyrillic; Latin Serbian is not separately exposed in this initial screen. Bidirectional presentation is delegated to SwiftUI, with logical strings retained for translation.

Native sessions are created/released within one recognition call. The Swift actor serializes native access; the photo controller waits for cancellation cleanup before closing. Source images are downsampled upright to max 2048 pixels and removed from temporary storage on close. A model download can be cancelled; an active native inference finishes before its cancelled result is discarded.

Test and release limitations: fixed-shape padding quality must be compared with the benchmark, real Cyrillic/Finnish/Arabic/Greek scenes need broader qualification, and the combined OCR+MT flow needs device memory/latency measurements. This package does not implement live video tracking or claim universal OCR accuracy.
