#include "qgmodule_engine.h"
#include "quickjs/quickjs.h"

#include <algorithm>
#include <memory>
#include <stdexcept>

namespace qgmodule {
namespace {

constexpr size_t MemoryLimit = 72 * 1024 * 1024;
constexpr size_t StackLimit = 384 * 1024;
constexpr size_t MaxHostTotal = 64 * 1024 * 1024;

constexpr char HostBootstrap[] = R"JS(
(function (source, callHost) {
    const stringify = JSON.stringify;
    const parse = JSON.parse;
    const arrayFrom = Array.from;
    const isView = ArrayBuffer.isView;
    const instanceOfArrayBuffer = Function.prototype[Symbol.hasInstance].bind(ArrayBuffer);
    const fromBytes = Uint8Array.from.bind(Uint8Array);
    const string = String;
    const failureType = Error;
    const apply = Reflect.apply;
    const promise = Promise;
    const instanceOfPromise = Function.prototype[Symbol.hasInstance].bind(promise);
    const encode = value => stringify(value, (_, value) => {
        if (isView(value)) {
            return arrayFrom(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
        }
        if (instanceOfArrayBuffer(value)) return arrayFrom(new Uint8Array(value));
        return typeof value === 'bigint' ? string(value) : value;
    });
    function invoke(method, args) {
        const response = parse(callHost(method, encode(args)));
        if (typeof response.error === 'string') {
            const failure = new failureType(response.error);
            for (const key of ['status', 'body', 'blocked', 'oversized', 'backoff', 'loginRequired']) {
                if (response[key] !== undefined) failure[key] = response[key];
            }
            throw failure;
        }
        return response.value;
    }
    const host = Object.create(null);
    for (const method of ['retries', 'maxPages', 'reserve', 'sleep', 'finishMedia', 'catalogContext',
        'isKnown', 'reportProgress', 'cacheGet', 'cacheSet', 'preserveIntegers', 'resolveUrl', 'parseHtml',
        'utf8Decode', 'base64Encode', 'fetchText', 'parseUrl', 'preferredSite',
        'fetchPlaylist', 'prepareWebMedia', 'loadState', 'saveState', 'log']) {
        host[method] = (...args) => invoke(method, args);
    }
    for (const method of ['utf8Encode', 'base64Decode', 'md5', 'sha256', 'sha512', 'gzip', 'gunzip',
        'randomBytes', 'aesCbcEncrypt', 'aesCbcDecrypt', 'aesGcmSeal', 'aesGcmOpen', 'ecdhP256', 'hkdfSha256']) {
        host[method] = (...args) => fromBytes(invoke(method, args));
    }
    host.fetch = (...args) => {
        const result = invoke('fetch', args);
        if (Array.isArray(result.bytes)) {
            result.body = fromBytes(result.bytes);
            delete result.bytes;
        }
        return result;
    };
    host.ecdhP256KeyPair = (...args) => {
        const pair = invoke('ecdhP256KeyPair', args);
        return { privateKey: fromBytes(pair.privateKey), publicKey: fromBytes(pair.publicKey) };
    };
    host.source = source;
    host.dramaId = id => source + ':' + string(id).trim();
    host.chapterId = (id, key) => host.dramaId(id) + ':' + string(key).trim();
    host.hexDecode = text => {
        text = string(text).trim();
        if (text.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(text)) throw new failureType('Invalid hexadecimal');
        const result = new Uint8Array(text.length / 2);
        for (let i = 0; i < result.length; i++) result[i] = parseInt(text.slice(i * 2, i * 2 + 2), 16);
        return result;
    };
    host.hexEncode = bytes => {
        const input = typeof bytes === 'string' ? host.utf8Encode(bytes) : bytes;
        let result = '';
        for (const value of input) result += value.toString(16).padStart(2, '0');
        return result;
    };
    let locked = false;
    host.exclusive = callback => {
        if (locked || typeof callback !== 'function') throw new failureType('Invalid exclusive callback');
        locked = true;
        try { return callback(); } finally { locked = false; }
    };
    const getOwn = Object.getOwnPropertyDescriptor;
    const names = Object.getOwnPropertyNames;
    const isArray = Array.isArray;
    return {
        host: Object.freeze(host),
        invoke(exports, name, encoded) {
            if (!exports || (typeof exports !== 'object' && typeof exports !== 'function')) {
                throw new failureType('Invalid module exports');
            }
            if (name === '') {
                const result = [];
                for (const key of names(exports)) {
                    if (typeof getOwn(exports, key).value === 'function') result[result.length] = key;
                }
                return encode(result);
            }
            const target = getOwn(exports, name);
            if (!target || typeof target.value !== 'function') throw new failureType('Missing module method: ' + name);
            const args = parse(encoded);
            if (!isArray(args)) throw new failureType('Expected module arguments array');
            const result = apply(target.value, exports, args);
            if (instanceOfPromise(result)) throw new failureType('Async module method is not supported');
            return encode(result === undefined ? null : result);
        }
    };
})
)JS";

struct Session {
    const Host &host;
    Clock::time_point deadline;
    bool validation;
    bool expired = false;
    size_t bytes = 0;
};

class Value {
public:
    Value(JSContext *ctx, JSValue value) : ctx_(ctx), value_(value) {}
    ~Value() { JS_FreeValue(ctx_, value_); }
    Value(const Value &) = delete;
    Value &operator=(const Value &) = delete;
    operator JSValueConst() const { return value_; }
private:
    JSContext *ctx_;
    JSValue value_;
};

class Text {
public:
    Text(JSContext *ctx, JSValueConst value) : ctx_(ctx), ptr_(JS_ToCStringLen(ctx, &length_, value)) {}
    ~Text() { if (ptr_) JS_FreeCString(ctx_, ptr_); }
    Text(const Text &) = delete;
    Text &operator=(const Text &) = delete;
    bool valid(size_t limit) const { return ptr_ && length_ <= limit; }
    std::string copy() const { return ptr_ ? std::string(ptr_, length_) : std::string(); }
private:
    JSContext *ctx_;
    size_t length_ = 0;
    const char *ptr_;
};

int Interrupt(JSRuntime *, void *opaque)
{
    auto &session = *static_cast<Session *>(opaque);
    if (Clock::now() < session.deadline) return 0;
    session.expired = true;
    return 1;
}

JSValue Rpc(JSContext *ctx, JSValueConst, int argc, JSValueConst *argv)
{
    auto &session = *static_cast<Session *>(JS_GetContextOpaque(ctx));
    if (session.validation) return JS_ThrowTypeError(ctx, "No host calls during module validation");
    if (Interrupt(JS_GetRuntime(ctx), &session)) return JS_ThrowInternalError(ctx, "Module timed out");
    if (argc != 2 || !JS_IsString(argv[0]) || !JS_IsString(argv[1])) {
        return JS_ThrowTypeError(ctx, "Invalid module host call");
    }
    try {
        Text method(ctx, argv[0]);
        Text args(ctx, argv[1]);
        if (!method.valid(80) || !args.valid(MaxPayload)) {
            return JS_ThrowRangeError(ctx, "Module host arguments too large");
        }
        std::string response = session.host(method.copy(), args.copy(), session.deadline);
        session.bytes += response.size();
        if (response.size() > MaxPayload || session.bytes > MaxHostTotal) {
            return JS_ThrowRangeError(ctx, "Module host response limit exceeded");
        }
        if (Interrupt(JS_GetRuntime(ctx), &session)) return JS_ThrowInternalError(ctx, "Module timed out");
        return JS_NewStringLen(ctx, response.data(), response.size());
    } catch (const std::exception &) {
        return JS_ThrowInternalError(ctx, "Module host unavailable");
    }
}

std::string ErrorText(JSContext *ctx, const Session &session)
{
    if (session.expired) return "Module timed out";
    Value exception(ctx, JS_GetException(ctx));
    Text message(ctx, exception);
    return message.valid(4096) ? message.copy() : "Module execution failed";
}

Result Evaluate(JSContext *ctx, Session &session, const std::string &code, const std::string &source,
                const std::string &method, const std::string &args)
{
    Value bootstrap(ctx, JS_Eval(ctx, HostBootstrap, sizeof(HostBootstrap) - 1, "host.js", JS_EVAL_TYPE_GLOBAL));
    if (JS_IsException(bootstrap)) return {{}, ErrorText(ctx, session)};
    Value id(ctx, JS_NewStringLen(ctx, source.data(), source.size()));
    Value rpc(ctx, JS_NewCFunction(ctx, Rpc, "callHost", 2));
    JSValueConst config[] = { id, rpc };
    Value setup(ctx, JS_Call(ctx, bootstrap, JS_UNDEFINED, 2, config));
    if (JS_IsException(setup)) return {{}, ErrorText(ctx, session)};
    Value host(ctx, JS_GetPropertyStr(ctx, setup, "host"));
    Value invoke(ctx, JS_GetPropertyStr(ctx, setup, "invoke"));

    std::string wrapper = "(function (module, exports, host) {\n";
    wrapper += code;
    wrapper += "\n})";
    Value load(ctx, JS_Eval(ctx, wrapper.data(), wrapper.size(), "main.js", JS_EVAL_FLAG_STRICT));
    if (JS_IsException(load)) return {{}, ErrorText(ctx, session)};
    Value module(ctx, JS_NewObject(ctx));
    Value exports(ctx, JS_NewObject(ctx));
    if (JS_SetPropertyStr(ctx, module, "exports", JS_DupValue(ctx, exports)) < 0) {
        return {{}, ErrorText(ctx, session)};
    }
    JSValueConst inputs[] = { module, exports, host };
    Value loaded(ctx, JS_Call(ctx, load, JS_UNDEFINED, 3, inputs));
    if (JS_IsException(loaded)) return {{}, ErrorText(ctx, session)};
    Value exported(ctx, JS_GetPropertyStr(ctx, module, "exports"));
    Value name(ctx, JS_NewStringLen(ctx, method.data(), method.size()));
    Value encoded(ctx, JS_NewStringLen(ctx, args.data(), args.size()));
    JSValueConst request[] = { exported, name, encoded };
    Value output(ctx, JS_Call(ctx, invoke, JS_UNDEFINED, 3, request));
    if (JS_IsException(output)) return {{}, ErrorText(ctx, session)};
    Text result(ctx, output);
    if (!JS_IsString(output) || !result.valid(MaxPayload)) return {{}, "Module result invalid or too large"};
    return {result.copy(), {}};
}

} // namespace

Result Run(const std::string &code, const std::string &source, const std::string &method,
           const std::string &args, const Host &host, std::chrono::milliseconds timeLimit)
{
    if (code.size() > MaxCode || source.empty() || source.size() > 32 ||
        method.size() > 80 || args.size() > MaxPayload ||
        source.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_-") != std::string::npos) {
        return {{}, "Invalid module input"};
    }
    try {
        Session session{host, Clock::now() + std::min(timeLimit, method.empty() ? std::chrono::milliseconds(5000)
                                                                             : std::chrono::milliseconds(60000)),
                        method.empty()};
        std::unique_ptr<JSRuntime, decltype(&JS_FreeRuntime)> runtime(JS_NewRuntime(), JS_FreeRuntime);
        if (!runtime) return {{}, "Module runtime could not start"};
        JS_SetMemoryLimit(runtime.get(), MemoryLimit);
        JS_SetMaxStackSize(runtime.get(), StackLimit);
        JS_SetCanBlock(runtime.get(), false);
        JS_SetInterruptHandler(runtime.get(), Interrupt, &session);
        std::unique_ptr<JSContext, decltype(&JS_FreeContext)> context(JS_NewContext(runtime.get()), JS_FreeContext);
        if (!context) return {{}, "Module context could not start"};
        JS_SetContextOpaque(context.get(), &session);
        Result result = Evaluate(context.get(), session, code, source, method, args);
        if (Interrupt(runtime.get(), &session)) return {{}, "Module timed out"};
        return result;
    } catch (const std::exception &) {
        return {{}, "Module runtime failed"};
    }
}

} // namespace qgmodule
