#pragma once

#include <cstdint>
#include <vector>

#include "audio/reader.h"                          // AudioData
#include "config/defaults.h"                       // VAD_SILENCE_MS
#include "../../third_party/webrtc_vad/webrtc_vad.h"  // VadInst, WebRtcVad_*

// ---------------------------------------------------------------------------
// Vad — thin C++ wrapper around the WebRTC Voice Activity Detector.
//
// Lifecycle:
//   Vad vad;                        // mode 3 ("very aggressive"), 16 kHz
//   bool active = vad.is_speech(frame, 480);   // test one 30 ms frame
//   auto trimmed = vad.filter(audio, 16000);   // strip silence from clip
//
// Thread safety: NOT thread-safe.  Use one Vad per thread.
// ---------------------------------------------------------------------------
class Vad {
public:
    // Construct a VAD instance.
    //   mode        — aggressiveness (0 = normal … 3 = very aggressive).
    //   sample_rate — rate used by is_speech() (8000 | 16000 | 32000 | 48000).
    // Throws std::runtime_error if creation or initialisation fails.
    explicit Vad(int mode = 3, int sample_rate = 16000);
    ~Vad();

    // Non-copyable; the WebRTC VAD instance owns heap state.
    Vad(const Vad&)            = delete;
    Vad& operator=(const Vad&) = delete;

    // ---------------------------------------------------------------------------
    // is_speech — classify a single PCM frame.
    //
    // samples     — pointer to int16_t PCM mono samples.
    // num_samples — frame length; must correspond to exactly 10, 20, or 30 ms
    //               at the sample_rate supplied at construction.
    //
    // Returns true if the WebRTC VAD classifies the frame as containing speech.
    // Returns false on error (invalid frame length, etc.).
    // ---------------------------------------------------------------------------
    bool is_speech(const int16_t* samples, int num_samples) const;

    // ---------------------------------------------------------------------------
    // filter — remove non-speech frames from an AudioData clip.
    //
    // Processes audio in 30 ms frames.  Keeps all speech frames plus up to
    // `silence_ms` of trailing silence after each speech region, which prevents
    // cutting off the tail of a word or sentence.
    //
    // Parameters:
    //   audio        — source AudioData (mono or multi-channel; filter works on
    //                  the raw samples vector — caller should to_mono() first).
    //   sample_rate  — rate of the audio (8000 | 16000 | 32000 | 48000 Hz).
    //   silence_ms   — maximum trailing silence to keep after each speech burst
    //                  (default VAD_SILENCE_MS = 500 ms).  Rounded down to a 30 ms
    //                  frame boundary.
    //
    // Minimum speech threshold:
    //   If the total number of detected speech frames across the entire clip is
    //   fewer than 7 frames (7 × 30 ms = 210 ms), the function returns an
    //   empty vector.  This threshold is frame-aligned to the 30 ms WebRTC VAD
    //   frame size; 7 frames is the smallest multiple that exceeds 200 ms.
    //
    // Returns:
    //   A std::vector<int16_t> containing the concatenated speech (+ trailing
    //   silence) segments in the original sample order.
    //   Empty if total speech < 7 frames or the input clip is too short for
    //   even one 30 ms frame.
    // ---------------------------------------------------------------------------
    std::vector<int16_t> filter(const AudioData& audio,
                                int              sample_rate,
                                int              silence_ms = VAD_SILENCE_MS) const;

private:
    VadInst* vad_;
    int      sample_rate_;
};
