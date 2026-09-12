CanaryManager.swift derives from FluidInference/FluidAudio, Apache-2.0 license:
https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudio/ASR/Canary/CanaryManager.swift

The upstream license is retained in LICENSE-FluidAudio.

Probe adaptations: remove default downloader (all model paths are explicit),
correct the stale truncation comment, release prediction temporaries per token,
and compute the half-float exponent as `exp + 112` to avoid unsigned intermediate
underflow for half-floats below 1.0. The helper is internal for regression checks.
Token decoding also checks task cancellation so backgrounding can stop the probe.

The downloaded NVIDIA model and its conversion are CC-BY-4.0. Attribution:
NVIDIA NeMo team, Canary-1b-v2; Core ML INT4 conversion by FluidInference.

Murmur application qualification adaptation: types prefixed to avoid collisions;
removed long-window overlapping token merge; strict <=15 second input guard,
normalized finite PCM validation, official 25-language ASR allowlist, and
source=target prompts. CPU+GPU requested for neural stages; FP32 preprocessing
remains CPU-only. The candidate is not a qualified production ASR default.

Experimental interactive adaptation (2026-09): a single loaded runtime accepts
source/target per window, reuses encoded audio for transcription and direct
English↔24-language translation, and reports decoder-limit failures explicitly.
A pinned Hub installer verifies all files with bounded SHA256 reads before
atomic snapshot publication. The compatibility qualification wrapper remains.
This does not qualify translation accuracy or change the default speech model.
