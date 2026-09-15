import { readFileSync } from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const script = readFileSync(new URL('../Resources/Page.js', import.meta.url), 'utf8');
function page(html, language = 'en') {
    const dom = new JSDOM(`<!doctype html><html${language === null ? '' : ` lang="${language}"`}><head><title>Fixture</title></head><body>${html}</body></html>`, {
        url: 'https://example.test/page?one=1', runScripts: 'outside-only', pretendToBeVisual: true
    });
    dom.window.eval(script);
    const window = dom.window, document = window.document;
    return {
        window, document,
        run() {
            let payload;
            window.ExtensionPreprocessingJS.run({ completionFunction(value) { payload = value; } });
            return payload;
        },
        finalize(payload, transform = text => text.toUpperCase(), overrides = {}) {
            window.ExtensionPreprocessingJS.finalize({
                version: 1, runId: payload.runId, action: 'apply', source: 'en', target: 'fi', fallbackGroups: [],
                translations: payload.groups.flatMap(group => group.runs.map(run => ({ id: run.id, text: transform(run.text, run.id) }))),
                labels: { translated: 'Sivu käännetty', showOriginal: 'Näytä alkuperäinen', showTranslation: 'Näytä käännös', close: 'Sulje ja palauta', changedPage: 'Sivu muuttui', partial: 'Osittainen käännös' },
                ...overrides
            });
        },
        click(id) { document.getElementById('murmator-page-translation').shadowRoot.getElementById(id).click(); },
        get bar() { return document.getElementById('murmator-page-translation')?.shadowRoot; }
    };
}

// Model Safari's distinct JS-world wrappers: these are different references,
// but WebIDL still recognises them as the same underlying DOM nodes.
function wrapSnapshotNodes(snapshot) {
    for (const group of snapshot.groups) {
        group.owner = new Proxy(group.owner, {});
        for (const run of group.runs) {
            run.node = new Proxy(run.node, {});
            run.path = run.path.map(node => new Proxy(node, {}));
        }
    }
}

test('v1 payload groups inline nodes and links in paragraph order, retaining whitespace', () => {
    const fixture = page('<h1>Heading</h1><p> Hello <strong>beautiful</strong> <a href="/world">world</a>! </p><p>Next</p>');
    const payload = fixture.run();
    assert.equal(payload.version, 1);
    assert.equal(payload.documentLanguage, 'en');
    assert.equal(payload.url, 'https://example.test/page?one=1');
    assert.equal(payload.title, 'Fixture');
    assert.deepEqual(Array.from(payload.groups, g => Array.from(g.runs, r => r.text)), [
        ['Heading'], [' Hello ', 'beautiful', ' ', 'world', '! '], ['Next']
    ]);
    assert.equal(payload.totalCharacters, 35);
    assert.equal(payload.truncated, false);
    assert.equal(new Set(payload.groups.flatMap(g => g.runs.map(r => r.id))).size, 7);
});

test('protects forms, code, editable, hidden and explicitly untranslated text', () => {
    const fixture = page('<p>Translate <code>secret()</code> this</p><form>Personal <label>Name<input value="Jane"></label></form><pre>code</pre><button>Action</button><textarea>Draft</textarea><p contenteditable="true">Editable <span contenteditable="false">Protected too</span></p><div hidden>Hidden</div><div style="display:none">Hidden CSS</div><div style="visibility:hidden">Invisible</div><p aria-hidden="true">ARIA hidden</p><p translate="no">Original only</p><div class="notranslate">Excluded</div><svg><text>Vector</text></svg><p>Привет 世界 مرحبا</p>');
    const payload = fixture.run();
    assert.deepEqual(Array.from(payload.groups, g => Array.from(g.runs, r => r.text)), [['Translate '], [' this'], ['Привет 世界 مرحبا']]);
    fixture.finalize(payload);
    assert.equal(fixture.document.querySelector('input').value, 'Jane');
    assert.equal(fixture.document.querySelector('textarea').value, 'Draft');
    assert.equal(fixture.document.querySelector('code').textContent, 'secret()');
    assert.equal(fixture.document.querySelector('[contenteditable]').textContent, 'Editable Protected too');
});

test('block and explicit line break boundaries do not merge unrelated contexts', () => {
    const fixture = page('<div>Intro <span>inline</span><p>Nested paragraph</p>After<br>Line two</div><ul><li>First</li><li>Second</li></ul>');
    assert.deepEqual(Array.from(fixture.run().groups, g => g.runs.map(r => r.text).join('')), ['Intro inline', 'Nested paragraph', 'After', 'Line two', 'First', 'Second']);
});

