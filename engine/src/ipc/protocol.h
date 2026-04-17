#pragma once

#include <cstdint>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <string>
#include <vector>

inline constexpr uint32_t MAX_FRAME_SIZE = 16u * 1024u * 1024u;

struct RecvBuffer {
    char        chunk[4096];
    std::string accumulated;
};

struct ConnectionClosed : public std::runtime_error {
    using std::runtime_error::runtime_error;
};

enum class ErrorCode {
    malformed_json,
    phase_violation,
    corrupt_audio,
    inference_failed,
    model_load_failed,
    session_limit,
    timeout
};

const char* error_code_string(ErrorCode code);

void                     send_json(int fd, const nlohmann::json& msg);
nlohmann::json           recv_json(int fd, RecvBuffer& buf, int timeout_ms = 15000);
void                     read_exact(int fd, uint8_t* buf, size_t n, int timeout_ms);
std::vector<uint8_t>     recv_binary_frame(int fd, RecvBuffer& buf, int timeout_ms = 15000);
void                     send_error(int fd, ErrorCode code, const std::string& message);
void                     send_warning(int fd, const char* code, const std::string& message);
void                     send_partial_result(int fd, int chunk_id, const std::string& text, bool is_final);
void                     send_queue_status(int fd, int pending, int in_flight, int eta_ms);
void                     send_polish_started(int fd);
void                     send_polished_result(int fd, const std::string& text);
