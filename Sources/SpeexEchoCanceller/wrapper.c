#include "JustSaidSpeex.h"
#include "speex/speex_echo.h"
void *js_speex_create(void) {
  SpeexEchoState *state = speex_echo_state_init(160, 4000);
  int rate = 16000;
  if (state && speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)) {
    speex_echo_state_destroy(state);
    return 0;
  }
  return state;
}
void js_speex_process(void *state, const int16_t *mic, const int16_t *render, int16_t *output) {
  speex_echo_cancellation(state, mic, render, output);
}
void js_speex_destroy(void *state) { speex_echo_state_destroy(state); }
