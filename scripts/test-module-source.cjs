const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const typescript = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, filename) => module._compile(typescript.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: {
    module: typescript.ModuleKind.CommonJS, target: typescript.ScriptTarget.ES2021
  } }).outputText, filename);

const root = path.resolve(__dirname, '../entry/src/main/ets');
const originalLoad = Module._load;
let invoke = async () => [];
const calls = [];
let latestContext = { ids: [], more: false };
Module._load = function (specifier, parent, main) {
  if (specifier === 'libqgmodule.so') {
    return { run: async (code, id, method, encoded, callback) => {
      const args = JSON.parse(encoded);
      calls.push({ code, id, method, args, context: latestContext });
      return JSON.stringify(await invoke(code, id, method, args, callback));
    } };
  }
  return originalLoad.call(this, specifier, parent, main);
};
function stub(relative, exports) {
  const filename = path.join(root, relative);
  const module = new Module(filename);
  module.exports = exports;
  require.cache[filename] = module;
}
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgModuleHost.ets', { QgModuleHost: class {
  beginCall() {}
  handle() {}
  setKnown(ids, more) { latestContext = { ids: [...ids], more }; }
  validateCoverUrl(address) { if (address.includes('127.0.0.1')) throw new Error('local address'); }
  async validateMediaUrl(address) { this.validateCoverUrl(address); }
} });
const playlistCalls = [];
stub('data/QgGateway.ets', { QgGateway: { playlistMediaUrl: async (...args) => {
  playlistCalls.push(args);
  return 'http://127.0.0.1/mock/module.m3u8';
} } });
const { QgModuleSource } = require(path.join(root, 'data/source/QgModuleSource.ets'));
const { QgSourceManager } = require(path.join(root, 'data/source/QgSource.ets'));
const required = ['categories', 'catalogPage', 'detail', 'resolveMedia', 'search'];
const fixtures = {
  id: 'demo:42', sourceId: '42', source: 'demo', title: 'Sample', category: 'Drama',
  coverUrl: 'https://img.example/a.jpg', episodeCount: '2', intro: 'Story',
  remark: '更新中', tags: ['Mystery'], badge: '2 chapters', views: '1000', heat: 28
};
const chapter = (key, number) => ({ id: 'demo:42:' + key, title: 'Episode ' + number,
  currentEpisode: number, pageUrl: 'https://example.com/watch/' + key,
  videoUrl: 'video:' + key, source: 'demo' });
const pkg = (version = '1.0.0', id = 'demo') => ({ code: version,
  manifest: { id, name: 'Demo', version, description: '', adult: false,
    hosts: ['example.com'], capabilities: ['search'], baseUrl: 'https://example.com' } });
