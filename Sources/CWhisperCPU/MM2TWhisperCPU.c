#include "MM2TWhisperCPU.h"
#include <whisper/whisper.h>

MM2TWhisperContext *mm2t_whisper_load(const char *path) {
    struct whisper_context_params options = whisper_context_default_params();
    options.use_gpu = false;
    return whisper_init_from_file_with_params(path, options);
}

void mm2t_whisper_free(MM2TWhisperContext *context) {
    whisper_free(context);
}

int mm2t_whisper_decode(MM2TWhisperContext *context, const float *pcm, int count,
                        const char *language, const char *prompt, MM2TWhisperAbort abort, void *state) {
    struct whisper_full_params options = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    options.language = language;
    options.initial_prompt = prompt;
    options.no_context = true;
    options.token_timestamps = true;
    options.print_progress = false;
    options.print_timestamps = false;
    options.print_realtime = false;
    options.abort_callback = abort;
    options.abort_callback_user_data = state;
    if (whisper_full(context, options, pcm, count) != 0) return -1;
    return whisper_full_n_segments(context);
}

const char *mm2t_whisper_segment(MM2TWhisperContext *context, int index, int64_t *start, int64_t *end) {
    *start = whisper_full_get_segment_t0(context, index);
    *end = whisper_full_get_segment_t1(context, index);
    return whisper_full_get_segment_text(context, index);
}

int mm2t_whisper_token_count(MM2TWhisperContext *context, int segment) {
    return whisper_full_n_tokens(context, segment);
}

const char *mm2t_whisper_token(MM2TWhisperContext *context, int segment, int index, int64_t *start, int64_t *end) {
    whisper_token_data data = whisper_full_get_token_data(context, segment, index);
    if (data.id >= whisper_token_eot(context)) return NULL;
    *start = data.t0;
    *end = data.t1;
    return whisper_full_get_token_text(context, segment, index);
}
