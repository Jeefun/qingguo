const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const tests = fs.readdirSync(__dirname).filter(name => /^test-.*\.cjs$/.test(name)).sort();
if (tests.length === 0) throw new Error('No test scripts found.');
for (const test of tests) {
  console.log(`\nRUN ${test}`);
  const result = spawnSync(process.execPath, [path.join(__dirname, test)], {
    cwd: root, env: process.env, stdio: 'inherit'
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
}
console.log(`\nPASS all ${tests.length} test scripts.`);
