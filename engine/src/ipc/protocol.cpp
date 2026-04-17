#include "ipc/protocol.h"
#include "config/log.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <poll.h>
#include <string>
#include <unistd.h>
#include <vector>

const char* error_code_string(ErrorCode code) {
    switch (code) {
        case ErrorCode::malformed_json:    return "malformed_json";
        case ErrorCode::phase_violation:   return "phase_violation";
        case ErrorCode::corrupt_audio:     return "corrupt_audio";
        case ErrorCode::inference_failed:  return "inference_failed";
        case ErrorCode::model_load_failed: return "model_load_failed";
        case ErrorCode::session_limit:     return "session_limit";
        case ErrorCode::timeout:           return "timeout";
    }
    return "unknown";
}

void send_json(int fd, const nlohmann::json& msg) {
    std::string data = msg.dump() + "\n";
    size_t total = data.size();
    size_t written = 0;
    while (written < total) {
        ssize_t n = ::write(fd, data.data() + written, total - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE || errno == ECONNRESET)
                throw ConnectionClosed("send_json: connection closed");
            throw std::runtime_error("send_json: write failed: " + std::string(std::strerror(errno)));
        }
        written += static_cast<size_t>(n);
    }
}

nlohmann::json recv_json(int fd, RecvBuffer& buf, int timeout_ms) {
    constexpr size_t MAX_JSON_SIZE = 65536;

    // #28: track deadline so each poll() iteration uses the remaining time
    // rather than the original timeout_ms (which allowed slow-drip clients
    // to hold the connection indefinitely).
    using clock = std::chrono::steady_clock;
    const auto deadline = clock::now() + std::chrono::milliseconds(timeout_ms);

    while (true) {
        auto nl = buf.accumulated.find('\n');
        if (nl != std::string::npos) {
            std::string msg = buf.accumulated.substr(0, nl);
            buf.accumulated.erase(0, nl + 1);
            if (msg.empty()) continue;
            try {
                return nlohmann::json::parse(msg);
            } catch (const nlohmann::json::parse_error&) {
                // #65: skip malformed lines instead of destroying the session.
                // One bad byte from the model or network should not kill a
                // live connection — warn and try the next newline-delimited line.
                LOG_WARN("recv_json: skipping malformed JSON line");
                continue;
            }
        }

        // #28: compute remaining ms against the deadline.
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                             deadline - clock::now()).count();
        if (remaining <= 0) {
            throw std::runtime_error("timeout");
        }

        struct pollfd pfd{};
        pfd.fd     = fd;
        pfd.events = POLLIN;

        int pret = ::poll(&pfd, 1, static_cast<int>(remaining));
        if (pret < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error("recv_json: poll error: " + std::string(std::strerror(errno)));
        }
        if (pret == 0) {
            throw std::runtime_error("timeout");  // deadline reached
        }

        // POLLHUP without POLLIN means the peer closed and no bytes remain;
        // POLLIN|POLLHUP means data was written before close — drain it first.
        if ((pfd.revents & POLLERR) ||
            ((pfd.revents & POLLHUP) && !(pfd.revents & POLLIN))) {
            throw ConnectionClosed("recv_json: connection closed");
        }

        size_t to_read = std::min(sizeof(buf.chunk),
            MAX_JSON_SIZE > buf.accumulated.size()
                ? MAX_JSON_SIZE - buf.accumulated.size() : 0);
        if (to_read == 0) {
            throw std::runtime_error("json message too large");
        }

        ssize_t n = ::read(fd, buf.chunk, to_read);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == ECONNRESET)
                throw ConnectionClosed("recv_json: connection reset");
            throw std::runtime_error("recv_json: read error: " + std::string(std::strerror(errno)));
        }
        if (n == 0) {
            throw ConnectionClosed("recv_json: EOF");
        }

        buf.accumulated.append(buf.chunk, static_cast<size_t>(n));
    }
}

