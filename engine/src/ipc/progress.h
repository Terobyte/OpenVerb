#pragma once

#include <mutex>
#include <vector>

class ProgressQueue {
public:
    void push(float percent);
    std::vector<float> drain();

private:
    std::mutex         mutex_;
    std::vector<float> items_;
};
