const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, file);
const root = path.resolve(__dirname, '../entry/src/main/ets');
function stub(relative, exports) {
  const filename = path.join(root, relative);
  const module = new Module(filename);
  module.exports = exports;
  require.cache[filename] = module;
}
const http = { request: async () => { throw new Error('Unexpected HTTP'); } };
stub('data/QgHttp.ets', { QgHttp: http });
stub('data/QgGateway.ets', { QgGateway: {} });
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgModuleHost.ets', { QgModuleHost: class {
  beginCall() {} handle() {} setKnown() {} validateCoverUrl() {} async validateMediaUrl() {}
} });
const { QgDrama, QgSeason, QgAppSettings } = require(path.join(root, 'model/QgModels.ets'));
const { HongguoSource } = require(path.join(root, 'data/source/HongguoSource.ets'));
const { QgSource, QgSourceManager } = require(path.join(root, 'data/source/QgSource.ets'));
const indexPath = '/reading/distribution/book_pack_fields/inner_feed_detail/v1/';
const ids = ['7234567890123456789', '7234567890123456790', '7234567890123456791'];
function response(text, status = 200) {
  if (typeof text !== 'string') text = JSON.stringify(text);
  return { status, data: Buffer.from(text), text: () => text };
}
function rawAlbum(values) {
  return '{"code":0,"data":{"' + ids[0] + '":{"album_info":{"album_series_ids":[' + values.join(',') + ']}}}}';
}
function packed(values = ids) {
  return { code: 0, data: Object.fromEntries(values.map((id, index) => [id, { base_info: {
    series_id: id, series_title: 'Official season ' + (index + 1), series_cover: 'https://img.test/' + id,
    episode_cnt: 8 + index, series_status: 1, category_schema: '[{"name":"Drama"}]'
  } }])) };
}
function nativeReset() {
  HongguoSource.registered = true;
  HongguoSource.deviceId = '3234567890123456789';
  HongguoSource.installId = '2234567890123456789';
  HongguoSource.registerPausedUntil = 0;
  HongguoSource.registerPauseErr = '';
  HongguoSource.registerPromise = null;
}
let nativeCalls;
function nativeFixture(album = ids, metadata = packed()) {
  nativeReset();
  nativeCalls = [];
  http.request = async (address, method, headers, body, timeout) => {
    const url = new URL(address);
    const text = Buffer.from(body).toString();
    nativeCalls.push({ url, method, headers, text, timeout });
    if (url.pathname === indexPath) {
      assert.equal(method, 'POST');
      assert.ok(headers['X-Gorgon'], 'native metadata calls keep existing signature protocol');
      const request = JSON.parse(text);
      assert.equal(request.book_pack_channel, 'inner_feed_detail');
      assert.ok(timeout > 0 && timeout <= 20000);
      if (request.req_fields.includes('album_series_ids')) return response(rawAlbum(album));
      return response(metadata);
    }
    if (url.pathname === '/novel/player/video_detail/v1/') {
      const id = JSON.parse(text).series_id;
      return response({ code: 0, data: { video_data: {
        series_id_str: id, series_title: 'Detail fallback', episode_cnt: 12
      } } });
    }
    throw Error('Unexpected request ' + address);
  };
}

let moduleResult = [];
let lastModuleCall;
let moduleExports = ['categories', 'catalogPage', 'detail', 'resolveMedia', 'seasons'];
const originalLoad = Module._load;
Module._load = function (name, parent, main) {
  if (name === 'libqgmodule.so') return { run: async (code, id, method, args) => {
    lastModuleCall = { code, id, method, args: JSON.parse(args) };
    return JSON.stringify(method === '' ? moduleExports : moduleResult);
  } };
  return originalLoad.call(this, name, parent, main);
};
const { QgModuleSource } = require(path.join(root, 'data/source/QgModuleSource.ets'));
const modulePackage = (version = '1.0.0') => ({ code: version,
  manifest: { id: 'demo', name: 'Demo', version, capabilities: ['seasons'], hosts: ['example.com'] } });
