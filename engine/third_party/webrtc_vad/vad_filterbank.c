/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_filterbank.c — 6-subband analysis filter-bank for the WebRTC VAD.
 *
 * Architecture:
 *
 *   8 kHz input
 *      │
 *      ├─[HP 80 Hz]─────────────────────────────────────────────────┐
 *      │                                                             │
 *      └─[SplitFilter]─┬─ LP (0–4 kHz)                             │
 *                       │    │                                        │
 *                       │    └─[SplitFilter]─┬─ LP (0–2 kHz)        │
 *                       │                    │    │                   │
 *                       │                    │    └─[Split]─ ch0, ch1 │
 *                       │                    └─ HP (2–4 kHz): ch2,ch3│
 *                       └─ HP (4–8 kHz): ch4, ch5                    │
 *                                                                     │
 *                                          LogEnergy per channel ←───┘
 *
 * In practice we do a two-level QMF split, yielding 6 channels.  The
 * lower band is split first (three levels), the upper band stays as two.
 * This matches the original WebRTC arrangement that yields the frequency
 * allocations documented in vad_filterbank.h.
 *
 * All-pass filter coefficients (Q15):
 *   Lower branch: kAllPassCoefsQ15[0] = 6549   (≈ 0.20)
 *   Upper branch: kAllPassCoefsQ15[1] = 21333  (≈ 0.65)
 */

#include "vad_filterbank.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "signal_processing_library.h"
#include "vad_core.h"

/* ---------------------------------------------------------------------------
 * All-pass filter coefficients in Q15 used for the QMF split.
 * These approximate the Daubechies D4 half-band prototype.
 * --------------------------------------------------------------------------- */
static const int16_t kAllPassCoefsQ15[2] = { 6549, 21333 };

/* HP filter coefficients (Q14) — 2nd-order direct-form IIR, 80 Hz cut-off.
 *   zeros: z = { 6631, -13262, 6631 } (Q14)
 *   poles: p = {    1, -14163,  7343 } (Q14 denominator, leading coeff = 1)
 */
static const int16_t kHpZeroCoefs[3] = { 6631, -13262, 6631 };
static const int16_t kHpPoleCoefs[2] = { 14163, -7343 };

/* ---------------------------------------------------------------------------
 * WebRtcVad_AllPassFilter — one first-order all-pass section:
 *   y[n] = coeff·(x[n] − y[n-1]) + x[n-1]
 *
 * The filter is evaluated at every other sample to produce a half-rate
 * output (QMF decimation by 2).
 * --------------------------------------------------------------------------- */
void WebRtcVad_AllPassFilter(const int16_t* data_in,
                             size_t         data_length,
                             int16_t        coeff,
                             int16_t*       filter_state,
                             int16_t*       data_out) {
    int16_t state = *filter_state;

    for (size_t i = 0; i < data_length; i += 2) {
        /* y[n] = coeff * (x[n] - y[n-1]) + x[n-1]  (Q15 coeff) */
        int32_t in = (int32_t)data_in[i];
        int32_t acc = WEBRTC_SPL_MUL_16_16(coeff, (int16_t)(in - state));
        /* acc is Q15; add Q0 state → normalise by >>15 */
        int32_t out = (acc + ((int32_t)state << 15)) >> 15;
        /* Saturate to int16. */
        if (out >  32767) out =  32767;
        if (out < -32768) out = -32768;
        data_out[i >> 1] = (int16_t)out;
        state = (int16_t)in;
    }

    *filter_state = state;
}

/* ---------------------------------------------------------------------------
 * WebRtcVad_HpFilter — 2nd-order IIR high-pass at ~80 Hz (8 kHz rate).
 *
 * Processes |data_length| samples from data_in → data_out.
 * filter_state[0..1] = x[n-1], x[n-2]; filter_state[2..3] = y[n-1], y[n-2]
 * --------------------------------------------------------------------------- */
