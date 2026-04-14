/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_gmm.h — Gaussian Mixture Model evaluation for WebRTC VAD.
 *
 * Each frequency channel is modelled with a 2-component GMM:
 *   P(x | class) = w0·N(x; μ0, σ0) + w1·N(x; μ1, σ1)
 *
 * The VAD decision is based on comparing the log-likelihood ratio
 *   LLR(x) = log P(x|speech) – log P(x|noise)
 * to a threshold.  Models are updated online using a simplified EM step.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_VAD_GMM_H_
#define THIRD_PARTY_WEBRTC_VAD_VAD_GMM_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * WebRtcVad_GaussianProbability — evaluate one Gaussian component.
 *
 * Computes:
 *   N(x; mean, std) ∝ exp(-(x - mean)^2 / (2·std^2))
 * in the log-energy / Q7 domain, returning a Q27-scaled probability.
 *
 * Parameters:
 *   x       — feature value (log-energy, Q7)
 *   mean    — Gaussian mean (Q7)
 *   std     — Gaussian standard deviation (Q7, must be > 0)
 *   delta   — output: (x - mean) / std^2  in Q7 (used for model update)
 *
 * Returns the probability density in Q27.
 * --------------------------------------------------------------------------- */
int32_t WebRtcVad_GaussianProbability(int16_t  x,
                                      int16_t  mean,
                                      int16_t  std,
                                      int16_t* delta);

#ifdef __cplusplus
}
#endif

#endif  /* THIRD_PARTY_WEBRTC_VAD_VAD_GMM_H_ */