void read_exact(int fd, uint8_t* out, size_t n, int timeout_ms) {
    using clock = std::chrono::steady_clock;
    const auto deadline = clock::now() + std::chrono::milliseconds(timeout_ms);

    size_t received = 0;
    while (received < n) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
                             deadline - clock::now()).count();
        if (remaining <= 0) {
            throw std::runtime_error("timeout");
        }

        struct pollfd pfd{};
        pfd.fd     = fd;
        pfd.events = POLLIN;

        int pret = ::poll(&pfd, 1, static_cast<int>(remaining));
        if (pret < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error("read_exact: poll error");
        }
        if (pret == 0) {
            throw std::runtime_error("timeout");
        }

        // Same drain-before-close logic as recv_json: read if POLLIN is set
        // even when POLLHUP is also reported.
        if ((pfd.revents & POLLERR) ||
            ((pfd.revents & POLLHUP) && !(pfd.revents & POLLIN))) {
            throw ConnectionClosed("read_exact: connection closed");
        }

        ssize_t r = ::read(fd, out + received, n - received);
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == ECONNRESET)
                throw ConnectionClosed("read_exact: connection reset");
            throw std::runtime_error("read_exact: read error");
        }
        if (r == 0) {
            throw ConnectionClosed("read_exact: EOF");
        }

        received += static_cast<size_t>(r);
    }
}

std::vector<uint8_t> recv_binary_frame(int fd, RecvBuffer& buf, int timeout_ms) {
    uint8_t header_buf[4]{};

    size_t already_have = std::min(buf.accumulated.size(), size_t{4});
    if (already_have > 0) {
        std::memcpy(header_buf, buf.accumulated.data(), already_have);
        buf.accumulated.erase(0, already_have);
    }

    if (already_have < 4) {
        read_exact(fd, header_buf + already_have, 4 - already_have, timeout_ms);
    }

    uint32_t frame_len = (static_cast<uint32_t>(header_buf[0]) << 24) |
                         (static_cast<uint32_t>(header_buf[1]) << 16) |
                         (static_cast<uint32_t>(header_buf[2]) << 8)  |
                          static_cast<uint32_t>(header_buf[3]);

    if (frame_len == 0) {
        return {};
    }

    if (frame_len > MAX_FRAME_SIZE)
        throw std::runtime_error("frame too large: " + std::to_string(frame_len));

    std::vector<uint8_t> payload(frame_len);

    size_t from_accum = std::min(buf.accumulated.size(), static_cast<size_t>(frame_len));
    if (from_accum > 0) {
        std::memcpy(payload.data(), buf.accumulated.data(), from_accum);
        buf.accumulated.erase(0, from_accum);
    }

    if (from_accum < frame_len) {
        read_exact(fd, payload.data() + from_accum, frame_len - from_accum, timeout_ms);
    }

    return payload;
}

void send_error(int fd, ErrorCode code, const std::string& message) {
    nlohmann::json err;
    err["type"]    = "error";
    err["code"]    = error_code_string(code);
    err["message"] = message;
    try {
        send_json(fd, err);
    } catch (...) {}
}

void send_warning(int fd, const char* code, const std::string& message) {
    nlohmann::json w;
    w["type"]    = "warning";
    w["code"]    = code;
    w["message"] = message;
    try {
        send_json(fd, w);
    } catch (...) {}
}

void send_partial_result(int fd, int chunk_id, const std::string& text, bool is_final) {
    nlohmann::json msg;
    msg["type"]     = "partial_result";
    msg["chunk_id"] = chunk_id;
    msg["text"]     = text;
    msg["is_final"] = is_final;
    send_json(fd, msg);
}

void send_queue_status(int fd, int pending, int in_flight, int eta_ms) {
    nlohmann::json msg;
    msg["type"]      = "queue_status";
    msg["pending"]   = pending;
    msg["in_flight"] = in_flight;
    msg["eta_ms"]    = eta_ms;
    send_json(fd, msg);
}

void send_polish_started(int fd) {
    nlohmann::json msg;
    msg["type"] = "polish_started";
    send_json(fd, msg);
}

void send_polished_result(int fd, const std::string& text) {
    nlohmann::json msg;
    msg["type"] = "polished_result";
    msg["text"] = text;
    send_json(fd, msg);
}
