#ifndef KUMONE_AUDIO_DSP_H
#define KUMONE_AUDIO_DSP_H

#include <stdbool.h>
#include <stdint.h>

#define KUMONE_EQUALIZER_BAND_COUNT 10

/// Publishes one complete equalizer target from the UI thread.
/// Returns the new even revision number.
uint32_t KumoneEqualizerPublish(const float gains[KUMONE_EQUALIZER_BAND_COUNT],
                                float preampDB,
                                bool bypassed);

/// Loads a coherent target on the real-time audio thread without locking.
/// Returns the even revision that was read.
uint32_t KumoneEqualizerLoad(float gains[KUMONE_EQUALIZER_BAND_COUNT],
                             float *preampDB,
                             bool *bypassed);

/// Restores the process-global store to transparent defaults. Intended for tests.
void KumoneEqualizerReset(void);

#endif
