// C API over bergamot-translator's BlockingService. Exceptions never cross this boundary.
#include "mm2t_bergamot.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "common/logging.h"
#include "translator/parser.h"
#include "translator/response_options.h"
#include "translator/service.h"
#include "translator/translation_model.h"

using marian::bergamot::BlockingService;
using marian::bergamot::ResponseOptions;
using marian::bergamot::TranslationModel;

struct MM2TBergamotModel {
  std::shared_ptr<TranslationModel> model;
};

namespace {

// BlockingService is not thread-safe and its logger registers process-wide names, so the process
// holds exactly one and every call goes through this lock.
std::mutex engineLock;

BlockingService &service() {
  static BlockingService *shared = [] {
    marian::setThrowExceptionOnAbort(true);
    BlockingService::Config config;
    config.cacheSize = 0;
    config.logger.level = "off";
    return new BlockingService(config);
  }();
  return *shared;
}

char *copy(const std::string &value) {
  char *out = static_cast<char *>(std::malloc(value.size() + 1));
  if (out) std::memcpy(out, value.c_str(), value.size() + 1);
  return out;
}

void fail(char **error, const std::string &message) {
  if (error) *error = copy(message);
}

// YAML double-quoted scalar, so paths with spaces ("Application Support") or quotes survive.
std::string quoted(const char *path) {
  std::string out = "\"";
  for (const char *c = path; *c; ++c) {
    if (*c == '\\' || *c == '"') out += '\\';
    out += *c;
  }
  return out + "\"";
}

// Greedy decoding on one thread; `int8shiftAlphaAll` is the format of the `*.intgemm.alphas.bin` files.
std::string configuration(const char *model, const char *shortlist, const char *source, const char *target) {
  std::ostringstream yaml;
  yaml << "models:\n  - " << quoted(model) << "\n"
       << "vocabs:\n  - " << quoted(source) << "\n  - " << quoted(target) << "\n"
       << "shortlist:\n  - " << quoted(shortlist) << "\n  - false\n"
       << "beam-size: 1\n"
       << "normalize: 1.0\n"
       << "word-penalty: 0\n"
       << "max-length-break: 128\n"
       << "mini-batch-words: 1024\n"
       << "workspace: 128\n"
       << "max-length-factor: 2.0\n"
       << "skip-cost: true\n"
       << "cpu-threads: 1\n"
       << "quiet: true\n"
       << "quiet-translation: true\n"
       << "gemm-precision: int8shiftAlphaAll\n";
  return yaml.str();
}

}  // namespace

extern "C" MM2TBergamotModel *mm2t_bergamot_model_create(const char *model_path, const char *shortlist_path,
                                                          const char *source_vocab_path,
                                                          const char *target_vocab_path, char **error) {
  if (!model_path || !shortlist_path || !source_vocab_path || !target_vocab_path) {
    fail(error, "missing model file path");
    return nullptr;
  }
  try {
    std::lock_guard<std::mutex> guard(engineLock);
    service();
    auto options = marian::bergamot::parseOptionsFromString(
        configuration(model_path, shortlist_path, source_vocab_path, target_vocab_path), /*validate=*/false);
    auto loaded = std::make_shared<TranslationModel>(options, /*replicas=*/1);
    return new MM2TBergamotModel{loaded};
  } catch (const std::exception &exception) {
    fail(error, exception.what());
  } catch (...) {
    fail(error, "unknown engine error while loading the model");
  }
  return nullptr;
}

extern "C" char *mm2t_bergamot_translate(MM2TBergamotModel *model, const char *text, char **error) {
  if (!model || !text) {
    fail(error, "missing model or text");
    return nullptr;
  }
  try {
    std::lock_guard<std::mutex> guard(engineLock);
    std::vector<std::string> sources{std::string(text)};
    std::vector<ResponseOptions> options(1);
    auto responses = service().translateMultiple(model->model, std::move(sources), options);
    if (responses.empty()) {
      fail(error, "the engine returned no response");
      return nullptr;
    }
    return copy(responses.front().getTranslatedText());
  } catch (const std::exception &exception) {
    fail(error, exception.what());
  } catch (...) {
    fail(error, "unknown engine error while translating");
  }
  return nullptr;
}

extern "C" void mm2t_bergamot_string_free(char *string) { std::free(string); }

extern "C" void mm2t_bergamot_model_free(MM2TBergamotModel *model) {
  if (!model) return;
  std::lock_guard<std::mutex> guard(engineLock);
  delete model;
}
