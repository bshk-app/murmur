/* Isolated-world controller. Page text crosses only the local native bridge. */
(() => {
    'use strict';
    if (globalThis.__murmatorStreamInstalled) return;
    globalThis.__murmatorStreamInstalled = true;
    const EXCLUDED = 'script,style,noscript,template,form,input,textarea,select,button,pre,code,kbd,samp,svg,math,canvas,iframe,object,embed,[hidden],[inert],[aria-hidden="true"],[translate="no"],.notranslate,[data-murmator-page-ignore]';
    const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DETAILS|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|H[1-6]|HEADER|HGROUP|LI|MAIN|NAV|OL|P|SECTION|SUMMARY|TABLE|TBODY|TD|TFOOT|TH|THEAD|TR|UL)$/;
    const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const t = (key, substitutions) => browser.i18n.getMessage(key, substitutions) || key;
    let active = null, sequence = 0, activation = 0;
    const bridge = async payload => {
        try { return await browser.runtime.sendMessage(payload) || { ok: false, code: 'translationFailed' }; }
        catch (_) { return { ok: false, code: 'translationFailed' }; }
    };
    const same = (a, b) => a === b || Boolean(a && b && a.isSameNode(b));
    function protectedElement(element) {
        const editable = element.getAttribute('contenteditable');
        return element.matches(EXCLUDED) || (editable !== null && editable.toLowerCase() !== 'false');
    }
    function visible(element) {
        const style = getComputedStyle(element);
        return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse';
    }
    function pathsMatch(run) {
        if (!run.node.isConnected) return false;
        let parent = run.node.parentNode;
        for (const expected of run.path) {
            if (!same(parent, expected)) return false;
            if (parent.nodeType === Node.ELEMENT_NODE && (protectedElement(parent) || !visible(parent))) return false;
            parent = parent.parentNode;
        }
        return true;
    }
    function matches(group) {
        return !group.changed && group.runs.every(run => pathsMatch(run) && run.node.nodeValue === run.expected);
    }
    function collect() {
        const groups = [];
        let current = null, characters = 0, count = 0, truncated = false;
        const styles = new WeakMap();
        function flush() {
            if (!current) return;
            const group = current; current = null;
            if (!group.runs.some(run => /\S/u.test(run.original))) return;
            const length = group.runs.reduce((sum, run) => sum + run.original.length, 0);
            if (groups.length >= 2000 || count + group.runs.length > 4000 || characters + length > 200000) { truncated = true; return; }
            group.id = `g${groups.length}`;
            group.runs.forEach(run => { run.id = `r${count++}`; });
            group.characters = length; characters += length; groups.push(group);
        }
        function visit(node, owner) {
            if (truncated) return;
            if (node.nodeType === Node.TEXT_NODE) {
                if (!node.nodeValue) return;
                if (!current || current.owner !== owner) { flush(); current = { owner, runs: [] }; }
                const path = []; let parent = node.parentNode;
                while (parent) { path.push(parent); parent = parent.parentNode; }
                current.runs.push({ node, path, original: node.nodeValue, expected: node.nodeValue });
                if (current.runs.length > 4000 || current.runs.reduce((sum, run) => sum + run.original.length, 0) > 200000) { current = null; truncated = true; }
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (protectedElement(node)) { flush(); return; }
            if (!styles.has(node)) styles.set(node, getComputedStyle(node));
            const style = styles.get(node);
            if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') { flush(); return; }
            if (node.tagName === 'BR' || node.tagName === 'HR') { flush(); return; }
            const block = node !== document.body && (BLOCK.test(node.tagName) || /^(block|flow-root|flex|grid|list-item|table.*)$/.test(style.display));
            if (block) flush();
            for (let child = node.firstChild; child && !truncated; child = child.nextSibling) visit(child, block ? node : owner);
            if (block) flush();
        }
        if (document.body) visit(document.body, document.body);
        flush();
        return { groups, characters, truncated };
    }
    // Split on whitespace when possible; never cut a surrogate pair. Each original
    // DOM group is committed only once every bounded fragment has returned.
    function splitText(text) {
        const chunks = [];
        while (text.length > 4800) {
            let cut = 4800;
            if (/[\uD800-\uDBFF]/.test(text[cut - 1])) cut--;
            const prefix = text.slice(0, cut);
            const whitespace = prefix.search(/\s+\S*$/u);
            if (whitespace > 2400) cut = whitespace + (prefix.slice(whitespace).match(/^\s+/u)?.[0].length || 0);
            chunks.push(text.slice(0, cut)); text = text.slice(cut);
        }
        if (text) chunks.push(text);
        return chunks;
    }
    function jobsFor(groups) {
        const jobs = [];
        for (const group of groups) {
            group.parts = new Map(); group.remaining = 0; group.complete = false;
            let job = null, fragment = 0;
            const flush = () => { if (job) { jobs.push(job); group.remaining++; job = null; } };
            for (const run of group.runs) {
                run.pieces = splitText(run.original).map((text, index) => ({ id: `${run.id}p${index}`, text }));
                for (const piece of run.pieces) {
                    if (job && (job.runs.length >= 32 || job.characters + piece.text.length > 4800)) flush();
                    if (!job) job = { id: `${group.id}f${fragment++}`, group, runs: [], characters: 0 };
                    job.runs.push(piece); job.characters += piece.text.length;
                }
            }
            flush();
        }
        const batches = [];
        for (const job of jobs) {
            let batch = batches[batches.length - 1];
            if (!batch || batch.jobs.length >= 8 || batch.runs + job.runs.length > 32 || batch.characters + job.characters > 4800) {
                batch = { jobs: [], runs: 0, characters: 0 }; batches.push(batch);
            }
            batch.jobs.push(job); batch.runs += job.runs.length; batch.characters += job.characters;
        }
        return batches;
    }
    function inspectMutations(state, records) {
        for (const record of records) {
            if (state.host && (record.target === state.host || state.host.contains(record.target))) continue;
            for (const group of state.groups) {
                if (group.changed) continue;
                if (record.type === 'characterData' && group.runs.some(run => same(run.node, record.target))) group.changed = true;
                if (record.type === 'childList' && (same(group.owner, record.target) || group.owner.contains(record.target) || Array.from(record.removedNodes).some(node => group.runs.some(run => same(node, run.node) || node.contains(run.node))))) group.changed = true;
                if (record.type === 'attributes' && group.runs.some(run => run.path.some(node => same(node, record.target)))) group.changed = true;
            }
        }
    }
    function flushMutations(state) { if (state.observer) inspectMutations(state, state.observer.takeRecords()); }
    function writeGroup(state, group, original) {
        if (!matches(group)) { group.changed = true; return false; }
        group.runs.forEach(run => { run.expected = original ? run.original : run.translated; run.node.nodeValue = run.expected; });
        // All external mutations were drained before this synchronous write.
        state.observer?.takeRecords();
        return true;
    }
    function restore(state) {
        flushMutations(state);
        state.groups.filter(group => group.complete).forEach(group => writeGroup(state, group, true));
    }
    function stop(state) {
        state.running = false; state.generation++;
        if (state.requestId) void bridge({ type: 'cancel', runId: state.runId, requestId: state.requestId });
        state.requestId = null; state.phase = 'stopped'; state.nativeProgress = null; render(state);
    }
    function close(state) {
        activation++; stop(state); restore(state); state.observer?.disconnect(); state.host.remove();
        if (active === state) active = null;
    }
    function node(tag, id, text) {
        const element = document.createElement(tag); if (id) element.id = id; if (text) element.textContent = text; return element;
    }
    function makeHeader(state) {
        document.getElementById('murmator-stream-setup')?.remove();
        const host = node('div', 'murmator-stream'); state.host = host;
        host.setAttribute('data-murmator-page-ignore', '');
        host.style.cssText = 'all:initial!important;display:block!important;position:sticky!important;top:0!important;z-index:2147483647!important;isolation:isolate!important;width:100%!important;';
        const shadow = host.attachShadow({ mode: 'open' });
        const css = node('style');
        css.textContent = `:host{color-scheme:light dark}*{box-sizing:border-box}.bar{font:14px/1.3 -apple-system,BlinkMacSystemFont,sans-serif;background:#ffead0;color:#3c2818;padding:8px 12px 9px;box-shadow:0 1px 5px #0002}.top,.controls{display:flex;align-items:center;gap:8px}.top{min-height:38px}.brand{font-size:13px;font-weight:750;letter-spacing:.15px}.status{flex:1;font-size:13px;min-width:0}.controls{flex-wrap:wrap}.language{display:flex;flex:1;min-width:95px;align-items:center;gap:5px}.language span{font-size:11px;opacity:.8}button,select{font:inherit;color:inherit;border:1px solid #b78a5b66;border-radius:9px;background:#ffffff65;min-height:44px;cursor:pointer}button{padding:6px 10px}select{min-width:0;max-width:100%;width:100%;padding:7px 22px 7px 8px}.language select{flex:1}.close{font-size:26px;border:0;background:transparent;width:44px;padding:0}.toggle{font-size:12px}.stop{font-size:12px}button:disabled{opacity:.45;cursor:default}button:focus-visible,select:focus-visible{outline:3px solid #2764c6;outline-offset:2px}.meter{height:3px;background:#ad6b2926;border-radius:3px;margin-top:8px;overflow:hidden}.fill{height:100%;width:0;background:#cf711f;transition:width .15s}.note{font-size:12px;padding-top:6px}.note:empty{display:none}[hidden]{display:none!important}@media(max-width:420px){.bar{padding:5px 9px 7px}.controls{gap:5px}.language{min-width:100px}.language span{display:none}.toggle,.stop{padding:6px 8px}}@media(prefers-color-scheme:dark){.bar{background:#38291e;color:#ffe8ce}button,select{background:#ffffff0d;border-color:#d9aa7066}.meter{background:#ffffff20}.fill{background:#f3a757}}`;
        shadow.append(css);
        const bar = node('section'); bar.className = 'bar'; bar.setAttribute('aria-label', t('extensionName'));
        const top = node('div'); top.className = 'top';
        const brand = node('span', null, 'Murmator'); brand.className = 'brand'; top.append(brand);
        state.status = node('span', 'murmator-status'); state.status.className = 'status'; state.status.setAttribute('role', 'status'); top.append(state.status);
        const exit = node('button', 'murmator-close', '×'); exit.type = 'button'; exit.className = 'close'; exit.setAttribute('aria-label', t('close')); exit.title = t('close'); exit.addEventListener('click', () => close(state)); top.append(exit);
        const controls = node('div'); controls.className = 'controls';
        for (const kind of ['source', 'target']) {
            const label = node('label'); label.className = 'language'; label.append(node('span', null, t(kind)));
            const select = node('select', `murmator-${kind}`); select.setAttribute('aria-label', t(kind));
            select.addEventListener('change', () => {
                if (kind === 'source') { state.source = select.value; populateLanguages(state); }
                else state.target = select.value;
                restart(state);
            }); state[kind + 'Select'] = select; label.append(select); controls.append(label);
        }
        const toggle = node('button', 'murmator-original', t('original')); toggle.type = 'button'; toggle.className = 'toggle'; toggle.setAttribute('aria-pressed', 'false');
        toggle.addEventListener('click', () => { flushMutations(state); state.originalView = !state.originalView; state.groups.filter(group => group.complete).forEach(group => writeGroup(state, group, state.originalView)); render(state); });
        state.toggle = toggle; controls.append(toggle);
        const cancel = node('button', 'murmator-stop', t('stop')); cancel.type = 'button'; cancel.className = 'stop'; cancel.addEventListener('click', () => {
            if (state.running) stop(state); else restart(state);
        }); state.stopButton = cancel; controls.append(cancel);
        const meter = node('div', 'murmator-progress'); meter.className = 'meter'; meter.setAttribute('role', 'progressbar'); meter.setAttribute('aria-label', t('pageProgress')); meter.setAttribute('aria-valuemin', '0'); meter.setAttribute('aria-valuemax', '100');
        state.meter = meter; state.fill = node('div'); state.fill.className = 'fill'; meter.append(state.fill);
        state.note = node('div', 'murmator-note'); state.note.className = 'note';
        bar.append(top, controls, meter, state.note); shadow.append(bar);
        document.body.insertBefore(host, document.body.firstChild);
    }
    function populateLanguages(state) {
        const languages = state.config.languages || [];
        const availableSources = languages.filter(language => (state.config.targets?.[language.code] || []).length);
        state.sourceSelect.replaceChildren(...availableSources.map(language => { const option = node('option', null, language.name); option.value = language.code; return option; }));
        state.sourceSelect.value = state.source;
        const targets = state.config.targets?.[state.source] || [];
        if (!targets.includes(state.target)) state.target = targets[0] || '';
        state.targetSelect.replaceChildren(...languages.filter(language => targets.includes(language.code)).map(language => { const option = node('option', null, language.name); option.value = language.code; return option; }));
        state.targetSelect.value = state.target;
    }
    function render(state) {
        if (!state.status) return;
        const percent = state.characters ? Math.floor(100 * state.completedCharacters / state.characters) : 0;
        let status = state.phase === 'done' ? t('translated', state.targetSelect.selectedOptions[0]?.textContent || state.target) : t(state.phase || 'preparing');
        if (state.running) status = t('translating', String(percent));
        state.status.textContent = status;
        state.meter.setAttribute('aria-valuenow', String(percent)); state.fill.style.width = `${percent}%`;
        const notes = [];
        if (state.error) notes.push(t(state.error === 'notReady' ? 'setupRequired' : state.error === 'busy' ? 'busy' : 'failed'));
        else if (state.nativeProgress?.phase === 'preparing') notes.push(t('preparingModel') + (typeof state.nativeProgress.fraction === 'number' ? ` ${Math.floor(Math.max(0, Math.min(1, state.nativeProgress.fraction)) * 100)}%` : ''));
        if (state.skipped || state.truncated) notes.push(t('partial'));
        state.note.textContent = notes.join(' ');
        state.toggle.textContent = t(state.originalView ? 'translation' : 'original'); state.toggle.setAttribute('aria-pressed', String(state.originalView)); state.toggle.disabled = !state.groups.some(group => group.complete);
        state.stopButton.textContent = t(state.running ? 'stop' : 'retry'); state.stopButton.hidden = state.phase === 'done'; state.stopButton.disabled = !state.config.ready || !state.source || !state.target;
        state.sourceSelect.disabled = !state.config.ready; state.targetSelect.disabled = !state.config.ready;
    }
    function preserveWhitespace(source, translated) {
        return /\S/u.test(source) ? source.match(/^\s*/u)[0] + translated.trim() + source.match(/\s*$/u)[0] : source;
    }
    function acceptBatch(state, batch, result) {
        if (!Array.isArray(result.translations)) throw new Error('invalidResult');
        const outputs = new Map(); let characters = 0;
        for (const item of result.translations) {
            if (!item || typeof item.id !== 'string' || typeof item.text !== 'string' || outputs.has(item.id)) throw new Error('invalidResult');
            characters += item.text.length; if (characters > 24000) throw new Error('invalidResult'); outputs.set(item.id, item.text);
        }
        const pieces = batch.jobs.flatMap(job => job.runs);
        if (outputs.size !== pieces.length || pieces.some(piece => !outputs.has(piece.id) || (/\S/u.test(piece.text) && !/\S/u.test(outputs.get(piece.id))))) throw new Error('invalidResult');
        flushMutations(state);
        for (const job of batch.jobs) {
            const group = job.group;
            job.runs.forEach(piece => group.parts.set(piece.id, preserveWhitespace(piece.text, outputs.get(piece.id))));
            group.remaining--;
            if (group.remaining !== 0) continue;
            group.runs.forEach(run => { run.translated = run.pieces.map(piece => group.parts.get(piece.id)).join(''); });
            group.parts.clear();
            if (!matches(group)) { group.changed = true; state.skipped++; continue; }
            group.complete = true;
            if (!state.originalView) writeGroup(state, group, false);
        }
        state.completedCharacters += batch.characters;
    }
    async function translateBatch(state, batch, generation) {
        const requestId = `${state.runId}-${++sequence}`; state.requestId = requestId;
        const request = { type: 'translate', runId: state.runId, requestId, source: state.source, target: state.target, groups: batch.jobs.map(job => ({ id: job.id, runs: job.runs })), totalCharacters: batch.characters };
        const poll = setInterval(async () => {
            if (!state.running || state.generation !== generation || state.requestId !== requestId) return;
            const progress = await bridge({ type: 'progress', runId: request.runId, requestId });
            if (progress.ok && state.running && state.generation === generation && state.requestId === requestId) { state.nativeProgress = progress; render(state); }
        }, 650);
        try {
            for (let attempt = 0; attempt < 8; attempt++) {
                if (!state.running || state.generation !== generation) return null;
                const result = await bridge(request);
                if (!state.running || state.generation !== generation) return null;
                if (result.code !== 'busy') {
                    if (result.ok && (result.runId !== request.runId || result.requestId !== requestId)) return { ok: false, code: 'translationFailed' };
                    return result;
                }
                state.nativeProgress = null; state.note.textContent = t('busy');
                await new Promise(resolve => setTimeout(resolve, Math.min(300 * (attempt + 1), 1800)));
            }
            return { ok: false, code: 'busy' };
        } finally { clearInterval(poll); if (state.generation === generation) { state.requestId = null; state.nativeProgress = null; } }
    }
    async function run(state) {
        const generation = state.generation;
        state.running = true; state.phase = 'translating'; state.error = null; render(state);
        try {
            for (const batch of jobsFor(state.groups)) {
                if (!state.running || state.generation !== generation) return;
                const result = await translateBatch(state, batch, generation);
                if (!state.running || state.generation !== generation || active !== state) return;
                if (!result?.ok) { state.error = result?.code || 'translationFailed'; state.phase = 'failed'; return; }
                if (result.runId !== state.runId || typeof result.requestId !== 'string') throw new Error('invalidResult');
                acceptBatch(state, batch, result); render(state);
            }
            state.phase = state.groups.length ? 'done' : 'empty';
        } catch (_) { if (state.generation === generation) { state.error = 'translationFailed'; state.phase = 'failed'; } }
        finally { if (state.generation === generation) { state.running = false; render(state); } }
    }
    function restart(state) {
        if (active !== state) return;
        stop(state); restore(state);
        // Keep saved original snapshots across language changes; page edits are
        // skipped and never turned into translated source text.
        state.groups = state.groups.filter(group => matches(group));
        state.groups.forEach(group => { group.complete = false; });
        state.originalView = false; state.completedCharacters = 0; state.characters = state.groups.reduce((sum, group) => sum + group.characters, 0); state.skipped = 0;
        state.runId = `${Date.now()}-${++sequence}`;
        if (!state.config.ready || !state.source || !state.target) { state.error = 'notReady'; render(state); return; }
        void run(state);
    }
    async function activate(ticket) {
        const configRequest = { type: 'config', sample: '', documentLanguage: (document.documentElement.getAttribute('lang') || '').slice(0, 64), url: location.href };
        let config;
        if (ticket) {
            config = await bridge({ ...configRequest, ticket });
            if (!config.ok) return;
        }
        const turn = ++activation;
        if (active) { stop(active); restore(active); active.observer?.disconnect(); active.host.remove(); }
        const snapshot = collect();
        configRequest.sample = snapshot.groups.flatMap(group => group.runs.map(run => run.original)).join(' ').slice(0, 1500);
        const state = { ...snapshot, config: { ready: false }, source: '', target: '', generation: 0, runId: `${Date.now()}-${++sequence}`, completedCharacters: 0, skipped: 0, phase: 'preparing', originalView: false, running: false };
        active = state; makeHeader(state); render(state);
        state.observer = new MutationObserver(records => inspectMutations(state, records));
        state.observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['hidden', 'inert', 'aria-hidden', 'translate', 'contenteditable', 'class', 'style'] });
        config = await bridge(configRequest);
        if (turn !== activation || active !== state) return;
        if (!config.ok) { state.phase = 'failed'; state.error = config.code; render(state); return; }
        state.config = config; state.source = config.source; state.target = config.target; populateLanguages(state);
        if (!config.ready) { state.phase = 'setupRequired'; state.error = 'notReady'; render(state); return; }
        if (!state.source || !state.target) { state.phase = 'unsupported'; render(state); return; }
        void run(state);
    }
    browser.runtime.onMessage.addListener(message => { if (message?.type === 'open') { void activate(); return Promise.resolve({ ok: true }); } });
    const root = document.documentElement;
    root.addEventListener('murmator-stream-probe', event => { if (same(event.target, root)) root.setAttribute('data-murmator-stream-ready', '1'); });
    root.addEventListener('murmator-stream-start', event => {
        if (!same(event.target, root)) return;
        const ticket = root.getAttribute('data-murmator-stream-ticket');
        if (ticket && UUID.test(ticket)) {
            root.setAttribute('data-murmator-stream-received', '1');
            void activate(ticket);
        }
    });
    window.addEventListener('pagehide', () => { activation++; if (active) stop(active); });
})();
