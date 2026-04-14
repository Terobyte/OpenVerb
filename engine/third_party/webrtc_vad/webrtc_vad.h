/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * webrtc_vad.h — public C API for the WebRTC Voice Activity Detector.
 *
 * Usage:
 *   VadInst* vad = NULL;
 *   WebRtcVad_Create(&vad);
 *   WebRtcVad_Init(vad);
 *   WebRtcVad_set_mode(vad, 3);          // very aggressive
 *   int result = WebRtcVad_Process(vad, 16000, samples, 480);  // 30 ms
 *   WebRtcVad_Free(vad);
 *
 * Valid sample rates:  8 000, 16 000, 32 000, 48 000 Hz.
 * Valid frame lengths: 10 ms, 20 ms, or 30 ms expressed in samples.
 *
 * The VAD operates internally at 8 kHz.  Higher sample rates are downsampled
 * before processing.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_WEBRTC_VAD_H_
#define THIRD_PARTY_WEBRTC_VAD_WEBRTC_VAD_H_

#include <stddef.h>
#include <stdint.h>

/* Opaque handle type. */
typedef struct WebRtcVadInst VadInst;

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * WebRtcVad_Create — allocate a new VAD instance.
 *
 * On success *handle points to the allocated object and 0 is returned.
 * Returns -1 if handle is NULL or allocation fails.
 * --------------------------------------------------------------------------- */
int WebRtcVad_Create(VadInst** handle);

/* ---------------------------------------------------------------------------
 * WebRtcVad_Free — release all memory owned by a VAD instance.
 *
 * Safe to call with NULL.
 * --------------------------------------------------------------------------- */
void WebRtcVad_Free(VadInst* handle);

/* ---------------------------------------------------------------------------
 * WebRtcVad_Init — initialise (or reset) a VAD instance to default state.
 *
 * Must be called after WebRtcVad_Create and before WebRtcVad_Process.
 * May be called again at any time to reset the internal model.
 *
 * Returns 0 on success, -1 if handle is NULL.
 * --------------------------------------------------------------------------- */
int WebRtcVad_Init(VadInst* handle);

/* ---------------------------------------------------------------------------
 * WebRtcVad_set_mode — select the operating aggressiveness mode.
 *
 * mode:
 *   0  Normal quality — lowest false-positive rate, may miss low-energy speech
 *   1  Low bitrate    — slightly more aggressive
 *   2  Aggressive     — good balance for typical voice applications
 *   3  Very aggressive — highest sensitivity; more false positives possible
 *
 * Returns 0 on success, -1 on invalid handle or out-of-range mode.
 * --------------------------------------------------------------------------- */
int WebRtcVad_set_mode(VadInst* handle, int mode);

/* ---------------------------------------------------------------------------
 * WebRtcVad_Process — classify one frame of audio.
 *
 * handle       — initialised VAD instance.
 * fs           — sample rate in Hz (8000 | 16000 | 32000 | 48000).
 * audio_frame  — pointer to |frame_length| interleaved int16_t samples.
 * frame_length — number of samples; must correspond to 10, 20, or 30 ms.
 *
 * Returns:
 *    1  — active voice detected
 *    0  — non-active (silence / noise)
 *   -1  — error (null handle, invalid rate, or invalid frame length)
 * --------------------------------------------------------------------------- */
int WebRtcVad_Process(VadInst*       handle,
                      int            fs,
                      const int16_t* audio_frame,
                      size_t         frame_length);

/* ---------------------------------------------------------------------------
 * WebRtcVad_ValidRateAndFrameLength — validate a (rate, frame_length) pair.
 *
 * Returns 0 if the combination is supported, -1 otherwise.
 * --------------------------------------------------------------------------- */
int WebRtcVad_ValidRateAndFrameLength(int rate, size_t frame_length);

#ifdef __cplusplus
}
#endif

#endif  /* THIRD_PARTY_WEBRTC_VAD_WEBRTC_VAD_H_ */
