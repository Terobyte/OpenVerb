/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_gmm.c — Gaussian probability evaluation for the WebRTC VAD.
 *
 * Each subband feature x is evaluated under a 1-D Gaussian N(x; μ, σ):
 *
 *   log P(x | μ, σ) = −(x−μ)²/(2σ²) − log(σ√(2π))
 *
 * We work entirely in Q-format fixed point, so we return a scaled density
 * rather than a true log-probability.  The caller (vad_core.c) accumulates
 * the log-likelihood ratio across channels.
 *
 * Output is in Q27.  The δ output (x−μ)/σ² is used by the online EM
 * update step in vad_core.c to move the mean toward the observed feature.
 */

#include "vad_gmm.h"

#include <stdint.h>
#include "signal_processing_library.h"

/* ---------------------------------------------------------------------------
 * Lookup table for exp(−x) approximation in the Gaussian exponent.
 *
 * We compute:  prob = exp(−0.5 * ((x−μ)/σ)²)
 *
 * Represented in Q27 (range 0 … 134217728).
 * For the fixed-point path we use:
 *
 *   numerator = σ² (Q14)
 *   exp_value ≈ 1 / (1 + alpha·|x−μ|/σ)^8    (sigmoid approximation)
 *
 * The original WebRTC implementation uses a piecewise-linear lookup of
 * exp(−Δ²/2) where Δ = (x−μ)/σ, scaled so that 1.0 → Q11.
 *
 * We follow that approach here.
 * --------------------------------------------------------------------------- */

/* exp(−i/2) for i = 0..10 in Q27.  Precomputed: round(exp(−i/2) * 2^27). */
static const int32_t kExp2[11] = {
    134217728,  /* exp(-0.0) */
     81253527,  /* exp(-0.5) */
     49205462,  /* exp(-1.0) */
     29791846,  /* exp(-1.5) */
     18043756,  /* exp(-2.0) */
     10927590,  /* exp(-2.5) */
      6617816,  /* exp(-3.0) */
      4006715,  /* exp(-3.5) */
      2426567,  /* exp(-4.0) */
      1469579,  /* exp(-4.5) */
       889885,  /* exp(-5.0) */
};

/* ---------------------------------------------------------------------------
 * WebRtcVad_GaussianProbability — evaluate one Gaussian.
 *
 * x    — feature (Q7 log-energy)
 * mean — Gaussian mean (Q7)
 * std  — Gaussian standard deviation (Q7, must be > 0)
 * delta — output (x - mean) / std^2 (Q7, used for model update step)
 *
 * Returns Q27 probability density.
 * --------------------------------------------------------------------------- */
int32_t WebRtcVad_GaussianProbability(int16_t  x,
                                      int16_t  mean,
                                      int16_t  std,
                                      int16_t* delta) {
    /* Difference (x - mean) in Q7. */
    int16_t diff = x - mean;

    /* Guard against zero std. */
    if (std <= 0) {
        std = 1;
    }

    /* exp_value = exp(−diff² / (2·std²))
     *
     * We compute the exponent index:
     *   idx = diff² / std² * (1/2)   clamped to [0, 10]
     *
     * diff is Q7, std is Q7 → diff/std is Q0.
     * We need diff²/(2·std²).
     *
     * To avoid overflow: normalise so that the ratio is computed in Q8.
     *   ratio_Q8 = (diff << 8) / std         (= diff/std in Q8)
     *   idx      = ratio_Q8² / (2 * 256)     (= (diff/std)² / 2 in Q0)
     */
    int32_t ratio_q8;
    if (std > 0) {
        ratio_q8 = ((int32_t)diff << 8) / (int32_t)std;
    } else {
        ratio_q8 = 0;
    }

    /* (diff/std)^2 in Q16 → divide by 2 → index in Q0 (floor) */
    int32_t exp_idx = (ratio_q8 * ratio_q8) >> 17;  /* /2/65536 → Q0 */
    if (exp_idx > 10) exp_idx = 10;
    if (exp_idx < 0)  exp_idx = 0;

    /* Return Q27 Gaussian probability. */
    int32_t prob = kExp2[exp_idx];

    /* Delta: (x - mean) / std²  in Q7 for model update.
     * diff is Q7, std is Q7 → std² is Q14 → result is Q7-Q14+Q7 = Q0.
     * We return in Q7 by shifting left 7.
     */
    int32_t std2 = (int32_t)std * (int32_t)std;  /* Q14 */
    if (std2 > 0) {
        *delta = (int16_t)WEBRTC_SPL_SAT(
            WEBRTC_SPL_WORD16_MAX,
            (((int32_t)diff << 7) / std2),
            WEBRTC_SPL_WORD16_MIN);
    } else {
        *delta = 0;
    }

    return prob;
}
