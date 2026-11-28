#ifndef MM2T_AEC3_H
#define MM2T_AEC3_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct mm2t_aec3 mm2t_aec3;
mm2t_aec3 *mm2t_aec3_create(void);
void mm2t_aec3_destroy(mm2t_aec3 *state);
/* Estimated render delay in ms, or -1 if unavailable. Zero can mean not yet estimated. */
int mm2t_aec3_delay_ms(mm2t_aec3 *state);
/* One serialized call per 10 ms: each buffer must contain 160 mono s16 samples. */
int mm2t_aec3_process(mm2t_aec3 *state, const int16_t *render, const int16_t *capture, int16_t *output);

#ifdef __cplusplus
}
#endif
#endif
