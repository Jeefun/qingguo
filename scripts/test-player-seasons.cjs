const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');

const filename = path.resolve(__dirname, '../entry/src/main/ets/pages/PlayerPage.ets');
const source = fs.readFileSync(filename, 'utf8');
const privateMethods = Array.from(source.matchAll(/^  private (?:async )?([A-Za-z_$][\w$]*)\(/gm));
const methods = privateMethods.map(match => {
  const end = source.indexOf('\n  }', match.index);
  assert.ok(end > match.index, `Unterminated player method ${match[1]}`);
  return source.slice(match.index, end + 4);
});
function lifecycle(name) {
  const start = source.indexOf(`  ${name}(): void {`);
  assert.ok(start >= 0, `Missing player lifecycle ${name}`);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const constants = source.slice(source.indexOf('const PLAYER_TAG'), source.indexOf('@Component'));
const videoEvents = [
  ['Prepared', 'info'], ['Update', 'event'], ['Start', 'unused'], ['Pause', 'unused'], ['Finish', 'unused'], ['Error', 'error']
].map(([name, argument]) => {
  const start = source.indexOf(`.on${name}(`, source.indexOf('  StageBuilder()'));
  const bodyStart = source.indexOf('=> {', start) + '=> {'.length;
  const bodyEnd = source.indexOf('\n          })', bodyStart);
  assert.ok(start >= 0 && bodyEnd > bodyStart, `Missing Video ${name} event`);
  return `event${name}(identity: string, ${argument}: Object = {}) {${source.slice(bodyStart, bodyEnd)}\n}`;
});
const code = ts.transpileModule(`${constants}\nclass Player {\n${methods.join('\n')}\n${lifecycle('aboutToDisappear')}\n${videoEvents.join('\n')}\n}\nglobalThis.Player = Player;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

const watches = new Map();
const saved = [];
const calls = { detail: [], play: [], seasons: [], prewarm: [] };
let timers = [];
let settings;
let detailHandler;
let playHandler;
let seasonsHandler;
let gatewayHandler;
const storage = new Map();
const store = {
  getSettings: () => settings,
  getWatch: id => watches.get(id),
  saveWatch: record => {
    const copy = JSON.parse(JSON.stringify(record));
    watches.set(copy.dramaId, copy);
    saved.push(copy);
  }
};
const context = vm.createContext({
  setTimeout: callback => { timers.push(callback); return timers.length; },
  clearTimeout: timer => { timers[timer - 1] = undefined; },
  QgStore: { getInstance: () => store },
  QgRepository: {
    detail: id => { calls.detail.push(id); return detailHandler(id); },
    play: (id, episode) => { calls.play.push({ id, episode }); return playHandler(id, episode); },
    seasons: drama => { calls.seasons.push(drama.id); return seasonsHandler(drama); }
  },
  QgGateway: {
    ready: () => gatewayHandler(),
    isRunning: () => true,
    mediaUrl: url => url,
    decryptedMediaUrl: url => url,
    prewarmDecrypted: async (...args) => { calls.prewarm.push(args); return new Uint8Array(); }
  },
  QgDiag: { log() {} }, hilog: { info() {} },
  QgWatchRecord: class {}, QgAppSettings: class {},
  QgDrama: class { constructor(id, title, genre) { this.id = id; this.title = title; this.genre = genre; } },
  AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) }
});
vm.runInContext(code, context, { filename });

const makeDrama = number => ({ id: `hongguo:${number}`, sourceId: 'hongguo', title: `Season ${number}`,
  cover: `https://cover.test/${number}.jpg`, episodeCount: 3, finished: true });
const seasonList = [1, 2, 3].map(number => ({ number, drama: makeDrama(number) }));
const makeDetail = number => ({ drama: makeDrama(number), episodes: [1, 2, 3].map(order => ({
  id: `hongguo:${number}:e${order}`, title: `Episode ${order}`, order
})) });
const media = (id, episode) => ({ url: `https://media.test/${id}/${episode}.mp4`, referer: '', headers: {},
  durationMs: 600000, danmakuId: '', routes: [], routeIndex: 0, qualities: [], quality: 0, cencKey: '' });
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const settle = async () => { for (let index = 0; index < 5; index++) await new Promise(resolve => setImmediate(resolve)); };
function reset() {
  watches.clear(); saved.length = 0; storage.clear(); timers = [];
  for (const entries of Object.values(calls)) entries.length = 0;
  settings = { autoPlay: true, autoNext: true, danmakuOn: false, danmakuBlockWords: [] };
  detailHandler = async id => makeDetail(Number(id.split(':')[1]));
  playHandler = async (id, episode) => media(id, episode);
  seasonsHandler = async () => seasonList;
  gatewayHandler = async () => {};
}
function player() {
  const player = new context.Player();
  const current = makeDetail(1);
  const operations = [];
  Object.assign(player, {
    pageActive: true, contentGeneration: 1, seasonRequest: 0, seasonListRequest: 0,
    seasons: seasonList, seasonsLoading: false, seasonsError: '', seasonSwitchError: '', switchingSeason: false,
    seasonsExpanded: false, advanceWhenSeasonsReady: false,
    dramaId: current.drama.id, drama: current.drama, episodes: current.episodes, episode: 2,
    curSec: 125, totalSec: 600, playing: true, playUrl: 'https://media.test/old.mp4',
    playAttempt: 4, autoRetried: false, lastSavedSec: 125, prewarmedOrder: 3,
    preloadedPlay: new Map([['old', media('hongguo:1', 'old')]]),
    lastInfo: media('hongguo:1', 'e2'), routes: ['https://media.test/old.mp4'], routeIdx: 0,
    qualities: [720], quality: 720, danmakuId: 'old', danmakuOn: false, danmakuStatus: '',
    pendingPlay: false, pendingResumeSec: 0, sheetOpen: true, controlsShown: true,
    resolving: false, loadErr: '', playFailed: false, playbackError: '',
    speedBoost: false, seekDragging: false, panMode: 0, hideTimer: -1,
    controller: {
      stop: () => operations.push('stop'), pause: () => operations.push('pause'),
      start: () => operations.push('start'), setCurrentTime: value => operations.push(['seek', value])
    },
    danmakuCtl: { setSource: (...args) => operations.push(['danmaku', ...args]),
      update() {}, setDanmakuOn() {}, setBlockWords() {}, statusText: () => '' },
    toast: text => operations.push(['toast', text]),
    restoreOrientation() {}, restoreBrightness() {}, applyPlayerBar() {},
    setupDanmaku() {}, driveDanmaku() {},
    operations
  });
  return player;
}

async function testManualResume() {
  reset();
  watches.set('hongguo:2', { dramaId: 'hongguo:2', episode: 3, progress: 72, duration: 600 });
  const target = deferred();
  detailHandler = id => id === 'hongguo:2' ? target.promise : Promise.resolve(makeDetail(Number(id.split(':')[1])));
  const current = player();
  const previousAttempt = current.playAttempt;
  const switched = current.selectSeason(seasonList[1]);
  await settle();
  assert.equal(saved[0].dramaId, 'hongguo:1');
  assert.equal(saved[0].episode, 2);
  assert.equal(saved[0].progress, 125, 'old season position must save before identity changes');
  assert.equal(current.dramaId, 'hongguo:1', 'target identity commits only after detail succeeds');
  assert.equal(current.switchingSeason, true);
  target.resolve(makeDetail(2));
  await switched;
  await settle();
  assert.equal(current.dramaId, 'hongguo:2');
  assert.equal(current.episode, 3);
  assert.equal(current.pendingResumeSec, 72, 'manual season switch resumes target season position');
  assert.equal(current.seasonSwitchError, '');
  assert.equal(current.switchingSeason, false);
  assert.ok(current.playAttempt > previousAttempt, 'committing target cancels pending old-season retry callbacks');
  assert.equal(current.preloadedPlay.has('old'), false);
  assert.equal(current.danmakuId, '');
  assert.ok(current.playUrl.includes('hongguo:2'));
  assert.deepEqual(calls.play.map(call => call.id), ['hongguo:2']);
  assert.equal(watches.get('hongguo:1').progress, 125);
  assert.equal(watches.get('hongguo:2').progress, 72);
  current.eventPrepared(current.videoIdentity(), { duration: 600 });
  assert.equal(current.pendingResumeSec, 0);
  assert.equal(current.curSec, 72, 'prepared callback seeks to target season watch position');
  assert.ok(current.operations.some(operation => Array.isArray(operation) && operation[0] === 'seek' && operation[1] === 72));
  console.log('PASS manual season switching preserves old progress and resumes target season');
}

async function testFailedSwitch() {
  reset();
  detailHandler = async () => { throw new Error('target unavailable'); };
  const current = player();
  await current.selectSeason(seasonList[1]);
  await settle();
  assert.equal(current.dramaId, 'hongguo:1');
  assert.equal(current.drama.id, 'hongguo:1');
  assert.equal(current.episode, 2);
  assert.match(current.seasonSwitchError, /target unavailable/);
  assert.equal(current.switchingSeason, false);
  assert.equal(watches.get('hongguo:1').progress, 125);
  assert.equal(calls.play.length, 0, 'failed target detail must not request target media');
  detailHandler = async () => ({ drama: makeDrama(2), episodes: [] });
  await current.selectSeason(seasonList[1]);
  assert.equal(current.dramaId, 'hongguo:1');
  assert.ok(current.seasonSwitchError.length > 0);
  assert.equal(calls.play.length, 0);
  console.log('PASS failed or empty season keeps current identity and watch record');
}

async function testAutomaticAdvance() {
  reset();
  watches.set('hongguo:2', { dramaId: 'hongguo:2', episode: 3, progress: 72, duration: 600 });
  const current = player();
  await current.selectSeason(seasonList[1], false);
  await settle();
  assert.equal(current.dramaId, 'hongguo:2');
  assert.equal(current.episode, 1, 'automatic next season starts from first episode');
  assert.equal(current.pendingResumeSec, 0);
  reset();
  const paused = player();
  paused.episode = 3; paused.curSec = 600;
  settings.autoNext = false;
  paused.onPlaybackFinished();
  await settle();
  assert.equal(paused.dramaId, 'hongguo:1');
  assert.equal(calls.detail.length, 0, 'autoNext disabled also disables season auto-advance');
  settings.autoNext = true;
  paused.onPlaybackFinished();
  paused.onPlaybackFinished();
  await settle();
  assert.equal(paused.dramaId, 'hongguo:2');
  assert.equal(paused.episode, 1);
  assert.equal(calls.detail.filter(id => id === 'hongguo:2').length, 1, 'duplicate finish events switch only once');
  console.log('PASS next season starts at episode one and obeys autoNext without duplicate switch');
}

async function testLeavingDuringSwitch() {
  reset();
  const target = deferred();
  detailHandler = () => target.promise;
  const current = player();
  const switched = current.selectSeason(seasonList[1]);
  await settle();
  current.aboutToDisappear();
  target.resolve(makeDetail(2));
  await switched;
  await settle();
  assert.equal(current.dramaId, 'hongguo:1');
  assert.equal(calls.play.length, 0, 'leaving the player cancels pending target media startup');
  console.log('PASS leaving player invalidates pending season switch');
}

async function testStaleMedia() {
  reset();
  const oldMedia = deferred();
  playHandler = (id, episode) => id === 'hongguo:1' ? oldMedia.promise : Promise.resolve(media(id, episode));
  const current = player();
  current.preloadedPlay.clear();
  current.resolvePlay();
  await settle();
  await current.selectSeason(seasonList[1]);
  await settle();
  const newUrl = current.playUrl;
  assert.ok(newUrl.includes('hongguo:2'));
  oldMedia.resolve(media('hongguo:1', 'e2'));
  await settle();
  assert.equal(current.playUrl, newUrl, 'old-season resolve cannot overwrite target playback');
  reset();
  const prewarm = deferred();
  playHandler = (id, episode) => id === 'hongguo:1' ? prewarm.promise : Promise.resolve(media(id, episode));
  const warmed = player();
  warmed.prewarmedOrder = -1;
  warmed.preloadedPlay.clear();
  warmed.prewarmNext();
  await warmed.selectSeason(seasonList[1]);
  await settle();
  prewarm.resolve(media('hongguo:1', 'e3'));
  await settle();
  assert.equal(warmed.preloadedPlay.has('hongguo:1:e3'), false, 'old-season prewarm must not repopulate new season cache');
  console.log('PASS stale media resolve and prewarm are rejected after switching seasons');
}

async function testIdentityAndLists() {
  reset();
  const current = player();
  const old = current.videoIdentity();
  assert.equal(current.isCurrentVideo(old), true);
  await current.selectSeason(seasonList[1]);
  await settle();
  assert.equal(current.isCurrentVideo(old), false, 'old Video event identity must be invalid after switch');
  assert.equal(current.isCurrentVideo(current.videoIdentity()), true);
  const before = saved.length;
  const playUrl = current.playUrl;
  const position = current.curSec;
  current.eventUpdate(old, { time: 599 });
  current.eventPause(old);
  current.eventFinish(old);
  current.eventError(old, { code: 111, message: 'old Video event' });
  assert.equal(saved.length, before, 'old Video pause/update cannot write progress under new season');
  assert.equal(current.curSec, position);
  assert.equal(current.playUrl, playUrl, 'old Video errors cannot tear down target season playback');
  assert.equal(current.dramaId, 'hongguo:2', 'old Video finish cannot advance target season');
  const count = calls.detail.length;
  await current.selectSeason(seasonList[1]);
  assert.equal(calls.detail.length, count, 'selecting current season is a no-op');
  const stale = deferred();
  seasonsHandler = () => stale.promise;
  current.loadSeasons(makeDrama(2));
  const previous = current.seasons;
  current.aboutToDisappear();
  stale.resolve([seasonList[0], seasonList[1]]);
  await settle();
  assert.equal(current.seasons, previous, 'season list cannot mutate disposed player');
  assert.equal(current.isCurrentVideo(current.videoIdentity()), false);
  console.log('PASS old Video events and stale season lists are invalidated, same season is a no-op');
}

async function testRapidSeasonSelection() {
  reset();
  const second = deferred();
  const third = deferred();
  detailHandler = id => id === 'hongguo:2' ? second.promise : third.promise;
  const current = player();
  const a = current.selectSeason(seasonList[1]);
  const b = current.selectSeason(seasonList[2]);
  third.resolve(makeDetail(3));
  await b;
  await settle();
  const committed = current.playUrl;
  assert.equal(current.dramaId, 'hongguo:3');
  second.resolve(makeDetail(2));
  await a;
  await settle();
  assert.equal(current.dramaId, 'hongguo:3');
  assert.equal(current.playUrl, committed);
  assert.equal(current.switchingSeason, false);
  assert.equal(current.seasonSwitchError, '');
  reset();
  const pending = deferred();
  detailHandler = () => pending.promise;
  const cancel = player();
  const selection = cancel.selectSeason(seasonList[1]);
  await cancel.selectSeason(seasonList[0]);
  pending.reject(new Error('late canceled error'));
  await selection;
  await settle();
  assert.equal(cancel.dramaId, 'hongguo:1');
  assert.equal(cancel.seasonSwitchError, '');
  assert.equal(cancel.switchingSeason, false);
  console.log('PASS rapid season requests commit only the newest selection and ignore canceled errors');
}

async function testUnpreparedResumeRetention() {
  reset();
  watches.set('hongguo:2', { dramaId: 'hongguo:2', episode: 3, progress: 72, duration: 600 });
  const current = player();
  await current.selectSeason(seasonList[1]);
  await settle();
  assert.equal(current.pendingResumeSec, 72);
  assert.equal(current.curSec, 0);
  await current.selectSeason(seasonList[2]);
  await settle();
  assert.equal(watches.get('hongguo:2').progress, 72, 'switching again before Video preparation must retain target watch position');
  reset();
  watches.set('hongguo:2', { dramaId: 'hongguo:2', episode: 3, progress: 72, duration: 600 });
  const leaving = player();
  await leaving.selectSeason(seasonList[1]);
  await settle();
  leaving.aboutToDisappear();
  assert.equal(watches.get('hongguo:2').progress, 72, 'leaving before Video preparation must not overwrite watch with zero');
  console.log('PASS unprepared resumed season preserves its previous progress when switching or leaving');
}

async function testLateSeasonListAtFinish() {
  reset();
  const list = deferred();
  seasonsHandler = () => list.promise;
  const current = player();
  current.episode = 3; current.curSec = 600; current.seasons = [];
  current.loadSeasons(current.drama);
  current.onPlaybackFinished();
  assert.equal(current.advanceWhenSeasonsReady, true);
  list.resolve(seasonList);
  await settle();
  assert.equal(current.dramaId, 'hongguo:2', 'a late valid season list can advance a completed season');
  assert.equal(current.episode, 1);
  reset();
  const canceled = deferred();
  seasonsHandler = () => canceled.promise;
  const manual = player();
  manual.episode = 3; manual.curSec = 600; manual.seasons = [];
  manual.loadSeasons(manual.drama);
  manual.onPlaybackFinished();
  manual.pickEpisode(1);
  canceled.resolve(seasonList);
  await settle();
  assert.equal(manual.dramaId, 'hongguo:1', 'manual episode selection cancels waiting auto-advance');
  assert.equal(manual.episode, 1);
  console.log('PASS late season lists advance only if the user still intends automatic continuation');
}

async function testStaleBootstrap() {
  reset();
  const first = deferred();
  const second = deferred();
  detailHandler = id => id === 'hongguo:2' ? first.promise : second.promise;
  const current = player();
  current.bootstrap('hongguo:2', 1);
  current.bootstrap('hongguo:3', 2);
  second.resolve(makeDetail(3));
  await settle();
  assert.equal(current.dramaId, 'hongguo:3');
  assert.equal(current.episode, 2);
  const currentUrl = current.playUrl;
  first.resolve(makeDetail(2));
  await settle();
  assert.equal(current.drama.id, 'hongguo:3');
  assert.equal(current.playUrl, currentUrl);
  assert.deepEqual(calls.play.map(call => call.id), ['hongguo:3']);
  reset();
  const left = deferred();
  detailHandler = () => left.promise;
  const disposed = player();
  disposed.bootstrap('hongguo:2', 1);
  disposed.aboutToDisappear();
  left.resolve(makeDetail(2));
  await settle();
  assert.equal(calls.play.length, 0);
  assert.equal(disposed.drama.id, 'hongguo:1');
  console.log('PASS stale bootstrap details and disposed page startup cannot replace the current season');
}

(async () => {
  for (const name of ['selectSeason', 'loadSeasons', 'nextSeason', 'onPlaybackFinished', 'videoIdentity', 'isCurrentVideo']) {
    assert.equal(typeof context.Player.prototype[name], 'function', `Missing player season method ${name}`);
  }
  await testManualResume();
  await testFailedSwitch();
  await testAutomaticAdvance();
  await testLeavingDuringSwitch();
  await testStaleMedia();
  await testIdentityAndLists();
  await testRapidSeasonSelection();
  await testUnpreparedResumeRetention();
  await testLateSeasonListAtFinish();
  await testStaleBootstrap();
})().catch(error => { console.error(error); process.exitCode = 1; });
