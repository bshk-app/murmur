#include "murmur_ct2.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>

int main(int argc, char **argv) {
  char *error = nullptr;
  assert(!murmur_ct2_open_with_options("/missing", 2, &error));
  assert(error && std::strstr(error, "compute"));
  murmur_ct2_string_free(error);
  MurmurCT2Options invalid{2, 200, 512, 1};
  assert(!murmur_ct2_translate_with_options(nullptr, "text", &invalid, nullptr, &error));
  assert(error && std::strstr(error, "profile"));
  murmur_ct2_string_free(error);
  invalid = {1, 200, 512, std::numeric_limits<float>::quiet_NaN()};
  assert(!murmur_ct2_translate_with_options(nullptr, "text", &invalid, nullptr, &error));
  assert(error && std::strstr(error, "profile"));
  murmur_ct2_string_free(error);
  for (const auto &profile : {MurmurCT2Options{1, 0, 512, 1},
                              MurmurCT2Options{1, 513, 512, 1},
                              MurmurCT2Options{1, 200, 0, 1},
                              MurmurCT2Options{1, 200, 1025, 1},
                              MurmurCT2Options{1, 200, 512, -1}}) {
    assert(!murmur_ct2_translate_with_options(nullptr, "text", &profile, nullptr, &error));
    assert(error && std::strstr(error, "profile"));
    murmur_ct2_string_free(error);
  }
  if (argc != 2) { std::cout << "Validation passed; pass model directory for inference checks\n"; return 0; }
  auto *engine = murmur_ct2_open(argv[1], &error);
  if (!engine) { std::cerr << error << '\n'; return 1; }
  const char *input = "Hello world.\n\nThis is a test.";
  char *old = murmur_ct2_translate(engine, input, &error);
  assert(old && !error);
  MurmurCT2Options baseline{1, 200, 512, 1};
  char *current = murmur_ct2_translate_with_options(engine, input, &baseline, nullptr, &error);
  assert(current && !error && std::strcmp(old, current) == 0);
  assert(std::string(current).find("\n\n") != std::string::npos);
  assert(!murmur_ct2_translate_with_options(engine, input, &baseline, "invalid", &error));
  assert(error && std::strstr(error, "tag"));
  murmur_ct2_string_free(error);
  for (int beam : {1, 4, 6, 8}) {
    MurmurCT2Options capped{beam, 200, 1, 1};
    assert(!murmur_ct2_translate_with_options(engine, input, &capped, nullptr, &error));
    assert(error && std::strstr(error, "decoding limit without EOS"));
    murmur_ct2_string_free(error);
  }
  char *after = murmur_ct2_translate(engine, input, &error);
  assert(after && !error && std::strcmp(old, after) == 0);
  murmur_ct2_string_free(old); murmur_ct2_string_free(current); murmur_ct2_string_free(after);
  murmur_ct2_close(engine);
  std::cout << "Validation, ABI parity, line preservation and tag isolation passed\n";
}
