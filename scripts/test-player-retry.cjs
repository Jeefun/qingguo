// Exercises the actual player methods with a deterministic timer and media gateway.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
const file = path.resolve(__dirname, '../entry/src/main/ets/pages/PlayerPage.ets');
const source = fs.readFileSync(file, 'utf8');
// ArkUI's struct/build syntax is platform-specific; parse just the unchanged method bodies.
function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, `Missing ${name}`);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}
const code = ts.transpileModule(`class Player {
  ${method('applyRoute')}
  ${method('onVideoError')}
  ${method('retryFromStart')}
}
globalThis.Player = Player;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
let timers = [];
const logs = [];
const context = vm.createContext({
  setTimeout: callback => { timers.push(callback); return timers.length; },
  QgGateway: {}, QgDiag: { log: (tag, message) => logs.push(message) }
});
vm.runInContext(code, context);
function player() {
  timers = [];
  const p = new context.Player();
  Object.assign(p, { routes: ['https://media.test/a.mp4', 'https://media.test/b.mp4'],
    routeIdx: 0, playUrl: '', playAttempt: 0, autoRetried: false, curSec: 12,
    episode: 1, lastInfo: { headers: {}, referer: '', cencKey: '' } });
  p.applyRoute(0, true);
  return p;
}
const error = { code: 5400106, message: 'Unsupported format' };
let p = player();
p.onVideoError(error);
assert.equal(p.playUrl, '', 'failed Video must be removed before retry');
assert.equal(timers.length, 1);
timers.shift()();
assert.equal(p.playUrl, p.routes[0]);
assert.equal(p.pendingResumeSec, 12);
assert.equal(p.autoRetried, true);
p.onVideoError(error);
assert.equal(p.playFailed, true);
assert.equal(timers.length, 0, 'persistent errors must not create an endless loop');
assert.match(p.playbackError, /5400106/);
assert.ok(logs.some(line => line.includes('5400106')));
console.log('PASS retries once, preserves position, then exposes engine error');
p.applyRoute(1, false);
assert.equal(p.autoRetried, false);
assert.equal(p.playFailed, false);
p.onVideoError(error);
assert.equal(timers.length, 1);
console.log('PASS manual route switch grants one fresh retry');
p = player();
p.onVideoError(error);
p.applyRoute(1, false);
const nextAttempt = p.playAttempt;
timers.shift()();
assert.equal(p.playAttempt, nextAttempt);
assert.equal(p.playUrl, p.routes[1]);
console.log('PASS stale retry cannot replace a manually selected route');
p = player();
p.onVideoError(error);
p.playAttempt++; // aboutToDisappear invalidates the pending callback.
timers.shift()();
assert.equal(p.playUrl, '');
console.log('PASS leaving player cancels pending retry');
p = player();
p.pendingResumeSec = 35;
p.retryFromStart();
assert.equal(p.pendingResumeSec, 0, 'retryFromStart must drop the resume position');
assert.equal(p.curSec, 0);
assert.equal(p.playUrl, p.routes[p.routeIdx], 'retryFromStart replays the same route');
assert.equal(p.playFailed, false);
console.log('PASS restart after failure opens the same episode from zero');
