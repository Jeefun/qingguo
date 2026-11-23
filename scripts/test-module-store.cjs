const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const assert = require('node:assert/strict');
const typescript = require('./load-typescript.cjs');
require.extensions['.ets'] = (module, filename) => module._compile(typescript.transpileModule(
  fs.readFileSync(filename, 'utf8'), { compilerOptions: {
    module: typescript.ModuleKind.CommonJS, target: typescript.ScriptTarget.ES2021
  } }).outputText, filename);

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'qg-module-store-'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const network = { request: async () => { throw new Error('offline'); } };
let failRename = false;
const platformFs = {
  OpenMode: { WRITE_ONLY: fs.constants.O_WRONLY, CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
  mkdirSync: (target, recursive) => fs.mkdirSync(target, { recursive }),
  listFileSync: target => fs.readdirSync(target),
  statSync: target => fs.statSync(target),
  readTextSync: target => fs.readFileSync(target, 'utf8'),
  openSync: (target, flags) => ({ fd: fs.openSync(target, flags) }),
  writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes)),
  fsyncSync: fd => fs.fsyncSync(fd),
  closeSync: file => fs.closeSync(file.fd),
  renameSync: (source, target) => {
    if (failRename) throw new Error('out of space');
    fs.renameSync(source, target);
  },
  unlinkSync: target => fs.unlinkSync(target)
};
const originalLoad = Module._load;
Module._load = function (specifier, parent, main) {
  if (specifier === '@kit.CoreFileKit') return { fileIo: platformFs };
  return originalLoad.call(this, specifier, parent, main);
};
function stub(relative, exports) {
  const filename = path.join(root, relative);
  const module = new Module(filename);
  module.exports = exports;
  require.cache[filename] = module;
}
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgHttp.ets', { QgHttp: network });
const storePath = path.join(root, 'data/QgModuleStore.ets');
let { QgModuleStore: Store, QgModuleEntry: Entry, QgModuleManifest: Manifest } = require(storePath);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const packageFor = version => {
  const manifest = JSON.stringify({ id: 'test', name: 'Test', version, description: 'Example',
    adult: false, runtime: 'js', api: 1, hosts: ['example.com', '*.example.net'], capabilities: ['search'] });
  const code = 'module.exports = { categories() { return []; } };';
  const entry = { id: 'test', name: 'Test', version, api: 1, adult: false,
    repo: 'guoapp-modules/test', tag: 'v' + version,
    sha256: { 'manifest.json': digest(manifest), 'main.js': digest(code) } };
  return { entry, manifest, code };
};
let fixture = packageFor('1.0.0');
let brokenAsset = false;
let wrongIdentity = false;
let seen = [];
function configureNetwork() {
  network.request = async (url, method, headers, body, timeout, limit) => {
    seen.push(url);
    assert.equal(method, 'GET');
    assert.ok(limit > 0, 'HTTP download must have an enforced byte limit');
    if (url.includes('/index/') || url.includes('/repos/guoapp-modules/index/')) {
      if (url.includes('raw.githubusercontent.com')) throw new Error('reset');
      return { status: 200, data: Buffer.from(JSON.stringify({ format: 1, modules: [fixture.entry] })) };
    }
    if (url.includes('raw.githubusercontent.com')) throw new Error('reset');
    if (url.includes('.jsdelivr.net')) return { status: 503, data: Buffer.from('error') };
    if (url.includes('manifest.json')) {
      return { status: 200, data: Buffer.from(wrongIdentity ? fixture.manifest.replace('"test"', '"other"') : fixture.manifest) };
    }
    return { status: 200, data: Buffer.from(brokenAsset ? 'tampered' : fixture.code) };
  };
}
async function run() {
  Store.init(directory);
  configureNetwork();
  let entries = await Store.index();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].installed(), false);
  const prepared = await Store.download(entries[0]);
  assert.equal(Store.load().length, 0, 'download must not activate unprobed code');
  assert.throws(() => Store.commit({ ...prepared }), /官方商店/, 'forged packages must not install');
  Store.commit(prepared);
  assert.equal(Store.load()[0].manifest.version, '1.0.0');
  assert.ok(seen.some(url => url.startsWith('https://api.github.com/')));
  assert.ok(seen.some(url => url.startsWith('https://gh-proxy.com/')), 'hash-checked file mirror should work');
  assert.ok(!seen.filter(url => url.includes('index.json')).some(url => url.startsWith('https://gh-proxy.com/')),
    'third-party mirror must never supply executable index authority');
  const savedPath = path.join(directory, 'qg_verified_modules/test.json');
  const previous = fs.readFileSync(savedPath, 'utf8');
  fixture = packageFor('1.0.1');
  entries = await Store.index();
  assert.equal(entries[0].hasUpdate(), true);
  brokenAsset = true;
  await assert.rejects(Store.download(entries[0]), /校验不符/);
  assert.equal(fs.readFileSync(savedPath, 'utf8'), previous, 'failed download preserves old package');
  brokenAsset = false;
  const correctManifest = fixture.manifest;
  const correctManifestHash = fixture.entry.sha256['manifest.json'];
  fixture.manifest = fixture.manifest.replace('"id":"test"', '"id":"other"');
  fixture.entry.sha256['manifest.json'] = digest(fixture.manifest);
  entries = await Store.index();
  await assert.rejects(Store.download(entries[0]), /索引不符/, 'hashes alone cannot authorize a different module identity');
  fixture.manifest = correctManifest;
  fixture.entry.sha256['manifest.json'] = correctManifestHash;
  entries = await Store.index();
  const upgrade = await Store.download(entries[0]);
  failRename = true;
  assert.throws(() => Store.commit(upgrade), /保存站源文件失败/);
  assert.equal(fs.readFileSync(savedPath, 'utf8'), previous, 'failed persistence preserves old package');
  assert.equal(Store.load()[0].manifest.version, '1.0.0');
  failRename = false;
  Store.commit(upgrade);
  assert.equal(Store.load()[0].manifest.version, '1.0.1');
  Store.saveState('test', 'session', 'opaque state');
  assert.equal(Store.loadState('test', 'session'), 'opaque state');
  assert.throws(() => Store.saveState('test', '../escape', 'bad'), /状态名/);
  assert.throws(() => Store.saveState('../escape', 'session', 'bad'), /存储不可用/);
  assert.throws(() => Store.saveState('test', 'session', 'a'.repeat(256 * 1024 + 1)), /状态过大/);
  for (let index = 0; index < 31; index++) Store.saveState('test', 'part' + index, 'tiny');
  assert.throws(() => Store.saveState('test', 'overflow', 'tiny'), /存储已达上限/);
  Store.saveState('test', 'session', 'opaque state');
  assert.equal(Entry.fromObject({ ...fixture.entry, api: 2 }), null);
  assert.equal(Entry.fromObject({ ...fixture.entry, repo: 'attacker/test' }), null);
  assert.equal(Entry.fromObject({ ...fixture.entry, tag: 'v9.0.0' }), null);
  assert.throws(() => Manifest.parse(fixture.manifest.replace('"example.com"', '"127.0.0.1"')), /声明无效/);
  assert.throws(() => Manifest.parse(fixture.manifest.replace('"api":1', '"api":2')), /不兼容/);
  assert.equal(Store.compareVersion('1.10.0', '1.9.9'), 1);
  assert.equal(Store.compareVersion('1.0.0', '1.0.0'), 0);
  delete require.cache[storePath];
  Store = require(storePath).QgModuleStore;
  Store.init(directory);
  assert.equal(Store.load()[0].manifest.version, '1.0.1', 'verified installed package survives restart');
  Store.remove('test');
  assert.equal(Store.load().length, 0);
  assert.equal(fs.existsSync(savedPath), false);
  assert.equal(Store.loadState('test', 'session'), 'opaque state', 'uninstall preserves source user state');
  console.log('PASS trusted index, manifest/hash checks, mirror fallback, two-phase install, atomic rollback, restart and namespaced state');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  Module._load = originalLoad;
  fs.rmSync(directory, { recursive: true, force: true });
});
