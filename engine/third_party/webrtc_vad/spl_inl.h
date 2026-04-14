/*
 *  Copyright (c) 2011 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree.
 */

/*
 * spl_inl.h — inline implementations of hot SPL primitives.
 *
 * Included at the bottom of signal_processing_library.h so every translation
 * unit that includes the SPL header gets the inline bodies without needing a
 * separate compilation unit.
 */

#ifndef THIRD_PARTY_WEBRTC_VAD_SPL_INL_H_
#define THIRD_PARTY_WEBRTC_VAD_SPL_INL_H_

#include <stdint.h>

/* ---------------------------------------------------------------------------
 * WebRtcSpl_NormW32 — count leading-sign bits in a signed 32-bit integer.
 *
 * Definition matches the original WebRTC SPL:
 *   Return 0  if a == 0.
 *   Otherwise negate if negative (we count zeros in the magnitude), then
 *   count the number of consecutive zero bits from the MSB downward,
 *   stopping before bit 31 (which is always 0 after negation for negatives,
 *   or always 0 for positives if a > 0).
 *
 *   Equivalent to:  __builtin_clz(a > 0 ? a : ~a) - 1   on GCC/Clang.
 * --------------------------------------------------------------------------- */
static inline int WebRtcSpl_NormW32(int32_t a) {
    if (a == 0) {
        return 0;
    }
    if (a < 0) {
        a = ~a;
    }
    /* a is now non-negative; count leading zeros minus 1 (sign bit). */
    int zeros = 0;
    if (!(a & 0xFFFF0000u)) { zeros += 16; a = (int32_t)((uint32_t)a << 16); }
    if (!(a & 0xFF000000u)) { zeros += 8;  a = (int32_t)((uint32_t)a << 8);  }
    if (!(a & 0xF0000000u)) { zeros += 4;  a = (int32_t)((uint32_t)a << 4);  }
    if (!(a & 0xC0000000u)) { zeros += 2;  a = (int32_t)((uint32_t)a << 2);  }
    if (!(a & 0x80000000u)) { zeros += 1;  }
    return zeros;
}

/* ---------------------------------------------------------------------------
 * WebRtcSpl_NormW16 — count leading-sign bits in a signed 16-bit integer.
 *
 * Widens to 32 bits and reuses NormW32.  The sign extension means the top
 * 16 bits are always identical to bit 15, so we subtract 16.
 * --------------------------------------------------------------------------- */
static inline int WebRtcSpl_NormW16(int16_t a) {
    int32_t a32 = (int32_t)a;
    if (a32 == 0) {
        return 0;
    }
    /* NormW32 on the sign-extended value counts 16 extra leading-sign bits. */
    int n = WebRtcSpl_NormW32(a32);
    return n - 16;
}

/* ---------------------------------------------------------------------------
 * WebRtcSpl_NormU32 — count leading zeros in an unsigned 32-bit integer.
 *
 * Returns 0 if a == 0 (consistent with the original WebRTC SPL behaviour).
 * --------------------------------------------------------------------------- */
static inline int WebRtcSpl_NormU32(uint32_t a) {
    if (a == 0) {
        return 0;
    }
    int zeros = 0;
    if (!(a & 0xFFFF0000u)) { zeros += 16; a <<= 16; }
    if (!(a & 0xFF000000u)) { zeros += 8;  a <<= 8;  }
    if (!(a & 0xF0000000u)) { zeros += 4;  a <<= 4;  }
    if (!(a & 0xC0000000u)) { zeros += 2;  a <<= 2;  }
    if (!(a & 0x80000000u)) { zeros += 1;  }
    return zeros;
}

#endif  /* THIRD_PARTY_WEBRTC_VAD_SPL_INL_H_ */
