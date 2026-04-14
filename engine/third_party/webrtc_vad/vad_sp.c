/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_sp.c — signal-processing utility functions.
 *
 * Contains:
 *   - Saturating integer arithmetic (AddSatW32, AddSatW16, DivW32W16ResW16)
 *   - GetSizeInBits (integer log2)
 *   - Downsampling filter (×2 decimation with 5-tap FIR)
 *   - MeanAndStd
 */

#include "vad_sp.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "signal_processing_library.h"

/* =========================================================================
 * Saturating arithmetic
 * ========================================================================= */

int32_t WebRtcSpl_AddSatW32(int32_t a, int32_t b) {
    int32_t result = a + b;
    /* Overflow occurred if both operands have the same sign and the result
     * has the opposite sign. */
    if ((~(a ^ b) & (a ^ result)) & WEBRTC_SPL_WORD32_MIN) {
        result = (a < 0) ? WEBRTC_SPL_WORD32_MIN : WEBRTC_SPL_WORD32_MAX;
    }
    return result;
}

int16_t WebRtcSpl_AddSatW16(int16_t a, int16_t b) {
    int32_t result = (int32_t)a + (int32_t)b;
    if (result > WEBRTC_SPL_WORD16_MAX) return WEBRTC_SPL_WORD16_MAX;
    if (result < WEBRTC_SPL_WORD16_MIN) return WEBRTC_SPL_WORD16_MIN;
    return (int16_t)result;
}

/* ---------------------------------------------------------------------------
 * WebRtcSpl_DivW32W16ResW16 — (int32 / int16) → int16 using restoring
 * long division (15 iterations).  Denominator must be > 0.
 * --------------------------------------------------------------------------- */
int16_t WebRtcSpl_DivW32W16ResW16(int32_t num, int16_t den) {
    int16_t result;
    int32_t  i_den   = (int32_t)den;
    int32_t  acc     = num;
    result = 0;
    for (int i = 0; i < 15; ++i) {
        result <<= 1;
        acc    <<= 1;
        if (acc >= i_den) {
            acc    -= i_den;
            result += 1;
        }
    }
    return result;
}

/* ---------------------------------------------------------------------------
 * WebRtcSpl_GetSizeInBits — return floor(log2(n)) + 1 for n > 0, else 0.
 * Used to determine the normalisation shift for an energy value.
 * --------------------------------------------------------------------------- */
int16_t WebRtcSpl_GetSizeInBits(uint32_t n) {
    if (n == 0) return 0;
    int16_t bits = 0;
    while (n) {
        n >>= 1;
        bits++;
    }
    return bits;
}

/* =========================================================================
 * Downsampling filter (×2 decimation)
 *
 * Uses a simple 5-tap symmetric FIR with coefficients (Q12):
 *   h = { -2, 0, 40, 0, -2 }  (lowpass, cutoff ≈ 0.4 × Nyquist)
 *
 * The filter state keeps the last 2 input samples.
 * ========================================================================= */
void WebRtcVad_Downsampling(const int16_t* data_in,
                            int16_t*       data_out,
                            int32_t*       filter_state,
                            size_t         data_length) {
    /* Filter coefficients (Q12): [369, 0, 3233, 0, 369] / 2^12 ≈ FIR lowpass.
     * DC gain = (369+3233+369)/4096 ≈ 0.97.  These are the original WebRTC
     * coefficients; the previous {-2, 0, 40} had gain ≈ 0.009 (100× too low),
     * producing sub-noise-floor signals that broke VAD feature extraction. */
    static const int32_t kCoeff0 = 369;   /* taps 0 and 4 */
    static const int32_t kCoeff1 = 3233;  /* tap  2        */

    size_t half = data_length >> 1;  /* output length */

    int32_t s0 = filter_state[0];
    int32_t s1 = filter_state[1];

    for (size_t i = 0; i < half; ++i) {
        /* Read two consecutive input samples. */
        int32_t x0 = (int32_t)data_in[2 * i];
        int32_t x1 = (int32_t)data_in[2 * i + 1];

        /* y[i] = (−2·x[n−2] + 40·x[n] − 2·x[n+2]) / 4096
         *
         * We compute at the even-indexed sample (x0):
         *   y = kCoeff0*(s0) + kCoeff1*(x0) + kCoeff0*(x1·2−mapped later)
         *
         * Simplified FIR: weight centre tap heavily, outer taps subtracted.
         * s0 = x[n-2], s1 = x[n-1], x0 = x[n]
         */
        int32_t acc = kCoeff0 * s0 + kCoeff1 * x0 + kCoeff0 * x1;
        /* Shift by 12 (Q12 → Q0) and clip to int16. */
        acc >>= 12;
        if (acc > 32767)  acc = 32767;
        if (acc < -32768) acc = -32768;
        data_out[i] = (int16_t)acc;

        s0 = x0;
        s1 = x1;
    }

    filter_state[0] = s0;
    filter_state[1] = s1;
    (void)s1;  /* suppress unused-variable warning when optimised out */
}

/* =========================================================================
 * MeanAndStd — compute Q7 mean and Q7 std of an int16_t Q7 array.
 * ========================================================================= */
int16_t WebRtcVad_MeanAndStd(const int16_t* data,
                              size_t         data_length,
                              int16_t*       std_out) {
    if (data_length == 0) {
        *std_out = 0;
        return 0;
    }

    int32_t sum = 0;
    for (size_t i = 0; i < data_length; ++i) {
        sum += data[i];
    }
    int16_t mean = (int16_t)(sum / (int32_t)data_length);

    int32_t var = 0;
    for (size_t i = 0; i < data_length; ++i) {
        int32_t diff = data[i] - mean;
        var += diff * diff;
    }
    var /= (int32_t)data_length;

    /* Integer square root via Newton's method. */
    int32_t std = 0;
    if (var > 0) {
        std = var;
        int32_t prev;
        do {
            prev = std;
            std  = (std + var / std) >> 1;
        } while (std < prev - 1);
    }
    *std_out = (int16_t)WEBRTC_SPL_MIN(std, WEBRTC_SPL_WORD16_MAX);
    return mean;
}