test('apply preserves live links, listeners, markup and node boundary whitespace', () => {
    const fixture = page('<p> Hello <a href="/target">world</a>! </p>');
    const link = fixture.document.querySelector('a');
    let clicks = 0; link.addEventListener('click', event => { event.preventDefault(); clicks++; });
    const payload = fixture.run();
    fixture.finalize(payload, text => text.trim().toUpperCase());
    assert.equal(fixture.document.querySelector('p').textContent, ' HELLO WORLD! ');
    assert.equal(fixture.document.querySelector('a'), link);
    assert.equal(link.getAttribute('href'), '/target');
    link.click(); assert.equal(clicks, 1);
    assert.equal(fixture.document.documentElement.lang, 'fi');
    assert.equal(fixture.bar.querySelector('[role=status]').textContent, 'MurmatorSivu käännetty');
    assert.equal(fixture.bar.getElementById('murmator-close').getAttribute('aria-label'), 'Sulje ja palauta');
});

test('toggle round trips and close restores exact original including missing lang', () => {
    const fixture = page('<p>  Original <b>words</b>\n</p>', null);
    const before = fixture.document.querySelector('p').textContent;
    fixture.finalize(fixture.run());
    fixture.click('murmator-toggle');
    assert.equal(fixture.document.querySelector('p').textContent, before);
    assert.equal(fixture.document.documentElement.hasAttribute('lang'), false);
    assert.equal(fixture.bar.getElementById('murmator-toggle').textContent, 'Näytä käännös');
    fixture.click('murmator-toggle');
    assert.equal(fixture.document.querySelector('p').textContent, before.toUpperCase());
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, before);
    assert.equal(fixture.document.documentElement.hasAttribute('lang'), false);
    assert.equal(fixture.bar, undefined);
});

test('repeat invocation and cancellation read originals and leave current page untouched', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run());
    // Safari may load the preprocessor file again for a new Action invocation.
    fixture.window.eval(script);
    const before = fixture.document.body.innerHTML;
    const second = fixture.run();
    assert.equal(second.documentLanguage, 'en');
    assert.equal(second.groups.flatMap(g => g.runs.map(r => r.text)).join(''), 'Hello world');
    fixture.finalize(second, undefined, { action: 'cancel' });
    assert.equal(fixture.document.body.innerHTML, before);
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
});

test('second accepted language replaces translated text but close restores first original', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run());
    fixture.finalize(fixture.run(), text => `(${text.trim()})`, { target: 'de' });
    assert.equal(fixture.document.querySelector('p').textContent, '(Hello) (world)');
    assert.equal(fixture.document.documentElement.lang, 'de');
    assert.equal(fixture.document.querySelectorAll('#murmator-page-translation').length, 1);
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    assert.equal(fixture.document.documentElement.lang, 'en');
});

test('distinct same-DOM-node wrappers preserve apply, toggle, close and original cache', () => {
    const fixture = page('<p>Hello <b>world</b></p><p>Other text</p>');
    const first = fixture.run();
    const session = fixture.window.__murmatorPageTranslationV1;
    wrapSnapshotNodes(session.pending);
    assert.notEqual(session.pending.groups[0].owner, fixture.document.querySelector('p'));
    assert.equal(session.pending.groups[0].owner.isSameNode(fixture.document.querySelector('p')), true);
    fixture.finalize(first);
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO WORLD');
    wrapSnapshotNodes(session.active);
    fixture.click('murmator-toggle');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    fixture.click('murmator-toggle');
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO WORLD');
    fixture.window.eval(script);
    const second = fixture.run();
    assert.equal(second.groups[0].runs.map(run => run.text).join(''), 'Hello world');
    wrapSnapshotNodes(session.pending);
    fixture.finalize(second, text => `(${text.trim()})`, { target: 'de' });
    assert.equal(fixture.document.querySelector('p').textContent, '(Hello) (world)');
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    assert.equal(fixture.document.querySelectorAll('p')[1].textContent, 'Other text');
    assert.equal(fixture.document.documentElement.lang, 'en');
});

