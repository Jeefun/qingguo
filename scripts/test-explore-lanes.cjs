// Tests the explore page per-category swipe lanes (#215 parity):
// fixed top bar + chips outside the Swiper, per-category lanes with skeleton,
// lazy activation + neighbor prefetch, and background fetches that must not
// clobber the hot-keywords first page.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/tab/ExploreTab.ets'), 'utf8');
const repo = fs.readFileSync(path.join(root, 'entry/src/main/ets/data/QgRepository.ets'), 'utf8');

// Per-category lane state model.
assert.ok(src.includes('@Observed') && src.includes('class QgExploreLane'),
  'explore page must model per-category lanes with @Observed QgExploreLane');
assert.ok(src.includes('@ObjectLink'), 'lane view must observe lane state via @ObjectLink');

// Fixed structure: TopBar + chips render outside the Swiper; Swiper hosts lane views only.
const buildStart = src.indexOf('build() {', src.indexOf('export struct ExploreTab'));
assert.ok(buildStart >= 0, 'ExploreTab must have a build method');
const swiperStart = src.indexOf('Swiper()', buildStart);
assert.ok(swiperStart > buildStart, 'explore page must host lanes in a Swiper');
const topBarCall = src.indexOf('this.TopBarBuilder()', buildStart);
assert.ok(topBarCall >= 0 && topBarCall < swiperStart, 'top bar must render above (outside) the Swiper');
const chipsIdx = src.indexOf('QgChip({', buildStart);
assert.ok(chipsIdx >= 0 && chipsIdx < swiperStart, 'category chips must stay outside the Swiper');
assert.ok(src.includes('.cachedCount(1)'), 'Swiper must prebuild adjacent lanes (cachedCount)');
assert.ok(src.includes('.loop(false)'), 'category Swiper must not loop');
assert.ok(src.includes('.onChange((idx: number) => this.onSwiperChange(idx))'), 'swipe end must activate the lane');

// Lazy activation + neighbor prefetch.
assert.ok(src.includes('private activateLane('), 'lanes must be lazily activated');
assert.ok(src.includes('private prefetchNeighbors('), 'adjacent lanes must be prefetched');
assert.ok(src.includes('this.loadLane(neighbor, true)'), 'neighbor prefetch must run in background');
assert.ok(src.includes('private ensureLanes('), 'lane set must be rebuilt from the category table');

// Per-lane skeleton / error / empty states.
assert.ok(src.includes('this.LoadingBuilder()'), 'unloaded lanes must render a skeleton');
assert.ok(src.includes('this.ErrorBuilder()'), 'failed lanes must render an error state');

// Repository: background catalog fetches must not clobber firstPage (hot keywords source).
assert.ok(/catalogPage\(categoryId: string, page: number, background: boolean = false\)/.test(repo),
  'QgRepository.catalogPage must accept a background flag');
assert.ok(/if \(!background && page === 1 /.test(repo),
  'background page-1 fetches must skip the firstPage write');

console.log('PASS Explore page swipes per-category lanes with skeleton + prefetch (no firstPage pollution)');
