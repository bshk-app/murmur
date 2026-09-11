import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const results = path.resolve(process.env.SAFARI_RESULTS || '/tmp/murmator-progressive-evidence');
fs.mkdirSync(results, { recursive: true });
const en = ['I will send the documents tomorrow.', 'The city library opens at nine in the morning. You can borrow books and read newspapers there.', 'Public transportation is an easy way to travel around the city. The bus station is next to the railway station.'];
const fi = ['Lähetän asiakirjat huomenna.', 'Kirjasto avautuu aamulla kello yhdeksän. Voit lainata kirjoja ja lukea sanomalehtiä.', 'Bussiasema on rautatieaseman vieressä. Voimme tavata siellä huomenna.'];
function page(url) {
    const language = url.searchParams.get('lang') === 'fi' ? 'fi' : 'en';
    const long = url.pathname === '/long';
    const sentences = language === 'fi' ? fi : en;
    const count = long ? 72 : 12;
    const paragraphs = Array.from({ length: count }, (_, i) => `<p id="p${i}" data-sample>${sentences[i % sentences.length]}</p>`).join('\n');
    return `<!doctype html><html lang="${language}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Progressive Safari fixture</title><style>body{font:18px/1.5 system-ui;margin:0;background:#faf7f2;color:#2a2520}main{padding:20px}p{margin:20px 0}aside{font:12px/1.3 system-ui;padding:8px;background:#e7f4df}button{font:inherit;min-height:44px}input,textarea{font:inherit;width:90%}</style><body>
    <aside data-murmator-page-ignore><div id="fixture-status" role="status">READY: Progressive Safari fixture</div><button id="verify">Verify page integrity</button><button id="mutate">Edit page externally</button><button id="scroll-top">Scroll to top</button></aside>
    <main><h1>${language === 'fi' ? 'Huomisen suunnitelma' : 'Tomorrow’s plan'}</h1>${paragraphs}<p id="inline">Bring <strong id="strong">your camera</strong> and <a id="link" href="#destination">walk by the sea</a>.</p><p id="mutable">This sentence can change while translation is running.</p><p translate="no" id="excluded">KEEP EXCLUDED TEXT</p><input id="input" value="KEEP INPUT"><textarea id="textarea">KEEP TEXTAREA</textarea><p contenteditable="true" id="editable">KEEP EDITABLE TEXT</p><pre id="code">const keep = 'SOURCE';</pre><div id="destination"></div></main>
    <script>
    (()=>{
      const nodes=[...document.querySelectorAll('[data-sample]')];
      const original=nodes.map(n=>n.textContent);const parents=nodes.map(n=>n.parentNode);
      const strong=document.querySelector('#strong'), link=document.querySelector('#link');
      const inline=document.querySelector('#inline'), inlineText=inline.textContent;
      let seen=false, stoppedCount=null, changed=false, last='', serial=0;
      function snapshot(){
        const host=document.getElementById('murmator-stream'), shadow=host?.shadowRoot;
        const count=nodes.filter((n,i)=>n.textContent!==original[i]).length;
        const status=shadow?.getElementById('murmator-status')?.textContent||'';
        const percent=Number(shadow?.getElementById('murmator-progress')?.getAttribute('aria-valuenow')||0);
        const source=shadow?.getElementById('murmator-source')?.value||'';
        const target=shadow?.getElementById('murmator-target')?.value||'';
        const showingOriginal=shadow?.getElementById('murmator-original')?.getAttribute('aria-pressed')==='true';
        const intact=nodes.every((n,i)=>n.isConnected&&n.parentNode===parents[i])&&document.getElementById('strong')===strong&&document.getElementById('link')===link&&link.getAttribute('href')==='#destination'&&document.getElementById('input').value==='KEEP INPUT'&&document.getElementById('textarea').value==='KEEP TEXTAREA'&&document.getElementById('editable').textContent==='KEEP EDITABLE TEXT'&&document.getElementById('excluded').textContent==='KEEP EXCLUDED TEXT'&&document.getElementById('code').textContent==="const keep = 'SOURCE';"&&(!changed||document.getElementById('mutable').textContent==='Website updated this text.');
        if(host)seen=true;
        let state=!intact?'FAIL: page integrity':!seen?'READY: Progressive Safari fixture':!host&&count===0&&inline.textContent===inlineText?'PASS: closed':showingOriginal&&count===0&&inline.textContent===inlineText?'PASS: original':status==='Stopped'?'PASS: stopped':percent===100&&count===nodes.length?'PASS: translated':count>0&&count<nodes.length?'PASS: partial':'RUNNING';
        return {state,count,total:nodes.length,percent,source,target,status,intact,showingOriginal,changed,host:!!host,first:nodes[0].textContent};
      }
      function report(force=false){const data=snapshot();document.getElementById('fixture-status').textContent=data.state;const signature=JSON.stringify(data);if(force||signature!==last){last=signature;fetch('/report?visit='+encodeURIComponent(new URL(location.href).searchParams.get('visit')||'unknown'),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...data,serial:++serial,time:Date.now()})}).catch(()=>{});}}
      document.getElementById('verify').onclick=()=>report(true);
      document.getElementById('mutate').onclick=()=>{document.getElementById('mutable').textContent='Website updated this text.';changed=true;report(true);};
      document.getElementById('scroll-top').onclick=()=>scrollTo(0,0);
      setInterval(report,120);report(true);
    })();
    </script></body></html>`;
}
const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1:18765');
    if (request.method === 'POST' && url.pathname === '/report') {
        let body = ''; request.on('data', chunk => { body += chunk; if (body.length > 20000) request.destroy(); });
        request.on('end', () => {
            try { const data = JSON.parse(body); const visit = (url.searchParams.get('visit') || '').replace(/[^a-zA-Z0-9-]/g, '').slice(0,80); fs.appendFileSync(path.join(results, `${visit || 'unknown'}.jsonl`), JSON.stringify(data) + '\n'); response.writeHead(204).end(); }
            catch { response.writeHead(400).end(); }
        }); return;
    }
    if (['/small','/long'].includes(url.pathname)) { response.writeHead(200, {'Content-Type':'text/html;charset=utf-8','Cache-Control':'no-store'}).end(page(url)); return; }
    response.writeHead(404).end();
});
server.listen(18765, '127.0.0.1', () => console.log('Synthetic progressive fixture on 127.0.0.1:18765'));
