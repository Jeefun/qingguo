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
const http = { request: async () => { throw new Error('Unexpected HTTP'); } };
stub('data/QgHttp.ets', { QgHttp: http });
stub('data/QgGateway.ets', { QgGateway: {} });
const { HongguoSource: Source, HONGGUO_MODULE_VERSION } = require(path.join(root, 'data/source/HongguoSource.ets'));
const videoId = '1234567890123456789';
const primaryDevice = '3234567890123456789';
const helperDevice = '4234567890123456789';
const rotatedDevice = '5234567890123456789';
const tabPath = '/reading/bookapi/video_tab/multi_video_model/v1/';
const playerPath = '/novel/player/multi_video_model/player/v1';
const variant = { video_meta: { codec_type: 'h264', definition: '720p' }, main_url: 'https://media.test/public.mp4' };
const model = { video_duration: 60, video_list: { video_1: variant } };
const unsupported = { video_model: { video_list: [{ video_meta: { codec_type: 'bytevc2' }, main_url: variant.main_url }] } };

function response(data, status = 200) {
  const text = JSON.stringify(data);
  return { status, data: Buffer.from(text), text: () => text };
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
  Source.helperRegistered = false;
  Source.helperRegisterPausedUntil = 0;
  Source.helperRegisterPauseErr = '';
  Source.helperRegisterPromise = null;
}
function signedRequest(url, method, headers, body) {
  const parsed = new URL(url);
  const tab = parsed.pathname === tabPath;
  assert.equal(parsed.hostname, tab ? 'api5-normal-sinfonlineb.fqnovel.com' : 'api5-normal-sinfonlinea.fqnovel.com');
  assert.equal(parsed.searchParams.get('version_code'), '74532');
  assert.equal(method, tab ? 'GET' : 'POST');
  assert.ok(headers['X-Medusa']);
  assert.ok(headers['X-Helios']);
  assert.equal(headers['X-Gorgon'], undefined);
  assert.equal(headers['X-XS-From-Web'], undefined);
  assert.equal(headers['Sdk-Version'], undefined);
  if (tab) {
    assert.equal(parsed.searchParams.get('video_id'), videoId);
    assert.equal(parsed.searchParams.get('video_id_type'), '0');
    assert.equal(parsed.searchParams.get('device_level'), '1');
    assert.equal(parsed.searchParams.get('video_platform'), '1024');
    assert.equal(body, null);
  } else {
    assert.equal(parsed.pathname, playerPath);
    const payload = JSON.parse(Buffer.from(body).toString());
    assert.equal(payload.biz_param.device_level, 1);
    assert.equal(payload.biz_param.video_platform, 1024);
    assert.deepEqual(payload.mixed_video_id_map, { '1004': [videoId] });
  }
  return parsed;
}

(async () => {
  assert.equal(HONGGUO_MODULE_VERSION, '1.0.7');
  reset();
  for (const encoding of ['object', 'json', 'base64']) {
    http.request = async (url, method, headers, body) => {
      const parsed = signedRequest(url, method, headers, body);
      assert.equal(parsed.pathname, tabPath);
      const value = encoding === 'object' ? model : encoding === 'json' ? JSON.stringify(model) : Buffer.from(JSON.stringify(model)).toString('base64');
      return response({ data: { video_model_data: { [videoId]: { video_model: value } } } });
    };
    const info = await Source.appMedia(videoId);
    assert.equal(info.url, variant.main_url);
    assert.equal(info.durationMs, 60000);
  }
  console.log('PASS V5 GET request and object/JSON/base64 models');

  for (const grouped of [true, false]) for (const encoded of [true, false]) {
    const calls = [];
    http.request = async (url, method, headers, body) => {
      const parsed = signedRequest(url, method, headers, body);
      calls.push(parsed.pathname);
      if (parsed.pathname === tabPath) return response({}, 404);
      const row = { video_model: encoded ? Buffer.from(JSON.stringify(model)).toString('base64') : model };
      return response({ data: grouped ? { '1004': { [videoId]: row } } : { [videoId]: row } });
    };
    assert.equal((await Source.appMedia(videoId)).url, variant.main_url);
    assert.deepEqual(calls, [tabPath, playerPath]);
  }
  console.log('PASS GET failure falls back to POST in four response representations');

  reset();
  http.request = async (url, method, headers, body) => {
    const parsed = signedRequest(url, method, headers, body);
    return response({ data: parsed.pathname === tabPath ? { video_model_data: { wrong: { video_model: model } } } : { '1004': { wrong: { video_model: model } } } });
  };
  await assert.rejects(Source.appMedia(videoId), /所请求的分集/);
  assert.equal(Source.helperRegistered, false);
  console.log('PASS mismatched episode rejected without registering extra devices');

  reset();
  let registrations = 0;
  let mediaCalls = [];
  http.request = async (url, method, headers, body) => {
    const parsed = new URL(url);
    if (parsed.hostname === 'log.snssdk.com') {
      registrations++;
      return response({ device_id_str: registrations === 1 ? helperDevice : rotatedDevice, install_id_str: '7234567890123456789' });
    }
    signedRequest(url, method, headers, body);
    assert.equal(parsed.pathname, tabPath);
    const device = parsed.searchParams.get('device_id');
    mediaCalls.push(device);
    const row = device === rotatedDevice ? { video_list: model.video_list, video_duration: model.video_duration } : unsupported;
    return response({ data: { video_model_data: { [videoId]: row } } });
  };
  assert.equal((await Source.appMedia(videoId)).url, variant.main_url);
  assert.equal(registrations, 2);
  assert.deepEqual(mediaCalls, [primaryDevice, helperDevice, rotatedDevice]);
  assert.equal(Source.deviceId, primaryDevice);
  console.log('PASS codec-only failure uses helper then bounded helper rotation, preserving primary identity');

  reset();
  Source.helperRegistered = true;
  mediaCalls = [];
  registrations = 0;
  http.request = async (url, method, headers, body) => {
    const parsed = new URL(url);
    if (parsed.hostname === 'log.snssdk.com') {
      registrations++;
      return response({ device_id_str: rotatedDevice, install_id_str: '7234567890123456789' });
    }
    signedRequest(url, method, headers, body);
    mediaCalls.push(parsed.searchParams.get('device_id'));
    return response({ data: { video_model_data: { [videoId]: unsupported } } });
  };
  await assert.rejects(Source.appMedia(videoId), /未返回兼容/);
  assert.equal(registrations, 1);
  assert.equal(mediaCalls.length, 3);
  console.log('PASS unsupported encoding stops after one helper replacement');

  reset();
  registrations = 0;
  http.request = async (url) => {
    if (new URL(url).hostname === 'log.snssdk.com') registrations++;
    return response({}, 403);
  };
  await assert.rejects(Source.appMedia(videoId), /HTTP 403/);
  assert.equal(registrations, 0);
  console.log('PASS access denial does not trigger auxiliary registrations');
})().catch(error => { console.error(error); process.exitCode = 1; });
