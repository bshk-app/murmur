import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';
const script=readFileSync(new URL('../Resources/background.js',import.meta.url),'utf8');
const sender={id:'extension-id',tab:{id:7},frameId:0,url:'https://example.test/page'};
const cfg={type:'config',sample:'Hello',documentLanguage:'en',url:'https://example.test/page'};
const request={type:'translate',runId:'run',requestId:'request',source:'en',target:'fi',groups:[{id:'g',runs:[{id:'r',text:'Hello'}]}],totalCharacters:5};
const ticket='12345678-1234-1234-1234-123456789abc';
function fixture(handler=message=>({ok:true,runId:message.runId,requestId:message.requestId})){
 const calls=[],injections=[],opens=[];let message,click;
 const browser={
  runtime:{id:'extension-id',onMessage:{addListener(fn){message=fn;}},sendNativeMessage(application,payload){calls.push({application,payload});return Promise.resolve(handler(payload));}},
  action:{onClicked:{addListener(fn){click=fn;}}},
  scripting:{async executeScript(spec){injections.push(spec);}},
  tabs:{async sendMessage(id,payload,options){opens.push({id,payload,options});}}
 };
 vm.runInNewContext(script,{browser,URL,Date,Map,Set,Number,Promise,crypto:webcrypto,TextEncoder,Uint8Array});
 return {calls,injections,opens,send:(payload,context=sender)=>message(payload,context),click:()=>click({...sender.tab,url:sender.url})};
}
test('foreign extensions, missing tab, subframes and non-web pages cannot reach native',async()=>{const f=fixture();for(const context of [{...sender,id:'other'},{...sender,tab:undefined},{...sender,frameId:1},{...sender,url:'file:///private/data'},{...sender,url:'safari-extension://foo'}])assert.equal((await f.send({...cfg,ticket},context)).code,'invalidRequest');assert.equal(f.calls.length,0);});
test('action injects only top frame then opens header',async()=>{const f=fixture();await f.click();assert.deepEqual([...f.injections[0].target.frameIds],[0]);assert.equal(f.injections[0].files[0],'content.js');assert.equal(f.opens[0].payload.type,'open');assert.equal((await f.send(cfg)).ok,true);assert.equal(f.calls[0].application,'app.bshk.murmur.ios');});
test('ticket config cannot switch URL or bypass UUID validation',async()=>{const f=fixture();assert.equal((await f.send({...cfg,url:'https://evil.test/',ticket})).code,'invalidRequest');assert.equal((await f.send({...cfg,ticket:'forged'})).code,'invalidTicket');assert.equal(f.calls.length,0);assert.equal((await f.send({...cfg,ticket})).ok,true);assert.equal(f.calls[0].payload.ticket,ticket);});
test('native invalidTicket propagates unchanged',async()=>{const f=fixture(()=>({ok:false,code:'invalidTicket'}));assert.equal((await f.send({...cfg,ticket})).code,'invalidTicket');assert.equal(f.calls.length,1);});
test('all malformed translate dimensions are rejected before native',async()=>{const f=fixture();const bad=[{...request,groups:[]},{...request,totalCharacters:6},{...request,groups:Array(9).fill(request.groups[0])},{...request,groups:[{id:'g',runs:[{id:'r',text:'x'.repeat(4801)}]}],totalCharacters:4801},{...request,groups:[{id:'g',runs:Array.from({length:33},(_,i)=>({id:String(i),text:'x'}))}],totalCharacters:33},{...request,groups:[{id:'g',runs:[{id:'r',text:'Hi'},{id:'r',text:'Hi'}]}],totalCharacters:4},{...request,runId:'a'.repeat(129)}];for(const payload of bad)assert.equal((await f.send(payload)).code,'invalidRequest');assert.equal(f.calls.length,0);});
test('native run IDs are tab-isolated, bounded and stable across background recreation',async()=>{const first=fixture();const result=await first.send(request);assert.equal(result.runId,request.runId);assert.equal(first.calls[0].payload.runId.length,68);const second=fixture();await second.send({type:'cancel',runId:request.runId,requestId:request.requestId});assert.equal(second.calls[0].payload.runId,first.calls[0].payload.runId);await second.send({type:'cancel',runId:request.runId,requestId:request.requestId},{...sender,tab:{id:8}});assert.notEqual(second.calls[1].payload.runId,first.calls[0].payload.runId);});
test('progress and cancellation do not wait for translation response',async()=>{let finish;const held=new Promise(resolve=>{finish=resolve;});let nativeRequest;const f=fixture(message=>{if(message.type==='translate'){nativeRequest=message;return held;}return {ok:true,phase:'preparing',fraction:.5};});const pending=f.send(request);for(let i=0;i<50&&!nativeRequest;i++)await new Promise(resolve=>setTimeout(resolve,2));const progress={type:'progress',runId:'run',requestId:'request'};assert.equal((await f.send(progress)).phase,'preparing');assert.equal((await f.send({...progress,type:'cancel'})).ok,true);assert.equal(f.calls.length,3);assert.equal(f.calls[0].payload.runId,f.calls[1].payload.runId);finish({ok:true,runId:nativeRequest.runId,requestId:nativeRequest.requestId});assert.equal((await pending).runId,'run');});
test('native mismatched run ID is rejected',async()=>{const f=fixture(()=>({ok:true,runId:'wrong',requestId:'request'}));assert.equal((await f.send(request)).code,'translationFailed');});
test('fragment URL config remains same page',async()=>{const f=fixture();assert.equal((await f.send({...cfg,url:cfg.url+'#part',ticket})).ok,true);});
test('manifest offers no external relay or iframe injection',()=>{const manifest=JSON.parse(readFileSync(new URL('../Resources/manifest.json',import.meta.url)));assert.equal(manifest.manifest_version,3);assert.equal(manifest.externally_connectable,undefined);assert.equal(manifest.content_scripts[0].all_frames,false);assert.equal(manifest.content_scripts[0].run_at,'document_idle');assert.deepEqual(manifest.permissions,['nativeMessaging','activeTab','scripting']);});
