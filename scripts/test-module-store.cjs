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
const rawRoot = path.join(directory, 'rawfile');
const root = path.resolve(__dirname, '../entry/src/main/ets');
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
  renameSync: (source, target) => fs.renameSync(source, target),
  unlinkSync: target => fs.unlinkSync(target)
};
const context = {
  filesDir: directory,
  resourceManager: {
    getRawFileListSync: parent => fs.readdirSync(path.join(rawRoot, parent)),
    getRawFileContentSync: relative => new Uint8Array(fs.readFileSync(path.join(rawRoot, relative)))
  }
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
const storePath = path.join(root, 'data/QgModuleStore.ets');
const { QgModuleStore: Store, QgModuleManifest: Manifest } = require(storePath);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const codeOf = id => `module.exports = { categories() { return []; } }; /* ${id} */`;
const manifestOf = (id, version) => JSON.stringify({ id, name: 'Module ' + id, version,
  description: 'Example', adult: false, runtime: 'js', api: 1,
  hosts: ['example.com', '*.example.net'], capabilities: ['search'] });
const archiveOf = id => JSON.stringify({ manifest: manifestOf(id, '1.0.0'), code: codeOf(id),
  manifestHash: digest(manifestOf(id, '1.0.0')), entryHash: digest(codeOf(id)) });
function bundle(id, version = '1.0.0') {
  const dir = path.join(rawRoot, 'modules', id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'manifest.json'), manifestOf(id, version));
  fs.writeFileSync(path.join(dir, 'main.js'), codeOf(id));
}
async function run() {
  assert.equal(Store.compareVersion('1.10.0', '1.9.9'), 1);
  assert.equal(Store.compareVersion('1.0.0', '1.0.0'), 0);
  assert.equal(Store.compareVersion('1.0.9', '1.0.10'), -1);
  assert.throws(() => Manifest.parse(manifestOf('test', '1.0.0').replace('"example.com"', '"127.0.0.1"')), /声明无效/);
  assert.throws(() => Manifest.parse(manifestOf('test', '1.0.0').replace('"api":1', '"api":2')), /不兼容/);
  assert.throws(() => Manifest.parse(manifestOf('test', '1.0.0').replace('"search"', '"flight"')), /声明无效/);
  assert.equal(Store.installed().length, 0, 'init has not run yet');
  bundle('hongguo', '1.0.6');
  bundle('demo');
  bundle('mismatch', '1.0.0');
  fs.writeFileSync(path.join(rawRoot, 'modules', 'mismatch', 'manifest.json'), manifestOf('other', '1.0.0'));
  bundle('upper');
  fs.rmSync(path.join(rawRoot, 'modules', 'upper'), { recursive: true, force: true });
  fs.mkdirSync(path.join(rawRoot, 'modules', 'UPPER'));
  Store.init(context);
  const versions = Object.fromEntries(Store.installed().map(pkg => [pkg.manifest.id, pkg.manifest.version]));
  assert.equal(versions.hongguo, '1.0.6', 'bundled module installs into sandbox');
  assert.equal(versions.demo, '1.0.0');
  assert.equal(versions.mismatch, undefined, 'manifest id must match its directory name');
  assert.equal(versions.UPPER, undefined, 'non-lowercase directory names are rejected');
  assert.equal(Store.installed().length, 2);
  assert.ok(fs.existsSync(path.join(directory, 'qg_verified_modules', 'hongguo.json')));
  const saved = JSON.parse(fs.readFileSync(path.join(directory, 'qg_verified_modules', 'demo.json'), 'utf8'));
  assert.equal(saved.entryHash, digest(codeOf('demo')), 'archive stores content hashes');
  assert.equal(saved.code, codeOf('demo'));
  Store.saveState('demo', 'session', 'opaque state');
  assert.equal(Store.loadState('demo', 'session'), 'opaque state');
  assert.throws(() => Store.saveState('demo', '../escape', 'bad'), /状态名/);
  assert.throws(() => Store.saveState('../escape', 'session', 'bad'), /存储不可用/);
  assert.throws(() => Store.saveState('demo', 'session', 'a'.repeat(256 * 1024 + 1)), /状态过大/);
  for (let index = 0; index < 31; index++) Store.saveState('demo', 'part' + index, 'tiny');
  assert.throws(() => Store.saveState('demo', 'overflow', 'tiny'), /存储已达上限/);
  delete require.cache[storePath];
  const RestartedStore = require(storePath).QgModuleStore;
  fs.writeFileSync(path.join(rawRoot, 'modules', 'demo', 'main.js'), 'tampered but newer rawfile is not reinstalled');
  const sandboxDemo = path.join(directory, 'qg_verified_modules', 'demo.json');
  fs.writeFileSync(sandboxDemo, archiveOf('demo').replace('1.0.0', '9.9.9').replace('"api":1', '"api":1'));
  const higher = JSON.parse(fs.readFileSync(sandboxDemo, 'utf8'));
  const repaired = JSON.stringify({ ...higher, manifest: higher.manifest, manifestHash: digest(higher.manifest) });
  fs.writeFileSync(sandboxDemo, repaired);
  const offlineContext = { filesDir: directory, resourceManager: { getRawFileListSync: () => {
    throw new Error('rawfile unavailable');
  }, getRawFileContentSync: () => {
    throw new Error('rawfile unavailable');
  } } };
  RestartedStore.init(offlineContext);
  const afterRestart = Object.fromEntries(RestartedStore.installed().map(pkg => [pkg.manifest.id, pkg.manifest.version]));
  assert.equal(afterRestart.demo, '9.9.9', 'newer sandbox version survives restart');
  assert.equal(afterRestart.hongguo, '1.0.6', 'sandbox archive loads without rawfile');
  fs.rmSync(path.join(directory, 'qg_verified_modules', 'hongguo.json'));
  fs.writeFileSync(path.join(directory, 'qg_verified_modules', 'corrupt.json'), '{ broken json');
  delete require.cache[storePath];
  const ThirdStore = require(storePath).QgModuleStore;
  ThirdStore.init(context);
  const ids = ThirdStore.installed().map(pkg => pkg.manifest.id).sort();
  assert.deepEqual(ids, ['demo', 'hongguo'], 'bundled root re-installs removed modules and skips corrupt archives');
  assert.equal(ThirdStore.loadState('demo', 'session'), 'opaque state', 're-install preserves module user state');
  console.log('PASS bundled install, id verification, sandbox persistence, higher-version retention, corrupt archive skip and namespaced state');
}
run().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  Module._load = originalLoad;
  fs.rmSync(directory, { recursive: true, force: true });
});
