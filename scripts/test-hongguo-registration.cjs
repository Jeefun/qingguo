// Runs the actual ArkTS provider under Node; only platform HTTP/gateway are substituted.
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
require.extensions['.ets'] = (m, file) => m._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, file);
const root = path.resolve(__dirname, '../entry/src/main/ets');
function stub(file, exports) {
  const name = path.join(root, file);
  const m = new Module(name); m.exports = exports; require.cache[name] = m;
}
const http = { request: async () => { throw new Error('Unconfigured HTTP'); } };
stub('data/QgHttp.ets', { QgHttp: http });
stub('data/QgGateway.ets', { QgGateway: {} });
const { HongguoSource: Source } = require(path.join(root, 'data/source/HongguoSource.ets'));
function response(status, data) { return { status, data: Buffer.from(JSON.stringify(data)), text: () => JSON.stringify(data) }; }
function reset() {
  Source.registered = false; Source.registerPausedUntil = 0;
  Source.registerPauseErr = ''; Source.registerPromise = null;
}
const success = () => response(200, { device_id_str: '1234567890123456789', install_id_str: '2234567890123456789' });
async function temporaryFailure(label, failure) {
  reset(); let calls = 0;
  http.request = async () => { calls++; if (calls === 1) return failure(); return success(); };
  await assert.rejects(Source.ensureDevice(''));
  await Source.ensureDevice('');
  assert.equal(calls, 2); assert.equal(Source.registered, true);
  console.log('PASS', label, 'allows immediate retry');
}
(async () => {
  await temporaryFailure('network timeout', () => { throw new Error('timeout'); });
  await temporaryFailure('HTTP 503', () => response(503, {}));
  await temporaryFailure('gateway HTML', () => ({ status: 200, data: Buffer.from('<html>Bad Gateway</html>'), text: () => '<html>Bad Gateway</html>' }));
  reset(); let calls = 0;
  http.request = async () => { calls++; await new Promise(r => setTimeout(r, 20)); return success(); };
  await Promise.all(Array.from({ length: 8 }, () => Source.ensureDevice('')));
  assert.equal(calls, 1); console.log('PASS concurrent startup uses one registration');
  reset(); calls = 0;
  http.request = async () => { calls++; return response(403, {}); };
  await assert.rejects(Source.ensureDevice(''));
  await assert.rejects(Source.ensureDevice(''), /暂不可用/);
  assert.equal(calls, 1); console.log('PASS explicit denial retains cooldown');
  reset(); calls = 0;
  http.request = async () => { calls++; return response(200, { device_id: 0, install_id: 0 }); };
  await assert.rejects(Source.ensureDevice(''), /未返回设备号/);
  assert.equal(Source.registered, false); assert.ok(Source.registerPausedUntil > Date.now());
  console.log('PASS invalid device identity never becomes usable');
})().catch(e => { console.error(e.message); process.exitCode = 1; });
