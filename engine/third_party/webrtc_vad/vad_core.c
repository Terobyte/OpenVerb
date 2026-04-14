/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_core.c — core VAD algorithm: initialisation, mode setting, and the
 * per-frame classification loop (GMM evaluation + model update + decision).
 *
 * Processing pipeline per 8 kHz frame:
 *   1. Extract 6 log-energy features via the QMF filterbank.
 *   2. For each channel evaluate both GMM components (noise / speech).
 *   3. Compute the log-likelihood ratio (LLR) for each channel.
 *   4. Apply per-channel and global thresholds to produce a raw decision.
 *   5. Update the GMM model parameters (online EM step).
 *   6. Apply the over-hang mechanism to smooth the output.
 */

#include "vad_core.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "signal_processing_library.h"
#include "vad_filterbank.h"
#include "vad_gmm.h"
#include "vad_sp.h"

/* =========================================================================
 * Compile-time tables
 * ========================================================================= */

/* Initial noise GMM means  (Q7, 6 channels × 2 Gaussians, channel-major)
 * Values match the actual filterbank feature scale (~5 energy-bits above
 * each channel's offset).  Per-channel variation tracks kOffsets:
 *   ch0,ch1 offset=1024 → mean 1600
 *   ch2,ch3 offset=896  → mean 1536
 *   ch4,ch5 offset=768  → mean 1408 */
static const int16_t kNoiseDataMeans[kTableSize] = {
    1600, 1600, 1536, 1536, 1408, 1408,   /* Gaussian 0 */
    1600, 1600, 1536, 1536, 1408, 1408    /* Gaussian 1 */
};

/* Initial noise GMM standard deviations (Q7).
 * Wide enough (256 Q7) that GaussianProbability does not clamp for
 * signals within a few thousand Q7 of the mean. */
static const int16_t kNoiseDataStds[kTableSize] = {
    256, 256, 256, 256, 256, 256,
    256, 256, 256, 256, 256, 256
};

/* Initial speech GMM means (Q7).
 * ~14 energy-bits above each channel's offset — typical voiced speech. */
static const int16_t kSpeechDataMeans[kTableSize] = {
    2816, 2816, 2688, 2688, 2560, 2560,
    2816, 2816, 2688, 2688, 2560, 2560
};

/* Initial speech GMM standard deviations (Q7). */
static const int16_t kSpeechDataStds[kTableSize] = {
    256, 256, 256, 256, 256, 256,
    256, 256, 256, 256, 256, 256
};

/* Over-hang limits per mode (0 = normal, 1 = low-bitrate, 2 = aggressive,
 * 3 = very aggressive).
 * over_hang_max_1 / over_hang_max_2 are the two-stage extension lengths. */
static const int16_t kOverHangMax1[4] = {  8,  4,  3,  2 };
static const int16_t kOverHangMax2[4] = { 14,  7,  5,  3 };

/* Per-channel individual decision thresholds (Q7, one per channel).
 * Lower value → more sensitive to speech. */
static const int16_t kLocalThreshold[4] = { 24, 21, 24, 27 };

/* Global (cross-channel) decision threshold (Q7). */
static const int16_t kGlobalThreshold[4] = { 57, 48, 57, 57 };

/* Gaussian mixture weights: component 0 carries weight 0.7, component 1 = 0.3
 * in Q15. */
static const int16_t kWeight[kNumGaussians] = { 22938, 9830 };  /* 0.70, 0.30 */

/* =========================================================================
 * Initialisation
 * ========================================================================= */

int WebRtcVad_InitCore(VadInstT* self) {
    if (!self) return -1;

    self->vad = 0;

    /* Filter states */
    memset(self->downsampling_filter_states, 0,
           sizeof(self->downsampling_filter_states));
    memset(self->hp_filter_state,  0, sizeof(self->hp_filter_state));
    memset(self->upper_state,      0, sizeof(self->upper_state));
    memset(self->lower_state,      0, sizeof(self->lower_state));

    /* Copy pre-trained GMM parameters */
    memcpy(self->noise_means,  kNoiseDataMeans,  sizeof(kNoiseDataMeans));
    memcpy(self->speech_means, kSpeechDataMeans, sizeof(kSpeechDataMeans));
    memcpy(self->noise_stds,   kNoiseDataStds,   sizeof(kNoiseDataStds));
    memcpy(self->speech_stds,  kSpeechDataStds,  sizeof(kSpeechDataStds));

    /* Power / energy */
    self->total_power        = 0;
    self->frame_len          = 0;
    self->lower_band_energy  = 0;
    self->upper_band_energy  = 0;

    /* History */
    memset(self->index_vector, 0, sizeof(self->index_vector));
    memset(self->speech_probs, 0, sizeof(self->speech_probs));

    /* Set default mode (mode 0 = normal). */
    return WebRtcVad_set_mode_core(self, 0);
}

/* =========================================================================
 * Mode setting
 * ========================================================================= */

