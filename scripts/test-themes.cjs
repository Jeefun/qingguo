const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');

const root = path.resolve(__dirname, '../entry/src/main/ets');
const filename = path.join(root, 'components/QgTheme.ets');
const source = fs.readFileSync(filename, 'utf8');
const document = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true);
const paletteNames = [];
for (const statement of document.statements) {
  if (!ts.isVariableStatement(statement)) continue;
  for (const declaration of statement.declarationList.declarations) {
    if (declaration.initializer && ts.isObjectLiteralExpression(declaration.initializer) &&
      declaration.initializer.properties.some(property => property.name && property.name.text === 'bg')) {
      paletteNames.push(declaration.name.getText(document));
    }
  }
}
const context = vm.createContext({ exports: {} });
const transpile = text => ts.transpileModule(text, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
vm.runInContext(transpile(source + '\nglobalThis.palettes = {' + paletteNames.join(',') + '};'), context, { filename });
const theme = context.exports.QgTheme;
const options = Array.from(theme.options());
const ids = options.map(option => option.id);
assert.deepEqual(ids, ['white', 'lime', 'sea', 'apricot', 'iris', 'rose', 'jade', 'gold']);
assert.equal(new Set(ids).size, ids.length);
for (const option of options) {
  for (const key of ['title', 'subtitle', 'tag']) assert.ok(option[key].trim().length > 0, `${option.id}: missing ${key}`);
  assert.equal(theme.normalize(option.id), option.id, 'every displayed theme must be a recognized stored value');
}
for (const unknown of ['', 'unknown', 'LIME', 'iris ', '__proto__']) {
  assert.equal(theme.normalize(unknown), 'lime');
  for (const dark of [false, true]) {
    assert.equal(theme.color('bg', unknown, dark), theme.color('bg', 'lime', dark));
    assert.equal(theme.color('accent', unknown, dark), theme.color('accent', 'lime', dark));
  }
}
console.log('PASS eight distinct theme choices retain a safe default for unknown stored values');

// These fingerprints record the original 40 color roles, independently of any local cache.
// Adding themes must not silently recolor an existing choice that the user asked to keep.
const legacyTokens = ['accent', 'accentDim', 'accentInk', 'accentOn', 'accentSoft', 'bg', 'bgClear', 'border',
  'brandEnd', 'brandStart', 'chipBg', 'chipOn', 'danger', 'detailScrim', 'divider', 'glass', 'glassBg',
  'glassStroke', 'gold', 'heroTop', 'mask', 'navBg', 'playerBg', 'playerControl', 'playerDim', 'playerText',
  'rankOne', 'rankThree', 'rankTwo', 'scrimBottom', 'scrimTop', 'start_window_background', 'surface',
  'surfaceHigh', 'tabBarBg', 'tabIconOff', 'text', 'textDim', 'textFaint', 'trackOff'];
const fingerprints = {
  lime: ['1ea0cdcee7b85ff9f0c2d7050cfca56c44b64e6329f3cc8326eb41b3e453e4c8',
    'e3257d626299dfed1121836bf7698f607be2d923a7d94ac6bb5b7b80205d3796'],
  sea: ['979e09eb03ff1cb13285b012c7aa9c4d2d891abca3b524eb999a47efd41e4c2e',
    '7f37aaf074a739c5e3a7121038bf560c1caae608c7c40d1ea5eee905c9df6479'],
  apricot: ['4d7b931de9ee2fd953a491a3712981579f7c437960463ad87ba8f7aa6bdafdd7',
    'aa298f25be9315c11b3d7ab21ec0b1cae82da6f4642ad33296a5fe7295b6d456']
};
for (const [id, expected] of Object.entries(fingerprints)) {
  for (const dark of [false, true]) {
    const actual = crypto.createHash('sha256').update(JSON.stringify(
      legacyTokens.map(key => [key, theme.color(key, id, dark)]))).digest('hex');
    assert.equal(actual, expected[Number(dark)], `${id}/${dark ? 'dark' : 'light'} changed an existing theme palette`);
  }
}
console.log('PASS original lime, sea and apricot palettes remain unchanged in both appearances');

function filesIn(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ?
    filesIn(path.join(directory, entry.name)) : entry.name.endsWith('.ets') ? [path.join(directory, entry.name)] : []);
}
const requiredTokens = new Set(legacyTokens);
for (const file of filesIn(root)) {
  for (const match of fs.readFileSync(file, 'utf8').matchAll(/QgTheme\.color\(\s*['"]([^'"]+)['"]/g)) {
    requiredTokens.add(match[1]);
  }
}
for (const id of ids) {
  for (const dark of [false, true]) {
    const palette = Object.values(context.palettes).find(candidate => candidate.bg === theme.color('bg', id, dark));
    assert.ok(palette, `${id}/${dark}: palette must be inspectable for missing-role validation`);
    for (const token of requiredTokens) {
      assert.ok(Object.hasOwn(palette, token), `${id}/${dark}: missing role ${token} would fall back to text color`);
      assert.match(palette[token], /^#(?:[\da-fA-F]{6}|[\da-fA-F]{8})$/, `${id}/${dark}: invalid ${token}`);
      assert.equal(theme.color(token, id, dark), palette[token]);
    }
    assert.equal(theme.veil('66', id, dark), '#66' + palette.bg.substring(1));
  }
}
console.log(`PASS all ${requiredTokens.size} app color roles exist in every light and dark palette`);

function luminance(color) {
  assert.match(color, /^#[\da-fA-F]{6}$/, 'contrast pairs must use opaque colors');
  const linear = [1, 3, 5].map(offset => parseInt(color.slice(offset, offset + 2), 16) / 255)
    .map(channel => channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4);
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
function contrast(first, second) {
  const values = [luminance(first), luminance(second)].sort((left, right) => left - right);
  return (values[1] + 0.05) / (values[0] + 0.05);
}
const contrastFailures = [];
let minimumRatio = Infinity;
for (const id of ['white', 'iris', 'rose', 'jade', 'gold']) {
  for (const dark of [false, true]) {
    const color = token => theme.color(token, id, dark);
    const pairs = ['bg', 'surface', 'surfaceHigh'].flatMap(background =>
      ['text', 'textDim', 'textFaint'].map(foreground => [foreground, background]));
    pairs.push(['accentOn', 'accent'], ['accentInk', 'bg'], ['accentInk', 'surface']);
    for (const [foreground, background] of pairs) {
      const ratio = contrast(color(foreground), color(background));
      minimumRatio = Math.min(minimumRatio, ratio);
      if (ratio < 4.5) contrastFailures.push(`${id}/${dark ? 'dark' : 'light'} ${foreground} ${color(foreground)} on ${background} ${color(background)} = ${ratio.toFixed(2)}:1`);
    }
  }
}
assert.deepEqual(contrastFailures, [], 'new theme contrast below 4.5:1:\n' + contrastFailures.join('\n'));
console.log(`PASS new theme (incl. monochrome white) text and primary actions meet 4.5:1 contrast (minimum ${minimumRatio.toFixed(2)}:1)`);

const storeFile = path.join(root, 'data/QgStore.ets');
const storeSource = fs.readFileSync(storeFile, 'utf8');
const storeDocument = ts.createSourceFile(storeFile, storeSource, ts.ScriptTarget.Latest, true);
const storeClass = storeDocument.statements.find(statement => ts.isClassDeclaration(statement) && statement.name.text === 'QgStore');
const methods = ['getTheme', 'setTheme'].map(name => {
  const member = storeClass.members.find(candidate => candidate.name && candidate.name.getText(storeDocument) === name);
  assert.ok(member, `missing store method ${name}`);
  return member.getText(storeDocument);
}).join('\n');
const saved = new Map([['qg_theme', 'sea'], ['qg_watch', 'existing watch data'], ['qg_settings', 'existing playback settings']]);
const appState = new Map();
const storeContext = vm.createContext({
  QgTheme: theme,
  saved,
  AppStorage: { setOrCreate: (key, value) => appState.set(key, value) }
});
vm.runInContext(transpile(`class ThemeStore {
  constructor(pref = null) { this.pref = pref; }
  persist(key, value) { saved.set(key, value); }
  ${methods}
} globalThis.ThemeStore = ThemeStore;`), storeContext, { filename: storeFile });
const preferences = { getSync: (key, fallback) => saved.has(key) ? saved.get(key) : fallback };
for (const id of ids) {
  const store = new storeContext.ThemeStore(preferences);
  store.setTheme(id);
  assert.equal(appState.get('qgTheme'), id, 'selecting a theme must update the visible app immediately');
  assert.equal(saved.get('qg_theme'), id, 'the chosen theme must persist under the existing key');
  assert.equal(new storeContext.ThemeStore(preferences).getTheme(), id, 'a fresh store must restore every theme');
}
for (const invalid of ['', 'unknown', 'IRIS', '__proto__']) {
  const store = new storeContext.ThemeStore(preferences);
  saved.set('qg_theme', invalid);
  assert.equal(store.getTheme(), 'lime');
  store.setTheme(invalid);
  assert.equal(saved.get('qg_theme'), 'lime');
  assert.equal(appState.get('qgTheme'), 'lime');
}
assert.equal(new storeContext.ThemeStore().getTheme(), 'lime');
assert.equal(new storeContext.ThemeStore({ getSync() { throw new Error('preferences unavailable'); } }).getTheme(), 'lime');
assert.equal(saved.get('qg_watch'), 'existing watch data');
assert.equal(saved.get('qg_settings'), 'existing playback settings');
console.log('PASS theme persistence, restart, immediate selection and invalid-preference fallback retain other stored data');
