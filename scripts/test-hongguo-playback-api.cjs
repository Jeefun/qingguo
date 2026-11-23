const fs=require('node:fs'),path=require('node:path'),Module=require('node:module'),assert=require('node:assert/strict');
const ts=require('./load-typescript.cjs');
require.extensions['.ets']=(m,f)=>m._compile(ts.transpileModule(fs.readFileSync(f,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,f);
const root=path.resolve(__dirname,'../entry/src/main/ets');
function stub(f,exports){const n=path.join(root,f);const m=new Module(n);m.exports=exports;require.cache[n]=m;}
const http={request:async()=>{throw Error('Unexpected HTTP')}};
stub('data/QgHttp.ets',{QgHttp:http});stub('data/QgGateway.ets',{QgGateway:{}});
const {HongguoSource:S}=require(path.join(root,'data/source/HongguoSource.ets'));
const id='1234567890123456789';S.registered=true;S.deviceId=id;S.installId='2234567890123456789';
const variant={video_meta:{codec_type:'h264',definition:'720p'},main_url:'https://media.test/public.mp4'};
const model={video_duration:60,video_list:{video_1:variant}};
let data;
http.request=async(url,method,headers,body)=>{
 if(method==='GET') { const text='{}'; return {status:404,data:Buffer.from(text),text:()=>text}; }
 const parsed=new URL(url),payload=JSON.parse(Buffer.from(body).toString());
 assert.equal(parsed.hostname,'api5-normal-sinfonlinea.fqnovel.com');
 assert.equal(parsed.pathname,'/novel/player/multi_video_model/player/v1');
 assert.equal(parsed.searchParams.get('version_code'),'74532');
 assert.equal(method,'POST');assert.equal(payload.biz_param.device_level,1);
 assert.equal(payload.biz_param.video_platform,1024);assert.deepEqual(payload.mixed_video_id_map,{'1004':[id]});
 assert.ok(headers['X-Medusa']);assert.ok(headers['X-Helios']);assert.equal(headers['X-Gorgon'],undefined);
 const text=JSON.stringify({data});return {status:200,data:Buffer.from(text),text:()=>text};
};
(async()=>{
 for(const grouped of [true,false])for(const encoded of [true,false]){
  const row={video_model:encoded?Buffer.from(JSON.stringify(model)).toString('base64'):model};
  data=grouped?{'1004':{[id]:row}}:{[id]:row};
  const info=await S.appMedia(id);assert.equal(info.url,variant.main_url);assert.equal(info.durationMs,60000);
 }
 console.log('PASS playback request contract and four response representations');
 data={'1004':{wrong:{video_model:model}}};await assert.rejects(S.appMedia(id),/所请求的分集/);
 console.log('PASS mismatched episode response rejected');
})().catch(e=>{console.error(e);process.exitCode=1});