const seasonRow = (number, id) => ({ number, drama: { id: 'demo:' + id, title: 'Season ' + number, source: 'demo' } });
let preparedPackage;
stub('data/QgModuleStore.ets', { QgModuleStore: {
  installed: () => [], download: async () => preparedPackage, commit() {}, remove() {}
} });
const settings = new QgAppSettings();
stub('data/QgStore.ets', { QgStore: { getInstance: () => ({
  getSettings: () => settings, updateSettings: next => Object.assign(settings, next)
}) } });
const values = new Map();
global.AppStorage = { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) };

async function nativeTests() {
  const source = new HongguoSource();
  nativeFixture();
  const result = await source.seasons('hongguo:' + ids[0]);
  assert.deepEqual(result.map(item => [item.number, item.drama.id]), ids.map((id, index) => [index + 1, 'hongguo:' + id]));
  assert.equal(result[1].drama.episodeCount, 9);
  assert.ok(nativeCalls[0].text.includes('"req_ids":[' + ids[0] + ']'), 'int64 request IDs retain exact unquoted bytes');
  assert.ok(nativeCalls[1].text.includes('"req_ids":[' + ids.join(',') + ']'));
  assert.equal(nativeCalls.length, 2, 'complete metadata is batched instead of one detail per season');
  assert.ok(result.every(item => item.drama.sourceId === 'hongguo'));
  console.log('PASS native official album membership/order, int64 IDs, batched metadata and existing signing');

  nativeFixture([ids[0]]);
  assert.deepEqual(await source.seasons('hongguo:' + ids[0]), []);
  assert.equal(nativeCalls.length, 1);
  nativeFixture([ids[1], ids[2]]);
  assert.deepEqual(await source.seasons('hongguo:' + ids[0]), [], 'other series album cannot be merged by title');
  assert.equal(nativeCalls.length, 1);
  nativeFixture();
  assert.deepEqual(await source.seasons('hongguo:book-123'), []);
  assert.equal(nativeCalls.length, 0);
  await assert.rejects(source.seasons('other:' + ids[0]), /无效/);
  await assert.rejects(source.seasons('hongguo:9223372036854775808'), /无效/);
  await assert.rejects(source.seasons('hongguo:00123'), /无效/);
  nativeFixture([ids[0], ids[0]]);
  await assert.rejects(source.seasons('hongguo:' + ids[0]), /重复/);
  nativeFixture([...Array(61)].map((value, index) => String(1000 + index)));
  assert.deepEqual(await source.seasons('hongguo:' + ids[0]), []);
  console.log('PASS single-season/unsupported/unrelated/oversized albums and duplicate/invalid IDs');

  nativeFixture(ids, packed([ids[0], ids[2]]));
  const partial = await source.seasons('hongguo:' + ids[0]);
  assert.equal(partial[1].drama.title, 'Detail fallback');
  assert.deepEqual(partial.map(item => item.number), [1, 2, 3]);
  assert.equal(nativeCalls.length, 3);
  nativeFixture(ids, packed([ids[0], ids[2]]));
  const completeRequest = http.request;
  let missingMiddle = true;
  http.request = async (...args) => {
    if (missingMiddle && new URL(args[0]).pathname === '/novel/player/video_detail/v1/') return response({}, 403);
    return completeRequest(...args);
  };
  await assert.rejects(source.seasons('hongguo:' + ids[0]), /第2季信息暂不可用，请重试/,
    'failed middle-season metadata must reject rather than allowing auto-next to jump from season 1 to season 3');
  missingMiddle = false;
  const retried = await source.seasons('hongguo:' + ids[0]);
  assert.deepEqual(retried.map(item => item.number), [1, 2, 3], 'retry rebuilds full listing after partial failure');
  assert.equal(retried[1].drama.id, 'hongguo:' + ids[1]);
  assert.equal(retried[1].drama.title, 'Detail fallback');
  nativeFixture();
  http.request = async () => response({}, 403);
  await assert.rejects(source.seasons('hongguo:' + ids[0]), /HTTP 403/);
  const realNow = Date.now;
  let now = realNow();
  nativeFixture();
  const request = http.request;
  http.request = async (...args) => { const result = await request(...args); now += 30000; return result; };
  Date.now = () => now;
  try { await assert.rejects(source.seasons('hongguo:' + ids[0]), /超时/); }
  finally { Date.now = realNow; }
  const realSetTimeout = global.setTimeout;
  const realClearTimeout = global.clearTimeout;
  nativeReset();
  HongguoSource.registered = false;
  let resolveRegistration;
  let timeoutCallback;
  let timerCleared = false;
  let requestCount = 0;
  now = realNow();
  Date.now = () => now;
  global.setTimeout = (callback, milliseconds) => {
    assert.equal(milliseconds, 25000);
    timeoutCallback = callback;
    return 99;
  };
  global.clearTimeout = timer => { assert.equal(timer, 99); timerCleared = true; };
  http.request = async address => {
    requestCount++;
    assert.equal(new URL(address).hostname, 'log.snssdk.com');
    return new Promise(resolve => { resolveRegistration = resolve; });
  };
  try {
    const pending = source.seasons('hongguo:' + ids[0]);
    assert.equal(typeof resolveRegistration, 'function', 'initial device registration must be in-flight');
    now += 25000;
    timeoutCallback();
    await assert.rejects(pending, /分季请求超时，请重试/);
    assert.ok(timerCleared, 'timeout timer is cleared after settling');
    resolveRegistration(response({ device_id_str: ids[0], install_id_str: ids[1] }));
    for (let index = 0; index < 10; index++) await Promise.resolve();
    assert.equal(requestCount, 1, 'late registration does not start metadata calls after season deadline');
  } finally {
    Date.now = realNow;
    global.setTimeout = realSetTimeout;
    global.clearTimeout = realClearTimeout;
    nativeReset();
  }
  console.log('PASS missing metadata detail fallback, propagated access errors and bounded season deadline');
}

