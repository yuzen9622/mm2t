// Command-line check of the C API: translates stdin line by line and prints the time per line.
// Usage: mm2t-bergamot-cli MODEL SHORTLIST SOURCE_VOCAB TARGET_VOCAB < sentences.txt
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mm2t_bergamot.h"

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: %s MODEL SHORTLIST SOURCE_VOCAB TARGET_VOCAB < input\n", argv[0]);
    return 2;
  }
  char *error = NULL;
  double start = now_ms();
  MM2TBergamotModel *model = mm2t_bergamot_model_create(argv[1], argv[2], argv[3], argv[4], &error);
  if (!model) {
    fprintf(stderr, "load failed: %s\n", error ? error : "?");
    mm2t_bergamot_string_free(error);
    return 1;
  }
  printf("load_ms\t%.1f\n", now_ms() - start);

  char line[8192];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (!line[0]) continue;
    double begin = now_ms();
    char *out = mm2t_bergamot_translate(model, line, &error);
    double elapsed = now_ms() - begin;
    if (!out) {
      fprintf(stderr, "translate failed: %s\n", error ? error : "?");
      mm2t_bergamot_string_free(error);
      error = NULL;
      continue;
    }
    printf("%.1f\t%s\t%s\n", elapsed, line, out);
    mm2t_bergamot_string_free(out);
  }
  mm2t_bergamot_model_free(model);
  return 0;
}