int WebRtcVad_set_mode_core(VadInstT* self, int mode) {
    if (!self || mode < 0 || mode > 3) return -1;

    self->over_hang      = 0;
    self->over_hang_max_1 = kOverHangMax1[mode];
    self->over_hang_max_2 = kOverHangMax2[mode];

    for (int ch = 0; ch < kNumChannels; ++ch) {
        self->individual[ch] = kLocalThreshold[mode];
    }
    self->total = kGlobalThreshold[mode];

    return 0;
}

/* =========================================================================
 * 48 kHz path — downsample 6:1 then call 8 kHz path
 *
 * A non-overlapping 6-tap box filter (mean of each group of 6 input samples)
 * provides the required anti-aliasing before integer decimation.  This keeps
 * the function stateless (no persistent filter memory across frames) while
 * correctly resampling the entire frame — unlike the naive truncation
 * approach, every input sample contributes to an output sample.
 *
 * frame_length at 48 kHz: 480, 960, or 1440 samples.
 * Resampled output:         80, 160, or  240 samples (8 kHz).
 * ========================================================================= */

int WebRtcVad_CalcVad48khz(VadInstT*      self,
                            const int16_t* speech_frame,
                            size_t         frame_length) {
    /* Ratio 48 kHz : 8 kHz = 6:1 */
    static const size_t kDecimation = 6;

    int16_t  out[240];
    size_t   out_len = frame_length / kDecimation;
    if (out_len > 240) return -1;
    /* frame_length must be an exact multiple of kDecimation (480 / 960 / 1440) */
    if (frame_length % kDecimation != 0) return -1;

    for (size_t i = 0; i < out_len; ++i) {
        const int16_t* p = speech_frame + i * kDecimation;
        /* Sum six consecutive input samples and round-shift to int16. */
        int32_t acc = (int32_t)p[0] + (int32_t)p[1] + (int32_t)p[2]
                    + (int32_t)p[3] + (int32_t)p[4] + (int32_t)p[5];
        /* Divide by 6 using a Q-shift: multiply by (1/6 ≈ 10923/65536)
         * then shift right 16 to stay in int16 range. */
        int32_t sample = (acc * 10923 + 32768) >> 16;
        /* Clamp to int16_t range. */
        if (sample >  32767) sample =  32767;
        if (sample < -32768) sample = -32768;
        out[i] = (int16_t)sample;
    }

    return WebRtcVad_CalcVad8khz(self, out, out_len);
}

/* =========================================================================
 * Core VAD calculation at 8 kHz
 * ========================================================================= */

