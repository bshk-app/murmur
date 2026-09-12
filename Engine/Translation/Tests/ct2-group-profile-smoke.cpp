#include "murmur_ct2.h"
#include <cassert>
#include <iostream>
#include <string>

std::string run(MurmurCT2Engine *engine, const char *text, MurmurCT2Options options, const char *tag) {
  char *error = nullptr;
  char *out = murmur_ct2_translate_with_options(engine, text, &options, tag, &error);
  if (!out) { std::cerr << (error ? error : "unknown error") << '\n'; std::abort(); }
  std::string result(out); murmur_ct2_string_free(out); assert(!error); return result;
}
int main(int argc, char **argv) {
  assert(argc == 2);
  const char *input = "The government announced a new law today.";
  for (int compute : {0, 1}) {
    char *error = nullptr;
    auto *engine = murmur_ct2_open_with_options(argv[1], compute, &error);
    if (!engine) { std::cerr << error << '\n'; return 1; }
    for (int beam : {1, 4, 6, 8}) {
      MurmurCT2Options options{beam, 200, 512, 1};
      auto ru = run(engine, input, options, ">>rus<<");
      auto uk = run(engine, input, options, ">>ukr<<");
      auto again = run(engine, input, options, ">>rus<<");
      assert(!ru.empty() && !uk.empty() && ru != uk && ru == again);
      std::cout << "compute=" << compute << " beam=" << beam << " ru=" << ru << " uk=" << uk << '\n';
    }
    // 5-piece cap forces multiple chunks; every chunk must receive its tag.
    MurmurCT2Options short_cap{1, 5, 512, 1};
    auto long_ru = run(engine, "The government announced a new law today and it will take effect next year.", short_cap, ">>rus<<");
    assert(!long_ru.empty());
    murmur_ct2_close(engine);
  }
}
