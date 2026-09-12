# European OPUS translation catalog

The baseline now resolves through `TranslationProfileCatalog` for preparation,
execution and offline availability. Its 52 direction bindings identify 44
distinct weight/tokenizer assets. New qualified profiles remain disabled until
the quality and device evidence gate passes; discovery is not qualification.

Run the translation tests with `swift test --package-path Engine/Translation`.
The generated baseline and complete direct-candidate audit are checked with
`node Engine/Translation/Scripts/generate-quality-baseline.mjs --check` and
`node Engine/Translation/Qualification/validate-audit.mjs`.

Verified 2026-09-07. All 24 official EU languages, plus Russian and Ukrainian, have OPUS routes in both directions. There are 52 downloadable direction packs (including the six existing Russian/Finnish packs) and 650 non-identity language combinations. A direct Russian–Finnish model is retained; other non-English combinations use two strict OPUS passes through English. Identity requests return the original text.

The catalog is independent of Mozilla preview availability and speech recognition. Where Mozilla has no stable pack, OPUS supplies the preview as well as the final translation. Current Parakeet speech recognition supports 25 catalog languages; Irish is a translation language, not a newly enabled Irish speech recognizer. The language-pack picker can prepare Irish in both directions; the dictation picker does not falsely offer unsupported Irish recognition.

Models are downloadable assets rather than bundled weights. No bulk download of all languages is performed on the phone. Some checkpoints are tc-big, others are standard OPUS-MT. A successful smoke test validates loading and decoding, not uniform translation quality or a comprehensive language benchmark.

## Reproducible preparation

1. `node Engine/Translation/Scripts/discover-eu-opus.mjs` records the chosen upstream model cards and original archive URLs.
2. `uv run Engine/Translation/Scripts/prepare-eu-opus.py` converts original archives with CTranslate2 4.8.2 INT8.
3. When original Irish archives are unavailable or the South Slavic archive vocabulary cannot be parsed, `uv run Engine/Translation/Scripts/prepare-eu-hf-fallback.py` converts pinned official Helsinki-NLP HF checkpoints. Its config appends EOS for raw SentencePiece callers, matching MarianTokenizer preprocessing.
4. Rerun the original converter to reverify all existing outputs; it preserves the valid HF fallbacks.
5. `node Engine/Translation/Scripts/register-eu-opus.mjs` verifies every hash/size, emits EuropeanQualityDigests.swift, and records smoke outputs in eu-opus-verification.json.

Distribution: [existing MurMur mirror](https://huggingface.co/beshkenadze/murmur-translation-ct2), update [7851fd226891a81d38cf71daa20feb50b4087fd3](https://huggingface.co/beshkenadze/murmur-translation-ct2/commit/7851fd226891a81d38cf71daa20feb50b4087fd3). Each folder includes per-source attribution, source SHA/revision, model-card license, output hashes and target tags. Portuguese explicitly selects European Portuguese.

## Added direction packs

| Direction | Source checkpoint | Download MB |
| --- | --- | ---: |
| en → bg | opus-mt-tc-big-en-bg | 252.1 |
| bg → en | opus-mt-tc-big-bg-en | 252.1 |
| en → cs | opus-mt-en-cs | 84.3 |
| cs → en | opus-mt-tc-big-ces_slk-en | 248.2 |
| en → da | opus-mt-tc-big-en-gmq | 244.9 |
| da → en | opus-mt-tc-big-gmq-en | 245.0 |
| en → de | opus-mt-en-de | 81.7 |
| de → en | opus-mt-de-en | 81.7 |
| en → el | opus-mt-tc-big-en-el | 250.4 |
| el → en | opus-mt-tc-big-el-en | 250.4 |
| en → es | opus-mt-tc-big-en-es | 245.3 |
| es → en | opus-mt-tc-big-cat_oci_spa-en | 245.0 |
| en → et | opus-mt-tc-big-en-et | 247.7 |
| et → en | opus-mt-tc-big-et-en | 246.8 |
| en → fr | opus-mt-tc-big-en-fr | 243.2 |
| fr → en | opus-mt-tc-big-fr-en | 243.2 |
| en → ga | opus-mt-en-ga | 78.0 |
| ga → en | opus-mt-ga-en | 78.0 |
| en → hr | opus-mt-en-zls | 78.7 |
| hr → en | opus-mt-tc-big-zls-en | 250.9 |
| en → hu | opus-mt-tc-big-en-hu | 247.4 |
| hu → en | opus-mt-tc-big-hu-en | 247.4 |
| en → it | opus-mt-tc-big-en-it | 244.6 |
| it → en | opus-mt-tc-big-it-en | 244.6 |
| en → lt | opus-mt-tc-big-en-lt | 249.1 |
| lt → en | opus-mt-tc-big-lt-en | 249.1 |
| en → lv | opus-mt-tc-big-en-lv | 248.8 |
| lv → en | opus-mt-tc-big-lv-en | 248.2 |
| en → mt | opus-mt-en-mt | 80.6 |
| mt → en | opus-mt-mt-en | 80.6 |
| en → nl | opus-mt-en-nl | 86.7 |
| nl → en | opus-mt-nl-en | 86.7 |
| en → pl | opus-mt-en-zlw | 81.8 |
| pl → en | opus-mt-tc-big-zlw-en | 248.6 |
| en → pt | opus-mt-tc-big-en-pt | 245.1 |
| pt → en | opus-mt-ROMANCE-en | 85.4 |
| en → ro | opus-mt-tc-big-en-ro | 244.5 |
| ro → en | opus-mt-ROMANCE-en | 85.4 |
| en → sk | opus-mt-en-sk | 82.9 |
| sk → en | opus-mt-tc-big-ces_slk-en | 248.2 |
| en → sl | opus-mt-en-zls | 78.7 |
| sl → en | opus-mt-tc-big-zls-en | 250.9 |
| en → sv | opus-mt-tc-big-en-gmq | 244.9 |
| sv → en | opus-mt-tc-big-gmq-en | 245.0 |
| en → uk | opus-mt-tc-big-en-zle | 253.3 |
| uk → en | opus-mt-tc-big-zle-en | 252.8 |

## Validation

EuropeanTranslationTests verifies all 650 routes resolve to pinned artifacts. The native Swift/C++ test translates all 46 new directions and runs a full TranslationSession preparation/preview/finalization/unload for Maltese → Irish without Mozilla packs. Model counts return to zero after eviction. Results are in eu-opus-native-verification.json. The associated quality-download tests also pass; the existing opt-in network test remains skipped. Core suite: 58 passing. Signed Debug and Release builds pass.

The published mirror was checked against every newly registered artifact: all 237 required files have the expected size; all 138 LFS artifacts also have matching remote SHA-256 identifiers. See eu-opus-mirror-verification.json.

The unlocked iPhone 15 Pro subsequently passed the production download/prepare/preview/final/unload checks for EN→DE, DE→FR, EN→PT, EN→HR, EN→MT and MT→GA. Each case ended with zero retained translation models. See eu-opus-device-verification.json. These are six device cases, not a runtime benchmark of all 650 routes. Release was restored and launched after the probe.
