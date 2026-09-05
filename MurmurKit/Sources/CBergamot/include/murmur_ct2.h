// C surface over CTranslate2, the quality engine used for the text that
// actually gets pasted.
//
// Why a second engine at all: on FLORES+ devtest ru->en (1012 rows, beam 1,
// one thread, M1 Max) the shipped bergamot student scores 56.79 chrF++ at a
// 12 ms median, and opus-mt tc-big under CTranslate2 int8 scores 60.40 at
// 378 ms. The +3.61 chrF++ is worth having on a final paste and impossible to
// afford on a live draft that retranslates several times a second, so the two
// engines are kept and routed by phase rather than one being chosen.
//
// This shim deliberately does NOT carry its own SentencePiece. CTranslate2
// does no tokenisation, and libmurmurmt.a already exports marian's copy;
// vendoring a second would be a duplicate-symbol conflict at link time. Both
// shims therefore live in one merged archive and share that copy, which is
// also why this header sits beside murmur_mt.h.
//
// Like the bergamot handle, one engine owns one loaded model, is NOT
// thread-safe, and translates synchronously.

#ifndef MURMUR_CT2_H
#define MURMUR_CT2_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MurmurCT2Engine MurmurCT2Engine;

/// Load a converted CTranslate2 model directory. It must hold `model.bin` and
/// `config.json` as written by `ct2-opus-mt-converter`, plus the `source.spm`
/// and `target.spm` the weights were trained against.
///
/// The tokenizer paths are derived rather than passed: a CT2 directory whose
/// SentencePiece models came from a different checkpoint produces fluent text
/// with no relation to the input, which is a failure that reads like success.
/// Keeping the pairing inside one directory makes that hard to do by accident.
///
/// Returns NULL on failure and writes a message into `error_out`, which the
/// caller frees with `murmur_ct2_string_free`. Pass NULL to discard it.
MurmurCT2Engine *murmur_ct2_open(const char *model_dir, char **error_out);

/// Translate one UTF-8 segment. Returns a NUL-terminated UTF-8 string the
/// caller frees with `murmur_ct2_string_free`, or NULL on failure.
///
/// Empty or whitespace-only input yields an empty string rather than an error,
/// matching murmur_mt_translate: a segment with no words is not a fault.
char *murmur_ct2_translate(MurmurCT2Engine *engine, const char *utf8,
                           char **error_out);

void murmur_ct2_close(MurmurCT2Engine *engine);

void murmur_ct2_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif  // MURMUR_CT2_H
