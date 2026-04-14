#pragma once

#include <atomic>

// ---------------------------------------------------------------------------
// g_interrupted — global graceful-shutdown flag.
//
// Set to true by the SIGINT / SIGTERM handler in main.cpp.
// Checked on every iteration of the inference generation loop in
// llama_context.cpp so that Ctrl-C aborts inference cleanly.
//
// Definition (in main.cpp):
//   std::atomic<bool> g_interrupted{false};
// ---------------------------------------------------------------------------
extern std::atomic<bool> g_interrupted;
