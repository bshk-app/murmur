import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';

const port = Number(process.env.PAGE_FIXTURE_PORT || 18765);
const results = process.env.PAGE_FIXTURE_RESULTS || '/tmp/murmator-page-integration-results';
fs.mkdirSync(results, {recursive: true});
const tokens = new Set();
const reports = [];

function fixture(long, token) {
  const paragraphs = long ? Array.from({length: 64}, (_, index) => `<p class="long-segment">Section ${index + 1}. I will send the documents tomorrow. We can meet by the station at three.</p>`).join('') : '';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Murmator production ${long ? 'long' : 'small'} fixture</title>
<style>body{font:18px -apple-system;line-height:1.55;margin:0;color:#282018;background:#faf7f2}main{padding:22px;max-width:700px;margin:auto}p{margin:18px 0}input,textarea{display:block;font:inherit;width:95%;margin:12px 0}#verify-original{font:inherit;min-height:44px;padding:8px 12px}#fixture-status{background:#dfeeda;padding:12px;font-weight:600}pre{white-space:pre-wrap;font-size:12px}</style></head><body><main>
<div translate="no"><p id="fixture-status">READY: Production page translation</p><button id="verify-original">Verify original page</button><p>Share → Murmator → Translate. Real installed language packages.</p></div>
<h1 id="heading">A plan for tomorrow</h1><p id="sentence">I will send the documents tomorrow.</p>
<p id="inline">Please bring <strong id="strong">your camera</strong> and <a id="link" href="#destination">walk by the sea</a>.</p>
<ul><li>Buy fresh bread at the market.</li><li>Take a train on Friday.</li></ul><p id="destination">Could we meet by the station at three?</p>
${paragraphs}
<div><h2 translate="no">Protected fields</h2><input id="input" value="Do not translate this input"><textarea id="textarea">Do not translate this textarea</textarea><p contenteditable="true" id="editable">Do not translate this editable text</p><pre><code id="code">const untouched = "Original code";</code></pre><p translate="no" id="excluded">Explicitly excluded English sentence.</p><div translate="no"><pre id="checks"></pre></div></div></main>
<script>
const token = ${JSON.stringify(token)};
const page = ${JSON.stringify(long ? 'long' : 'small')};
const byId = id => document.getElementById(id);
const originalURL = location.href;
const strong = byId('strong'), link = byId('link');
const originals = {sentence: byId('sentence').textContent, inline: byId('inline').textContent, heading: byId('heading').textContent, lang: document.documentElement.getAttribute('lang'), input: byId('input').value, textarea: byId('textarea').value, editable: byId('editable').textContent, code: byId('code').textContent, excluded: byId('excluded').textContent, href: link.getAttribute('href')};
const longNodes = Array.from(document.querySelectorAll('.long-segment'));
const longOriginals = longNodes.map(node => node.textContent);
let wasTranslated = false, lastState = '';
function observe(forceOriginalCheck) {
  if (typeof document === 'undefined' || !document.documentElement || !byId('sentence')) return;
  const toolbar = byId('murmator-page-translation');
  const lang = document.documentElement.getAttribute('lang');
  let stage;
  if (forceOriginalCheck === true) stage = 'unchanged';
  else if (toolbar && lang === 'fi') { stage = 'translated'; wasTranslated = true; }
  else if (wasTranslated && lang === originals.lang) stage = toolbar ? 'restored' : 'closed';
  else return;
  const state = stage + '|' + byId('sentence').textContent + '|' + byId('inline').textContent;
  if (state === lastState) return;
  lastState = state;
  const checks = {
    urlPreserved: location.href === originalURL,
    strongElementPreserved: byId('strong') === strong,
    linkElementPreserved: byId('link') === link,
    hrefPreserved: link.getAttribute('href') === originals.href,
    inputPreserved: byId('input').value === originals.input,
    textareaPreserved: byId('textarea').value === originals.textarea,
    editablePreserved: byId('editable').textContent === originals.editable,
    codePreserved: byId('code').textContent === originals.code,
    excludedPreserved: byId('excluded').textContent === originals.excluded
  };
  if (stage === 'translated') {
    Object.assign(checks, {
      languageUpdated: lang === 'fi',
      sentenceChanged: byId('sentence').textContent !== originals.sentence,
      finnishSentence: /huomenna/i.test(byId('sentence').textContent),
      inlineTextChanged: byId('inline').textContent !== originals.inline,
      headingChanged: byId('heading').textContent !== originals.heading,
      allLongParagraphsTranslated: longNodes.every((node, index) => node.textContent !== longOriginals[index] && /huomenna/i.test(node.textContent)),
      toolbarHasOpenShadow: !!toolbar.shadowRoot,
      toolbarTogglePresent: !!toolbar.shadowRoot?.getElementById('murmator-toggle'),
      toolbarClosePresent: !!toolbar.shadowRoot?.getElementById('murmator-close')
    });
  } else {
    Object.assign(checks, {
      languageRestored: lang === originals.lang,
      sentenceRestored: byId('sentence').textContent === originals.sentence,
      inlineTextRestored: byId('inline').textContent === originals.inline,
      headingRestored: byId('heading').textContent === originals.heading,
      allLongParagraphsRestored: longNodes.every((node, index) => node.textContent === longOriginals[index])
    });
    if (stage === 'closed' || stage === 'unchanged') checks.toolbarRemoved = !toolbar;
  }
  const passed = Object.values(checks).every(Boolean);
  byId('fixture-status').textContent = (passed ? 'PASS: ' : 'FAIL: ') + stage;
  byId('checks').textContent = JSON.stringify(checks, null, 2);
  const report = {page, stage, checks, passed, sentence: byId('sentence').textContent, inline: byId('inline').textContent, longCount: longNodes.length, observedAt: new Date().toISOString(), userAgent: navigator.userAgent};
  fetch('/report', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Fixture-Token': token}, body: JSON.stringify(report)}).catch(() => {});
}
new MutationObserver(observe).observe(document.documentElement, {subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['lang']});
byId('verify-original').addEventListener('click', () => observe(true));
</script></body></html>`;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'GET' && url.pathname === '/health') {
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ready: true, port, results})); return;
  }
  if (req.method === 'GET' && url.pathname === '/reports') {
    res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(reports)); return;
  }
  if (req.method === 'POST' && url.pathname === '/report') {
    if (!tokens.has(req.headers['x-fixture-token'])) { res.writeHead(403).end(); return; }
    let body = '';
    for await (const chunk of req) { body += chunk; if (body.length > 250000) { res.writeHead(413).end(); return; } }
    try {
      const report = JSON.parse(body);
      const filename = 'page-' + Date.now() + '-' + randomUUID() + '.json';
      fs.writeFileSync(path.join(results, filename), JSON.stringify(report, null, 2) + '\n');
      reports.push(report); if (reports.length > 100) reports.shift();
      console.log(report.page, report.stage, report.passed ? 'PASS' : 'FAIL', filename);
      res.writeHead(200).end('saved');
    } catch { res.writeHead(400).end(); }
    return;
  }
  if (req.method !== 'GET' || !['/small', '/long'].includes(url.pathname)) { res.writeHead(404).end(); return; }
  const token = randomUUID(); tokens.add(token);
  if (tokens.size > 100) tokens.delete(tokens.values().next().value);
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end(fixture(url.pathname === '/long', token));
});
server.listen(port, '127.0.0.1', () => console.log('Production Safari fixtures: http://127.0.0.1:' + port + '/small and /long; reports: ' + results));
