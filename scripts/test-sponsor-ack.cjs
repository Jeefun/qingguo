// Tests the sponsor acknowledgment in Settings › About:
// the tappable row must open the sponsor profile via openLink.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');

assert.ok(/import\s*\{[^}]*OpenLinkOptions[^}]*\}\s*from\s*'@kit\.AbilityKit'/.test(src),
  'SettingsPage must import OpenLinkOptions from @kit.AbilityKit');
assert.ok(src.includes('感谢赞助 · mnyyds'),
  'Settings › About must render the sponsor acknowledgment row');
assert.ok(/openLink\('https:\/\/github\.com\/mnyyds',\s*options\)/.test(src),
  'openSponsorLink must call ctx.openLink with the sponsor profile URL');

// The sponsor row must be inside AboutBuilder and clickable.
const aboutStart = src.indexOf('AboutBuilder() {');
const aboutEnd = src.indexOf('openSponsorLink(): void', aboutStart);
assert.ok(aboutStart >= 0 && aboutEnd > aboutStart, 'AboutBuilder and openSponsorLink must exist');
const aboutBody = src.slice(aboutStart, aboutEnd);
assert.ok(aboutBody.includes('感谢赞助 · mnyyds'), 'sponsor row must live in AboutBuilder');
assert.ok(/onClick\(\(\) => \{\s*this\.openSponsorLink\(\);\s*\}\)/.test(aboutBody),
  'sponsor row must be tappable');

console.log('PASS Settings › About shows a tappable sponsor acknowledgment opening the sponsor profile');
