// ---------------------------------------------------------------------------
// resampler.cpp — sample-rate conversion and channel downmix
//
// Public API (declared in audio/resampler.h):
//   to_mono()   — average all channels into one; returns new AudioData copy
//   resample()  — convert sample rate; returns new AudioData copy
//
// Downsampling pipeline (e.g. 44 100 → 16 000 Hz):
//   1. Windowed-sinc (FIR) low-pass filter at target Nyquist (target_rate/2)
//      — removes energy above 8 kHz before decimation to prevent aliasing
//        artefacts that degrade Gemma word-error rate.
//      Kernel: 64-tap Blackman-windowed sinc.
//   2. Cubic (Catmull-Rom) interpolation to land on exact output positions.
//
// Upsampling pipeline (e.g. 8 000 → 16 000 Hz):
//   Cubic interpolation only — no pre-filter needed; aliasing cannot occur
//   when the output rate is higher than the input rate.
//
// No third-party resampling library is required.
// ---------------------------------------------------------------------------

#include "audio/resampler.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

// ===========================================================================
// Internal helpers
// ===========================================================================

namespace {

constexpr double kPi = 3.14159265358979323846;

// ---------------------------------------------------------------------------
// blackman_sinc_kernel — build a Blackman-windowed sinc FIR low-pass filter.
//
//   num_taps   — filter length (should be even for symmetric, causal kernel;
//                64 is the default used by resample()).
//   cutoff_hz  — −3 dB corner in Hz.
//   sample_rate — the *input* sample rate the filter will operate at.
//
// Returns a vector of `num_taps` coefficients normalised to unit DC gain.
// ---------------------------------------------------------------------------

std::vector<double> blackman_sinc_kernel(int num_taps,
                                          double cutoff_hz,
                                          int sample_rate)
{
    if (num_taps < 2) return {1.0};

    const double fc = cutoff_hz / static_cast<double>(sample_rate);

    std::vector<double> h(static_cast<std::size_t>(num_taps));

    // Centre index (fractional so the kernel is symmetric even for even N).
    const double M = static_cast<double>(num_taps - 1);

    for (int i = 0; i < num_taps; ++i) {
        const double n = static_cast<double>(i);

        // Sinc kernel: sin(2π·fc·(n − M/2)) / (π·(n − M/2))
        // Special case at the centre sample avoids 0/0.
        double sinc_val;
        const double x = n - M / 2.0;
        if (x == 0.0) {
            sinc_val = 2.0 * fc;
        } else {
            sinc_val = std::sin(2.0 * kPi * fc * x) / (kPi * x);
        }

        // Blackman window: 0.42 − 0.50·cos(2πn/M) + 0.08·cos(4πn/M)
        const double window = 0.42
                            - 0.50 * std::cos(2.0 * kPi * n / M)
                            + 0.08 * std::cos(4.0 * kPi * n / M);

        h[static_cast<std::size_t>(i)] = sinc_val * window;
    }

    // Normalise to unit DC gain (sum of coefficients == 1.0).
    double sum = 0.0;
    for (double c : h) sum += c;
    if (sum != 0.0) {
        for (double& c : h) c /= sum;
    }

    return h;
}

// ---------------------------------------------------------------------------
// apply_fir — filter `in` with the FIR kernel `h`; returns filtered samples.
//
// Boundary handling: zero-pads the signal outside [0, in.size()) so the
// output length matches the input length exactly.
// ---------------------------------------------------------------------------

std::vector<int16_t> apply_fir(const std::vector<int16_t>& in,
                                const std::vector<double>&  h)
{
    const int n_in   = static_cast<int>(in.size());
    const int n_taps = static_cast<int>(h.size());
    const int half   = n_taps / 2;  // group delay (symmetric kernel)

    std::vector<int16_t> out(static_cast<std::size_t>(n_in));

    for (int i = 0; i < n_in; ++i) {
        double acc = 0.0;
        for (int k = 0; k < n_taps; ++k) {
            const int idx = i + k - half;
            // Zero-pad outside signal boundaries.
            const double s = (idx >= 0 && idx < n_in)
                           ? static_cast<double>(in[static_cast<std::size_t>(idx)])
                           : 0.0;
            acc += h[static_cast<std::size_t>(k)] * s;
        }
        // Clamp to int16_t range.
        const double clamped = std::max(-32768.0, std::min(32767.0, acc));
        out[static_cast<std::size_t>(i)] = static_cast<int16_t>(clamped);
    }

    return out;
}

// ---------------------------------------------------------------------------
// cubic_interp — Catmull-Rom cubic interpolation.
//
//   p0, p1, p2, p3 — four consecutive sample values (p1 is the "left" sample
//                    of the interpolation interval, t ∈ [0,1) is the offset).
//   t              — fractional position within [p1, p2].
//
// Returns the interpolated value.
// ---------------------------------------------------------------------------

inline double cubic_interp(double p0, double p1, double p2, double p3,
                            double t) noexcept
{
    // Catmull-Rom coefficients.
    const double a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
    const double b =        p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
    const double c = -0.5 * p0             + 0.5 * p2;
    const double d =                  p1;
    return ((a * t + b) * t + c) * t + d;
}

// ---------------------------------------------------------------------------
// resample_channel — resample a single-channel (mono) sample vector from
// `src_rate` to `dst_rate`, returning a new vector.
//
// When downsampling, the caller must pass a pre-filtered (low-pass) signal.
// ---------------------------------------------------------------------------

std::vector<int16_t> resample_channel(const std::vector<int16_t>& src,
                                       int src_rate,
                                       int dst_rate)
{
    if (src.empty()) return {};

    const std::size_t n_in  = src.size();
    // Compute output length: ceil(n_in * dst_rate / src_rate).
    const std::size_t n_out = static_cast<std::size_t>(
        std::ceil(static_cast<double>(n_in) * static_cast<double>(dst_rate)
        / static_cast<double>(src_rate)));

    if (n_out == 0) return {};

    std::vector<int16_t> out(n_out);

    const double ratio = static_cast<double>(src_rate)
                       / static_cast<double>(dst_rate);

    for (std::size_t i = 0; i < n_out; ++i) {
        // Continuous position in the source signal.
        const double pos = static_cast<double>(i) * ratio;
        const auto   i1  = static_cast<int>(pos);  // left neighbour index
        const double t   = pos - static_cast<double>(i1);

        // Four neighbours for cubic interpolation; clamp to signal bounds.
        const int i0 = std::max(0, i1 - 1);
        const int i2 = std::min(static_cast<int>(n_in) - 1, i1 + 1);
        const int i3 = std::min(static_cast<int>(n_in) - 1, i1 + 2);
        const int ic = std::min(static_cast<int>(n_in) - 1, i1);

        const double p0 = static_cast<double>(src[static_cast<std::size_t>(i0)]);
        const double p1 = static_cast<double>(src[static_cast<std::size_t>(ic)]);
        const double p2 = static_cast<double>(src[static_cast<std::size_t>(i2)]);
        const double p3 = static_cast<double>(src[static_cast<std::size_t>(i3)]);

        const double v       = cubic_interp(p0, p1, p2, p3, t);
        const double clamped = std::max(-32768.0, std::min(32767.0, v));
        out[i] = static_cast<int16_t>(clamped);
    }

    return out;
}

}  // anonymous namespace

