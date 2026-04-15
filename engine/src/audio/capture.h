#pragma once

#include <functional>
#include <cstdint>

class AudioCapture {
public:
    using CaptureCallback = std::function<void(const uint8_t* data, size_t len)>;

    AudioCapture();
    ~AudioCapture();

    AudioCapture(const AudioCapture&)            = delete;
    AudioCapture& operator=(const AudioCapture&) = delete;

    void start(CaptureCallback callback);
    void stop();
    bool is_capturing() const;

private:
    struct Impl;
    Impl* impl_{nullptr};
};
