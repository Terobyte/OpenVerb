#include <gtest/gtest.h>

#include "audio/capture.h"

TEST(AudioCaptureTest, ConstructAndDestroy) {
    AudioCapture capture;
    EXPECT_FALSE(capture.is_capturing());
}
