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
stub('data/QgHttp.ets', { QgHttp: {} });
stub('data/QgGateway.ets', { QgGateway: {} });
stub('data/QgDiag.ets', { QgDiag: { log() {} } });
stub('data/QgModuleHost.ets', { QgModuleHost: class {
  beginCall() {} handle() {} setKnown() {} validateCoverUrl() {} async validateMediaUrl() {}
} });
const { QgDrama, QgSeason, QgAppSettings } = require(path.join(root, 'model/QgModels.ets'));
const { QgSource, QgSourceManager } = require(path.join(root, 'data/source/QgSource.ets'));

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
stub('data/QgModuleStore.ets', { QgModuleStore: { installed: () => [] } });
const settings = new QgAppSettings();
stub('data/QgStore.ets', { QgStore: { getInstance: () => ({
  getSettings: () => settings, updateSettings: next => Object.assign(settings, next)
}) } });
const values = new Map();
global.AppStorage = { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) };

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
  const repositoryPath = path.join(root, 'data/QgRepository.ets');
  const custom = new class extends QgSource {
    constructor() { super('demo', 'Demo'); } async detail() { throw Error('Unused'); } async play() { throw Error('Unused'); }
  }();
  let queries = 0;
  let output = [];
  custom.seasons = async () => { queries++; return output; };
  QgSourceManager.register(custom);
  const freshRepository = () => {
    delete require.cache[repositoryPath];
    const { QgRepository: Repository } = require(repositoryPath);
    Repository.init();
    return Repository;
  };
  const Repository = freshRepository();
  const anchor = new QgDrama('demo:first', '', '');
  const list = [new QgSeason(2, new QgDrama('demo:second', 'Second', '')),
    new QgSeason(1, new QgDrama('demo:first', 'First', ''))];
  output = list;
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
  output = [list[0]];
  let Invalid = freshRepository();
  assert.deepEqual(await Invalid.seasons(anchor), [], 'current anchor must appear and there must be multiple seasons');
  for (const invalid of [[list[1], list[1]], [new QgSeason(1, new QgDrama('other:first', 'Bad', '')), list[0]],
    [new QgSeason(1.5, new QgDrama('demo:first', 'Bad', '')), list[0]]]) {
    Invalid = freshRepository();
    output = invalid;
    await assert.rejects(Invalid.seasons(anchor), /无效|重复/);
  }
  output = [];
  await assert.rejects(freshRepository().seasons(new QgDrama('nomodule:42', '', '')), /未找到该剧所属的站源/, 'unregistered sources expose no seasons');
  console.log('PASS repository sort/cache, anchor/duplicate/source validation and cross-source isolation');
}

(async () => { await moduleTests(); await repositoryTests(); })().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => { Module._load = originalLoad; delete global.AppStorage; });
