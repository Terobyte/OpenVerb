/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_core.h — internal VAD state and per-rate processing entry points.
 *
 * This header is NOT part of the public API.  Include webrtc_vad.h instead.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_VAD_CORE_H_
#define THIRD_PARTY_WEBRTC_VAD_VAD_CORE_H_

#include <stddef.h>
#include <stdint.h>

/* --------------------------------------------------------------------------
 * Compile-time constants
 * -------------------------------------------------------------------------- */
enum { kNumChannels  = 6 };                         /* subband count          */
enum { kNumGaussians = 2 };                         /* GMM components/channel */
enum { kTableSize    = kNumChannels * kNumGaussians };
enum { kMinEnergy    = 10 };                        /* minimum log-energy (Q7)*/

/* --------------------------------------------------------------------------
 * VadInstT — complete internal state for one VAD instance.
 *
 * All fixed-point values are annotated with their Q-format in comments.
 * -------------------------------------------------------------------------- */
typedef struct VadInstT_ {
    int vad;   /* last decision: 0 = no speech, 1 = speech */

    /* Downsampling filter states (two cascaded all-pass sections per path).
     * Index layout: [lower_path_0, lower_path_1, upper_path_0, upper_path_1]
     * Used when the input sample rate exceeds 8 kHz. */
    int32_t downsampling_filter_states[4];

    /* High-pass filter (80 Hz cut-off) biquad state, two sections × 2. */
    int16_t hp_filter_state[4];

    /* All-pass filter states for the 6-subband splitFilterBank (Q15). */
    int16_t lower_state[5];
    int16_t upper_state[5];

    /* GMM noise / speech models — Q7 log-energy domain.
     * Layout: [ch0_g0, ch0_g1, ch1_g0, … ch5_g1]  (channel-major order) */
    int16_t noise_means[kTableSize];   /* Noise GMM means (Q7)  */
    int16_t speech_means[kTableSize];  /* Speech GMM means (Q7) */
    int16_t noise_stds[kTableSize];    /* Noise GMM σ (Q7)      */
    int16_t speech_stds[kTableSize];   /* Speech GMM σ (Q7)     */

    /* Running log-energy accumulators for model update. */
    int32_t total_power;        /* accumulated energy over the utterance       */
    int32_t frame_len;          /* samples in current frame (for normalisation)*/

    /* Per-channel feature history used for adaptive GMM update.
     * Circular buffer of the last 16 log-energy values per channel. */
    int16_t index_vector[16 * kNumChannels];

    /* Per-channel VAD decision probability (Q15). */
    int16_t speech_probs[kNumChannels];

    /* Sub-band energy split (used by 16 kHz path). */
    int32_t lower_band_energy;
    int32_t upper_band_energy;

    /* Over-hang counters — extend positive decisions past the last voiced
     * frame so transient off-glides are not clipped. */
    int32_t over_hang;
    int32_t over_hang_max_1;
    int32_t over_hang_max_2;

    /* Per-channel and overall decision thresholds (mode-dependent). */
    int16_t individual[kNumChannels];
    int16_t total;
} VadInstT;

/* --------------------------------------------------------------------------
 * Internal API
 * -------------------------------------------------------------------------- */
#ifdef __cplusplus
extern "C" {
#endif

/* Initialise all fields to their default values and load the pre-trained
 * noise/speech GMM parameters.  Must be called before the first Process. */
int WebRtcVad_InitCore(VadInstT* self);

/* Set the aggressiveness mode (0–3).  Updates over-hang limits and
 * decision thresholds in self.  Returns 0 on success, -1 if out of range. */
int WebRtcVad_set_mode_core(VadInstT* self, int mode);

/* Process one 30 ms frame at 32 kHz (960 samples).
 * Downsamples internally before calling the 8 kHz path. */
int WebRtcVad_CalcVad32khz(VadInstT* self,
                            const int16_t* speech_frame,
                            size_t frame_length);

/* Process one frame at 16 kHz.  Downsamples to 8 kHz. */
int WebRtcVad_CalcVad16khz(VadInstT* self,
                            const int16_t* speech_frame,
                            size_t frame_length);

/* Process one frame at 48 kHz.  Downsamples 6:1 to 8 kHz using a 6-tap box
 * filter then calls the 8 kHz path.
 * frame_length must be 480 (10 ms), 960 (20 ms), or 1440 (30 ms) samples. */
int WebRtcVad_CalcVad48khz(VadInstT* self,
                            const int16_t* speech_frame,
                            size_t frame_length);

/* Process one frame at 8 kHz — the core processing path.
 * frame_length must be 80 (10 ms), 160 (20 ms), or 240 (30 ms) samples. */
int WebRtcVad_CalcVad8khz(VadInstT* self,
                           const int16_t* speech_frame,
                           size_t frame_length);

#ifdef __cplusplus
}
#endif

#endif  /* THIRD_PARTY_WEBRTC_VAD_VAD_CORE_H_ */
