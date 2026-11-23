const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('./load-typescript.cjs');

const filename = path.resolve(__dirname, '../entry/src/main/ets/components/QgEpisodeCatalog.ets');
const source = fs.readFileSync(filename, 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const context = vm.createContext({ exports: {} });
vm.runInContext(code, context, { filename });
const catalog = context.exports.QgEpisodeCatalog;
const episode = order => ({ id: `video-${order}`, title: `第 ${order} 集`, order });
const orders = episodes => Array.from(episodes, item => item.order);
const fixture = total => Array.from({ length: total }, (_, index) => episode(index + 1));

{
  const original = [episode(42), episode(2), episode(10), episode(1)];
  const identities = original.slice();
  assert.deepEqual(orders(catalog.ordered(original, false)), [1, 2, 10, 42],
    'episode numbers must sort numerically even when supplied out of order');
  assert.deepEqual(orders(catalog.ordered(original, true)), [42, 10, 2, 1]);
  assert.deepEqual(original, identities, 'view sorting must not reorder the source playback array');
  assert.equal(catalog.ordered(original, false)[2], original[2], 'keep the original episode ID and object');
  console.log('PASS episode sorting preserves source order, IDs and real episode numbers');
}

{
  for (const total of [0, 1, 29, 30, 31, 60, 61, 101]) {
    const episodes = fixture(total);
    for (const descending of [false, true]) {
      const labels = Array.from(catalog.labels(episodes, descending));
      assert.equal(labels.length, Math.ceil(total / 30), `wrong number of ranges for ${total} episodes`);
      const visible = labels.flatMap((_, group) => {
        const page = catalog.page(episodes, group, descending);
        assert.ok(page.length > 0 && page.length <= 30, 'every range must contain 1–30 real episodes');
        return orders(page);
      });
      const expected = orders(episodes);
      if (descending) expected.reverse();
      assert.deepEqual(visible, expected, 'browsing all ranges must never skip or duplicate an episode');
      const first = orders(catalog.page(episodes, 0, descending));
      const last = orders(catalog.page(episodes, Math.max(0, labels.length - 1), descending));
      assert.deepEqual(orders(catalog.page(episodes, -1, descending)), first);
      assert.deepEqual(orders(catalog.page(episodes, labels.length + 5, descending)), last,
        'a stale range after changing seasons must clamp to an existing page');
    }
  }
  assert.deepEqual(Array.from(catalog.labels(fixture(61), false)), ['1–30', '31–60', '61–61']);
  assert.deepEqual(Array.from(catalog.labels(fixture(61), true)), ['32–61', '2–31', '1–1']);
  console.log('PASS 30-episode ranges handle exact boundaries, tail pages, empty lists and stale pages');
}

{
  const episodes = fixture(101);
  for (const order of [1, 30, 31, 60, 61, 88, 90, 91, 101]) {
    for (const descending of [false, true]) {
      const group = catalog.groupOf(episodes, order, descending);
      assert.ok(orders(catalog.page(episodes, group, descending)).includes(order),
        `locating episode ${order} must reveal it in either sort direction`);
      const reverseGroup = catalog.groupOf(episodes, order, !descending);
      assert.ok(orders(catalog.page(episodes, reverseGroup, !descending)).includes(order),
        'the same episode number can stay visible when reversing the order');
    }
  }
  assert.equal(catalog.groupOf(episodes, 30, false), 0);
  assert.equal(catalog.groupOf(episodes, 31, false), 1);
  assert.equal(catalog.groupOf(episodes, 101, true), 0);
  const sparse = Array.from({ length: 61 }, (_, index) => episode(2 * index + 1));
  assert.deepEqual(Array.from(catalog.labels(sparse, false)), ['1–59', '61–119', '121–121']);
  assert.equal(catalog.locate(sparse, '61'), 61);
  assert.equal(catalog.groupOf(sparse, 61, false), 1,
    'page lookup must use actual list membership, not divide the episode number by 30');
  assert.ok(orders(catalog.page(sparse, catalog.groupOf(sparse, 61, true), true)).includes(61));
  assert.equal(catalog.locate(sparse, '60'), 0, 'a gap in source episode numbers is not playable');
  console.log('PASS current and located episodes remain addressable in either order, including sparse numbering');
}

{
  const episodes = fixture(101);
  for (const [input, expected] of [['1', 1], [' 88 ', 88], ['0031', 31], ['101', 101]]) {
    assert.equal(catalog.locate(episodes, input), expected);
  }
  for (const input of ['', ' ', '0', '-1', '102', '1.5', '1e2', '1 0', '第2集', 'NaN', 'Infinity', '9999999999999999999999']) {
    assert.equal(catalog.locate(episodes, input), 0, `invalid input ${JSON.stringify(input)} must not locate a tile`);
  }
  assert.equal(catalog.locate([], '1'), 0);
  console.log('PASS locating accepts existing integer episode numbers and rejects malformed or absent ones');
}
