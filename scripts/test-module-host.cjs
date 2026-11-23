const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require('./load-typescript.cjs');
const root = path.resolve(__dirname, '../entry/src/main/ets');
require.extensions['.ets'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, file);
function stub(relative, exports) {
  const file = path.join(root, relative);
  const module = new Module(file);
  module.exports = exports;
  require.cache[file] = module;
}
const htmlFile = path.join(root, 'data/QgModuleHtml.js');
const htmlModule = new Module(htmlFile);
htmlModule._compile(ts.transpileModule(fs.readFileSync(htmlFile, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, allowJs: true }
}).outputText, htmlFile);
require.cache[htmlFile] = htmlModule;
let requests = [];
let addresses = [{ address: '93.184.215.14' }];
let responses = [];
stub('data/QgHttp.ets', { QgHttp: {
  proxy: { enabled: false },
  resolveProxy: () => ({ enabled: false }),
  request: async (...args) => {
    requests.push(args);
    const response = responses.shift();
    if (!response) throw new Error('Unconfigured request');
    return response;
  }
}});
stub('data/QgModuleStore.ets', { QgModuleStore: {
  loadState: (id, name) => id + ':' + name,
  saveState: () => {}
}});
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
const load = Module._load;
Module._load = function(request, parent, main) {
  if (request === '@kit.CryptoArchitectureKit') return { cryptoFramework: {} };
  if (request === '@kit.NetworkKit') return { connection: { getAddressesByName: async () => addresses } };
  if (request === '@ohos.url') return { default: { URL: { parseURL: (url, base) => new URL(url, base) } } };
  return load.call(this, request, parent, main);
};
const { QgModuleHost: Host } = require(path.join(root, 'data/QgModuleHost.ets'));
function response(status, body, headers = {}) {
  return { status, data: Buffer.from(body), text: () => body, headers };
}
function makeHost(version = '1.0.0') {
  return new Host({ entryHash: version, manifest: {
    id: 'example', name: 'Example', version, hosts: ['example.com', '*.cdn.example.com']
  } });
}
function call(host, method, args) {
  return new Promise(resolve => host.handle(method, JSON.stringify(args), text => resolve(JSON.parse(text))));
}
async function main() {
  let host = makeHost();
  assert.equal((await call(host, 'loadState', ['device'])).value, 'example:device');
  assert.equal((await call(host, 'preserveIntegers', ['{"a":9999999999999999999,"s":"9999999999999999999","d":1.3}'])).value,
    '{"a":"9999999999999999999","s":"9999999999999999999","d":1.3}');
  const bytes = value => [...Buffer.from(value)];
  const derived = (await call(host, 'hkdfSha256', [bytes('secret'), bytes('salt'), bytes('info'), 77])).value;
  assert.deepEqual(Buffer.from(derived), Buffer.from(crypto.hkdfSync('sha256', Buffer.from('secret'), Buffer.from('salt'), Buffer.from('info'), 77)));
  assert.equal((await call(host, 'base64Decode', ['$bad'])).error, 'Base64 内容无效');
  assert.ok((await call(host, 'utf8Decode', [[256]])).error);
  console.log('PASS module state scope, integer-preserving JSON, HKDF and input byte validation');
  host = makeHost();
  const sha512 = (await call(host, 'sha512', [bytes('abc')])).value;
  assert.deepEqual(Buffer.from(sha512), crypto.createHash('sha512').update('abc').digest(), 'sha512 vector mismatch');
  const packed = (await call(host, 'gzip', [bytes('hello')])).value;
  const plain = (await call(host, 'gunzip', [packed])).value;
  assert.deepEqual(plain, bytes('hello'), 'gzip/gunzip round trip failed');
  assert.equal((await call(host, 'gunzip', [[1, 2, 3]])).error, 'gzip 内容无效');
  const zlib = require('node:zlib');
  const bomb = [...zlib.gzipSync(Buffer.alloc(3 * 1024 * 1024))];
  assert.equal((await call(host, 'gunzip', [bomb])).error, '解压后内容过大');
  console.log('PASS sha512, gzip/gunzip round trip and decompression bomb guard');
  host = makeHost();
  await call(host, 'cacheSet', ['a', 'first', 0]);
  assert.equal((await call(makeHost(), 'cacheGet', ['a'])).value, 'first');
  assert.equal((await call(makeHost('1.0.1'), 'cacheGet', ['a'])).value, null,
    'new script version must discard old version response caches');
  await call(host, 'cacheSet', ['a', null, 0]);
  assert.equal((await call(host, 'cacheGet', ['a'])).value, null);
  assert.ok((await call(host, 'unknown', [])).error);
  console.log('PASS shared scoped cache and unsupported-host rejection');
  requests = [];
  responses = [response(200, '{"items":[]}')];
  assert.equal((await call(host, 'fetch', [{ url: 'https://example.com/api' }])).value.status, 200);
  assert.equal(requests[0][6], 0);
  assert.ok(requests[0][5] <= 2 * 1024 * 1024);
  requests = [];
  assert.ok((await call(host, 'fetch', [{ url: 'https://evil.example/api' }])).error);
  assert.equal(requests.length, 0);
  assert.ok((await call(host, 'fetch', [{ url: 'https://localhost/' }])).error);
  assert.ok((await call(host, 'fetch', [{ url: 'http://127.1/' }])).error);
  assert.ok((await call(host, 'fetch', [{ url: 'file:///data/x' }])).error);
  addresses = [{ address: '192.168.1.1' }];
  assert.ok((await call(host, 'fetch', [{ url: 'https://example.com/api' }])).error);
  await assert.rejects(host.validateMediaUrl('https://media.example.com/movie.mp4'), /本地网络/,
    'returned media URLs must use the same private-network DNS guard');
  assert.throws(() => host.validateCoverUrl('http://127.0.0.1/cover.jpg'), /地址无效/);
  assert.equal(requests.length, 0);
  addresses = [{ address: '93.184.215.14' }];
  console.log('PASS HTTP declared hosts, no automatic redirects, bounded response and private-address protections');
  requests = [];
  responses = [response(302, '', { location: 'http://127.0.0.1/private' })];
  assert.ok((await call(host, 'fetch', [{ url: 'https://example.com/redirect' }])).error);
  assert.equal(requests.length, 1);
  requests = [];
  responses = [response(302, '', { location: 'https://media.cdn.example.com/second' }), response(200, 'OK')];
  assert.equal((await call(host, 'fetch', [{ url: 'https://example.com/redirect', headers: { Cookie: 'session=x' } }])).value.body, 'OK');
  assert.equal(requests.length, 2);
  assert.equal(requests[1][2].Cookie, undefined);
  responses = [response(403, '<html>denied</html>')];
  const error = await call(host, 'fetch', [{ url: 'https://example.com/api' }]);
  assert.equal(error.status, 403);
  assert.equal(error.blocked, true);
  responses = [response(403, '{"message":"need token"}')];
  assert.equal((await call(host, 'fetch', [{ url: 'https://example.com/api', acceptStatus: [403] }])).value.status, 403);
  console.log('PASS redirect revalidation, credential stripping, blocked errors and JSON acceptStatus');
  requests = [];
  responses = [{ status: 200, data: Buffer.from([0xff, 0x00, 0x80]), text: () => '', headers: {} }];
  const binary = await call(host, 'fetch',
    [{ url: 'https://example.com/raw', method: 'POST', body: [255, 0, 128], binary: true }]);
  assert.deepEqual(binary.value.bytes, [255, 0, 128], 'binary fetch must return raw response bytes');
  assert.equal(binary.value.body, '', 'binary fetch must not decode a text body');
  assert.deepEqual([...requests[0][3]], [255, 0, 128], 'binary fetch must send the raw request body');
  requests = [];
  responses = [response(200, '{"items":[]}')];
  assert.equal((await call(host, 'fetch', [{ url: 'https://example.com/api', body: 'text-body' }])).value.body,
    '{"items":[]}', 'string fetch bodies keep the text path');
  assert.equal(Buffer.from(requests[0][3]).toString(), 'text-body');
  console.log('PASS fetch accepts and returns binary bodies with the binary flag');
  const tree = (await call(host, 'parseHtml', ['<div title="A &amp; B"><p>A<p>B<script>if(a<b)c()</script>'])).value;
  const serialized = JSON.stringify(tree);
  assert.ok(serialized.includes('A & B'));
  assert.ok(serialized.includes('if(a<b)c()'));
  assert.equal((serialized.match(/"tag":"p"/g) || []).length, 2);
  assert.ok((await call(host, 'parseHtml', ['<div>'.repeat(200)])).error);
  assert.ok((await call(host, 'parseHtml', ['<i></i>'.repeat(31000)])).error);
  console.log('PASS standards-based HTML recovery, entities, raw script text and parser bounds');
  console.log('Host protocol tests passed with native HTTP/crypto interfaces substituted.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
