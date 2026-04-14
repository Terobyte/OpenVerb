/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * webrtc_vad.c — public C API implementation.
 *
 * This file is a thin shim that validates inputs and delegates to the
 * internal implementation in vad_core.c.  It owns heap allocation via
 * WebRtcVad_Create / WebRtcVad_Free and handles the sample-rate routing
 * (48 kHz is downsampled 6:1 to 8 kHz via WebRtcVad_CalcVad48khz; other
 * rates are passed to their respective CalcVadXXkhz entry points).
 */

#include "webrtc_vad.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "vad_core.h"

/* The public VadInst type is an alias for the internal VadInstT. */
struct WebRtcVadInst {
    VadInstT core;
};

/* =========================================================================
 * Lifecycle
 * ========================================================================= */

int WebRtcVad_Create(VadInst** handle) {
    if (!handle) return -1;

    *handle = (VadInst*)malloc(sizeof(VadInst));
    if (!*handle) return -1;

    memset(*handle, 0, sizeof(VadInst));
    return 0;
}

void WebRtcVad_Free(VadInst* handle) {
    free(handle);
}

int WebRtcVad_Init(VadInst* handle) {
    if (!handle) return -1;
    return WebRtcVad_InitCore(&handle->core);
}

int WebRtcVad_set_mode(VadInst* handle, int mode) {
    if (!handle) return -1;
    return WebRtcVad_set_mode_core(&handle->core, mode);
}

/* =========================================================================
 * Validation
 * ========================================================================= */

int WebRtcVad_ValidRateAndFrameLength(int rate, size_t frame_length) {
    /* The frame_length must correspond to exactly 10, 20, or 30 ms. */
    int samples_per_ms;
    switch (rate) {
        case 8000:  samples_per_ms =  8; break;
        case 16000: samples_per_ms = 16; break;
        case 32000: samples_per_ms = 32; break;
        case 48000: samples_per_ms = 48; break;
        default: return -1;
    }
    size_t samples_10ms = (size_t)(samples_per_ms * 10);
    if (frame_length == samples_10ms ||
        frame_length == samples_10ms * 2 ||
        frame_length == samples_10ms * 3) {
        return 0;
    }
    return -1;
}

/* =========================================================================
 * Processing
 * ========================================================================= */

int WebRtcVad_Process(VadInst*       handle,
                      int            fs,
                      const int16_t* audio_frame,
                      size_t         frame_length) {
    if (!handle || !audio_frame) return -1;
    if (WebRtcVad_ValidRateAndFrameLength(fs, frame_length) != 0) return -1;

    VadInstT* core = &handle->core;

    switch (fs) {
        case 48000:
            return WebRtcVad_CalcVad48khz(core, audio_frame, frame_length);
        case 32000:
            return WebRtcVad_CalcVad32khz(core, audio_frame, frame_length);
        case 16000:
            return WebRtcVad_CalcVad16khz(core, audio_frame, frame_length);
        case 8000:
            return WebRtcVad_CalcVad8khz(core, audio_frame, frame_length);
        default:
            return -1;
    }
}
