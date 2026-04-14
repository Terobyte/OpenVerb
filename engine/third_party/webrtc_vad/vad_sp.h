/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_sp.h — signal-processing utility functions for the WebRTC VAD.
 *
 * Provides the downsampling path (48 kHz / 32 kHz / 16 kHz → 8 kHz) and
 * the saturating arithmetic helpers that are too small to warrant a separate
 * compilation unit but are too large to keep inline.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_VAD_SP_H_
#define THIRD_PARTY_WEBRTC_VAD_VAD_SP_H_

#include <stddef.h>
#include <stdint.h>

#include "vad_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * WebRtcVad_Downsampling — decimate by 2 with a simple FIR anti-alias filter.
 *
 * filter_state — 2 int32_t filter memory elements (updated in place).
 * data_in      — input at the higher sample rate.
 * data_out     — output at half the sample rate (length = data_length / 2).
 * data_length  — number of input samples; must be even.
 * --------------------------------------------------------------------------- */
void WebRtcVad_Downsampling(const int16_t* data_in,
                            int16_t*       data_out,
                            int32_t*       filter_state,
                            size_t         data_length);

/* ---------------------------------------------------------------------------
 * WebRtcVad_MeanAndStd — compute mean and standard deviation of an int16_t
 * array in the Q7 log-energy domain.
 *
 * Used during GMM model initialisation.
 *
 * Returns mean in Q7; writes std to *std_out in Q7.
 * --------------------------------------------------------------------------- */
int16_t WebRtcVad_MeanAndStd(const int16_t* data,
                              size_t         data_length,
                              int16_t*       std_out);

/* ---------------------------------------------------------------------------
 * Saturating arithmetic helpers (non-inline, bodies in vad_sp.c).
 * --------------------------------------------------------------------------- */
int32_t WebRtcSpl_AddSatW32(int32_t a, int32_t b);
int16_t WebRtcSpl_AddSatW16(int16_t a, int16_t b);
int16_t WebRtcSpl_DivW32W16ResW16(int32_t num, int16_t den);
int16_t WebRtcSpl_GetSizeInBits(uint32_t n);

#ifdef __cplusplus
}
#endif

#endif  /* THIRD_PARTY_WEBRTC_VAD_VAD_SP_H_ */