// ===========================================================================
// to_mono
// ===========================================================================

AudioData to_mono(const AudioData& input)
{
    // Already mono — return a copy, do not modify anything.
    if (input.channels == 1) {
        return input;
    }

    if (input.channels <= 0) {
        throw std::runtime_error("to_mono: invalid channel count");
    }

    const int ch        = input.channels;
    const std::size_t frames =
        (input.samples.size() + static_cast<std::size_t>(ch) - 1)
        / static_cast<std::size_t>(ch);

    std::vector<int16_t> mono(frames);

    for (std::size_t f = 0; f < frames; ++f) {
        int64_t sum = 0;
        for (int c = 0; c < ch; ++c) {
            sum += static_cast<int64_t>(
                input.samples[f * static_cast<std::size_t>(ch)
                              + static_cast<std::size_t>(c)]);
        }
        const int64_t avg = sum / ch;
        mono[f] = static_cast<int16_t>(
            std::max(static_cast<int64_t>(-32768),
                     std::min(static_cast<int64_t>(32767), avg)));
    }

    AudioData out;
    out.samples         = std::move(mono);
    out.sample_rate     = input.sample_rate;
    out.channels        = 1;
    out.bits_per_sample = input.bits_per_sample;
    return out;
}

// ===========================================================================
// resample
// ===========================================================================

AudioData resample(const AudioData& input, int target_rate)
{
    if (target_rate <= 0) {
        throw std::runtime_error("resample: target_rate must be positive");
    }

    // ------------------------------------------------------------------
    // Mono-first contract: always normalise to mono before any rate work.
    // This ensures stereo (or N-channel) input is collapsed to 1 channel
    // regardless of whether a rate conversion is needed.
    // ------------------------------------------------------------------
    const AudioData mono = to_mono(input);

    // Already at target rate — return the mono copy without further work.
    if (mono.sample_rate == target_rate) {
        return mono;
    }

    if (mono.sample_rate <= 0) {
        throw std::runtime_error("resample: input sample_rate is invalid");
    }

    const int src_rate = mono.sample_rate;
    // mono.channels == 1 after to_mono(); single-channel processing below.

    // ------------------------------------------------------------------
    // Rate conversion on the mono signal.
    // ------------------------------------------------------------------

    const bool downsampling = (target_rate < src_rate);

    std::vector<int16_t> processed;

    if (downsampling) {
        constexpr int kFirTaps = 64;
        // Cut-off at target Nyquist; expressed in terms of the *source* rate.
        const double cutoff_hz = static_cast<double>(target_rate) / 2.0;
        const std::vector<double> fir_kernel =
            blackman_sinc_kernel(kFirTaps, cutoff_hz, src_rate);
        // Anti-aliasing: low-pass filter first, then interpolate.
        const std::vector<int16_t> filtered = apply_fir(mono.samples, fir_kernel);
        processed = resample_channel(filtered, src_rate, target_rate);
    } else {
        // Upsampling: cubic interpolation only (no aliasing risk).
        processed = resample_channel(mono.samples, src_rate, target_rate);
    }

    AudioData out;
    out.samples         = std::move(processed);
    out.sample_rate     = target_rate;
    out.channels        = 1;
    out.bits_per_sample = mono.bits_per_sample;
    return out;
}
