#pragma once

#include <chrono>
#include <cstddef>
#include <functional>
#include <string>

namespace qgmodule {

using Clock = std::chrono::steady_clock;
using Host = std::function<std::string(const std::string &, const std::string &, Clock::time_point)>;

constexpr size_t MaxCode = 4 * 1024 * 1024;
constexpr size_t MaxPayload = 12 * 1024 * 1024;

struct Result {
    std::string value;
    std::string error;
};

Result Run(const std::string &code, const std::string &source, const std::string &method,
           const std::string &args, const Host &host,
           std::chrono::milliseconds timeLimit = std::chrono::seconds(60));

} // namespace qgmodule
