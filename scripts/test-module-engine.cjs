const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { getQuickJS } = require('../.cache/module-html-runtime/node_modules/quickjs-emscripten');

const root = path.resolve(__dirname, '..');
const engine = fs.readFileSync(path.join(root, 'entry/src/main/cpp/qgmodule_engine.cpp'), 'utf8');
const bootstrap = engine.match(/R"JS\(([\s\S]*?)\)JS"/)[1];

async function main() {
  const QuickJS = await getQuickJS();
  let calls = 0;
  function run(code, name = 'test', args = [], timeout = 1000) {
    const runtime = QuickJS.newRuntime();
    runtime.setMemoryLimit(72 * 1024 * 1024);
    runtime.setMaxStackSize(384 * 1024);
    const deadline = Date.now() + timeout;
    runtime.setInterruptHandler(() => Date.now() > deadline);
    const ctx = runtime.newContext();
    const rpc = ctx.newFunction('callHost', (methodHandle, argsHandle) => {
      calls++;
      const method = ctx.getString(methodHandle);
      const args = JSON.parse(ctx.getString(argsHandle));
      let value;
      if (method === 'utf8Encode') value = Array.from(Buffer.from(args[0], 'utf8'));
      else if (method === 'randomBytes') value = Array(args[0]).fill(42);
      else if (method === 'sha512') value = new Array(64).fill(7);
      else if (method === 'gzip') value = [1, 2, 3];
      else if (method === 'gunzip') value = [4, 5, 6];
      else if (method === 'fetch') {
        if (args[0].binary) {
          return ctx.newString(JSON.stringify({
            value: { status: 200, headers: {}, body: '', bytes: args[0].body, url: args[0].url }
          }));
        }
        return ctx.newString(JSON.stringify({ error: 'Forbidden', status: 403, blocked: true }));
      }
      else throw new Error('Unexpected host call: ' + method);
      return ctx.newString(JSON.stringify({ value }));
    });
    ctx.setProp(ctx.global, '__rpc', rpc);
    rpc.dispose();
    const literal = value => JSON.stringify(value);
    const source = `(() => {const setup = (${bootstrap})('fixture', __rpc); const module = {exports:{}};
      (function(module,exports,host){${code}\n})(module,module.exports,setup.host);
      return setup.invoke(module.exports,${literal(name)},${literal(JSON.stringify(args))});})()`;
    let value;
    let error;
    try {
      const result = ctx.evalCode(source);
      if (result.error) {
        error = ctx.dump(result.error);
        result.error.dispose();
      } else {
        value = ctx.getString(result.value);
        result.value.dispose();
      }
    } finally { ctx.dispose(); runtime.dispose(); }
    return { value, error };
  }
  assert.equal(run('module.exports={test(){return 1}}').value, '1');
  assert.equal(run('module.exports={test(){return 2}}').value, '2');
  console.log('PASS updated module code executes on the next invocation');
  assert.equal(run('module.exports={test(){return [typeof process,typeof require,typeof fetch,typeof os,typeof std]}}').value,
    '["undefined","undefined","undefined","undefined","undefined"]');
  assert.equal(run('module.exports={test(){return [Object.getPrototypeOf(host)===null,Object.isFrozen(host)]}}').value, '[true,true]');
  console.log('PASS guest has no file, network, npm or native API access');
  assert.equal(run("module.exports={test(){return host.hexDecode('00FF01')}}").value, '[0,255,1]');
  assert.equal(run("module.exports={test(){return host.utf8Encode('中文')}}").value, '[228,184,173,230,150,135]');
  assert.equal(run("module.exports={test(){return [Object.prototype.toString.call(host.sha512('abc')),host.sha512('abc').length,Object.prototype.toString.call(host.gzip('x')),Array.from(host.gunzip(host.gzip('x')))]}}").value,
    '["[object Uint8Array]",64,"[object Uint8Array]",[4,5,6]]');
  assert.equal(run("module.exports={test(){const response=host.fetch({url:'https://example.org',method:'POST',body:new Uint8Array([255,0,128]),binary:true});return [response.status,Object.prototype.toString.call(response.body),Array.from(response.body),response.bytes===undefined]}}").value,
    '[200,"[object Uint8Array]",[255,0,128],true]');
  assert.equal(run("module.exports={test(){try{host.fetch({url:'https://example.org'})}catch(error){return [error.message,error.status,error.blocked]}}}").value,
    '["Forbidden",403,true]');
  console.log('PASS byte transport, sha512/gzip/gunzip, binary fetch bodies and structured host errors');
  assert.ok(run('module.exports={test(){return Promise.resolve(1)}}').error);
  assert.ok(run('module.exports={test(){while(true){}}}', 'test', [], 40).error);
  assert.ok(run('module.exports={test(){return new Uint8Array(100*1024*1024)}}').error);
  assert.ok(run('module.exports={test(){function recurse(){return recurse()}; return recurse()}}').error);
  console.log('PASS async-result rejection, infinite-loop, heap and stack protection');
  assert.ok(!engine.includes('MaxHostCalls') && !engine.includes('Module host call limit exceeded'),
    'host-call count limit must stay removed: upstream module hosts impose no call-count cap, deadline and byte budgets bound modules instead');
  assert.ok(engine.includes('MaxHostTotal') && engine.includes('Module timed out'),
    'deadline and total-response byte budget must remain enforced');
  console.log('PASS no host-call count cap while deadline and byte budgets remain');
  for (const file of fs.readdirSync(path.join(root, '.cache/module-work')).filter(file => file.endsWith('-main.js'))) {
    const code = fs.readFileSync(path.join(root, '.cache/module-work', file), 'utf8');
    const result = run(code, '');
    assert.equal(result.error, undefined, file + ': ' + JSON.stringify(result.error));
    const exported = JSON.parse(result.value);
    for (const method of ['categories', 'catalogPage', 'detail', 'resolveMedia']) assert.ok(exported.includes(method), file + ': ' + method);
  }
  console.log('PASS all 15 cached upstream modules load and expose the required API');
  assert.ok(calls > 0);
  console.log('QuickJS WASM guest tests passed; native OHOS/NAPI runtime execution still requires a connected device.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