let receivedTask;
let media;
let currentChapters;
let categoryResult;
let detailOverride;
function normalHandler() {
  currentChapters = [chapter('one', 1), chapter('two', 2)];
  categoryResult = { items: [{ id: 'hot', name: 'Popular' }], incomplete: true };
  detailOverride = undefined;
  media = { url: 'https://cdn.example/video.mp4', referer: 'https://example.com/',
    durationMs: 60000, quality: 720, cencKey: Array.from({ length: 16 }, (_, index) => index),
    credentials: { cookie: 'session=test', origin: 'https://example.com',
      referer: 'https://example.com/watch', userAgent: 'DemoPlayer' },
    variants: [] };
  media.variants = [{ ...media, url: 'https://cdn.example/video.mp4', variants: undefined },
    { ...media, url: 'https://cdn.example/backup.mp4', variants: undefined },
    { ...media, url: 'https://cdn.example/different-key.mp4', cencKey: [99], variants: undefined },
    { url: 'javascript:bad' }];
  invoke = async (code, id, method, args) => {
    if (method === '') return required;
    if (method === 'categories') return categoryResult;
    if (method === 'catalogPage') return { items: [fixtures, { ...fixtures, id: '43' }], hasMore: true };
    if (method === 'search') return { items: [fixtures], hasMore: false };
    if (method === 'detail') return detailOverride ?? { drama: fixtures, chapters: currentChapters };
    if (method === 'resolveMedia') { receivedTask = args[0]; return media; }
    throw new Error('Unexpected method ' + method);
  };
}
async function run() {
  normalHandler();
  const source = new QgModuleSource(pkg());
  await source.validate();
  assert.equal(source.id, 'demo');
  assert.deepEqual(JSON.parse(JSON.stringify(await source.loadCategories())), [{ id: 'hot', label: 'Popular' }]);
  const listing = await source.catalogPage('hot', 2);
  assert.equal(listing.hasMore, true);
  assert.equal(listing.dramas[0].id, 'demo:42');
  assert.equal(listing.dramas[1].id, 'demo:43');
  assert.equal(listing.dramas[0].sourceId, 'demo');
  assert.equal(listing.dramas[0].episodeCount, 2);
  assert.equal(listing.dramas[0].finished, false);
  assert.equal(listing.dramas[0].cover, fixtures.coverUrl);
  assert.equal(calls.at(-1).method, 'catalogPage');
  assert.deepEqual(calls.at(-1).args, [2, 'hot']);
  assert.equal(calls.at(-1).context.more, true);
  await source.catalogPage('hot', 3);
  assert.ok(calls.at(-1).context.ids.includes('demo:42'), 'load-more informs module of known titles');
  await source.catalogPage('different-category', 2);
  assert.deepEqual(calls.at(-1).context.ids, [], 'known IDs belong to each category independently');
  await source.catalogPage('hot', 1);
  assert.equal(calls.at(-1).context.more, false);
  assert.deepEqual(calls.at(-1).context.ids, [], 'refresh resets known titles and cursor mode');
  const searched = await source.search('word', 3);
  assert.equal(searched.dramas[0].id, 'demo:42');
  assert.deepEqual(calls.at(-1).args, [3, 'word']);
  assert.equal(calls.at(-1).context.more, false, 'search cannot inherit load-more catalog context');
  const detail = await source.detail('demo:42');
  assert.equal(calls.at(-1).args[0], '42', 'upstream receives source-local ID');
  assert.deepEqual(detail.episodes.map(episode => [episode.id, episode.order]), [
    ['demo:42:one', 1], ['demo:42:two', 2]
  ]);
  const info = await source.play('demo:42', 'demo:42:two');
  assert.equal(receivedTask.dramaId, 'demo:42');
  assert.equal(receivedTask.chapter.pageUrl, 'https://example.com/watch/two');
  assert.equal(receivedTask.chapter.videoUrl, 'video:two');
  assert.equal(receivedTask.index, 1);
  assert.equal(receivedTask.total, 2);
  assert.equal(info.url, media.url);
  assert.equal(info.durationMs, 60000);
  assert.equal(info.quality, 720);
  assert.equal(info.cencKey, '000102030405060708090a0b0c0d0e0f');
  assert.deepEqual(info.headers, { Cookie: 'session=test', Origin: 'https://example.com',
    Referer: 'https://example.com/watch', 'User-Agent': 'DemoPlayer' });
  assert.equal(info.routes.length, new Set(info.routes).size, 'routes deduplicate');
  assert.ok(info.routes.every(address => address.startsWith('https://')));
  assert.ok(info.routes.includes('https://cdn.example/backup.mp4'));
  assert.ok(!info.routes.includes('https://cdn.example/different-key.mp4'), 'different keys must not share one retry key');
  media.cencKey = Buffer.from(Array.from({ length: 16 }, (_, index) => index)).toString('base64');
  assert.equal((await source.play('demo:42', 'demo:42:one')).cencKey, info.cencKey);
  const playableUrl = media.url;
  media.url = 'http://127.0.0.1/private';
  await assert.rejects(source.play('demo:42', 'demo:42:one'), /local address/,
    'provider must run media addresses through the host validator');
  media.url = playableUrl;
  media.playlist = '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example/one.ts';
  media.hlsKey = Buffer.alloc(16, 7).toString('base64');
  const hls = await source.play('demo:42', 'demo:42:one');
  assert.equal(hls.url, 'http://127.0.0.1/mock/module.m3u8');
  assert.equal(playlistCalls.at(-1)[0], media.playlist);
  assert.equal(Buffer.from(playlistCalls.at(-1)[3]).toString('hex'), '07'.repeat(16));
  assert.equal(hls.referer, '');
  assert.deepEqual(hls.headers, {});
  delete media.playlist;
  delete media.hlsKey;
  currentChapters = [...currentChapters, chapter('three', 3)];
  await source.play('demo:42', 'demo:42:three');
  assert.equal(receivedTask.index, 2, 'changed chapters must use the refreshed list index');
  assert.equal(receivedTask.total, 3, 'changed chapters must use refreshed chapter count');
  await assert.rejects(source.play('demo:42', 'demo:42:missing'), /分集已变更/);
  const previous = new QgModuleSource(pkg('1.0.0'));
  const upgraded = new QgModuleSource(pkg('1.0.1'));
  QgSourceManager.replace(previous);
  QgSourceManager.replace(upgraded);
  assert.equal(QgSourceManager.byId('demo'), upgraded, 'new package hot replaces source registry');
  assert.equal(QgSourceManager.all().filter(item => item.id === 'demo').length, 1);
  await upgraded.play('demo:42', 'demo:42:one');
  assert.equal(calls.at(-1).code, '1.0.1', 'new invocations use updated module code');
  const restarted = new QgModuleSource(pkg('1.0.1'));
  const before = calls.length;
  await restarted.play('demo:42', 'demo:42:one');
  assert.deepEqual(calls.slice(before).map(call => call.method), ['detail', 'resolveMedia'],
    'fresh provider reconstructs chapter mapping before playback');
  detailOverride = { drama: { ...fixtures, id: 'demo:99' }, chapters: currentChapters };
  await assert.rejects(restarted.detail('demo:42'), /请求不符/);
  const noSearch = new QgModuleSource({ ...pkg(), manifest: { ...pkg().manifest, capabilities: [] } });
  await assert.rejects(noSearch.search('word', 1), /不支持搜索/);
  invoke = async () => ['categories', 'catalogPage'];
  await assert.rejects(new QgModuleSource(pkg()).validate(), /缺少 detail/);
  invoke = async () => required.filter(name => name !== 'search');
  await assert.rejects(new QgModuleSource(pkg()).validate(), /缺少 search/,
    'declared search capability requires an actual exported search implementation');
  normalHandler();
  const serial = new QgModuleSource(pkg());
  let active = 0;
  let maximum = 0;
  const immediate = invoke;
  invoke = async (...args) => {
    active++;
    maximum = Math.max(maximum, active);
    try { await new Promise(resolve => setTimeout(resolve, 5)); return await immediate(...args); }
    finally { active--; }
  };
  await Promise.all([serial.search('a', 1), serial.search('b', 1), serial.search('c', 1)]);
  assert.equal(maximum, 1, 'calls are serialized per source');
  normalHandler();
  detailOverride = { drama: { ...fixtures, id: 'hongguo:42' }, chapters: [
    { id: 'hongguo:42:1', currentEpisode: 1, videoUrl: 'hongguo-cenc://987654321' }
  ] };
  const hongguo = new QgModuleSource(pkg('1.0.0', 'hongguo'));
  assert.equal((await hongguo.play('hongguo:42', 'hongguo:42:1')).danmakuId, '987654321',
    'hongguo-cenc scheme must produce a clean numeric danmaku ID');
  console.log('PASS module provider IDs, catalog, chapters, media headers/CENC, hot replacement, restart and serialization');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  Module._load = originalLoad;
});