test('cross-world wrappers do not make a replaced or moved node eligible', () => {
    const fixture = page('<p>Hello <b>world</b></p><p>Other</p>');
    const payload = fixture.run();
    wrapSnapshotNodes(fixture.window.__murmatorPageTranslationV1.pending);
    fixture.document.querySelector('b').textContent = 'world';
    const other = fixture.document.querySelectorAll('p')[1];
    const wrapper = fixture.document.createElement('section');
    other.replaceWith(wrapper); wrapper.appendChild(other);
    fixture.finalize(payload);
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    assert.equal(other.textContent, 'Other');
    assert.match(fixture.bar.textContent, /Sivu muuttui/);
});

test('fresh Action globals reuse the retained toolbar controller for originals and cancellation', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run());
    const oldSession = fixture.window.__murmatorPageTranslationV1;
    wrapSnapshotNodes(oldSession.active);
    delete fixture.window.__murmatorPageTranslationV1;
    fixture.window.eval(script);
    assert.equal(fixture.window.__murmatorPageTranslationV1.active, null);
    const second = fixture.run();
    assert.equal(second.documentLanguage, 'en');
    assert.equal(second.groups[0].runs.map(run => run.text).join(''), 'Hello world');
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO WORLD');
    fixture.finalize(second, undefined, { action: 'cancel' });
    assert.equal(oldSession.pending, null);
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO WORLD');
    const host = fixture.document.getElementById('murmator-page-translation');
    assert.equal(host.hasAttribute('data-murmator-request'), false);
    assert.equal(host.hasAttribute('data-murmator-response'), false);
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
});

test('fresh Action globals apply a new translation and retain exact first originals on close', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run());
    delete fixture.window.__murmatorPageTranslationV1;
    fixture.window.eval(script);
    const second = fixture.run();
    fixture.finalize(second, text => `(${text.trim()})`, { target: 'de' });
    assert.equal(fixture.document.querySelector('p').textContent, '(Hello) (world)');
    assert.equal(fixture.document.documentElement.lang, 'de');
    delete fixture.window.__murmatorPageTranslationV1;
    fixture.window.eval(script);
    const third = fixture.run();
    assert.equal(third.groups[0].runs.map(run => run.text).join(''), 'Hello world');
    assert.equal(third.documentLanguage, 'en');
    fixture.finalize(third, undefined, { action: 'cancel' });
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    assert.equal(fixture.document.documentElement.lang, 'en');
});

test('a changed run makes its entire inline group ineligible', () => {
    const fixture = page('<p>Hello <b>world</b></p><p>Unchanged</p>');
    const payload = fixture.run();
    fixture.document.querySelector('b').firstChild.nodeValue = 'updated';
    fixture.finalize(payload);
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello updated');
    assert.equal(fixture.document.querySelectorAll('p')[1].textContent, 'UNCHANGED');
    assert.match(fixture.bar.textContent, /Osittainen käännös/);
    assert.equal(fixture.document.documentElement.lang, 'en');
});

test('replaced, inserted or reordered DOM nodes reject affected group atomically', async t => {
    for (const mutation of [
        document => { document.querySelector('b').textContent = 'world'; },
        document => { document.querySelector('p').appendChild(document.createTextNode(' new')); },
        document => { const p = document.querySelector('p'); p.prepend(p.querySelector('b')); },
        document => { const p = document.querySelector('p'); const wrapper = document.createElement('section'); p.replaceWith(wrapper); wrapper.appendChild(p); }
    ]) await t.test(mutation.toString(), () => {
        const fixture = page('<p>Hello <b>world</b></p>');
        const payload = fixture.run(); mutation(fixture.document);
        const before = fixture.document.querySelector('p').textContent;
        fixture.finalize(payload);
        assert.equal(fixture.document.querySelector('p').textContent, before);
        assert.match(fixture.bar.textContent, /Sivu muuttui/);
    });
});

test('missing or duplicate outputs skip complete group, stale run IDs are inert', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    const payload = fixture.run();
    fixture.finalize(payload, undefined, { runId: 'stale' });
    assert.equal(fixture.bar, undefined);
    fixture.finalize(payload, undefined, { translations: [{ id: 'r0', text: 'HELLO' }] });
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    const next = fixture.run();
    fixture.finalize(next, undefined, { translations: [{ id: 'r0', text: 'HELLO' }, { id: 'r1', text: 'WORLD' }, { id: 'r1', text: 'OTHER' }] });
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
});

