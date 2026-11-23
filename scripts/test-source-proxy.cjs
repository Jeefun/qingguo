// Tests per-source proxy support: QgStore.resolveProxyFor / parseSettings,
// QgHttp.resolveProxy, QgGateway src-param threading, PlayerPage sourceIdOf/applyRoute.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
const root = path.resolve(__dirname, '..');
const ets = relative => fs.readFileSync(path.join(root, relative), 'utf8');

// Extracts a full method (any qualifier combination) from an .ets file.
function extract(source, name) {
  const re = new RegExp(`^  (?:private |public )?(?:static )?(?:async )?${name}\\(`, 'm');
  const match = re.exec(source);
  assert.ok(match, `Missing method ${name}`);
  const start = match.index;
  const end = source.indexOf('\n  }', start) + 4;
  assert.ok(end > start, `Unterminated method ${name}`);
  return source.slice(start, end);
}
function transpile(code) {
  return ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
}
function run(code, globals) {
  const sandbox = Object.assign({ console }, globals);
  vm.createContext(sandbox);
  vm.runInContext(transpile(code), sandbox);
  return sandbox;
}

// ---------- Part 1: QgStore.resolveProxyFor ----------
const storeSrc = ets('entry/src/main/ets/data/QgStore.ets');
const store = run(`
class QgHttpProxy { constructor() { this.enabled = false; this.host = ''; this.port = 7890; } }
class QgSourceProxy { constructor(mode, host, port) { this.mode = mode; this.host = host ?? ''; this.port = port ?? 7890; } }
class Store {
  ${extract(storeSrc, 'resolveProxyFor')}
  ${extract(storeSrc, 'copySourceProxies')}
}
globalThis.Store = Store; globalThis.QgHttpProxy = QgHttpProxy; globalThis.QgSourceProxy = QgSourceProxy;
`, {
  QgHttp: { proxy: { enabled: true, host: '10.0.0.1', port: 1080 } }
});
const s = new store.Store();
s.settings = {
  sourceProxies: {
    hongguo: new store.QgSourceProxy('direct'),
    huangju: new store.QgSourceProxy('manual', '127.0.0.1', 8888),
    yeguo: new store.QgSourceProxy('manual', '', 8888)
  }
};
let p = s.resolveProxyFor('hongguo');
assert.equal(p.enabled, false, 'direct override must disable the proxy');
p = s.resolveProxyFor('huangju');
assert.equal(p.enabled, true);
assert.equal(p.host, '127.0.0.1');
assert.equal(p.port, 8888);
p = s.resolveProxyFor('yeguo');
assert.equal(p.host, '10.0.0.1', 'manual override without host falls back to the global proxy');
p = s.resolveProxyFor('beitao');
assert.equal(p.host, '10.0.0.1', 'unattributed source follows the global proxy');
p = s.resolveProxyFor('');
assert.equal(p.host, '10.0.0.1', 'empty source follows the global proxy');
// copySourceProxies deep-copies overrides so later mutation cannot leak into settings.
const copied = store.Store.copySourceProxies ? store.Store.copySourceProxies(s.settings.sourceProxies) : null;
assert.ok(copied, 'copySourceProxies exists');
copied.huangju.host = 'changed';
assert.equal(s.settings.sourceProxies.huangju.host, '127.0.0.1', 'copySourceProxies must deep-copy');
console.log('PASS resolveProxyFor: direct/manual/global fallback and deep copy');

// ---------- Part 2: QgHttp.resolveProxy ----------
const httpSrc = ets('entry/src/main/ets/data/QgHttp.ets');
const httpSandbox = run(`
class QgHttpProxy { constructor(enabled, host, port) { this.enabled = enabled; this.host = host; this.port = port; } }
class QgHttp {
  static proxy = globalThis.globalProxy;
  static proxyResolver = null;
  ${extract(httpSrc, 'resolveProxy')}
}
globalThis.QgHttp = QgHttp;
`, { globalProxy: { enabled: true, host: '10.0.0.1', port: 1080 } });
const QgHttp = httpSandbox.QgHttp;
let resolved = QgHttp.resolveProxy('hongguo');
assert.equal(resolved.host, '10.0.0.1', 'no resolver registered falls back to the global proxy');
QgHttp.proxyResolver = sourceId => {
  if (sourceId === 'hongguo') {
    return { enabled: false, host: '', port: 7890 };
  }
  if (sourceId === 'huangju') {
    return { enabled: true, host: '127.0.0.1', port: 8888 };
  }
  return QgHttp.proxy;
};
resolved = QgHttp.resolveProxy('hongguo');
assert.equal(resolved.enabled, false, 'resolver override wins for the given source');
resolved = QgHttp.resolveProxy('huangju');
assert.equal(resolved.port, 8888);
resolved = QgHttp.resolveProxy('other');
assert.equal(resolved.host, '10.0.0.1', 'resolver decides fallback for other sources');
resolved = QgHttp.resolveProxy('');
assert.equal(resolved.host, '10.0.0.1', 'empty source skips the resolver entirely');
console.log('PASS QgHttp.resolveProxy: resolver registration and empty-source shortcut');

