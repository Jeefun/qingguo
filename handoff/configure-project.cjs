const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const home = process.env.DEVECO_STUDIO_HOME;
if (!home) throw new Error('DEVECO_STUDIO_HOME is required. Use Setup-Project.ps1.');
const json5 = require(path.join(home, 'tools/hvigor/hvigor-ohos-plugin/node_modules/json5'));
const configPath = path.join(root, 'build-profile.json5');
const config = json5.parse(fs.readFileSync(configPath, 'utf8'));
const signing = config.app.signingConfigs.find(item => item.name === 'default');
if (!signing || !signing.material) throw new Error('Default signing configuration is missing.');
const files = { certpath: 'qingguo.cer', profile: 'qingguo.p7b', storeFile: 'qingguo.p12' };
for (const [key, file] of Object.entries(files)) {
  const relative = './.private-signing/' + file;
  if (!fs.existsSync(path.join(root, relative))) throw new Error('Packaged signing file missing: ' + file);
  signing.material[key] = relative;
}
for (const dir of ['fd', 'ac', 'ce']) {
  if (!fs.statSync(path.join(root, '.private-signing/material', dir)).isDirectory()) {
    throw new Error('Signing password decryption material is incomplete.');
  }
}
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
console.log('Configured project-relative signing paths; secret values were not printed.');
