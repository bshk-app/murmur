// C surface over bergamot-translator, so Swift can link it without a C++
// interop mode and without exceptions crossing the boundary.
//
// The engine is CPU-only. That is the point rather than a limitation: Nemotron
// and Parakeet already hold the GPU under a 60% memory cap, and translation in
// the two-line mode runs while they are working, not instead of them.
//
// One handle owns one loaded model and is NOT thread-safe; give each concurrent
// caller its own, or serialise. Translation is synchronous and takes roughly
// 30 ms for a fifteen-second utterance on an M-series machine.

#ifndef MURMUR_MT_H
#define MURMUR_MT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MurmurMTEngine MurmurMTEngine;

/// Load the model described by `config_path` (a bergamot YAML config).
/// Returns NULL on failure and writes a message into `error_out`, which the
/// caller frees with `murmur_mt_string_free`. Pass NULL for `error_out` to
/// discard the message.
MurmurMTEngine *murmur_mt_open(const char *config_path, char **error_out);

/// Translate one UTF-8 segment. Returns a NUL-terminated UTF-8 string the
/// caller frees with `murmur_mt_string_free`, or NULL on failure.
///
/// An empty or whitespace-only input yields an empty string rather than an
/// error: a segment the recogniser produced no words for is not a fault.
char *murmur_mt_translate(MurmurMTEngine *engine, const char *utf8,
                          char **error_out);

void murmur_mt_close(MurmurMTEngine *engine);

void murmur_mt_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif  // MURMUR_MT_H
