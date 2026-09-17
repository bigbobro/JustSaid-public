#ifndef JUSTSAID_SPEEX_H
#define JUSTSAID_SPEEX_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *js_speex_create(void);
void js_speex_process(void *state, const int16_t *mic, const int16_t *render, int16_t *output);
void js_speex_destroy(void *state);
#ifdef __cplusplus
}
#endif
#endif
