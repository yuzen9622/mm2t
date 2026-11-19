#pragma once
#include <stdbool.h>
#include <stdint.h>

// Keep whisper.cpp's private ggml headers out of the Swift module that also uses llama.cpp.
typedef struct whisper_context MM2TWhisperContext;
typedef bool (*MM2TWhisperAbort)(void *state);
MM2TWhisperContext *mm2t_whisper_load(const char *path);
void mm2t_whisper_free(MM2TWhisperContext *context);
int mm2t_whisper_decode(MM2TWhisperContext *context, const float *pcm, int count,
                        const char *language, const char *prompt, MM2TWhisperAbort abort, void *state);
const char *mm2t_whisper_segment(MM2TWhisperContext *context, int index, int64_t *start, int64_t *end);
int mm2t_whisper_token_count(MM2TWhisperContext *context, int segment);
const char *mm2t_whisper_token(MM2TWhisperContext *context, int segment, int index, int64_t *start, int64_t *end);
