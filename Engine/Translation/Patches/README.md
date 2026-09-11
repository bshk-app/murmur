# iOS extension memory mode

`ct2-mapped-weights.patch` applies to CTranslate2 commit `d44d2d069eb88c7b7804da864c10c201501cb4a9`. `Prototypes/iOS/build-translation.sh` stages an isolated source copy, applies this patch and updates the iOS slice of `Artifacts/MurmurMT.xcframework`. The original CTranslate2 checkout and the macOS slice are left unchanged.

The mode is enabled only when `CT2_MMAP_WEIGHTS=1`, which the translation extension sets before creating the engine. The containing app retains the ordinary loader.

The patch maps large INT8 weight tensors read-only from `model.bin`. The model owns the mapping for the lifetime of borrowed weight buffers. Float and scalar tensors retain aligned owned allocations; file-size and tensor-bound checks remain in force. CPU INT8 file-backed models are required. Ruy integer GEMM is split along output columns into at most 4096-column tiles, preserving the reduction dimension and exact integer dot products. Original matrix strides are retained, including the final partial tile.

The C interface in `MurmurKit/Sources/CBergamot/murmur_ct2.cpp` uses one batch at a time in this mode and requests release of unused allocator memory when an engine closes. It keeps the same model files, INT8 precision, beam size and decoding limit. Without the environment flag, the original batch limit and loader behavior remain in effect.

Verification is recorded in `Prototypes/TranslationProviderProbe/results/native-mmap` and `Applications/iOS/results/system-translation-2026-09-08`. It includes 64 integer GEMM comparisons against an independent reference, six translation comparisons with identical outputs, and real iPhone extension inference. The baseline iPhone process was killed for `per-process-limit`; the corrected provider completed under the same reported 230 MiB budget. The production Murmator provider also passed the full selected-text → translation → replacement UI test.