async function moduleTests() {
  moduleResult = [seasonRow(2, 'second'), seasonRow(1, 'first')];
  const source = new QgModuleSource(modulePackage());
  await source.validate();
  const seasons = await source.seasons('demo:first');
  assert.deepEqual(lastModuleCall.args, ['first']);
  assert.equal(lastModuleCall.method, 'seasons');
  assert.deepEqual(seasons.map(item => [item.number, item.drama.id]), [[2, 'demo:second'], [1, 'demo:first']]);
  const noCapability = new QgModuleSource({ ...modulePackage(), manifest: { ...modulePackage().manifest, capabilities: [] } });
  lastModuleCall = null;
  assert.deepEqual(await noCapability.seasons('demo:first'), []);
  assert.equal(lastModuleCall, null);
  await assert.rejects(source.seasons('other:first'), /不属于/);
  for (const invalid of [null, {}, [seasonRow(0, 'first')], [{ ...seasonRow(1, 'first'), drama: { id: 'other:first', title: 'Other' } }],
    [{ ...seasonRow(1, 'first'), drama: { id: 'demo:first', source: 'other', title: 'Other' } }],
    [{ ...seasonRow(1, 'first'), drama: { id: 'demo:first', title: '' } }]]) {
    moduleResult = invalid;
    await assert.rejects(source.seasons('demo:first'), /无效|其他站源/);
  }
  moduleExports = ['categories', 'catalogPage', 'detail', 'resolveMedia'];
  await assert.rejects(new QgModuleSource(modulePackage()).validate(), /缺少 seasons/);
  moduleExports.push('seasons');
  console.log('PASS optional module seasons contract, scoped IDs, malformed data and required export checks');
}