// ---------- Part 3: QgStore.parseSettings validation ----------
const parseSandbox = run(`
class QgSourceProxy { constructor() { this.mode = 'follow'; this.host = ''; this.port = 7890; } }
class QgAppSettings {
  constructor() {
    this.colorMode = 'system'; this.sourceId = 'hongguo'; this.autoPlay = true; this.autoNext = true;
    this.directPlay = false; this.playSpeed = 1; this.videoAspect = 'original'; this.danmakuOn = true;
    this.danmakuOpacity = 80; this.danmakuFontSize = 100; this.danmakuArea = 75; this.danmakuBlockWords = [];
    this.downloadWifiOnly = true; this.downloadParallel = 2; this.proxyOn = false; this.proxyHost = '';
    this.proxyPort = 7890; this.sourceProxies = {}; this.homeContinue = true; this.homeRank = true;
    this.homeRecommendations = true;
  }
}
class QgStore {
  ${extract(storeSrc, 'parseSettings')}
}
globalThis.QgStore = QgStore;
`, {});
const raw = JSON.stringify({
  sourceProxies: {
    hongguo: { mode: 'direct' },
    huangju: { mode: 'manual', host: '192.168.1.9', port: 7891 },
    Invalid_ID: { mode: 'direct' },
    yeguo: { mode: 'follow' },
    cloudfront: { mode: 'manual', host: '', port: 7890 },
    heitao: { mode: 'weird' },
    jinguo: { mode: 'manual', host: 'h', port: 99999 },
    beabox: { mode: 'manual', host: 'h' },
    dsd: { mode: 'manual', host: 'h', port: 'abc' }
  }
});
const parsed = parseSandbox.QgStore.parseSettings(raw);
assert.deepEqual(Object.keys(parsed.sourceProxies).sort(), ['beabox', 'hongguo', 'huangju'],
  'only valid per-source overrides survive parsing');
assert.equal(parsed.sourceProxies.hongguo.mode, 'direct');
assert.equal(parsed.sourceProxies.huangju.host, '192.168.1.9');
assert.equal(parsed.sourceProxies.huangju.port, 7891);
assert.equal(parsed.sourceProxies.beabox.port, 7890, 'manual entry without port defaults to 7890');
assert.equal(typeof parseSandbox.QgStore.parseSettings('').sourceProxies, 'object',
  'empty settings yields defaults');
console.log('PASS parseSettings: rejects bad ids/modes/hosts/ports, keeps valid overrides');

// ---------- Part 4: QgGateway src-param threading ----------
const gatewaySrc = ets('entry/src/main/ets/data/QgGateway.ets');
const sessionCalls = [];
const gatewaySandbox = run(`
const GATEWAY_HOST = '127.0.0.1';
class QgGateway {
  static port = 8080;
  static token = 'tok';
  static cleanMediaHeaders(headers) { return Object.assign({}, headers); }
  static storeMediaSession(headers, playlist, upstream, hlsKey, sourceId) {
    globalThis.sessionCalls.push([playlist, sourceId]);
    return 'SESS';
  }
  static endpoint() { return 'http://' + GATEWAY_HOST + ':8080'; }
  static isHttpUrl(raw) { return raw.startsWith('http'); }
  ${extract(gatewaySrc, 'buildSessionUrl')}
  ${extract(gatewaySrc, 'buildUrl')}
  ${extract(gatewaySrc, 'headerOf')}
  ${extract(gatewaySrc, 'fileNameOf')}
}
globalThis.QgGateway = QgGateway;
`, { sessionCalls });
const QgGateway = gatewaySandbox.QgGateway;
let url = QgGateway.buildSessionUrl('http://up.media/a.m3u8', 's1', 'hongguo');
assert.match(url, /\/f\/a\.m3u8\?u=.+&s=s1&src=hongguo$/, 'session URL carries the src param');
url = QgGateway.buildSessionUrl('http://up.media/a.m3u8', 's1', '');
assert.ok(!url.includes('src='), 'empty source id omits the src param');
url = QgGateway.buildUrl('http://up.media/a.mp4', { 'Referer': 'https://r.test/' }, 'huangju');
assert.match(url, /\/f\/a\.mp4\?u=.+&r=https%3A%2F%2Fr\.test%2F&src=huangju$/,
  'inline gateway URL carries the src param');
