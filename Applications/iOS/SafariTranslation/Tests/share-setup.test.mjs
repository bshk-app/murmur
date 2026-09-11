import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {JSDOM} from 'jsdom';
const script=fs.readFileSync(new URL('../../PageTranslation/Resources/SharePage.js',import.meta.url),'utf8');
function fixture(){const dom=new JSDOM('<!doctype html><html><body><p>Original page</p></body></html>',{url:'https://example.test/',runScripts:'outside-only'});dom.window.eval(script);return dom;}
test('Share setup closes with the native disclosure action and can be reopened',()=>{
 const dom=fixture();const {window}=dom;const run=()=>window.ExtensionPreprocessingJS.finalize({action:'setup',message:'Permission needed',close:'Close'});
 run();let host=window.document.getElementById('murmator-stream-setup');let details=host.shadowRoot.querySelector('details');let close=host.shadowRoot.querySelector('summary');
 assert.ok(details.open);assert.equal(close.onclick,null);close.click();assert.equal(details.open,false);assert.match(host.shadowRoot.querySelector('style').textContent,/\.panel:not\(\[open\]\)\{display:none\}/);
 run();assert.equal(window.document.querySelectorAll('#murmator-stream-setup').length,1);assert.ok(window.document.getElementById('murmator-stream-setup').shadowRoot.querySelector('details').open);assert.equal(window.document.querySelector('p').textContent,'Original page');window.close();
});
test('Share handoff probes without text and clears the single-use ticket after synchronous receipt',()=>{
 const dom=fixture();const {window}=dom;const root=window.document.documentElement;const ticket='11111111-2222-4333-8444-555555555555';
 root.addEventListener('murmator-stream-probe',()=>root.setAttribute('data-murmator-stream-ready','1'));
 let metadata;window.ExtensionPreprocessingJS.run({completionFunction:data=>metadata=data});assert.equal(metadata.extensionAvailable,true);assert.equal(metadata.url,'https://example.test/');assert.equal('text' in metadata,false);
 root.addEventListener('murmator-stream-start',()=>{assert.equal(root.getAttribute('data-murmator-stream-ticket'),ticket);root.setAttribute('data-murmator-stream-received','1');});
 window.ExtensionPreprocessingJS.finalize({action:'start',ticket});assert.equal(window.document.getElementById('murmator-stream-setup'),null);assert.equal(root.hasAttribute('data-murmator-stream-ticket'),false);assert.equal(root.hasAttribute('data-murmator-stream-received'),false);window.close();
});
