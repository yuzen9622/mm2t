#include "mm2t_aec3.h"
#include <array>
#include <memory>
#include "modules/audio_processing/include/audio_processing.h"

struct mm2t_aec3 {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig mono{16000,1};
};

mm2t_aec3 *mm2t_aec3_create(void) try {
  auto state = std::make_unique<mm2t_aec3>();
  state->apm = webrtc::AudioProcessingBuilder().Create();
  if (!state->apm) return nullptr;
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  config.high_pass_filter.enabled = true;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  state->apm->ApplyConfig(config);
  return state.release();
} catch (...) { return nullptr; }

void mm2t_aec3_destroy(mm2t_aec3 *state) { delete state; }

int mm2t_aec3_delay_ms(mm2t_aec3 *state) try {
  return state ? state->apm->GetStatistics().delay_ms.value_or(-1) : -1;
} catch (...) { return -1; }

int mm2t_aec3_process(mm2t_aec3 *state, const int16_t *render, const int16_t *capture, int16_t *output) try {
  if (!state || !render || !capture || !output) return -1;
  std::array<int16_t,160> scratch;
  const auto& mono = state->mono;
  const int status = state->apm->ProcessReverseStream(render,mono,mono,scratch.data());
  return status ? status : state->apm->ProcessStream(capture,mono,mono,output);
} catch (...) { return -1; }