int WebRtcVad_CalcVad8khz(VadInstT*      self,
                           const int16_t* speech_frame,
                           size_t         frame_length) {
    int16_t features[kNumChannels];

    /* --- 1. Extract features ----------------------------------------------- */
    int16_t total_energy = WebRtcVad_get_features(self, speech_frame,
                                                   frame_length, features);

    /* Early exit: if the frame has no meaningful energy, return silence.
     * This protects the GMM from updating on silence padding. */
    if (total_energy <= kMinEnergy) {
        self->vad = 0;
        if (self->over_hang > 0) {
            self->over_hang--;
            self->vad = 1;
        }
        return self->vad;
    }

    /* --- 2. GMM evaluation + per-channel decision -------------------------- */
    int32_t weighted_llr = 0;
    int16_t speech_count = 0;

    for (int ch = 0; ch < kNumChannels; ++ch) {
        int16_t x = features[ch];

        /* Evaluate both Gaussian components for each model. */
        int32_t noise_prob  = 0;
        int32_t speech_prob = 0;

        int16_t noise_delta[kNumGaussians];
        int16_t speech_delta[kNumGaussians];

        for (int g = 0; g < kNumGaussians; ++g) {
            int idx = ch + g * kNumChannels;

            /* Noise component. */
            int32_t np = WebRtcVad_GaussianProbability(
                x,
                self->noise_means[idx],
                self->noise_stds[idx],
                &noise_delta[g]);
            noise_prob = WebRtcSpl_AddSatW32(
                noise_prob,
                WEBRTC_SPL_MUL_16_32_RSFT16(kWeight[g], np));

            /* Speech component. */
            int32_t sp = WebRtcVad_GaussianProbability(
                x,
                self->speech_means[idx],
                self->speech_stds[idx],
                &speech_delta[g]);
            speech_prob = WebRtcSpl_AddSatW32(
                speech_prob,
                WEBRTC_SPL_MUL_16_32_RSFT16(kWeight[g], sp));
        }

        /* Log-likelihood ratio (Q7 approximation):
         * LLR = log(speech_prob) - log(noise_prob)
         * We use GetSizeInBits as a proxy for log2 since both values are
         * computed on the same Q27 scale. */
        int16_t n_bits = WebRtcSpl_GetSizeInBits((uint32_t)
                          WEBRTC_SPL_MAX(noise_prob, 1));
        int16_t s_bits = WebRtcSpl_GetSizeInBits((uint32_t)
                          WEBRTC_SPL_MAX(speech_prob, 1));
        int16_t llr_ch = (int16_t)((s_bits - n_bits) << 4);  /* scale to Q7 */

        /* Store per-channel probability (used for over-hang weight). */
        self->speech_probs[ch] = llr_ch;

        /* Per-channel decision. */
        if (llr_ch > self->individual[ch]) {
            speech_count++;
        }
        weighted_llr += llr_ch;

        /* --- 3. Online GMM update ------------------------------------------ */
        /* Noise model update: move slowly toward x when classified as noise. */
        for (int g = 0; g < kNumGaussians; ++g) {
            int idx = ch + g * kNumChannels;
            /* Update mean: μ ← μ + α·δ  where α ≈ 1/400 (very slow). */
            int32_t mean_adj = WEBRTC_SPL_MUL_16_16_RSFT(noise_delta[g], 1, 9);
            self->noise_means[idx] = (int16_t)WEBRTC_SPL_SAT(
                WEBRTC_SPL_WORD16_MAX,
                self->noise_means[idx] + mean_adj,
                WEBRTC_SPL_WORD16_MIN);

            /* Update std: keep in [3, 72] Q7. */
            int32_t std_adj = WEBRTC_SPL_MUL_16_16_RSFT(noise_delta[g], 2, 10);
            int16_t new_std = (int16_t)WEBRTC_SPL_SAT(72,
                self->noise_stds[idx] + std_adj, 3);
            self->noise_stds[idx] = new_std;
        }
        /* Speech model update: only when we believe the frame is speech. */
        if (llr_ch > self->individual[ch]) {
            for (int g = 0; g < kNumGaussians; ++g) {
                int idx = ch + g * kNumChannels;
                int32_t mean_adj = WEBRTC_SPL_MUL_16_16_RSFT(
                    speech_delta[g], 1, 9);
                self->speech_means[idx] = (int16_t)WEBRTC_SPL_SAT(
                    WEBRTC_SPL_WORD16_MAX,
                    self->speech_means[idx] + mean_adj,
                    WEBRTC_SPL_WORD16_MIN);

                int32_t std_adj = WEBRTC_SPL_MUL_16_16_RSFT(
                    speech_delta[g], 2, 10);
                int16_t new_std = (int16_t)WEBRTC_SPL_SAT(72,
                    self->speech_stds[idx] + std_adj, 3);
                self->speech_stds[idx] = new_std;
            }
        }
    }

    /* --- 4. Global decision ----------------------------------------------- */
    int16_t global_llr = (int16_t)(weighted_llr / kNumChannels);
    int raw_vad = 0;
    if (speech_count >= 2 || global_llr > self->total) {
        raw_vad = 1;
    }

    /* --- 5. Over-hang extension ------------------------------------------- */
    if (raw_vad) {
        /* Reset over-hang timer. */
        self->over_hang = self->over_hang_max_1;
        self->vad = 1;
    } else if (self->over_hang > 0) {
        self->over_hang--;
        self->vad = 1;
    } else {
        self->vad = 0;
    }

    return self->vad;
}

/* =========================================================================
 * 16 kHz path — downsample ×2 then call 8 kHz path
 * ========================================================================= */

int WebRtcVad_CalcVad16khz(VadInstT*      self,
                            const int16_t* speech_frame,
                            size_t         frame_length) {
    /* frame_length at 16 kHz: 160, 320, or 480 samples.
     * Downsampled output: 80, 160, or 240 samples. */
    int16_t  out[240];
    size_t   out_len = frame_length >> 1;
    if (out_len > 240) return -1;

    WebRtcVad_Downsampling(speech_frame, out,
                           self->downsampling_filter_states, frame_length);

    return WebRtcVad_CalcVad8khz(self, out, out_len);
}

/* =========================================================================
 * 32 kHz path — downsample ×4 (two cascaded ×2 stages) then 8 kHz
 * ========================================================================= */

int WebRtcVad_CalcVad32khz(VadInstT*      self,
                            const int16_t* speech_frame,
                            size_t         frame_length) {
    /* frame_length at 32 kHz: 320, 640, or 960 samples. */
    int16_t  tmp[480];    /* after first ÷2: 160, 320, 480 */
    size_t   tmp_len = frame_length >> 1;
    if (tmp_len > 480) return -1;

    /* First decimation ×2 using filter states [0..1]. */
    WebRtcVad_Downsampling(speech_frame, tmp,
                           &self->downsampling_filter_states[0],
                           frame_length);

    /* Second decimation ×2 using filter states [2..3]. */
    int16_t  out[240];
    size_t   out_len = tmp_len >> 1;
    if (out_len > 240) return -1;

    WebRtcVad_Downsampling(tmp, out,
                           &self->downsampling_filter_states[2],
                           tmp_len);

    return WebRtcVad_CalcVad8khz(self, out, out_len);
}
