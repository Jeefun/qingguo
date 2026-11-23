const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
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
const http = { request: async () => { throw new Error('Unexpected HTTP'); } };
stub('data/QgHttp.ets', { QgHttp: http });
stub('data/QgGateway.ets', { QgGateway: {} });
const { HongguoSource: Source, HONGGUO_MODULE_VERSION } = require(path.join(root, 'data/source/HongguoSource.ets'));
const { qgSha512 } = require(path.join(root, 'data/QgCrypto.ets'));
const videoId = '1234567890123456789';
const primaryDevice = '3234567890123456789';
const helperDevice = '4234567890123456789';
const playUrlSalt = '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
const fallbackEndpoint = 'https://vas.example.invalid/video/fplay/1/synthetic/synthetic-video?aid=8662&codec_type=4&stream_type=encrypt';
const bytevc2Model = {
  video_duration: 80.5,
  fallback_api: { fallback_api: fallbackEndpoint },
  video_list: [{ main_url: 'https://media.example.invalid/vvc.mp4', video_meta: { codec_type: 'bytevc2', definition: '1080p' } }],
};
const seedText = Buffer.from('synthetic-play-url-seed-value').toString('base64');

function sealPlayUrl(address, seed) {
  const salt = Buffer.from(playUrlSalt, 'hex');
  const digest = crypto.createHash('sha512').update(Buffer.concat([crypto.createHash('sha512').update(Buffer.from(seed, 'base64')).digest(), salt])).digest();
  const pad = 16 - (Buffer.byteLength(address) % 16);
  const plain = Buffer.concat([Buffer.from(address), Buffer.alloc(pad, pad)]);
  const cipher = crypto.createCipheriv('aes-128-cbc', digest.subarray(0, 16), digest.subarray(16, 32));
  cipher.setAutoPadding(false);
  return Buffer.concat([Buffer.from([0xa8, 0x00, 0x01, 0x00]), cipher.update(plain), cipher.final()]).toString('base64');
}

function fallbackResponse(codecType) {
  return {
    video_info: {
      data: {
        video_duration: 80.5,
        key_seed: seedText,
        video_list: {
          video_1: { definition: '720p', codec_type: codecType, vwidth: 720, vheight: 1280, main_url: sealPlayUrl('https://media.example.invalid/h265-720.mp4', seedText) },
          video_2: { definition: '1080p', codec_type: codecType, vwidth: 1080, vheight: 1920, main_url: sealPlayUrl('https://media.example.invalid/h265-1080.mp4', seedText), backup_url_1: sealPlayUrl('https://media.example.invalid/h265-1080-backup.mp4', seedText) },
        },
      },
    },
  };
}

function response(data, status = 200) {
  const text = JSON.stringify(data);
  return { status, data: Buffer.from(text), text: () => text };
}

function tabResponse(model) {
  return { code: 0, data: { video_model_data: { [videoId]: { video_model: JSON.stringify(model) } } } };
}

function reset() {
  Source.registered = true;
  Source.deviceId = primaryDevice;
  Source.installId = '2234567890123456789';
  Source.registerPausedUntil = 0;
  Source.registerPauseErr = '';
  Source.registerPromise = null;
  Source.helperDeviceId = helperDevice;
  Source.helperInstallId = '6234567890123456789';
  Source.helperRegistered = true;
  Source.helperRegisterPausedUntil = 0;
  Source.helperRegisterPauseErr = '';
  Source.helperRegisterPromise = null;
}

(async () => {
  assert.equal(HONGGUO_MODULE_VERSION, '1.0.7');

  assert.equal(Buffer.from(qgSha512(Buffer.from('abc'))).toString('hex'),
    crypto.createHash('sha512').update('abc').digest('hex'));
  assert.equal(Buffer.from(qgSha512(Buffer.from(''))).toString('hex'),
    crypto.createHash('sha512').update('').digest('hex'));
  const long = Buffer.from('a'.repeat(300));
  assert.equal(Buffer.from(qgSha512(long)).toString('hex'),
    crypto.createHash('sha512').update(long).digest('hex'));
  console.log('PASS qgSha512 matches node crypto');

  reset();
  const requests = [];
  http.request = async (url, method, headers, body) => {
    requests.push(new URL(url));
    if (url.includes('/reading/bookapi/video_tab/')) {
      return response(tabResponse(bytevc2Model));
    }
    return response(fallbackResponse('h265'));
  };
  const media = await Source.fetchAppMedia(videoId, false);
  assert.equal(media.url, 'https://media.example.invalid/h265-1080.mp4');
  assert.equal(media.quality, 1080);
  assert.equal(media.durationMs, 80500);
  assert.equal(media.routes.length, 3);
  assert.equal(requests.length, 2);
  const fallback = requests[1];
  assert.equal(fallback.hostname, 'vas.example.invalid');
  assert.equal(fallback.searchParams.get('codec_type'), '1');
  assert.equal(fallback.searchParams.get('stream_type'), 'encrypt');
  console.log('PASS bytevc2-only episodes fall back to the decoded h265 endpoint');

  reset();
  const codecRequests = [];
  http.request = async (url) => {
    codecRequests.push(new URL(url));
    if (url.includes('/reading/bookapi/video_tab/')) {
      return response(tabResponse(bytevc2Model));
    }
    return response(fallbackResponse('bytevc2'));
  };
  await assert.rejects(Source.fetchAppMedia(videoId, false), /备用线路/);
  assert.equal(codecRequests.length, 3);
  assert.equal(codecRequests[1].searchParams.get('codec_type'), '1');
  assert.equal(codecRequests[2].searchParams.get('codec_type'), '3');
  console.log('PASS fallback without a compatible codec tries both codec types');

  reset();
  const unknown = Buffer.concat([Buffer.from([0xa8, 0x00, 0x02, 0x00]), Buffer.alloc(32, 7)]).toString('base64');
  const versionRequests = [];
  http.request = async (url) => {
    versionRequests.push(new URL(url));
    if (url.includes('/reading/bookapi/video_tab/')) {
      return response(tabResponse(bytevc2Model));
    }
    return response({ video_info: { data: { key_seed: seedText, video_list: {
      video_1: { definition: '1080p', codec_type: 'h265', vwidth: 1080, vheight: 1920, main_url: unknown },
    } } } });
  };
  await assert.rejects(Source.fetchAppMedia(videoId, false), /编码版本 2/);
  console.log('PASS unknown play url version reports the version instead of failing silently');

  reset();
  http.request = async (url) => {
    if (url.includes('/reading/bookapi/video_tab/')) {
      return response(tabResponse(bytevc2Model));
    }
    return response({ video_info: { data: { key_seed: seedText, video_list: {
      video_1: { definition: '1080p', codec_type: 'h265', main_url: 'https://media.example.invalid/plain.mp4', backup_url_1: unknown },
    } } } });
  };
  const plainMedia = await Source.fetchAppMedia(videoId, false);
  assert.equal(plainMedia.url, 'https://media.example.invalid/plain.mp4');
  assert.equal(plainMedia.routes.length, 1);
  console.log('PASS plain play urls pass through and an unknown version on one field is skipped');
})().catch(error => { console.error(error); process.exitCode = 1; });
