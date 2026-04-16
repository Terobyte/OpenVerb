#include "audio/vad.h"

#include <stdexcept>
#include <vector>

// ---------------------------------------------------------------------------
// Implementation notes:
//
// The WebRTC VAD operates internally at 8 kHz.  Higher input rates are
// downsampled on the way in.  We always process 30 ms frames because:
//   - It matches the maximum WebRTC VAD frame size for all supported rates.
//   - It gives the coarsest time resolution (one bool per 30 ms) which is
//     the right granularity for a silence-stripping application.
//   - The minimum speech duration threshold (7 frames = 210 ms) must be a
//     whole multiple of the frame size; 7 × 30 ms = 210 ms is the first
//     frame-aligned value that exceeds the "<200 ms" spec requirement.
// ---------------------------------------------------------------------------

static constexpr int kFrameMs       = 30;   // WebRTC VAD frame length (ms)
static constexpr int kMinSpeechFrames = 7;  // 7 × 30 ms = 210 ms minimum

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

Vad::Vad(int mode, int sample_rate) : vad_(nullptr), sample_rate_(sample_rate) {
    if (WebRtcVad_Create(&vad_) != 0 || !vad_) {
        throw std::runtime_error("Vad: WebRtcVad_Create failed");
    }
    if (WebRtcVad_Init(vad_) != 0) {
        WebRtcVad_Free(vad_);
        throw std::runtime_error("Vad: WebRtcVad_Init failed");
    }
    if (WebRtcVad_set_mode(vad_, mode) != 0) {
        WebRtcVad_Free(vad_);
        throw std::runtime_error("Vad: WebRtcVad_set_mode failed (mode out of range)");
    }
}

Vad::~Vad() {
    WebRtcVad_Free(vad_);
}

// ---------------------------------------------------------------------------
// is_speech
// ---------------------------------------------------------------------------

bool Vad::is_speech(const int16_t* samples, int num_samples) const {
    int result = WebRtcVad_Process(vad_, sample_rate_, samples,
                                   static_cast<size_t>(num_samples));
    return result == 1;
}

// ---------------------------------------------------------------------------
// filter
// ---------------------------------------------------------------------------

std::vector<int16_t> Vad::filter(const AudioData& audio,
                                  int              sample_rate,
                                  int              silence_ms) const {
    if (sample_rate != sample_rate_) {
        throw std::invalid_argument(
            "Vad::filter: sample_rate (" + std::to_string(sample_rate) +
            ") != constructor rate (" + std::to_string(sample_rate_) + ")");
    }

    // Compute frame size and silence limit in frames.
    const int frame_size          = sample_rate * kFrameMs / 1000;
    const int silence_frame_limit = silence_ms / kFrameMs;

    const std::vector<int16_t>& pcm = audio.samples;

    // Need at least one complete 30 ms frame.
    if (static_cast<int>(pcm.size()) < frame_size) {
        return {};
    }

    // -----------------------------------------------------------------------
    // Pass 1: classify every 30 ms frame and count total speech frames.
    // -----------------------------------------------------------------------
    const size_t num_frames = pcm.size() / static_cast<size_t>(frame_size);

    std::vector<bool> speech(num_frames);
    int total_speech = 0;

    for (size_t fi = 0; fi < num_frames; ++fi) {
        int result = WebRtcVad_Process(vad_, sample_rate,
                                       pcm.data() + fi * static_cast<size_t>(frame_size),
                                       static_cast<size_t>(frame_size));
        bool s = (result == 1);
        speech[fi] = s;
        if (s) ++total_speech;
    }

    // If the clip has fewer than 7 speech frames (210 ms), treat it as
    // entirely non-speech and return nothing.
    if (total_speech < kMinSpeechFrames) {
        return {};
    }

    // -----------------------------------------------------------------------
    // Pass 2: build output — speech frames + trailing silence up to silence_ms.
    //
    // State machine:
    //   not in speech: skip silence frames; on speech → enter speech region.
    //   in speech:     copy speech frames immediately;
    //                  on silence → buffer up to silence_frame_limit frames.
    //                  if speech resumes within the limit → flush buffer + continue.
    //                  if silence exceeds limit → close region, discard buffer.
    // -----------------------------------------------------------------------
    std::vector<int16_t> out;
    out.reserve(num_frames * static_cast<size_t>(frame_size));

    bool              in_speech    = false;
    int               silence_cnt  = 0;
    std::vector<size_t> pending;        // frame indices of buffered silence

    auto append_frame = [&](size_t fi) {
        const int16_t* p = pcm.data() + fi * static_cast<size_t>(frame_size);
        out.insert(out.end(), p, p + frame_size);
    };

    for (size_t fi = 0; fi < num_frames; ++fi) {
        if (speech[fi]) {
            if (in_speech) {
                // Speech resumed within the silence gap — flush buffered silence.
                for (size_t si : pending) {
                    append_frame(si);
                }
                pending.clear();
                silence_cnt = 0;
            }
            in_speech = true;
            append_frame(fi);
        } else {
            if (in_speech) {
                ++silence_cnt;
                if (silence_cnt <= silence_frame_limit) {
                    // Buffer: may be mid-word silence or a brief pause.
                    pending.push_back(fi);
                } else {
                    // Silence exceeded limit — close this speech region.
                    // Discard pending (the trailing silence after real end).
                    in_speech   = false;
                    silence_cnt = 0;
                    pending.clear();
                }
            }
            // Before first speech: skip silently.
        }
    }

    // If audio ends while still inside a speech region, flush any buffered
    // trailing silence (it's within the silence_ms limit).
    if (in_speech && !pending.empty()) {
        for (int si : pending) {
            append_frame(si);
        }
    }

    return out;
}