async function repositoryTests() {
  const builtinSources = { Hongguo: 'hongguo', Hanxiaoquan: 'hanxiaoquan', Sorani: 'sorani',
    Huangdou: 'huangdou', Guipian: 'guipian', Heitao: 'heitao', Huangju: 'huangju', Beabox: 'beabox',
    Jinguoduanju: 'jinguoduanju', Yeguo: 'yeguo', Dsd: 'dsd', Jinguo: 'jinguo',
    Huangguoai: 'huangguoai', HuangguoVideo: 'huangguo-video', Legacy: 'cloudfront' };
  Object.entries(builtinSources).forEach(([name, id]) => {
    stub('data/source/' + name + 'Source.ets', { [name + 'Source']: class extends QgSource {
      constructor() { super(id, id); } async detail() { throw Error('Unused'); } async play() { throw Error('Unused'); }
    } });
  });
  const { QgRepository: Repository } = require(path.join(root, 'data/QgRepository.ets'));
  Repository.init();
  const anchor = new QgDrama('demo:first', '', '');
  const list = [new QgSeason(2, new QgDrama('demo:second', 'Second', '')),
    new QgSeason(1, new QgDrama('demo:first', 'First', ''))];
  let queries = 0;
  let output = list;
  const custom = new class extends QgSource {
    constructor() { super('demo', 'Demo'); } async detail() { throw Error('Unused'); } async play() { throw Error('Unused'); }
    async seasons() { queries++; return output; }
  }();
  QgSourceManager.replace(custom);
  assert.deepEqual((await Repository.seasons(anchor)).map(item => item.number), [1, 2]);
  assert.equal(queries, 1);
  await Repository.seasons(anchor);
  assert.equal(queries, 1, 'valid season listing is cached');
  const secondAnchor = new QgDrama('demo:second', '', '');
  const related = await Repository.seasons(secondAnchor);
  assert.deepEqual(related.map(item => item.number), [1, 2]);
  assert.equal(queries, 1, 'switching to a known member reuses the complete official series');
  related.pop();
  assert.equal((await Repository.seasons(secondAnchor)).length, 2, 'callers receive a separate result array');
  assert.deepEqual(await Repository.seasons(new QgDrama('demo:unrelated', '', '')), [],
    'unrelated anchors cannot inherit a cached series');
  assert.equal(queries, 2);
  assert.equal((await Repository.seasons(secondAnchor)).length, 2,
    'an unrelated empty result does not replace the valid series');
  assert.equal(queries, 2);
  const realNow = Date.now;
  Date.now = () => realNow() + 5 * 60 * 1000 + 1;
  try {
    assert.equal((await Repository.seasons(secondAnchor)).length, 2);
    assert.equal(queries, 3, 'expired related listings must refresh instead of remaining cached across seasons');
  } finally {
    Date.now = realNow;
  }
  Repository.invalidate();
  output = [list[0]];
  assert.deepEqual(await Repository.seasons(anchor), [], 'current anchor must appear and there must be multiple seasons');
  for (const invalid of [[list[1], list[1]], [new QgSeason(1, new QgDrama('other:first', 'Bad', '')), list[0]],
    [new QgSeason(1.5, new QgDrama('demo:first', 'Bad', '')), list[0]]]) {
    Repository.invalidate();
    output = invalid;
    await assert.rejects(Repository.seasons(anchor), /无效|重复/);
  }
  Repository.invalidate();
  let release;
  let signal;
  const pending = new Promise(resolve => { signal = resolve; });
  custom.seasons = async () => { signal(); return new Promise(resolve => { release = resolve; }); };
  const oldRequest = Repository.seasons(anchor);
  await pending;
  preparedPackage = modulePackage('1.0.1');
  moduleResult = [seasonRow(1, 'first'), seasonRow(2, 'second')];
  await Repository.installModule({});
  release(list);
  const updated = await oldRequest;
  assert.equal(updated[0].drama.title, 'Season 1', 'late old-version season data is discarded after online upgrade');
  assert.equal(lastModuleCall.code, '1.0.1');
  Repository.restoreModule('demo');
  await assert.rejects(Repository.seasons(anchor), /未找到/);
  assert.deepEqual(await Repository.seasons(new QgDrama('hanxiaoquan:42', '', '')), [], 'unsupported builtins return no seasons');
  console.log('PASS repository sort/cache, anchor/duplicate/source validation, upgrade invalidation and stale-response protection');
}

(async () => { await nativeTests(); await moduleTests(); await repositoryTests(); })().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => { Module._load = originalLoad; delete global.AppStorage; });
