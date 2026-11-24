const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const assert = require('node:assert/strict');
const typescript = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, filename) => module._compile(typescript.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: {
    module: typescript.ModuleKind.CommonJS, target: typescript.ScriptTarget.ES2021
  } }).outputText, filename);
const root = path.resolve(__dirname, '../entry/src/main/ets');
const globalValues = new Map();
global.AppStorage = { get: name => globalValues.get(name), setOrCreate: (name, value) => globalValues.set(name, value) };
const originalLoad = Module._load;
Module._load = function (name, parent, main) {
  if (name === 'libqgmodule.so') return { run: async (code, id, method, encoded) => {
    if (!method) return JSON.stringify(['categories', 'catalogPage', 'detail', 'resolveMedia', 'search']);
    const args = JSON.parse(encoded);
    if (method === 'detail') {
      const drama = { id: id + ':' + args[0], title: code, episodeCount: 1, cover: 'https://example.com/cover.jpg' };
      return JSON.stringify({ drama, chapters: [{ id: id + ':' + args[0] + ':1', videoUrl: 'video:1', currentEpisode: 1 }] });
    }
    if (method === 'resolveMedia') return JSON.stringify({ url: 'https://example.com/' + code + '.mp4' });
    if (method === 'categories') return '[]';
    return JSON.stringify({ items: [], hasMore: false });
  } };
  return originalLoad.call(this, name, parent, main);
};
function stub(relative, exports) {
  const filename = path.join(root, relative);
  const module = new Module(filename);
  module.exports = exports;
  require.cache[filename] = module;
}
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgModuleHost.ets', { QgModuleHost: class {
  beginCall() {} handle() {} validateCoverUrl() {} async validateMediaUrl() {}
  setKnown() {}
} });
stub('data/QgGateway.ets', { QgGateway: {} });
const { QgAppSettings } = require(path.join(root, 'model/QgModels.ets'));
const settings = new QgAppSettings();
settings.videoAspect = 'fill';
stub('data/QgStore.ets', { QgStore: { getInstance: () => ({
  getSettings: () => settings, updateSettings: next => Object.assign(settings, next)
}) } });
const packages = [];
stub('data/QgModuleStore.ets', { QgModuleStore: { installed: () => packages } });
const manifestOf = id => JSON.parse(JSON.stringify({ id, name: 'Module ' + id, version: '1.0.0',
  description: 'Example ' + id, adult: false, runtime: 'js', api: 1,
  hosts: ['example.com'], capabilities: ['search'] }));
const packageOf = id => ({ manifest: manifestOf(id), code: 'code-' + id, rawManifest: '',
  manifestHash: '', entryHash: '' });
async function run() {
  const { QgRepository: Repository } = require(path.join(root, 'data/QgRepository.ets'));
  packages.push(packageOf('hongguo'), packageOf('demo'));
  assert.equal(Repository.sources().length, 2, 'installed modules register as sources');
  assert.equal(Repository.sources().length, 2, 'registration is idempotent');
  assert.deepEqual(Repository.descriptions().map(item => [item.id, item.desc]),
    [['hongguo', 'Example hongguo'], ['demo', 'Example demo']],
    'descriptions derive from module manifests');
  assert.equal(Repository.currentSourceId(), 'hongguo', 'settings source selects current source');
  settings.sourceId = 'missing';
  assert.equal(Repository.currentSourceId(), 'hongguo', 'unknown source falls back to hongguo');
  settings.sourceId = 'demo';
  assert.equal(Repository.currentSourceName(), 'Module demo');
  const detail = await Repository.detail('demo:42');
  assert.equal(detail.drama.title, 'code-demo', 'detail routes by source prefix to the module');
  assert.equal((await Repository.play('demo:42', 'demo:42:1')).url, 'https://example.com/code-demo.mp4');
  assert.equal((await Repository.coverHeadersOf('demo', 'https://example.com/a.jpg'))['Referer'], undefined,
    'module without baseUrl has no cover headers');
  assert.deepEqual(await Repository.loadCategories(), []);
  Repository.setSource('hongguo');
  assert.equal(settings.sourceId, 'hongguo', 'setSource persists through store settings');
  assert.equal(settings.videoAspect, 'fill', 'source changes retain playback preferences');
  assert.equal(Repository.currentSourceId(), 'hongguo');
  Repository.setSource('missing');
  assert.equal(settings.sourceId, 'hongguo', 'unknown source ids are rejected');
  await assert.rejects(Repository.detail('missing:42'), /未找到该剧所属的站源/);
  assert.equal((await Repository.detail('demo:42')).drama.title, 'code-demo',
    'sources are looked up by id prefix, not the current source');
  console.log('PASS module source registration, manifest descriptions, source switching and prefix routing');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  Module._load = originalLoad;
  delete global.AppStorage;
});
