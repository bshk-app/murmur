Pinned source: https://github.com/beshkenadze/mlx-audio-swift at 6768a6d7233a1ac673d3d117fc3dd8ae1d8a9de4.
Speech/Core/VAD targets only. Includes the tested Cohere vocabulary fallback and Whisper quantized-loading/embedding fixes from Prototypes/iOS/patches/quantized-model-loaders.patch.
Local patch: `ModelUtils.resolveOrDownloadModel` rejects cached or downloaded `.safetensors` files cut short of the tensors their header lists (`SafetensorsIntegrity`); upstream accepted any non-empty file.
Vendored so package consumers do not need build-time checkout mutation; no remote fork was published.
