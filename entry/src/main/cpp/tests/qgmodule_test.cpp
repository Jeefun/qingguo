#include "qgmodule_engine.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
void Check(bool value, const char *message)
{
    if (!value) throw std::runtime_error(message);
}

qgmodule::Result Run(const std::string &code, const std::string &method = "test", const std::string &args = "[]")
{
    return qgmodule::Run(code, "fixture", method, args,
        [](const std::string &method, const std::string &args, qgmodule::Clock::time_point) {
            if (method == "utf8Encode" && args == R"(["OK"])") return std::string(R"({"value":[79,75]})");
            if (method == "gzip") return std::string(R"({"value":[1,2,3]})");
            if (method == "gunzip") return std::string(R"({"value":[4,5,6]})");
            if (method == "fetch") {
                if (args.find("\"binary\":true") != std::string::npos) {
                    return std::string(R"({"value":{"status":200,"headers":{},"body":"","bytes":[255,0,128]}})");
                }
                return std::string(R"({"error":"Blocked","status":403,"blocked":true})");
            }
            return std::string(R"({"value":null})");
        });
}
}

int main()
{
    try {
        auto result = Run("module.exports = { test() { return 1; } };");
        Check(result.error.empty() && result.value == "1", "first module code did not run");
        result = Run("module.exports = { test() { return 2; } };");
        Check(result.error.empty() && result.value == "2", "replacement module code did not run");
        result = Run("module.exports = { test() { return typeof require + ',' + typeof process + ',' + typeof fetch + ',' + typeof os + ',' + typeof std + ',' + typeof WebView; } };");
        Check(result.error.empty() && result.value == R"("undefined,undefined,undefined,undefined,undefined,undefined")",
              "unexpected host/native API is exposed");
        result = Run("module.exports = { test() { return [Object.getPrototypeOf(host) === null, Object.isFrozen(host)]; } };");
        Check(result.error.empty() && result.value == "[true,true]", "host capabilities are not frozen");
        result = Run("module.exports = { test() { return host.utf8Encode('OK'); } };");
        Check(result.error.empty() && result.value == "[79,75]", "byte result was not marshalled");
        result = Run("module.exports = { test() { return host.hexDecode('00FF01'); } };");
        Check(result.error.empty() && result.value == "[0,255,1]", "top-level byte helper failed");
        result = Run("module.exports = { test() { try { host.fetch({url:'https://example.org'}); } catch(error) { return [error.message,error.status,error.blocked]; } } };");
        Check(result.error.empty() && result.value == R"(["Blocked",403,true])", "host error fields were not preserved");
        result = Run("module.exports = { test() { const response = host.fetch({url:'https://example.org', method:'POST', body:new Uint8Array([255,0,128]), binary:true}); return [response.status, Object.prototype.toString.call(response.body), Array.from(response.body), response.bytes === undefined]; } };");
        Check(result.error.empty() && result.value == R"([200,"[object Uint8Array]",[255,0,128],true])", "binary fetch body was not marshalled");
        result = Run("module.exports = { test() { return [Object.prototype.toString.call(host.gzip('x')), Array.from(host.gunzip(host.gzip('x')))]; } };");
        Check(result.error.empty() && result.value == R"(["[object Uint8Array]",[4,5,6]])", "gzip and gunzip results were not marshalled");
        result = Run("module.exports = { test() { return Promise.resolve(1); } };");
        Check(!result.error.empty(), "asynchronous module result accepted");
        result = Run("module.exports = {test(){return 1;}, detail(){return 2;}}", "");
        Check(result.error.empty() && result.value == R"(["test","detail"])", "module validation failed");
        result = Run("host.fetch({url:'https://example.org'}); module.exports = {}", "");
        Check(!result.error.empty(), "validation attempted host I/O");
        result = qgmodule::Run("module.exports={test(){while(true){}}}", "fixture", "test", "[]",
            [](const std::string &, const std::string &, qgmodule::Clock::time_point) { return std::string(); },
            std::chrono::milliseconds(100));
        Check(!result.error.empty(), "infinite loop was not interrupted");
        result = Run("module.exports={test(){return new Uint8Array(100 * 1024 * 1024);}}");
        Check(!result.error.empty(), "memory limit was not enforced");
        result = Run("module.exports = {test(){let result = function repeat(){return repeat();};return result();}}");
        Check(!result.error.empty(), "stack limit was not enforced");
        result = Run("module.exports = {test(){for(let i=0;i<300;i++)host.log('tick ' + i);return true;}}");
        Check(result.error.empty() && result.value == "true", "repeated host calls were rejected");
        std::cout << "PASS: hot replacement, isolation, byte transport, host errors, validation, timeout, heap and stack limits\n";
        return EXIT_SUCCESS;
    } catch (const std::exception &failure) {
        std::cerr << "FAIL: " << failure.what() << '\n';
        return EXIT_FAILURE;
    }
}
