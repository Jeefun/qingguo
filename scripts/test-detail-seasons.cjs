const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/DetailPage.ets'), 'utf8');

function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, `Missing detail method: ${name}`);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}
const names = ['getD', 'goPlayer', 'load', 'refreshWatch', 'loadSeasons', 'selectSeason',
  'seasonSubtitle', 'currentSeasonLabel', 'revealCurrentSeason', 'hideDestination', 'showDestination'];
const code = ts.transpileModule(`class Detail { ${names.map(method).join('\n')} } globalThis.Detail = Detail;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText;
const watches = new Map();
const queries = { details: [], seasons: [], paths: [] };
let detailRequest;
let seasonRequest;
class Drama {
  constructor(id, title = id, genre = '') {
    Object.assign(this, { id, title, genre, sourceId: id.split(':')[0], episodeCount: 3 });
  }
}
const context = vm.createContext({
  QgDrama: Drama,
  qgSameImage: (a, b) => {
    const strip = u => String(u ?? '').trim().replace(/^[a-zA-Z][a-zA-Z0-9+.\-]*:\/\//, '')
      .replace(/^\/\//, '').split('?')[0];
    const x = strip(a);
    const y = strip(b);
    return x.length > 0 && y.length > 0 && x.toLowerCase() === y.toLowerCase();
  },
  QgRepository: {
    detail: id => { queries.details.push(id); return detailRequest(id); },
    seasons: anchor => { queries.seasons.push(anchor.id); return seasonRequest(anchor); }
  },
  QgStore: { getInstance: () => ({ getWatch: id => watches.get(id), isFollowed: id => id.endsWith(':two'),
    isQueued: id => id.endsWith(':one') }) }
});
vm.runInContext(code, context);
function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
const detail = id => ({ drama: new Drama(id), episodes: [1, 2, 3].map(order => ({
  id: id + ':' + order, title: 'Episode ' + order, order
})) });
const seasons = ['one', 'two', 'three'].map((id, index) => ({ number: index + 1, drama: new Drama('demo:' + id) }));
function page() {
  const page = new context.Detail();
  Object.assign(page, {
    seasons: [], seasonsLoading: false, seasonsError: '', seasonRailReady: false,
    switchingSeasonId: '', seasonSwitchError: '', requestedId: '', loadSequence: 0,
    seasonsSequence: 0, visible: true, seasonsCancelled: false, loading: true,
    errMsg: '', episodes: [], drama: undefined, watchEp: 0, currentEp: 1,
    stack: { pushPathByName: (...args) => queries.paths.push(args) }
  });
  return page;
}

async function run() {
  const firstDetail = deferred();
  const firstSeasons = deferred();
  detailRequest = () => firstDetail.promise;
  seasonRequest = () => firstSeasons.promise;
  const current = page();
  current.load('demo:one');
  assert.equal(queries.details.at(-1), 'demo:one');
  assert.equal(queries.seasons.at(-1), 'demo:one', 'series lookup starts alongside detail lookup');
  firstDetail.resolve(detail('demo:one'));
  await flush();
  assert.equal(current.loading, false, 'optional season request cannot block detail display');
  assert.equal(current.episodes.length, 3);
  assert.equal(current.seasonsLoading, true);
  firstSeasons.reject(new Error('Temporary series failure'));
  await flush();
  assert.equal(current.errMsg, '');
  assert.equal(current.seasonsError, 'Temporary series failure');
  seasonRequest = async () => seasons;
  current.loadSeasons(current.drama);
  await flush();
  assert.equal(current.seasonsError, '');
  assert.equal(current.seasons.length, 3);
  console.log('PASS optional seasons load in parallel, fail independently and retry without blocking episodes');

  watches.set('demo:two', { episode: 2, progress: 45, duration: 120 });
  detailRequest = async id => detail(id);
  const officialSeasons = current.seasons;
  current.selectSeason(seasons[1]);
  assert.equal(current.drama.id, 'demo:one', 'old season remains until target detail succeeds');
  assert.equal(current.switchingSeasonId, 'demo:two');
  const pathCount = queries.paths.length;
  current.goPlayer(1);
  assert.equal(queries.paths.length, pathCount, 'old season must not play while a switch is pending');
  await flush();
  assert.equal(current.drama.id, 'demo:two');
  assert.equal(current.episodes[0].id, 'demo:two:1');
  assert.equal(current.watchEp, 2);
  assert.equal(current.currentEp, 2);
  assert.equal(current.followed, true);
  assert.equal(current.queued, false);
  assert.equal(current.seasons, officialSeasons, 'known official season list stays available across switching');
  current.goPlayer(current.currentEp);
  assert.equal(queries.paths.at(-1)[1].dramaId, 'demo:two');
  assert.equal(queries.paths.at(-1)[1].episode, 2);
  assert.match(current.seasonSubtitle(seasons[1]), /已看到第 2 集/);
  assert.equal(current.currentSeasonLabel(), '第 2 季');
  console.log('PASS season switch uses new chapter IDs, per-season resume and collection state without playing stale content');

  detailRequest = async () => { throw new Error('Season temporarily unavailable'); };
  current.selectSeason(seasons[2]);
  await flush();
  assert.equal(current.drama.id, 'demo:two');
  assert.equal(current.episodes[0].id, 'demo:two:1');
  assert.equal(current.errMsg, '');
  assert.equal(current.seasonSwitchError, 'Season temporarily unavailable');
  assert.equal(current.requestedId, 'demo:two');
  assert.equal(current.switchingSeasonId, '');
  console.log('PASS failed switch retains current season and releases controls');

  const oldDetail = deferred();
  const newDetail = deferred();
  detailRequest = id => id === 'demo:one' ? oldDetail.promise : newDetail.promise;
  current.load('demo:one');
  current.load('demo:three');
  newDetail.resolve(detail('demo:three'));
  await flush();
  oldDetail.resolve(detail('demo:one'));
  await flush();
  assert.equal(current.drama.id, 'demo:three', 'late prior detail must not overwrite newer selected season');

  const priorSeries = deferred();
  const latestSeries = deferred();
  seasonRequest = anchor => anchor.id === 'demo:one' ? priorSeries.promise : latestSeries.promise;
  current.loadSeasons(new Drama('demo:one'));
  current.loadSeasons(new Drama('demo:three'));
  latestSeries.resolve(seasons);
  await flush();
  priorSeries.resolve([]);
  await flush();
  assert.equal(current.seasons.length, 3, 'late prior series result must not replace active list');
  console.log('PASS stale detail and series responses cannot overwrite newer selection');

  const hiddenDetail = deferred();
  const hiddenSeries = deferred();
  detailRequest = () => hiddenDetail.promise;
  seasonRequest = () => hiddenSeries.promise;
  const hidden = page();
  hidden.load('demo:one');
  hidden.hideDestination();
  hidden.hideDestination();
  hiddenDetail.resolve(detail('demo:one'));
  hiddenSeries.resolve(seasons);
  await flush();
  assert.equal(hidden.drama, undefined);
  assert.equal(hidden.seasons.length, 0);
  detailRequest = async id => detail(id);
  seasonRequest = async () => seasons;
  hidden.showDestination();
  await flush();
  assert.equal(hidden.drama.id, 'demo:one');
  assert.equal(hidden.seasons.length, 3);
  hidden.hideDestination();
  watches.set('demo:one', { episode: 3, progress: 15 });
  hidden.showDestination();
  assert.equal(hidden.currentEp, 3, 'returning from playback refreshes saved episode');
  console.log('PASS leaving cancels callbacks; returning reloads pending data and refreshes watch position');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
