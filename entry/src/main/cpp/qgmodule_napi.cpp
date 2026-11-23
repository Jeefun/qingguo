#include "qgmodule_engine.h"
#include <napi/native_api.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace {
constexpr size_t MaxActive = 4;
std::atomic<size_t> active{0};

struct Exchange {
    std::string method;
    std::string args;
    std::mutex mutex;
    std::condition_variable ready;
    std::string response;
    bool done = false;
    bool closed = false;
};

using Reply = std::shared_ptr<Exchange>;

struct Job {
    std::string code;
    std::string source;
    std::string method;
    std::string args;
    qgmodule::Result result;
    napi_threadsafe_function host = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

bool ReadString(napi_env env, napi_value value, size_t limit, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > limit) {
        return false;
    }
    out.resize(length + 1);
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, out.data(), out.size(), &written) != napi_ok) return false;
    out.resize(written);
    return true;
}

bool MakeString(napi_env env, const std::string &value, napi_value *out)
{
    return napi_create_string_utf8(env, value.data(), value.size(), out) == napi_ok;
}

void Deliver(const Reply &reply, std::string response)
{
    {
        std::lock_guard lock(reply->mutex);
        if (reply->closed || reply->done) return;
        reply->response = std::move(response);
        reply->done = true;
    }
    reply->ready.notify_one();
}

void FreeReply(napi_env, void *data, void *)
{
    delete static_cast<Reply *>(data);
}

napi_value Respond(napi_env env, napi_callback_info info)
{
    void *data = nullptr;
    size_t count = 1;
    napi_value args[1] = {};
    if (napi_get_cb_info(env, info, &count, args, nullptr, &data) != napi_ok || !data) return nullptr;
    const auto &reply = *static_cast<Reply *>(data);
    {
        std::lock_guard lock(reply->mutex);
        if (reply->closed || reply->done) return nullptr;
    }
    try {
        std::string response;
        if (count != 1 || !ReadString(env, args[0], qgmodule::MaxPayload, response)) {
            response = R"({"error":"Invalid module host response"})";
        }
        Deliver(reply, std::move(response));
    } catch (...) {
        Deliver(reply, {});
    }
    return nullptr;
}

void CallHost(napi_env env, napi_value callback, void *, void *message)
{
    std::unique_ptr<Reply> queued(static_cast<Reply *>(message));
    const auto &reply = *queued;
    if (!env || !callback) {
        Deliver(reply, R"({"error":"Module host closed"})");
        return;
    }
    {
        std::lock_guard lock(reply->mutex);
        if (reply->closed) return;
    }
    try {
        auto finalizerData = std::make_unique<Reply>(reply);
        napi_value inputs[3] = {};
        napi_value receiver = nullptr;
        if (!MakeString(env, reply->method, &inputs[0]) || !MakeString(env, reply->args, &inputs[1]) ||
            napi_create_function(env, "respond", NAPI_AUTO_LENGTH, Respond, finalizerData.get(),
                                 &inputs[2]) != napi_ok ||
            napi_add_finalizer(env, inputs[2], finalizerData.get(), FreeReply, nullptr, nullptr) != napi_ok) {
            Deliver(reply, R"({"error":"Module host dispatch failed"})");
            return;
        }
        finalizerData.release();
        if (napi_get_undefined(env, &receiver) != napi_ok ||
            napi_call_function(env, receiver, callback, 3, inputs, nullptr) != napi_ok) {
            bool pending = false;
            if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
                napi_value ignored;
                napi_get_and_clear_last_exception(env, &ignored);
            }
            Deliver(reply, R"({"error":"Module host callback failed"})");
        }
    } catch (...) {
        Deliver(reply, {});
    }
}

std::string Request(Job &job, const std::string &method, const std::string &args,
                    qgmodule::Clock::time_point deadline)
{
    auto reply = std::make_shared<Exchange>();
    reply->method = method;
    reply->args = args;
    auto queued = std::make_unique<Reply>(reply);
    auto *message = queued.release();
    if (napi_call_threadsafe_function(job.host, message, napi_tsfn_nonblocking) != napi_ok) {
        delete message;
        throw std::runtime_error("Module host is not available");
    }
    std::unique_lock lock(reply->mutex);
    const bool complete = reply->ready.wait_until(lock, deadline, [&] { return reply->done; });
    reply->closed = true;
    if (!complete || reply->response.empty()) throw std::runtime_error("Module host did not respond");
    return std::move(reply->response);
}

void Execute(napi_env, void *data)
{
    auto &job = *static_cast<Job *>(data);
    job.result = qgmodule::Run(job.code, job.source, job.method, job.args,
        [&](const std::string &method, const std::string &args, qgmodule::Clock::time_point deadline) {
            return Request(job, method, args, deadline);
        });
}

void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    --active;
    napi_release_threadsafe_function(job->host, napi_tsfn_release);
    if (!env) return;
    napi_delete_async_work(env, job->work);
    napi_value result;
    if (status == napi_ok && job->result.error.empty() && MakeString(env, job->result.value, &result)) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_value message;
        const std::string reason = job->result.error.empty() ? "Module execution cancelled" : job->result.error;
        if (MakeString(env, reason, &message) && napi_create_error(env, nullptr, message, &result) == napi_ok) {
            napi_reject_deferred(env, job->deferred, result);
        }
    }
}

napi_value Run(napi_env env, napi_callback_info info)
{
    try {
        auto job = std::make_unique<Job>();
        size_t count = 5;
        napi_value args[5] = {};
        napi_valuetype type = napi_undefined;
        if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 5 ||
            !ReadString(env, args[0], qgmodule::MaxCode, job->code) ||
            !ReadString(env, args[1], 32, job->source) ||
            !ReadString(env, args[2], 80, job->method) ||
            !ReadString(env, args[3], qgmodule::MaxPayload, job->args) ||
            napi_typeof(env, args[4], &type) != napi_ok || type != napi_function) {
            napi_throw_type_error(env, nullptr, "Invalid module invocation");
            return nullptr;
        }
        if (active.fetch_add(1) >= MaxActive) {
            --active;
            napi_throw_error(env, nullptr, "Too many module requests");
            return nullptr;
        }
        napi_value name;
        napi_value promise;
        if (MakeString(env, "QingguoModule", &name) &&
            napi_create_promise(env, &job->deferred, &promise) == napi_ok &&
            napi_create_threadsafe_function(env, args[4], nullptr, name, 1, 1, nullptr, nullptr,
                                            nullptr, CallHost, &job->host) == napi_ok &&
            napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) == napi_ok &&
            napi_queue_async_work(env, job->work) == napi_ok) {
            job.release();
            return promise;
        }
        if (job->work) napi_delete_async_work(env, job->work);
        if (job->host) napi_release_threadsafe_function(job->host, napi_tsfn_abort);
        --active;
        napi_throw_error(env, nullptr, "Module worker could not start");
    } catch (...) {
        napi_throw_error(env, nullptr, "Could not allocate module worker");
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor descriptor = {
        "run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr
    };
    napi_define_properties(env, exports, 1, &descriptor);
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "qgmodule", nullptr, {nullptr}};
} // namespace

extern "C" __attribute__((constructor)) void RegisterQingguoModule()
{
    napi_module_register(&module);
}
