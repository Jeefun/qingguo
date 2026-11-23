// Tests the audio (#219 parity) port: declared mediaType=audio chapters,
// named-episode single-column lists, the player audio stage (artwork instead
// of video surface), sleep timer, and the same-image cover merge fix.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');

const root = path.resolve(__dirname, '..');

// --- Model logic (evaluate QgModels.ets in a VM) ---
const modelsFile = path.resolve(root, 'entry/src/main/ets/model/QgModels.ets');
const modelsCode = ts.transpileModule(fs.readFileSync(modelsFile, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const modelsCtx = vm.createContext({ exports: {} });
vm.runInContext(modelsCode, modelsCtx, { filename: modelsFile });
const { QgEpisode, qgEpisodeNamed, qgEpisodeLabel, qgEpisodesNamed, qgSameImage } = modelsCtx.exports;

{
  const ep = (title, order) => new QgEpisode(`v${order}`, title, order);
  for (const title of ['12', '第 3 集', '第3集', 'EP3', 'e 12', '第12话', '第 7 期', '第4章', '第2回', '第5节', '第 9 話']) {
    assert.equal(qgEpisodeNamed(ep(title, 3)), false, `"${title}" is a numbered title`);
  }
  for (const title of ['第一章 风起', '听书第1集', '第三集', '正片', '番外·雨夜']) {
    assert.equal(qgEpisodeNamed(ep(title, 3)), true, `"${title}" is a named chapter`);
  }
  assert.equal(qgEpisodeNamed(ep('  ', 1)), false, 'blank titles are not named');
  assert.equal(qgEpisodeLabel(ep('第一章 风起', 3)), '第一章 风起');
  assert.equal(qgEpisodeLabel(ep('第 3 集', 3)), '第 3 集');
  assert.equal(qgEpisodeLabel(ep('12', 7)), '第 7 集', 'label falls back to the episode order');
  console.log('PASS named detection keeps "第 N 集" tiles numbered and promotes real chapter titles');
}

{
  const ep = (title, order) => new QgEpisode(`v${order}`, title, order);
  assert.equal(qgEpisodesNamed([]), false, 'empty lists are not in named mode');
  const numbered = Array.from({ length: 30 }, (_, i) => ep(`第 ${i + 1} 集`, i + 1));
  assert.equal(qgEpisodesNamed(numbered), false);
  assert.equal(qgEpisodesNamed([...numbered, ep('大结局·真相', 31)]), false,
    'a single named tail among numbered episodes stays grid mode');
  const chapters = [ep('第一章 起点', 1), ep('第二章 风波', 2), ep('第三章 夜行', 3)];
  assert.equal(qgEpisodesNamed(chapters), true);
  assert.equal(qgEpisodesNamed([ep('第一章 起点', 1), ep('第 2 集', 2), ep('第三章 夜行', 3)]), true,
    'half named already counts as named mode');
  assert.equal(qgEpisodesNamed([ep('第一章 起点', 1), ep('第 2 集', 2), ep('第 3 集', 3)]), false,
    'a named minority stays numbered');
  console.log('PASS named mode requires a majority of titled episodes');
}

{
  assert.equal(qgSameImage('https://a.b/c.jpg?sig=1', 'https://a.b/c.jpg?sig=2'), true,
    're-signed URLs of the same image compare equal');
  assert.equal(qgSameImage('http://a.b/c.jpg', 'https://a.b/c.jpg?x=1'), true,
    'scheme and query differences are ignored');
  assert.equal(qgSameImage('//a.b/c.jpg', 'https://a.b/c.jpg'), true);
  assert.equal(qgSameImage('https://a.b/c.jpg', 'https://a.b/d.jpg'), false);
  assert.equal(qgSameImage('https://a.b/c.jpg', ''), false);
  assert.equal(qgSameImage('', ''), false);
  console.log('PASS same-image check matches host+path only, ignoring signatures');
}

// --- Module source: declared mediaType=audio chapters become audio episodes ---
const moduleSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/data/source/QgModuleSource.ets'), 'utf8');
assert.ok(/item\.audio = QgJson\.str\(chapter\?\.\['mediaType'\]\) === 'audio'/.test(moduleSrc),
  'module chapters must declare audio episodes via mediaType=audio');

// --- Episode picker: named mode renders a single-column chapter list ---
const pickerSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/QgEpisodePicker.ets'), 'utf8');
assert.ok(pickerSrc.includes('qgEpisodesNamed'), 'picker must detect named mode');
assert.ok(/private columns\(\): number \{\s*if \(this\.namedMode\(\)\) \{\s*return 1;/.test(pickerSrc),
  'named mode must collapse the tile grid to a single column');
assert.ok(pickerSrc.includes('qgEpisodeLabel(ep)'), 'named tiles must show the chapter title');
assert.ok(/this\.namedMode\(\) \? `第 \$\{ep\.order\} 集，\$\{qgEpisodeLabel\(ep\)\}`/.test(pickerSrc),
  'named tiles must stay accessible by episode number');

// --- Player: audio stage replaces the video surface, sleep timer, tool row ---
const playerSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/PlayerPage.ets'), 'utf8');
assert.ok(playerSrc.includes('@State audioMode: boolean = false'), 'player must track audio mode');
assert.ok(playerSrc.includes('this.AudioStageBuilder()'), 'player must render the audio stage');
assert.ok(playerSrc.includes('if (this.audioMode && this.playUrl.length > 0)'),
  'audio stage covers the video surface while the audio URL plays');
assert.ok(playerSrc.includes('private syncAudioMode(): void'), 'audio mode must resync per episode');
const pickEpAt = playerSrc.indexOf('private pickEpisode(ep: number): void');
assert.ok(pickEpAt >= 0 && playerSrc.indexOf('this.syncAudioMode();', pickEpAt) > pickEpAt,
  'picking an episode must resync audio mode');
const seasonAt = playerSrc.indexOf('private async selectSeason(');
assert.ok(seasonAt >= 0 && playerSrc.indexOf('this.syncAudioMode();', seasonAt) > seasonAt,
  'switching seasons must resync audio mode');
assert.ok(playerSrc.includes('this.episodeLabel()'), 'player headers must show chapter labels');
assert.ok(/if \(!this\.audioMode && this\.danmakuId\.length > 0\)/.test(playerSrc),
  'danmaku must stay hidden in audio mode');
assert.ok(/if \(!this\.audioMode\) \{\r?\n\s+this\.PlayerToolBuilder\(this\.aspectFill/.test(playerSrc),
  'aspect and rotate pills must stay hidden in audio mode');
assert.ok(/if \(!this\.audioMode\) \{\r?\n\s+Stack\(\) \{/.test(playerSrc),
  'the fullscreen button must stay hidden in audio mode');

// Sleep timer: chip row, deadline check in onUpdate, stop-at-episode-end before auto-next.
assert.ok(playerSrc.includes('const SLEEP_MINUTES: number[] = [15, 30, 60]'), 'sleep choices must exist');
assert.ok(playerSrc.includes("this.SectionTitleBuilder('定时停止')"), 'settings sheet must offer the sleep timer');
assert.ok(playerSrc.includes('this.fireSleepTimeout();'), 'the sleep deadline must be enforced during playback');
const finishedAt = playerSrc.indexOf('private onPlaybackFinished(): void');
const sleepEndAt = playerSrc.indexOf('this.sleepMode === -1', finishedAt);
const autoNextAt = playerSrc.indexOf('getSettings().autoNext', finishedAt);
assert.ok(finishedAt >= 0 && sleepEndAt > finishedAt && autoNextAt > sleepEndAt,
  'stop-at-episode-end must win over auto-next');
assert.ok(playerSrc.includes("item.audio = QgJson.str(chapter?.['mediaType']) === 'audio'") === false,
  'player must not parse module chapters itself');

// --- Detail page: keep the old cover when only the signature changed ---
const detailSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/DetailPage.ets'), 'utf8');
assert.ok(detailSrc.includes('qgSameImage(this.drama.cover, detail.drama.cover)'),
  'detail loads must keep the old cover URL for the same image');
assert.ok(detailSrc.indexOf('qgSameImage(this.drama.cover, detail.drama.cover)') <
  detailSrc.indexOf('this.drama = detail.drama;'),
  'the cover merge must happen before the state swap');

console.log('PASS audio mode: declared mediaType, named single-column lists, audio stage, sleep timer, stable covers');
