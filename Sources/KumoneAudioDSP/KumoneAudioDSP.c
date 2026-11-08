#include "KumoneAudioDSP.h"

#include <stdatomic.h>
#include <string.h>

static _Atomic(uint32_t) revision = 0;
static _Atomic(uint32_t) gainBits[KUMONE_EQUALIZER_BAND_COUNT];
static _Atomic(uint32_t) preampBits;
static _Atomic(uint32_t) bypassedBits = 1;

static uint32_t bitsFromFloat(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float floatFromBits(uint32_t bits) {
    float value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

uint32_t KumoneEqualizerPublish(const float gains[KUMONE_EQUALIZER_BAND_COUNT],
                                float preampDB,
                                bool bypassed) {
    // Odd means a writer is in flight. Every field is atomic as well, so even
    // the bounded fallback in the reader remains data-race free.
    atomic_fetch_add_explicit(&revision, 1, memory_order_acq_rel);
    for (int index = 0; index < KUMONE_EQUALIZER_BAND_COUNT; index += 1) {
        atomic_store_explicit(&gainBits[index], bitsFromFloat(gains[index]),
                              memory_order_relaxed);
    }
    atomic_store_explicit(&preampBits, bitsFromFloat(preampDB), memory_order_relaxed);
    atomic_store_explicit(&bypassedBits, bypassed ? 1 : 0, memory_order_relaxed);
    return atomic_fetch_add_explicit(&revision, 1, memory_order_release) + 1;
}

uint32_t KumoneEqualizerLoad(float gains[KUMONE_EQUALIZER_BAND_COUNT],
                             float *preampDB,
                             bool *bypassed) {
    uint32_t start = 0;
    uint32_t end = 0;
    for (int attempt = 0; attempt < 4; attempt += 1) {
        start = atomic_load_explicit(&revision, memory_order_acquire);
        if ((start & 1U) != 0) {
            continue;
        }
        for (int index = 0; index < KUMONE_EQUALIZER_BAND_COUNT; index += 1) {
            gains[index] = floatFromBits(
                atomic_load_explicit(&gainBits[index], memory_order_relaxed));
        }
        *preampDB = floatFromBits(atomic_load_explicit(&preampBits, memory_order_relaxed));
        *bypassed = atomic_load_explicit(&bypassedBits, memory_order_relaxed) != 0;
        end = atomic_load_explicit(&revision, memory_order_acquire);
        if (start == end && (end & 1U) == 0) {
            return end;
        }
    }

    // A UI gesture can publish repeatedly. Atomic fields make a mixed fallback
    // safe; the DSP's 80 ms glide makes it inaudible, and the next buffer will
    // pick up the settled revision.
    for (int index = 0; index < KUMONE_EQUALIZER_BAND_COUNT; index += 1) {
        gains[index] = floatFromBits(
            atomic_load_explicit(&gainBits[index], memory_order_relaxed));
    }
    *preampDB = floatFromBits(atomic_load_explicit(&preampBits, memory_order_relaxed));
    *bypassed = atomic_load_explicit(&bypassedBits, memory_order_relaxed) != 0;
    end = atomic_load_explicit(&revision, memory_order_acquire);
    return end & ~1U;
}

void KumoneEqualizerReset(void) {
    float gains[KUMONE_EQUALIZER_BAND_COUNT] = {0};
    KumoneEqualizerPublish(gains, 0, true);
}
