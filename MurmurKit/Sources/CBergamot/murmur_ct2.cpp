#include "murmur_ct2.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <algorithm>
#include <fstream>
#include <vector>

#include "ctranslate2/translator.h"
#include "sentencepiece_processor.h"

namespace {

// Beam 1 rather than tc-big's own beam 4. Measured on FLORES+ devtest ru->en:
// beam 4 gives 60.61 chrF++ / 35.35 BLEU against beam 1's 60.41 / 35.58, for
// 390 ms instead of 349. The quality difference changes sign between the two
// metrics, which is what noise looks like; the latency difference does not.
constexpr size_t kBeamSize = 1;
constexpr size_t kMaxDecodingLength = 512;

// opus-mt is a sentence-level model and bergamot does its own splitting
// (`ssplit-mode: sentence`); CTranslate2 does none. Handing it a whole
// dictation is not merely slow, it is wrong: measured on 4514 characters of
// Russian, one call returned 360 characters that trailed off into a repeating
// loop - a confident, successful-looking answer that had silently dropped most
// of the input. So the shim splits, and these bound what one decoder call may
// ever see.
constexpr size_t kMaxSourcePieces = 200;
constexpr size_t kMaxBatchSize = 8;

char *copy_c_string(const std::string &value) {
  char *out = static_cast<char *>(std::malloc(value.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, value.c_str(), value.size() + 1);
  return out;
}

void report(char **error_out, const std::string &message) {
  if (error_out != nullptr) *error_out = copy_c_string(message);
}

std::string join_path(const std::string &directory, const char *leaf) {
  if (directory.empty()) return leaf;
  if (directory.back() == '/') return directory + leaf;
  return directory + "/" + leaf;
}

bool is_blank(const char *utf8) {
  for (const char *p = utf8; *p != '\0'; ++p) {
    unsigned char c = static_cast<unsigned char>(*p);
    // Only ASCII whitespace: any multi-byte sequence is content, and treating
    // a high byte as blank would silently drop non-Latin input.
    if (c > 0x20) return false;
  }
  return true;
}

bool is_blank(const std::string &text) { return is_blank(text.c_str()); }

// Byte-oriented on purpose. UTF-8 continuation bytes are all >= 0x80, so an
// ASCII '.', '!' or '?' can never occur inside a multi-byte character and
// scanning for them cannot split one in half.
size_t terminator_length(const std::string &text, size_t i) {
  const char c = text[i];
  if (c == '.' || c == '!' || c == '?') return 1;
  // U+2026 HORIZONTAL ELLIPSIS, which dictation produces for a trailing off.
  if (i + 2 < text.size() && static_cast<unsigned char>(text[i]) == 0xE2 &&
      static_cast<unsigned char>(text[i + 1]) == 0x80 &&
      static_cast<unsigned char>(text[i + 2]) == 0xA6) {
    return 3;
  }
  return 0;
}

// Closing punctuation that belongs to the sentence it follows, so that
// `сказал он."` does not become a sentence plus a stray quote.
size_t closer_length(const std::string &text, size_t i) {
  const char c = text[i];
  if (c == '"' || c == '\'' || c == ')' || c == ']') return 1;
  const unsigned char b0 = static_cast<unsigned char>(text[i]);
  if (i + 1 < text.size() && b0 == 0xC2 &&
      static_cast<unsigned char>(text[i + 1]) == 0xBB) {
    return 2;  // U+00BB RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK
  }
  if (i + 2 < text.size() && b0 == 0xE2 &&
      static_cast<unsigned char>(text[i + 1]) == 0x80) {
    const unsigned char b2 = static_cast<unsigned char>(text[i + 2]);
    if (b2 == 0x9D || b2 == 0x99) return 3;  // U+201D, U+2019
  }
  return 0;
}

std::vector<std::string> split_sentences(const std::string &line) {
  std::vector<std::string> out;
  size_t start = 0;
  size_t i = 0;
  while (i < line.size()) {
    const size_t term = terminator_length(line, i);
    if (term == 0) {
      ++i;
      continue;
    }
    size_t end = i + term;
    while (end < line.size()) {
      const size_t closer = closer_length(line, end);
      if (closer == 0) break;
      end += closer;
    }
    // A terminator only ends a sentence when whitespace or the end of the line
    // follows it. Without this, "т.е." and "3.5" each become two sentences.
    const bool boundary =
        end >= line.size() ||
        static_cast<unsigned char>(line[end]) <= 0x20;
    if (!boundary) {
      i = end;
      continue;
    }
    std::string piece = line.substr(start, end - start);
    if (!is_blank(piece)) out.push_back(piece);
    while (end < line.size() &&
           static_cast<unsigned char>(line[end]) <= 0x20) {
      ++end;
    }
    start = end;
    i = end;
  }
  if (start < line.size()) {
    std::string piece = line.substr(start);
    if (!is_blank(piece)) out.push_back(piece);
  }
  return out;
}

}  // namespace

struct MurmurCT2Engine {
  std::unique_ptr<ctranslate2::Translator> translator;
  sentencepiece::SentencePieceProcessor source;
  sentencepiece::SentencePieceProcessor target;
  // Empty unless the checkpoint is an OPUS-MT *group* model, which cannot
  // pick a target language on its own.
  std::string target_tag;
};

namespace {

// A group checkpoint such as eng->zle covers several target languages and
// selects between them from a leading tag token like `>>rus<<`. Without it the
// model still produces fluent output - in whichever language it guesses - so
// the tag lives beside the weights rather than being passed per call: a
// directory either is a tagged model or is not, and that cannot drift.
std::string read_target_tag(const std::string &directory) {
  std::ifstream file(join_path(directory, "target_tag.txt"));
  if (!file) return "";
  std::string tag;
  std::getline(file, tag);
  while (!tag.empty() &&
         static_cast<unsigned char>(tag.back()) <= 0x20) {
    tag.pop_back();
  }
  return tag;
}

}  // namespace

MurmurCT2Engine *murmur_ct2_open(const char *model_dir, char **error_out) {
  if (model_dir == nullptr) {
    report(error_out, "model directory is null");
    return nullptr;
  }
  try {
    auto engine = std::make_unique<MurmurCT2Engine>();
    const std::string dir(model_dir);

    const auto source_status = engine->source.Load(join_path(dir, "source.spm"));
    if (!source_status.ok()) {
      report(error_out, "source.spm: " + source_status.ToString());
      return nullptr;
    }
    const auto target_status = engine->target.Load(join_path(dir, "target.spm"));
    if (!target_status.ok()) {
      report(error_out, "target.spm: " + target_status.ToString());
      return nullptr;
    }

    // int8 on CPU with a single thread in each dimension. The GPU is not an
    // option here rather than an omission: Nemotron and Parakeet hold it under
    // a 60% memory cap, and this engine runs while they are working.
    ctranslate2::ComputeType compute = ctranslate2::ComputeType::INT8;
    engine->translator = std::make_unique<ctranslate2::Translator>(
        dir, ctranslate2::Device::CPU, compute,
        /*device_indices=*/std::vector<int>{0},
        /*tensor_parallel=*/false,
        ctranslate2::ReplicaPoolConfig{/*num_threads_per_replica=*/1,
                                       /*max_queued_batches=*/0,
                                       /*cpu_core_offset=*/-1});
    engine->target_tag = read_target_tag(dir);
    return engine.release();
  } catch (const std::exception &error) {
    report(error_out, error.what());
    return nullptr;
  } catch (...) {
    report(error_out, "unknown failure opening the CTranslate2 model");
    return nullptr;
  }
}

char *murmur_ct2_translate(MurmurCT2Engine *engine, const char *utf8,
                           char **error_out) {
  if (engine == nullptr || utf8 == nullptr) {
    report(error_out, "engine or input is null");
    return nullptr;
  }
  if (is_blank(utf8)) return copy_c_string("");
  try {
    const std::string input(utf8);

    // Line structure is the user's, not the model's, so it survives the round
    // trip: a dictation pasted back as one run-on paragraph would be a
    // regression even if every sentence were perfect.
    std::vector<std::vector<std::string>> batch;   // one entry per decoder call
    std::vector<size_t> line_of_chunk;             // which line it belongs to
    size_t line_count = 0;

    size_t line_start = 0;
    while (line_start <= input.size()) {
      size_t line_end = input.find('\n', line_start);
      if (line_end == std::string::npos) line_end = input.size();
      const std::string line = input.substr(line_start, line_end - line_start);

      for (const std::string &sentence : split_sentences(line)) {
        std::vector<std::string> pieces;
        const auto status = engine->source.Encode(sentence, &pieces);
        if (!status.ok()) {
          report(error_out, "encode: " + status.ToString());
          return nullptr;
        }
        // A sentence with no terminator - run-on dictation - can still be
        // longer than the decoder should ever see, so length bounds it even
        // when punctuation did not.
        for (size_t at = 0; at < pieces.size(); at += kMaxSourcePieces) {
          const size_t upto = std::min(at + kMaxSourcePieces, pieces.size());
          std::vector<std::string> chunk(pieces.begin() + at,
                                         pieces.begin() + upto);
          // Prepended per chunk, not per input: every decoder call needs its
          // own tag, and a chunked long sentence would otherwise lose the
          // target language after the first chunk.
          if (!engine->target_tag.empty()) {
            chunk.insert(chunk.begin(), engine->target_tag);
          }
          batch.push_back(std::move(chunk));
          line_of_chunk.push_back(line_count);
        }
      }

      ++line_count;
      if (line_end == input.size()) break;
      line_start = line_end + 1;
    }

    if (batch.empty()) return copy_c_string("");

    ctranslate2::TranslationOptions options;
    options.beam_size = kBeamSize;
    options.max_decoding_length = kMaxDecodingLength;

    auto results = engine->translator->translate_batch(
        batch, options, kMaxBatchSize);
    if (results.size() != batch.size()) {
      report(error_out, "the decoder returned the wrong number of results");
      return nullptr;
    }

    std::vector<std::string> lines(line_count);
    for (size_t i = 0; i < results.size(); ++i) {
      if (results[i].hypotheses.empty()) {
        report(error_out, "the decoder returned no hypothesis");
        return nullptr;
      }
      std::string piece;
      const auto decoded = engine->target.Decode(results[i].hypotheses[0],
                                                 &piece);
      if (!decoded.ok()) {
        report(error_out, "decode: " + decoded.ToString());
        return nullptr;
      }
      std::string &line = lines[line_of_chunk[i]];
      if (!line.empty() && !piece.empty()) line += " ";
      line += piece;
    }

    std::string text;
    for (size_t i = 0; i < lines.size(); ++i) {
      if (i > 0) text += "\n";
      text += lines[i];
    }
    return copy_c_string(text);
  } catch (const std::exception &error) {
    report(error_out, error.what());
    return nullptr;
  } catch (...) {
    report(error_out, "unknown failure during translation");
    return nullptr;
  }
}

void murmur_ct2_close(MurmurCT2Engine *engine) { delete engine; }

void murmur_ct2_string_free(char *value) { std::free(value); }
