/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

/*
 * signal_processing_library.h — fixed-point DSP primitives used by WebRTC VAD.
 *
 * All arithmetic is integer-only (no floating point).  Shift and multiply
 * macros operate on int16_t / int32_t types in specific Q-formats as
 * documented per call-site in the VAD implementation files.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_SIGNAL_PROCESSING_LIBRARY_H_
#define THIRD_PARTY_WEBRTC_VAD_SIGNAL_PROCESSING_LIBRARY_H_

#include <stdint.h>

/* --------------------------------------------------------------------------
 * Integer limits
 * -------------------------------------------------------------------------- */
#define WEBRTC_SPL_WORD16_MAX    32767
#define WEBRTC_SPL_WORD16_MIN   (-32768)
#define WEBRTC_SPL_WORD32_MAX    ((int32_t)0x7fffffff)
#define WEBRTC_SPL_WORD32_MIN    ((int32_t)0x80000000)

/* --------------------------------------------------------------------------
 * Min / Max / Abs
 * -------------------------------------------------------------------------- */
#define WEBRTC_SPL_MIN(A, B)     ((A) < (B) ? (A) : (B))
#define WEBRTC_SPL_MAX(A, B)     ((A) > (B) ? (A) : (B))
#define WEBRTC_SPL_ABS_W16(a)    ((int16_t)((a) >= 0 ? (a) : -(a)))
#define WEBRTC_SPL_ABS_W32(a)    ((int32_t)((a) >= 0 ? (a) : -(a)))

/* --------------------------------------------------------------------------
 * Saturation
 * -------------------------------------------------------------------------- */
#define WEBRTC_SPL_SAT(a, b, c)  ((b) > (a) ? (a) : (b) < (c) ? (c) : (b))

/* --------------------------------------------------------------------------
 * Multiply macros
 * All results are int32_t.
 * -------------------------------------------------------------------------- */

/* 16×16 → 32 */
#define WEBRTC_SPL_MUL_16_16(a, b) \
    ((int32_t)((int16_t)(a)) * (int32_t)((int16_t)(b)))

/* 16×16 → 32, then right-shift c bits */
#define WEBRTC_SPL_MUL_16_16_RSFT(a, b, c) \
    (WEBRTC_SPL_MUL_16_16((a), (b)) >> (c))

/* 16×16 → 32 with rounding, right-shift c bits */
#define WEBRTC_SPL_MUL_16_16_RSFT_WITH_ROUND(a, b, c) \
    ((WEBRTC_SPL_MUL_16_16((a), (b)) + (1 << ((c) - 1))) >> (c))

/* 16(signed)×16(unsigned) → 32 */
#define WEBRTC_SPL_MUL_16_U16(a, b) \
    ((int32_t)(int16_t)(a) * (int32_t)(uint16_t)(b))

/* 16×32 → 32, result right-shifted 16 bits (i.e. high 16 bits of product) */
#define WEBRTC_SPL_MUL_16_32_RSFT16(a, b)                          \
    (WEBRTC_SPL_MUL_16_16((a), (int16_t)((b) >> 16)) +             \
     ((WEBRTC_SPL_MUL_16_U16((a), (uint16_t)((b) & 0xffff)) +      \
       0x8000) >> 16))

/* --------------------------------------------------------------------------
 * Shift macros (named shifts help annotate Q-format changes in context)
 * -------------------------------------------------------------------------- */
#define WEBRTC_SPL_RSHIFT_W16(x, c)  ((int16_t)(x) >> (c))
#define WEBRTC_SPL_LSHIFT_W16(x, c)  ((int16_t)(x) << (c))
#define WEBRTC_SPL_RSHIFT_W32(x, c)  ((int32_t)(x) >> (c))
#define WEBRTC_SPL_LSHIFT_W32(x, c)  ((int32_t)(x) << (c))
#define WEBRTC_SPL_RSHIFT_U32(x, c)  ((uint32_t)(x) >> (c))
#define WEBRTC_SPL_LSHIFT_U32(x, c)  ((uint32_t)(x) << (c))

/* --------------------------------------------------------------------------
 * Saturating addition — inline implementations follow in spl_inl.h
 * -------------------------------------------------------------------------- */
#define WEBRTC_SPL_ADD_SAT_W32(a, b)  WebRtcSpl_AddSatW32((a), (b))

/* --------------------------------------------------------------------------
 * Function declarations
 * (inline bodies in spl_inl.h; non-inline bodies in vad_sp.c)
 * -------------------------------------------------------------------------- */
#ifdef __cplusplus
extern "C" {
#endif

/* Count leading-sign bits in a 32-bit signed integer.
 * Returns 0 for a == 0.  Equivalent to clz(|a|) - 1 for a != 0. */
static inline int WebRtcSpl_NormW32(int32_t a);

/* Count leading-sign bits in a 16-bit signed integer. */
static inline int WebRtcSpl_NormW16(int16_t a);

/* Count leading zeros in a 32-bit unsigned integer.  Returns 0 for a == 0. */
static inline int WebRtcSpl_NormU32(uint32_t a);

/* Saturating 32-bit addition. */
int32_t WebRtcSpl_AddSatW32(int32_t a, int32_t b);

/* Saturating 16-bit addition. */
int16_t WebRtcSpl_AddSatW16(int16_t a, int16_t b);

/* WebRTC division: (int16_t / int16_t) → int16_t  using 15 iterations of
 * restoring long division.  Denominator must be > 0. */
int16_t WebRtcSpl_DivW32W16ResW16(int32_t num, int16_t den);

/* Integer binary logarithm of (value >> 7).  Returns log2_Q10. */
int16_t WebRtcSpl_GetSizeInBits(uint32_t n);

#ifdef __cplusplus
}
#endif

/* Inline bodies */
#include "spl_inl.h"

#endif  /* THIRD_PARTY_WEBRTC_VAD_SIGNAL_PROCESSING_LIBRARY_H_ */
