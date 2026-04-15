#include "ipc/progress.h"

void ProgressQueue::push(float percent) {
    std::lock_guard<std::mutex> lock(mutex_);
    items_.push_back(percent);
}

std::vector<float> ProgressQueue::drain() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<float> result;
    result.swap(items_);
    return result;
}