url = QgGateway.buildUrl('http://up.media/a.mp4', { 'Referer': 'https://r.test/', 'Cookie': 'x=1' }, 'hongguo');
assert.match(url, /&s=SESS&src=hongguo$/, 'session-branch URL carries the src param');
const lastSessionCall = sessionCalls[sessionCalls.length - 1];
assert.equal(lastSessionCall.length, 2);
assert.equal(lastSessionCall[0], '');
assert.equal(lastSessionCall[1], 'hongguo', 'storeMediaSession receives the source id');
url = QgGateway.buildUrl('http://up.media/a.mp4', { 'Referer': 'https://r.test/' }, '');
assert.ok(!url.includes('src='), 'buildUrl omits src for empty source id');
// Request path wiring (checked against source text): src -> c.sourceId, c.sourceId -> resolved proxy.
assert.ok(gatewaySrc.includes("c.sourceId = query['src'] ?? ''"), 'handleRequest reads the src param');
assert.ok(gatewaySrc.includes('QgHttp.resolveProxy(c.sourceId)'), 'proxy() resolves the proxy per source');
assert.ok(gatewaySrc.includes('session.sourceId = sourceId;') && gatewaySrc.includes('c.sourceId = session.sourceId;'),
  'sessions carry and restore the source id');
console.log('PASS QgGateway: src param on session/inline/dec URLs and per-source proxy resolution');

// ---------- Part 5: PlayerPage passes the drama source id ----------
const playerSrc = ets('entry/src/main/ets/pages/PlayerPage.ets');
const gatewayCalls = [];
const playerSandbox = run(`
class Player {
  ${extract(playerSrc, 'applyRoute')}
  ${extract(playerSrc, 'sourceIdOf')}
}
globalThis.Player = Player;
`, {
  QgGateway: {
    mediaUrl: (...args) => { gatewayCalls.push(['mediaUrl', args]); return args[0]; },
    decryptedMediaUrl: (...args) => { gatewayCalls.push(['decryptedMediaUrl', args]); return args[0]; }
  }
});
function player(dramaId, cencKey) {
  gatewayCalls.length = 0;
  const p = new playerSandbox.Player();
  Object.assign(p, {
    dramaId, routes: ['http://media.test/a.mp4'], routeIdx: 0, playUrl: '', playAttempt: 0,
    autoRetried: false, curSec: 0, episode: 1, loadErr: '',
    lastInfo: { headers: {}, referer: '', cencKey: cencKey ?? '' }
  });
  return p;
}
let pp = player('hongguo:8812');
pp.applyRoute(0, true);
assert.equal(gatewayCalls.length, 1);
assert.equal(gatewayCalls[0][0], 'mediaUrl');
assert.equal(gatewayCalls[0][1][2], 'hongguo', 'plain media passes the drama source id');
pp = player('hongguo:8812', '00112233445566778899aabbccddeeff');
pp.applyRoute(0, true);
assert.equal(gatewayCalls[0][0], 'decryptedMediaUrl');
assert.equal(gatewayCalls[0][1][3], 'hongguo', 'CENC media passes the drama source id');
pp = player('huangju:7');
assert.equal(pp.sourceIdOf(), 'huangju');
pp = player('nocolon');
assert.equal(pp.sourceIdOf(), '', 'drama id without a colon yields an empty source id');
// prewarm also threads the source id (source text check).
assert.ok(playerSrc.includes('QgGateway.prewarmDecrypted(upstream, headers, info.cencKey, this.sourceIdOf())'),
  'prewarmDecrypted passes the source id');
console.log('PASS PlayerPage: media/CENC/prewarm calls carry the drama source id');

// ---------- Part 6: module host and per-source HTTP calls ----------
const hostSrc = ets('entry/src/main/ets/data/QgModuleHost.ets');
assert.ok(hostSrc.includes('QgHttp.resolveProxy(this.pkg.manifest.id).enabled'),
  'module host DNS fast-path respects the per-source proxy');
assert.ok(hostSrc.includes('this.pkg.manifest.id);'),
  'module host fetch passes the module id to QgHttp.request');
const sourceDir = path.join(root, 'entry/src/main/ets/data/source');
const SOURCE_IDS = {
  'BeaboxSource.ets': 'this.id', 'DsdSource.ets': 'this.id', 'GuipianSource.ets': 'this.id',
  'HanxiaoquanSource.ets': 'this.id', 'HeitaoSource.ets': 'this.id', 'HongguoSource.ets': "'hongguo'",
  'HongguoDanmaku.ets': "'hongguo'", 'HuangdouSource.ets': 'this.id', 'HuangguoaiSource.ets': 'this.id',
  'HuangguoVideoSource.ets': 'this.id', 'HuangjuSource.ets': "'huangju'",
  'JinguoduanjuSource.ets': "'jinguoduanju'", 'JinguoSource.ets': "this.id", 'LegacySource.ets': "'cloudfront'",
  'SoraniSource.ets': 'this.id', 'YeguoSource.ets': 'this.id'
};
for (const [file, id] of Object.entries(SOURCE_IDS)) {
  const src = fs.readFileSync(path.join(sourceDir, file), 'utf8');
  assert.ok(src.includes(`, ${id});`) || src.includes(`, ${id},`),
    `${file} must pass ${id} as the QgHttp sourceId`);
}
console.log('PASS module host and all station sources pass their source id to QgHttp');

console.log('PASS all per-source proxy tests');
