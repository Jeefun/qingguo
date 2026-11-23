const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const typescript = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, filename) => module._compile(typescript.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: {
    module: typescript.ModuleKind.CommonJS, target: typescript.ScriptTarget.ES2021
  } }).outputText, filename);
const root = path.resolve(__dirname, '../entry/src/main/ets');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'qg-module-repository-'));
const globalValues = new Map();
global.AppStorage = { get: name => globalValues.get(name), setOrCreate: (name, value) => globalValues.set(name, value) };
const originalLoad = Module._load;
const nativeFs = {
  OpenMode: { WRITE_ONLY: fs.constants.O_WRONLY, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
  mkdirSync: (target, recursive) => fs.mkdirSync(target, { recursive }),
  listFileSync: target => fs.readdirSync(target),
  statSync: target => fs.statSync(target), readTextSync: target => fs.readFileSync(target, 'utf8'),
  openSync: (target, flags) => ({ fd: fs.openSync(target, flags) }),
  writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes)),
  fsyncSync: fd => fs.fsyncSync(fd), closeSync: file => fs.closeSync(file.fd),
  renameSync: (source, target) => fs.renameSync(source, target), unlinkSync: target => fs.unlinkSync(target)
};
let missingExport = false;
let heldDetailVersion = '';
let notifyHeldDetail;
let releaseHeldDetail;
const methods = ['categories', 'catalogPage', 'detail', 'resolveMedia', 'search'];
Module._load = function (name, parent, main) {
  if (name === '@kit.CoreFileKit') return { fileIo: nativeFs };
  if (name === 'libqgmodule.so') return { run: async (code, id, method, encoded) => {
    const args = JSON.parse(encoded);
    if (!method) return JSON.stringify(missingExport ? ['categories'] : methods);
    const sourceId = method === 'detail' ? args[0] : '42';
    const drama = { id: id + ':' + sourceId, title: code, episodeCount: 1, cover: 'https://example.com/cover.jpg' };
    if (method === 'detail') {
      if (code === heldDetailVersion) await new Promise(resolve => {
        releaseHeldDetail = resolve;
        notifyHeldDetail();
      });
      return JSON.stringify({ drama, chapters: [{ id: id + ':' + sourceId + ':1', videoUrl: 'video:1', currentEpisode: 1 }] });
    }
    if (method === 'resolveMedia') return JSON.stringify({ url: 'https://example.com/' + code + '.mp4' });
    if (method === 'categories') return '[]';
    return JSON.stringify({ items: [drama], hasMore: false });
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
const builtinSources = { Hongguo: 'hongguo', Hanxiaoquan: 'hanxiaoquan', Sorani: 'sorani',
  Huangdou: 'huangdou', Guipian: 'guipian', Heitao: 'heitao', Huangju: 'huangju', Beabox: 'beabox',
  Jinguoduanju: 'jinguoduanju', Yeguo: 'yeguo', Dsd: 'dsd', Jinguo: 'jinguo',
  Huangguoai: 'huangguoai', HuangguoVideo: 'huangguo-video', Legacy: 'cloudfront' };
Object.entries(builtinSources).forEach(([name, id]) => {
  stub('data/source/' + name + 'Source.ets', { [name + 'Source']: class {
    constructor() { this.id = id; this.name = 'Builtin ' + id; }
    categories() { return []; } async loadCategories() { return []; }
    async detail() { return { builtin: true }; } async play() { return { builtin: true }; }
  } });
});
let fixture;
function setFixture(id, version) {
  const manifest = JSON.stringify({ id, name: 'Online ' + id, version, runtime: 'js', api: 1,
    adult: false, hosts: ['example.com'], capabilities: ['search'] });
  const sum = value => crypto.createHash('sha256').update(value).digest('hex');
  fixture = { manifest, code: version, entry: { id, name: 'Online ' + id, version, api: 1, adult: false,
    repo: 'guoapp-modules/' + id, tag: 'v' + version,
    sha256: { 'manifest.json': sum(manifest), 'main.js': sum(version) } } };
}
stub('data/QgHttp.ets', { QgHttp: { request: async url => ({
  status: 200, data: Buffer.from(url.includes('/index/') ? JSON.stringify({ format: 1, modules: [fixture.entry] }) :
    url.includes('manifest.json') ? fixture.manifest : fixture.code)
}) } });
const repositoryPath = path.join(root, 'data/QgRepository.ets');
const storePath = path.join(root, 'data/QgModuleStore.ets');
function runtime() {
  const { QgModuleStore: Store } = require(storePath);
  Store.init(directory);
  return { Store, Repository: require(repositoryPath).QgRepository };
}
async function run() {
  let { Store, Repository } = runtime();
  const initialCount = Repository.sources().length;
  assert.equal(Repository.currentSourceName(), 'Builtin hongguo');
  setFixture('hongguo', '1.0.0');
  await Repository.installModule((await Store.index())[0]);
  assert.equal(Repository.sources().length, initialCount, 'module replaces matching builtin without duplicates');
  assert.equal(Repository.currentSourceName(), 'Online hongguo');
  assert.equal((await Repository.detail('hongguo:42')).drama.title, '1.0.0');
  assert.equal((await Repository.play('hongguo:42', 'hongguo:42:1')).url, 'https://example.com/1.0.0.mp4');
  setFixture('hongguo', '1.0.1');
  await Repository.installModule((await Store.index())[0]);
  assert.equal((await Repository.detail('hongguo:42')).drama.title, '1.0.1',
    'upgrading discards previous repository detail cache');
  assert.equal((await Repository.play('hongguo:42', 'hongguo:42:1')).url, 'https://example.com/1.0.1.mp4');
  setFixture('hongguo', '1.0.2');
  missingExport = true;
  await assert.rejects(Repository.installModule((await Store.index())[0]), /缺少/);
  missingExport = false;
  assert.equal(Store.installed()[0].manifest.version, '1.0.1', 'probe failure cannot persist bad version');
  assert.equal((await Repository.detail('hongguo:42')).drama.title, '1.0.1');
  heldDetailVersion = '1.0.1';
  const held = new Promise(resolve => { notifyHeldDetail = resolve; });
  const oldDetail = Repository.detail('hongguo:99');
  await held;
  await Repository.installModule((await Store.index())[0]);
  releaseHeldDetail();
  heldDetailVersion = '';
  assert.equal((await oldDetail).drama.title, '1.0.2', 'late previous-version result cannot overwrite new version cache');
  assert.equal((await Repository.detail('hongguo:99')).drama.title, '1.0.2');
  Repository.restoreModule('hongguo');
  assert.equal(Repository.currentSourceName(), 'Builtin hongguo');
  setFixture('newsource', '1.0.0');
  await Repository.installModule((await Store.index())[0]);
  Repository.setSource('newsource');
  assert.equal(settings.sourceId, 'newsource');
  assert.equal(settings.videoAspect, 'fill', 'source changes retain playback preferences');
  assert.equal(Repository.currentSourceId(), 'newsource');
  assert.equal(Repository.sources().length, initialCount + 1);
  assert.ok(globalValues.get('qgSourceTick') >= 4, 'installed updates notify subscribed views');
  for (const relative of ['data/QgRepository.ets', 'data/QgModuleStore.ets', 'data/source/QgModuleSource.ets', 'data/source/QgSource.ets']) {
    delete require.cache[path.join(root, relative)];
  }
  ({ Store, Repository } = runtime());
  assert.equal(Repository.currentSourceId(), 'newsource', 'dynamic installed source survives restart');
  assert.equal((await Repository.detail('newsource:42')).drama.title, '1.0.0');
  assert.equal((await Repository.play('newsource:42', 'newsource:42:1')).url, 'https://example.com/1.0.0.mp4');
  Repository.restoreModule('newsource');
  assert.equal(Repository.currentSourceId(), 'hongguo', 'removing online-only current source selects available fallback');
  console.log('PASS repository online activation, code replacement, cache invalidation, failed-probe rollback, builtin restore and restart');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  Module._load = originalLoad;
  delete global.AppStorage;
  fs.rmSync(directory, { recursive: true, force: true });
});
