// The C surface of the Bergamot (Marian) translation engine as mm2t uses it. Swift sees only this.
#ifndef MM2T_BERGAMOT_H
#define MM2T_BERGAMOT_H

#ifdef __cplusplus
extern "C" {
#endif

/// One loaded translation direction.
typedef struct MM2TBergamotModel MM2TBergamotModel;

/// Loads a model from its files. On failure returns NULL and, when `error` is not NULL, stores a
/// message there that the caller frees with `mm2t_bergamot_string_free`.
MM2TBergamotModel *mm2t_bergamot_model_create(const char *model_path,
                                              const char *shortlist_path,
                                              const char *source_vocab_path,
                                              const char *target_vocab_path,
                                              char **error);

/// Translates UTF-8 text. Returns a UTF-8 string the caller frees with `mm2t_bergamot_string_free`,
/// or NULL with `error` set. Calls are serialised inside the engine; it is safe from any thread.
char *mm2t_bergamot_translate(MM2TBergamotModel *model, const char *text, char **error);

void mm2t_bergamot_string_free(char *string);

void mm2t_bergamot_model_free(MM2TBergamotModel *model);

#ifdef __cplusplus
}
#endif

#endif