test('untrusted translation and label strings are displayed as plain text', () => {
    const fixture = page('<p>Hello</p>');
    const malicious = '<img src=x onerror="window.hacked=true"><script>alert(1)</script>';
    fixture.finalize(fixture.run(), () => malicious, { labels: { translated: malicious } });
    assert.equal(fixture.document.querySelector('p').textContent, malicious);
    assert.equal(fixture.document.querySelector('p').children.length, 0);
    assert.equal(fixture.bar.querySelectorAll('img,script').length, 0);
    assert.equal(fixture.window.hacked, undefined);
});

test('empty output cannot erase a nonempty run', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run(), () => '   ');
    assert.equal(fixture.document.querySelector('p').textContent, 'Hello world');
    assert.match(fixture.bar.textContent, /Sivu muuttui/);
});

test('page making existing text editable after translation prevents toggle writes', () => {
    const fixture = page('<p>Hello <b>world</b></p>');
    fixture.finalize(fixture.run());
    fixture.document.querySelector('p').setAttribute('contenteditable', 'true');
    fixture.click('murmator-toggle');
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO WORLD');
});

test('toggle and close preserve text changed by the page after translation', () => {
    const fixture = page('<p>Hello <b>world</b></p><p>Other</p>');
    fixture.finalize(fixture.run());
    fixture.document.querySelector('b').firstChild.nodeValue = 'Live update';
    fixture.document.documentElement.lang = 'sv';
    fixture.click('murmator-toggle');
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO Live update');
    assert.equal(fixture.document.querySelectorAll('p')[1].textContent, 'Other');
    fixture.click('murmator-close');
    assert.equal(fixture.document.querySelector('p').textContent, 'HELLO Live update');
    assert.equal(fixture.document.documentElement.lang, 'sv');
});

test('200k character cap is explicit and never slices a text node or group', () => {
    const exact = page(`<p>${'a'.repeat(200000)}</p>`).run();
    assert.equal(exact.totalCharacters, 200000); assert.equal(exact.truncated, false);
    const overflow = page(`<p>Included</p><p>${'a'.repeat(200001)}</p>`).run();
    assert.equal(overflow.totalCharacters, 8); assert.equal(overflow.truncated, true);
    assert.equal(overflow.groups.length, 1);
    const combined = page(`<p>${'a'.repeat(120000)}<b>${'b'.repeat(100000)}</b></p>`).run();
    assert.equal(combined.groups.length, 0); assert.equal(combined.truncated, true);
});

test('4000 run cap and 2000 group cap are explicit and atomic', () => {
    const runs = page(`<p>${'<span>a</span>'.repeat(4000)}</p><p>Beyond</p>`).run();
    assert.equal(runs.groups.length, 1); assert.equal(runs.groups[0].runs.length, 4000); assert.equal(runs.truncated, true);
    const hugeGroup = page(`<p>${'<span>a</span>'.repeat(4001)}</p>`).run();
    assert.equal(hugeGroup.groups.length, 0); assert.equal(hugeGroup.truncated, true);
    const groups = page('<p>a</p>'.repeat(2001)).run();
    assert.equal(groups.groups.length, 2000); assert.equal(groups.truncated, true);
});

test('no readable body is a valid empty payload', () => {
    const fixture = page('<pre>Code only</pre>');
    const payload = fixture.run();
    assert.equal(payload.groups.length, 0);
    assert.equal(payload.totalCharacters, 0);
    assert.equal(payload.truncated, false);
});

test('Arabic output reads right to left; toggle and close restore direction', () => {
    const fixture = page('<p>Hello</p>');
    const root = fixture.document.documentElement;
    fixture.finalize(fixture.run(), undefined, { target: 'ar' });
    assert.equal(root.getAttribute('dir'), 'rtl');
    fixture.click('murmator-toggle');
    assert.equal(root.hasAttribute('dir'), false);
    fixture.click('murmator-toggle');
    assert.equal(root.getAttribute('dir'), 'rtl');
    fixture.click('murmator-close');
    assert.equal(root.hasAttribute('dir'), false);
});

test('RTL page translated into an LTR language is laid out left to right until closed', () => {
    const fixture = page('<p>Hello</p>', 'ar');
    const root = fixture.document.documentElement;
    root.setAttribute('dir', 'rtl');
    fixture.finalize(fixture.run(), undefined, { source: 'ar', target: 'en' });
    assert.equal(root.getAttribute('dir'), 'ltr');
    fixture.click('murmator-close');
    assert.equal(root.getAttribute('dir'), 'rtl');
});