void WebRtcVad_HpFilter(const int16_t* data_in,
                        size_t         data_length,
                        int16_t*       filter_state,
                        int16_t*       data_out) {
    int16_t xn1 = filter_state[0];
    int16_t xn2 = filter_state[1];
    int16_t yn1 = filter_state[2];
    int16_t yn2 = filter_state[3];

    for (size_t i = 0; i < data_length; ++i) {
        int16_t xn = data_in[i];

        /* y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] + a1·y[n-1] + a2·y[n-2]
         * Coefficients in Q14; result right-shifted 14. */
        int32_t acc = (int32_t)kHpZeroCoefs[0] * xn
                    + (int32_t)kHpZeroCoefs[1] * xn1
                    + (int32_t)kHpZeroCoefs[2] * xn2
                    + (int32_t)kHpPoleCoefs[0]  * yn1
                    + (int32_t)kHpPoleCoefs[1]  * yn2;
        acc >>= 14;

        int16_t yn = (int16_t)WEBRTC_SPL_SAT(32767, acc, -32768);
        data_out[i] = yn;

        xn2 = xn1; xn1 = xn;
        yn2 = yn1; yn1 = yn;
    }

    filter_state[0] = xn1;
    filter_state[1] = xn2;
    filter_state[2] = yn1;
    filter_state[3] = yn2;
}

/* ---------------------------------------------------------------------------
 * WebRtcVad_SplitFilter — QMF two-band split.
 *
 * Applies two all-pass sections with different coefficients to produce a
 * low half-band and a high half-band, each at half the input rate.
 * --------------------------------------------------------------------------- */
void WebRtcVad_SplitFilter(const int16_t* data_in,
                           size_t         data_length,
                           int16_t*       upper_state,
                           int16_t*       lower_state,
                           int16_t*       hp_data,
                           int16_t*       lp_data) {
    /* Temporary buffers for the two all-pass branches (stack-allocated).
     * Maximum frame size at 8 kHz: 240 samples → 120 per branch. */
    int16_t tmp_upper[120];
    int16_t tmp_lower[120];

    size_t out_len = data_length >> 1;
    if (out_len > 120) out_len = 120;  /* safety clamp */

    /* Lower all-pass branch — coefficient kAllPassCoefsQ15[0] */
    WebRtcVad_AllPassFilter(data_in, data_length,
                            kAllPassCoefsQ15[0], lower_state, tmp_lower);

    /* Upper all-pass branch — coefficient kAllPassCoefsQ15[1] */
    WebRtcVad_AllPassFilter(data_in + 1, data_length - 1,
                            kAllPassCoefsQ15[1], upper_state, tmp_upper);

    /* Combine: lp = (lower + upper) / 2   hp = (lower − upper) / 2 */
    for (size_t i = 0; i < out_len; ++i) {
        int32_t lo = tmp_lower[i];
        int32_t hi = (i < out_len - 1) ? tmp_upper[i] : 0;
        lp_data[i] = (int16_t)((lo + hi) >> 1);
        hp_data[i] = (int16_t)((lo - hi) >> 1);
    }
}

/* ---------------------------------------------------------------------------
 * WebRtcVad_LogOfEnergy — compute log2(energy) for a sub-band signal.
 *
 * Returns log-energy in Q7 (0 if energy ≤ kMinEnergy).
 * Writes total linear energy (un-scaled) to *total_energy.
 *
 * offset — Q7 constant added to the result; accounts for decimation factor.
 * --------------------------------------------------------------------------- */
int16_t WebRtcVad_LogOfEnergy(const int16_t* data,
                               size_t         data_length,
                               int16_t        offset,
                               int16_t*       total_energy) {
    /* Compute sum of squared samples. */
    int32_t energy = 0;
    for (size_t i = 0; i < data_length; ++i) {
        int32_t s = data[i];
        energy += (s * s) >> 10;  /* accumulate scaled energy */
        if (energy < 0) {         /* overflow guard */
            energy = 0x7fffffff;
            break;
        }
    }

    *total_energy = (int16_t)WEBRTC_SPL_MIN(energy, WEBRTC_SPL_WORD16_MAX);

    if (energy <= kMinEnergy) {
        return 0;
    }

    /* log2 via bit-length: floor(log2(energy)) in Q0.
     * We want Q7, so shift up 7 after the integer part. */
    int16_t bits = WebRtcSpl_GetSizeInBits((uint32_t)energy);
    /* Simple Q7 approximation: log2_Q7 = bits * 128 */
    int16_t log_q7 = (int16_t)((bits << 7) + offset);

    return log_q7;
}

