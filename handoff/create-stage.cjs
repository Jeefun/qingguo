// Creates a private, relocatable working-tree snapshot. Never prints secret values.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const source = path.resolve(__dirname, '..');
const stage = path.resolve(process.argv[2] || path.join(source, '.cache/handoff-stage/qingguoapp'));
const allowed = path.join(source, '.cache') + path.sep;
if (!stage.startsWith(allowed)) throw new Error('Staging directory must be inside this project .cache.');
if (fs.existsSync(stage)) throw new Error('Staging directory already exists. Choose a fresh directory.');
const home = process.env.DEVECO_STUDIO_HOME;
if (!home) throw new Error('Set DEVECO_STUDIO_HOME before creating the transfer snapshot.');
const json5 = require(path.join(home, 'tools/hvigor/hvigor-ohos-plugin/node_modules/json5'));
const profile = json5.parse(fs.readFileSync(path.join(source, 'build-profile.json5'), 'utf8'));
const material = profile.app.signingConfigs.find(item => item.name === 'default').material;
const skipTop = new Set(['.cache', '.hvigor', '.idea', 'local.properties', 'oh_modules', '.private-signing']);
function include(file) {
  const rel = path.relative(source, file).split(path.sep).join('/');
  if (!rel) return true;
  if (skipTop.has(rel.split('/')[0])) return false;
  if (/^entry\/(build|\.cxx|oh_modules)(\/|$)/.test(rel)) return false;
  if (/^dist\/qingguo-project-transfer-.*\.(zip|txt)$/.test(rel)) return false;
  if (/^handoff\/(local-env\.json|build\.log|regression\.log)$/.test(rel)) return false;
  if (/^\.git\/.*\.lock$/.test(rel)) return false;
  return true;
}
fs.mkdirSync(stage, { recursive: true });
for (const name of fs.readdirSync(source)) {
  const from = path.join(source, name);
  if (include(from)) fs.cpSync(from, path.join(stage, name), { recursive: true, dereference: true, filter: include });
}
for (const rel of ['oh_modules', 'entry/oh_modules', '.cache/module-html-runtime', '.cache/module-work']) {
  const from = path.join(source, rel);
  if (!fs.existsSync(from)) throw new Error('Required dependency or fixture missing: ' + rel);
  fs.cpSync(from, path.join(stage, rel), { recursive: true, dereference: true });
}
function git(args) {
  const result = spawnSync('git', ['-c', 'core.quotepath=false', ...args], { cwd: source, encoding: 'utf8' });
  if (result.status !== 0) throw new Error('Git snapshot inspection failed.');
  return result.stdout;
}
// Preserve even tracked generated files so the original Git work tree remains recoverable.
const tracked = git(['ls-files', '-z']).split('\0').filter(Boolean);
for (const rel of tracked) {
  const from = path.join(source, rel), to = path.join(stage, rel);
  if (fs.existsSync(from) && !fs.existsSync(to)) {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(from, to);
  }
}
const privateDir = path.join(stage, '.private-signing');
fs.mkdirSync(privateDir, { recursive: true });
const hashes = {};
for (const [key, name] of Object.entries({ certpath: 'qingguo.cer', profile: 'qingguo.p7b', storeFile: 'qingguo.p12' })) {
  const from = path.resolve(source, material[key]);
  fs.copyFileSync(from, path.join(privateDir, name));
  hashes[name] = crypto.createHash('sha256').update(fs.readFileSync(from)).digest('hex');
  material[key] = './.private-signing/' + name;
}
const original = json5.parse(fs.readFileSync(path.join(source, 'build-profile.json5'), 'utf8'));
const originalMaterial = original.app.signingConfigs.find(item => item.name === 'default').material;
const originalStore = path.resolve(source, originalMaterial.storeFile);
const csr = originalStore.replace(/\.p12$/i, '.csr');
if (fs.existsSync(csr)) fs.copyFileSync(csr, path.join(privateDir, 'qingguo.csr'));
const decryptMaterial = path.join(path.dirname(originalStore), 'material');
function copyMaterial(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const item of fs.readdirSync(from, { withFileTypes: true })) {
    const input = path.join(from, item.name), output = path.join(to, item.name);
    if (item.isDirectory()) copyMaterial(input, output);
    else fs.copyFileSync(input, output);
  }
}
copyMaterial(decryptMaterial, path.join(privateDir, 'material'));
fs.writeFileSync(path.join(stage, 'build-profile.json5'), JSON.stringify(profile, null, 2) + '\n');
fs.writeFileSync(path.join(privateDir, 'README.txt'),
  'PRIVATE SIGNING MATERIAL. Keep this directory with build-profile.json5.\n' +
  'The material/ directory decrypts the existing encrypted passwords locally.\n' +
  'Do not print secrets, publish this archive, or replace unrelated global signing files.\n');
fs.writeFileSync(path.join(stage, 'local.properties'), '# Regenerated for the destination computer by DevEco Studio.\n');
fs.writeFileSync(path.join(stage, 'handoff/ORIGINAL_GIT_STATUS.txt'), git(['status', '--short']));
fs.writeFileSync(path.join(stage, 'handoff/SNAPSHOT_METADATA.json'), JSON.stringify({
  createdAt: new Date().toISOString(), appVersion: '1.1.1',
  head: git(['rev-parse', 'HEAD']).trim(), gitHistoryIncluded: true,
  currentWorkingTreeIncluded: true, signingMaterialIncluded: true,
  signingFileSHA256: hashes,
  signingPaths: 'Project-relative .private-signing; original encrypted passwords retained',
  excludedRegenerableItems: ['.hvigor', 'entry/build', 'entry/.cxx', '.idea',
    '.cache except required runtime/fixtures and tracked files', 'previous migration ZIPs'],
  sdkAndIdeIncluded: false, phoneSandboxIncluded: false
}, null, 2) + '\n');
console.log(JSON.stringify({ stage, signingFiles: Object.keys(hashes), gitHead: git(['rev-parse', 'HEAD']).trim() }));
