const fs = require('node:fs');
const path = require('node:path');

const candidates = [
  process.env.QG_TYPESCRIPT_PATH,
  process.env.DEVECO_STUDIO_HOME && path.join(process.env.DEVECO_STUDIO_HOME,
    'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'),
  'D:/DevEco Studio/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'
].filter(Boolean);
const target = candidates.find(candidate => fs.existsSync(path.join(candidate, 'package.json')));
if (!target) {
  throw new Error('TypeScript not found. Set DEVECO_STUDIO_HOME to your DevEco Studio folder, or QG_TYPESCRIPT_PATH to its TypeScript package.');
}
module.exports = require(target);