/* ---------------------------------------------------------------------------
 * WebRtcVad_get_features — full filter-bank producing 6 Q7 log-energies.
 *
 * Frame-size contract (at 8 kHz):
 *   10 ms → 80 samples
 *   20 ms → 160 samples
 *   30 ms → 240 samples
 * --------------------------------------------------------------------------- */
int16_t WebRtcVad_get_features(VadInstT*      self,
                               const int16_t* in,
                               size_t         frame_length,
                               int16_t*       features) {
    /* --- Stage 0: high-pass filter removes DC / rumble -------------------- */
    int16_t hp_out[240];
    WebRtcVad_HpFilter(in, frame_length, self->hp_filter_state, hp_out);

    /* --- Stage 1: first QMF split → bands [0–4 kHz] and [4–8 kHz] -------- */
    size_t  half1    = frame_length >> 1;
    int16_t lp1[120], hp1[120];
    WebRtcVad_SplitFilter(hp_out, frame_length,
                          &self->upper_state[0], &self->lower_state[0],
                          hp1, lp1);

    /* --- Stage 2: split LP band → [0–2 kHz] and [2–4 kHz] ---------------- */
    size_t  half2    = half1 >> 1;
    int16_t lp2[60], hp2[60];
    WebRtcVad_SplitFilter(lp1, half1,
                          &self->upper_state[1], &self->lower_state[1],
                          hp2, lp2);

    /* --- Stage 3: split lower LP → [0–1 kHz] and [1–2 kHz] --------------- */
    size_t  half3    = half2 >> 1;
    int16_t lp3[30], hp3[30];
    WebRtcVad_SplitFilter(lp2, half2,
                          &self->upper_state[2], &self->lower_state[2],
                          hp3, lp3);

    /* --- Stage 4: split lowest LP → [0–0.5 kHz] and [0.5–1 kHz] ---------- */
    size_t  half4    = half3 >> 1;
    int16_t lp4[16], hp4[16];
    WebRtcVad_SplitFilter(lp3, half3,
                          &self->upper_state[3], &self->lower_state[3],
                          hp4, lp4);

    /* --- Stage 5: split [2–4 kHz] → [2–3 kHz] and [3–4 kHz] ------------- */
    int16_t hp5a[32], hp5b[32];
    WebRtcVad_SplitFilter(hp2, half2,
                          &self->upper_state[4], &self->lower_state[4],
                          hp5b, hp5a);

    /* --- Log-energy per channel -------------------------------------------- */
    /*  ch0:  80–250 Hz   → lp4 */
    /*  ch1: 250–500 Hz   → hp4 */
    /*  ch2: 500–1000 Hz  → hp3 */
    /*  ch3: 1000–2000 Hz → hp2 */
    /*  ch4: 2000–3000 Hz → hp5a */
    /*  ch5: 3000–4000 Hz → hp5b */

    int16_t total_energy = 0;
    int16_t sub_energy;

    /* Offset values (Q7) compensate for the energy reduction per band split.
     * Each ×2 decimation halves the bandwidth, reducing total energy by ~½.
     * We add log2(2^k) * 128 to keep features on a comparable scale. */
    static const int16_t kOffsets[6] = { 1024, 1024, 896, 896, 768, 768 };

    features[0] = WebRtcVad_LogOfEnergy(lp4, half4,    kOffsets[0], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    features[1] = WebRtcVad_LogOfEnergy(hp4, half4,    kOffsets[1], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    features[2] = WebRtcVad_LogOfEnergy(hp3, half3,    kOffsets[2], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    features[3] = WebRtcVad_LogOfEnergy(hp2, half2,    kOffsets[3], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    features[4] = WebRtcVad_LogOfEnergy(hp5a, half2>>1, kOffsets[4], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    features[5] = WebRtcVad_LogOfEnergy(hp5b, half2>>1, kOffsets[5], &sub_energy);
    total_energy = (int16_t)WEBRTC_SPL_ADD_SAT_W32(total_energy, sub_energy);

    return total_energy;
}
