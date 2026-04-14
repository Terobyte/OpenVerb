/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * vad_filterbank.h — 6-subband analysis filter-bank used by the WebRTC VAD.
 *
 * The filter bank splits an 8 kHz mono frame into 6 frequency channels:
 *
 *   Channel 0 :   80 –  250 Hz
 *   Channel 1 :  250 –  500 Hz
 *   Channel 2 :  500 – 1000 Hz
 *   Channel 3 : 1000 – 2000 Hz
 *   Channel 4 : 2000 – 3000 Hz
 *   Channel 5 : 3000 – 4000 Hz
 *
 * The implementation uses a pair of cascaded all-pass sections to realise a
 * two-band QMF split, applied recursively to achieve the 6-channel structure.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_VAD_FILTERBANK_H_
#define THIRD_PARTY_WEBRTC_VAD_VAD_FILTERBANK_H_

#include <stddef.h>
#include <stdint.h>

#include "vad_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * WebRtcVad_HpFilter — 2nd-order high-pass biquad (cutoff ≈ 80 Hz at 8 kHz).
 *
 * Filters `data_in` (length `data_length`) in-place, updating `filter_state`
 * (4 int16_t elements: [x[n-1], x[n-2], y[n-1], y[n-2]]).
 * --------------------------------------------------------------------------- */
void WebRtcVad_HpFilter(const int16_t* data_in,
                        size_t         data_length,
                        int16_t*       filter_state,
                        int16_t*       data_out);

/* ---------------------------------------------------------------------------
 * WebRtcVad_AllPassFilter — one cascaded all-pass filter section.
 *
 * Used within the QMF filterbank to realise half-band filtering.
 * coeff — Q15 all-pass coefficient.
 * filter_state — pointer to one int16_t state element (updated in place).
 * --------------------------------------------------------------------------- */
void WebRtcVad_AllPassFilter(const int16_t* data_in,
                             size_t         data_length,
                             int16_t        coeff,
                             int16_t*       filter_state,
                             int16_t*       data_out);

/* ---------------------------------------------------------------------------
 * WebRtcVad_SplitFilter — split an 8 kHz signal into two 4 kHz sub-bands.
 *
 * Applies two all-pass filters with different coefficients to produce:
 *   lower_data — low half-band (0 – 4 kHz, decimated ×2)
 *   upper_data — high half-band (4 – 8 kHz, decimated ×2)
 *
 * state — pointer to 2 × int16_t all-pass states (lower then upper).
 * --------------------------------------------------------------------------- */
void WebRtcVad_SplitFilter(const int16_t* data_in,
                           size_t         data_length,
                           int16_t*       upper_state,
                           int16_t*       lower_state,
                           int16_t*       hp_data,
                           int16_t*       lp_data);

/* ---------------------------------------------------------------------------
 * WebRtcVad_get_features — run the full 6-channel filter-bank and return
 * the log-energy per channel.
 *
 * self    — VAD instance (provides persistent all-pass filter states).
 * in      — 8 kHz mono frame of length `frame_length`.
 * features — output array of 6 Q7 log-energy values (one per channel).
 *
 * Returns the total (wideband) log-energy in Q7.
 * --------------------------------------------------------------------------- */
int16_t WebRtcVad_get_features(VadInstT*      self,
                               const int16_t* in,
                               size_t         frame_length,
                               int16_t*       features);

/* ---------------------------------------------------------------------------
 * WebRtcVad_LogOfEnergy — compute log2(energy) for a sub-band signal.
 *
 * Returns the log-energy in Q7 and writes the total linear energy (Q4)
 * to *total_energy.  The offset compensates for the decimation factor and
 * frame length so that features across frame sizes are comparable.
 * --------------------------------------------------------------------------- */
int16_t WebRtcVad_LogOfEnergy(const int16_t* data,
                               size_t         data_length,
                               int16_t        offset,
                               int16_t*       total_energy);

#ifdef __cplusplus
}
#endif

#endif  /* THIRD_PARTY_WEBRTC_VAD_VAD_FILTERBANK_H_ */
