const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, file);
const root = path.resolve(__dirname, '../entry/src/main/ets');
function stub(file, exports) {
  const resolved = path.join(root, file);
  const module = new Module(resolved);
  module.exports = exports;
  require.cache[resolved] = module;
}
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgCencTask.ets', { qgDecryptInWorker() {} });
stub('data/QgHttp.ets', { QgHttp: { proxy: { enabled: false }, proxyResolver: null, resolveProxy: () => ({ enabled: false }) } });
let upstreamResponse = { status: 200, headers: {}, text: 'segment' };
let requested;
const network = {
  RequestMethod: { GET: 'GET', HEAD: 'HEAD' }, HttpDataType: { ARRAY_BUFFER: 1 }, HttpProtocol: { HTTP1_1: 1 },
  createHttp() {
    const handlers = {};
    return {
      once(name, callback) { handlers[name] = callback; },
      on(name, callback) { handlers[name] = callback; },
      destroy() {},
      requestInStream(address, options) {
        requested = { address, options };
        handlers.headersReceive(upstreamResponse.headers);
        if (options.method !== 'HEAD') {
          const data = Buffer.from(upstreamResponse.text);
          handlers.dataReceive(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
        }
        handlers.dataEnd();
        return Promise.resolve(upstreamResponse.status);
      }
    };
  }
};
const originalLoad = Module._load;
Module._load = function (request, ...args) {
  if (request === '@kit.NetworkKit') return { http: network, socket: {} };
  if (request === '@kit.ArkTS') return { taskpool: {}, url: { URL } };
  return originalLoad.call(this, request, ...args);
};
const { QgGateway: Gateway } = require(path.join(root, 'data/QgGateway.ets'));
Gateway.port = 51999;
Gateway.token = 'gateway-secret';

async function request(address, method = 'GET', extra = '') {
  const chunks = [];
  const connection = {
    conn: { send: async ({ data }) => chunks.push(Buffer.from(data)), close: async () => {} },
    clientId: 1, buf: new Uint8Array(0), handled: false, closed: false, sendChain: Promise.resolve(),
    queuedBytes: 0, upstream: null, headersSent: false, buffering: false, bodyParts: [], upstreamHeader: {},
    upstreamUrl: '', upstreamReferer: '', upstreamUa: '', sessionId: '', bufferedBytes: 0,
    upstreamEnded: false, statusReceived: false
  };
  const url = new URL(address);
  Gateway.handleRequest(connection, `${method} ${url.pathname}${url.search} HTTP/1.1\r\n${extra}\r\n`);
  await new Promise(resolve => setImmediate(resolve));
  await connection.sendChain;
  const raw = Buffer.concat(chunks);
  const separator = raw.indexOf('\r\n\r\n');
  return { headers: raw.subarray(0, separator).toString(), body: raw.subarray(separator + 4), raw };
}

(async () => {
  const key = Uint8Array.from({ length: 16 }, (_, index) => index);
  const headers = { Referer: 'https://site.test/', 'User-Agent': 'TestPlayer', Cookie: 'session=secret', Origin: 'https://site.test', 'Sec-Fetch-Site': 'cross-site' };
  const playlist = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x00000000000000000000000000000001\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6,\n../segments/one.ts?auth=x\n#EXT-X-ENDLIST';
  const base = 'https://cdn.test/list/index.m3u8?original=1';
  const local = await Gateway.playlistMediaUrl(playlist, base, headers, key);
  assert.match(local, /\/playlist\//);
  assert.ok(!local.includes('session=secret'));
  const served = await request(local);
  assert.match(served.headers, /^HTTP\/1.1 200/);
  assert.match(served.headers, /Content-Type: application\/vnd.apple.mpegurl/);
  const rewritten = served.body.toString();
  assert.ok(rewritten.includes('IV=0x00000000000000000000000000000001'));
  const keyAddress = rewritten.match(/#EXT-X-KEY:[^\n]*URI="([^"]+)"/)[1];
  const servedKey = await request(keyAddress);
  assert.deepEqual(servedKey.body, Buffer.from(key));
  const mapAddress = rewritten.match(/#EXT-X-MAP:URI="([^"]+)"/)[1];
  assert.equal(new URL(mapAddress).searchParams.get('u'), 'https://cdn.test/list/init.mp4');
  const segment = rewritten.split('\n').find(line => line.startsWith('http') && !line.includes('URI='));
  assert.equal(new URL(segment).searchParams.get('u'), 'https://cdn.test/segments/one.ts?auth=x');
  await request(segment);
  assert.equal(requested.options.header.Cookie, 'session=secret');
  assert.equal(requested.options.header.Origin, 'https://site.test');
  assert.equal(requested.options.header['Sec-Fetch-Site'], undefined);
  console.log('PASS inline playlist, AES key bytes, relative maps/segments, private credentials and omitted fetch metadata');

  const head = await request(local, 'HEAD');
  assert.match(head.headers, new RegExp(`Content-Length: ${served.body.length}`));
  assert.equal(head.body.length, 0);
  assert.match((await request(local.replace('/gateway-secret/', '/wrong/'))).headers, /^HTTP\/1.1 404/);
  assert.match((await request(local, 'POST')).headers, /^HTTP\/1.1 405/);
  await assert.rejects(Gateway.playlistMediaUrl('#EXTM3U', 'file:///etc/hosts', {}), /无效/);
  await assert.rejects(Gateway.playlistMediaUrl('#EXTM3U', base, {}, Uint8Array.of(1)), /无效/);
  const malicious = await Gateway.playlistMediaUrl('#EXTM3U\nfile:///etc/hosts', base, {});
  assert.match((await request(malicious)).headers, /^HTTP\/1.1 502/);
  console.log('PASS HEAD lengths, method/token checks and unsupported URL/key rejection');

  const credentialUrl = Gateway.mediaUrl(base, headers);
  assert.ok(!credentialUrl.includes('session%3Dsecret'));
  upstreamResponse = { status: 200, headers: { 'content-type': 'application/vnd.apple.mpegurl' }, text: '#EXTM3U\n#EXT-X-MAP:URI="../init.mp4"\n#EXTINF:6,\nchunk.ts\n#EXT-X-ENDLIST' };
  const remote = await request(credentialUrl);
  assert.match(remote.headers, /^HTTP\/1.1 200/);
  assert.ok(remote.body.toString().includes('chunk.ts'));
  assert.ok(!remote.body.toString().includes('\nchunk.ts'));
  assert.ok(remote.body.toString().includes('init.mp4'));
  assert.equal(requested.options.header.Cookie, 'session=secret');
  console.log('PASS early streamed playlist bytes survive status timing and child URI rewriting');

  upstreamResponse = { status: 403, headers: { 'content-type': 'text/plain' }, text: 'denied' };
  assert.match((await request(credentialUrl)).headers, /^HTTP\/1.1 403/);
  const unsafeHeaders = Gateway.cleanMediaHeaders({ Host: 'evil', 'Content-Length': '99', 'X-Test': 'a\r\nb', Authorization: 'Bearer token' });
  assert.deepEqual(unsafeHeaders, { Authorization: 'Bearer token' });
  assert.equal(Gateway.resolveUrl('https://host.test/path/file.m3u8?old=1', '?new=1'), 'https://host.test/path/file.m3u8?new=1');
  assert.equal(Gateway.resolveUrl('https://host.test/path/file.m3u8', '//cdn.test/stream'), 'https://cdn.test/stream');
  console.log('PASS upstream status, header injection protection and query/scheme-relative URLs');

  const encrypted = Gateway.decryptedMediaUrl('https://cdn.test/encrypted.mp4', headers, '1234567890abcdef1234567890abcdef');
  assert.ok(!encrypted.includes('session%3Dsecret'));
  const fetchDecrypted = Gateway.fetchDecrypted;
  let decryptHeaders;
  Gateway.fetchDecrypted = async (address, referer, agent, contentKey, extraHeaders) => {
    assert.equal(address, 'https://cdn.test/encrypted.mp4');
    assert.equal(contentKey, '1234567890abcdef1234567890abcdef');
    decryptHeaders = extraHeaders;
    return Uint8Array.from([1, 2, 3, 4]);
  };
  const decrypted = await request(encrypted, 'GET', 'Range: bytes=1-2\r\n');
  assert.match(decrypted.headers, /^HTTP\/1.1 206/);
  assert.deepEqual(decrypted.body, Buffer.from([2, 3]));
  assert.equal(decryptHeaders.Cookie, 'session=secret');
  await Gateway.prewarmDecrypted('https://cdn.test/encrypted.mp4', headers, '1234567890abcdef1234567890abcdef');
  assert.equal(decryptHeaders.Cookie, 'session=secret');
  Gateway.fetchDecrypted = fetchDecrypted;
  console.log('PASS existing CENC range and prewarming preserve module credentials');

  for (let index = 0; index < 20; index++) await Gateway.playlistMediaUrl(`#EXTM3U\n#${index}`, base, {});
  assert.ok(Gateway.mediaSessions.size <= 16);
  assert.match((await request(local)).headers, /^HTTP\/1.1 404/);
  console.log('PASS bounded playlist/session retention');
})().catch(error => { console.error(error); process.exitCode = 1; });
