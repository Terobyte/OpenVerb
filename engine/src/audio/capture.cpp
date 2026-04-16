#include "audio/capture.h"
#include "config/defaults.h"
#include "config/log.h"

#include <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <cstring>
#include <vector>

struct AudioCapture::Impl {
    AudioQueueRef           queue{nullptr};
    AudioQueueBufferRef     buffers[3]{};
    CaptureCallback         callback;
    std::atomic<bool>       capturing{false};

    static constexpr int kBufferBytes = 4096;

    static void audio_callback(void* user_data, AudioQueueRef,
                                AudioQueueBufferRef buffer,
                                const AudioTimeStamp*,
                                UInt32,
                                const AudioStreamPacketDescription*) {
        auto* self = static_cast<Impl*>(user_data);
        if (!self->capturing.load(std::memory_order_acquire) || !self->callback) {
            // Do not re-enqueue during dispose — AudioQueueDispose(true) is in flight
            // and re-enqueuing a buffer into a queue being torn down is undefined.
            return;
        }

        self->callback(reinterpret_cast<const uint8_t*>(buffer->mAudioData),
                       buffer->mAudioDataByteSize);

        AudioQueueEnqueueBuffer(self->queue, buffer, 0, nullptr);
    }
};

AudioCapture::AudioCapture() : impl_(new Impl()) {}

AudioCapture::~AudioCapture() {
    stop();
    delete impl_;
}

void AudioCapture::start(CaptureCallback callback) {
    if (impl_->capturing.load(std::memory_order_acquire)) return;
    impl_->callback = std::move(callback);

    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate       = SAMPLE_RATE;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket   = 2;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerFrame    = 2;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel   = 16;

    OSStatus status = AudioQueueNewInput(&fmt, &Impl::audio_callback, impl_,
                                          nullptr, nullptr, 0, &impl_->queue);
    if (status != noErr) {
        LOG_ERROR("AudioCapture: AudioQueueNewInput failed: %d", (int)status);
        return;
    }

    for (int i = 0; i < 3; ++i) {
        OSStatus alloc_s = AudioQueueAllocateBuffer(
            impl_->queue, Impl::kBufferBytes, &impl_->buffers[i]);
        if (alloc_s != noErr) {
            LOG_ERROR("AudioCapture: AudioQueueAllocateBuffer[%d] failed: %d", i, (int)alloc_s);
            AudioQueueDispose(impl_->queue, true);
            impl_->queue = nullptr;
            return;
        }
        AudioQueueEnqueueBuffer(impl_->queue, impl_->buffers[i], 0, nullptr);
    }

    OSStatus start_s = AudioQueueStart(impl_->queue, nullptr);
    if (start_s != noErr) {
        LOG_ERROR("AudioCapture: AudioQueueStart failed: %d", (int)start_s);
        AudioQueueDispose(impl_->queue, true);
        impl_->queue = nullptr;
        return;
    }
    impl_->capturing.store(true, std::memory_order_release);
}

void AudioCapture::stop() {
    if (!impl_->capturing.load(std::memory_order_acquire)) return;
    impl_->capturing.store(false, std::memory_order_release);

    if (impl_->queue) {
        AudioQueueStop(impl_->queue, true);
        AudioQueueDispose(impl_->queue, true);  // immediate: no more callbacks after this returns
        impl_->queue = nullptr;
    }
}

bool AudioCapture::is_capturing() const {
    return impl_ && impl_->capturing.load(std::memory_order_acquire);
}
