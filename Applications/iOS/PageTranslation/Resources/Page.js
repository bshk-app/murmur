/* Safari Action extension protocol v1. Translation results are text, never HTML. */
(function () {
    'use strict';

    var KEY = '__murmatorPageTranslationV1';
    var session = window[KEY] || { pending: null, active: null, sequence: 0 };
    window[KEY] = session;
    var LIMITS = { characters: 200000, runs: 4000, groups: 2000 };
    var EXCLUDED = 'script,style,noscript,template,form,input,textarea,select,button,pre,code,kbd,samp,svg,math,canvas,iframe,object,embed,[hidden],[inert],[aria-hidden="true"],[translate="no"],.notranslate,[data-murmator-page-ignore]';
    var BLOCK_TAGS = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DETAILS|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|H[1-6]|HEADER|HGROUP|LI|MAIN|NAV|OL|P|SECTION|SUMMARY|TABLE|TBODY|TD|TFOOT|TH|THEAD|TR|UL)$/;

    function sameNode(left, right) {
        return left === right || (!!left && !!right && left.isSameNode(right));
    }

    // Safari can expose a different JavaScript wrapper for the same DOM node
    // when a toolbar event or a subsequent Action invocation enters another world.
    // Reading the node through DOM relationships returns the current world's
    // wrapper, so identity-keyed caches work without adding attributes to the page.
    function currentNodeReference(node) {
        var parent = node.parentNode;
        if (!parent) return node;
        var previous = node.previousSibling;
        var current = previous ? previous.nextSibling : parent.firstChild;
        return sameNode(current, node) ? current : node;
    }

    function pathsMatch(run) {
        if (!run.node.isConnected) return false;
        var parent = run.node.parentNode;
        for (var i = 0; i < run.path.length; i++) {
            if (!sameNode(parent, run.path[i])) return false;
            parent = parent.parentNode;
        }
        return true;
    }

    function originalTextMap() {
        var originals = new WeakMap();
        if (session.active) session.active.groups.forEach(function (group) {
            group.runs.forEach(function (run) {
                if (pathsMatch(run) && (run.node.nodeValue === run.original || run.node.nodeValue === run.translated)) {
                    originals.set(currentNodeReference(run.node), run.original);
                }
            });
        });
        return originals;
    }

    // A block's inline text stays in one group. Nested blocks, explicit line breaks,
    // and protected content are boundaries; markup itself never crosses the bridge.
    function collect() {
        var originals = originalTextMap();
        var groups = [], current = null, characters = 0, count = 0, truncated = false;
        var styles = new WeakMap();
        function style(element) {
            if (!styles.has(element)) styles.set(element, getComputedStyle(element));
            return styles.get(element);
        }
        function flush() {
            if (!current) return;
            var group = current;
            current = null;
            if (!group.runs.some(function (run) { return /\S/u.test(run.original); })) return;
            var length = group.runs.reduce(function (sum, run) { return sum + run.original.length; }, 0);
            if (groups.length >= LIMITS.groups || count + group.runs.length > LIMITS.runs || characters + length > LIMITS.characters) {
                truncated = true;
                return;
            }
            group.id = 'g' + groups.length;
            group.runs.forEach(function (run) { run.id = 'r' + count++; });
            characters += length;
            groups.push(group);
        }
        function visit(node, owner) {
            if (truncated) return;
            if (node.nodeType === Node.TEXT_NODE) {
                var original = originals.has(node) ? originals.get(node) : node.nodeValue;
                if (!original) return;
                if (!current || current.owner !== owner) { flush(); current = { owner: owner, runs: [], characters: 0 }; }
                var path = [], parent = node.parentNode;
                while (parent) { path.push(parent); parent = parent.parentNode; }
                current.runs.push({ node: node, path: path, original: original, expected: node.nodeValue });
                current.characters += original.length;
                // Bound a single enormous block too, before building an unbounded snapshot.
                if (current.runs.length > LIMITS.runs || current.characters > LIMITS.characters) { current = null; truncated = true; }
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            var editable = node.getAttribute('contenteditable');
            if (node.matches(EXCLUDED) || (editable !== null && editable.toLowerCase() !== 'false')) { flush(); return; }
            var computed = style(node);
            if (computed.display === 'none' || computed.visibility === 'hidden' || computed.visibility === 'collapse') { flush(); return; }
            if (node.tagName === 'BR' || node.tagName === 'HR') { flush(); return; }
            var block = node !== document.body && (BLOCK_TAGS.test(node.tagName) || /^(block|flow-root|flex|grid|list-item|table.*)$/.test(computed.display));
            if (block) flush();
            for (var child = node.firstChild; child && !truncated; child = child.nextSibling) visit(child, block ? node : owner);
            if (block) flush();
        }
        if (document.body) visit(document.body, document.body);
        flush();
        return { groups: groups, totalCharacters: characters, truncated: truncated };
    }

    function matches(group, valueKey) {
        return group.runs.every(function (run) {
            return pathsMatch(run) && run.node.nodeValue === run[valueKey] && !run.path.some(function (ancestor) {
                if (ancestor.nodeType !== Node.ELEMENT_NODE) return false;
                var editable = ancestor.getAttribute('contenteditable');
                return ancestor.matches(EXCLUDED) || (editable !== null && editable.toLowerCase() !== 'false');
            });
        });
    }

    function setRootAttribute(name, value) {
        if (value === null) document.documentElement.removeAttribute(name);
        else document.documentElement.setAttribute(name, value);
    }

    function setLanguage(value) { setRootAttribute('lang', value); }

    // Translated text reads in the target script's direction; an RTL page turned
    // into an LTR language must stop right-aligning it.
    function textDirection(language, originalDirection) {
        if (/^(ar|fa|he|ur)(-|$)/i.test(language || '')) return 'rtl';
        return originalDirection === 'rtl' ? 'ltr' : originalDirection;
    }

    function restore(active) {
        active.groups.forEach(function (group) {
            if (matches(group, 'translated')) group.runs.forEach(function (run) { run.node.nodeValue = run.original; });
        });
        if (document.documentElement.getAttribute('lang') === active.language) setLanguage(active.originalLanguage);
        if (document.documentElement.getAttribute('dir') === active.direction) setRootAttribute('dir', active.originalDirection);
    }

    // A new Safari Action gets a new global object. The existing toolbar's event
    // handlers still own the original node snapshots, so use that controller for
    // later requests. DOM attributes carry JSON strings across worlds only for
    // this synchronous exchange; no webpage text nodes gain IDs or metadata.
    function relay(action, payload) {
        var host = document.getElementById('murmator-page-translation');
        if (!host || host.getAttribute('data-murmator-page-controller') !== '1') return null;
        try {
            host.removeAttribute('data-murmator-response');
            host.setAttribute('data-murmator-request', JSON.stringify({ action: action, payload: payload }));
            host.dispatchEvent(new Event('murmator-page-request'));
            var response = host.getAttribute('data-murmator-response');
            return response ? JSON.parse(response) : null;
        } finally {
            host.removeAttribute('data-murmator-request');
            host.removeAttribute('data-murmator-response');
        }
    }

    function toolbar(active, args, applied, skipped, truncated) {
        var labels = args.labels || {};
        function label(key, fallback) { return typeof labels[key] === 'string' && labels[key] ? labels[key] : fallback; }
        var host = document.createElement('div');
        host.setAttribute('data-murmator-page-ignore', '');
        host.setAttribute('data-murmator-page-controller', '1');
        host.id = 'murmator-page-translation';
        host.addEventListener('murmator-page-request', function (event) {
            if (!sameNode(event.target, host) || session.active !== active) return;
            var request = JSON.parse(host.getAttribute('data-murmator-request') || 'null');
            if (!request) return;
            if (request.action === 'run') host.setAttribute('data-murmator-response', JSON.stringify({ handled: true, request: prepareRequest() }));
            else if (request.action === 'finalize') {
                applyResult(request.payload);
                host.setAttribute('data-murmator-response', JSON.stringify({ handled: true }));
            }
        });
        host.style.cssText = 'all:initial!important;display:block!important;position:sticky!important;top:0!important;z-index:2147483647!important;isolation:isolate!important;';
        var shadow = host.attachShadow({ mode: 'open' });
        var style = document.createElement('style');
        style.textContent = ':host{color-scheme:light dark}*{box-sizing:border-box}.bar{font:15px/1.35 -apple-system,BlinkMacSystemFont,sans-serif;background:#ffe2a8;color:#241d15;padding:10px 12px;display:flex;align-items:center;gap:8px;box-shadow:0 1px 4px #0003}.status{flex:1;min-width:0}.name{font-weight:650}.message{display:block;font-size:13px}button{font:inherit;color:inherit;background:#fff9;border:1px solid #76582a;border-radius:8px;padding:9px 11px;min-height:44px;cursor:pointer}button:focus-visible{outline:3px solid #115bce;outline-offset:2px}.close{font-size:23px;min-width:44px;padding:4px} @media(prefers-color-scheme:dark){.bar{background:#3c3020;color:#fff0d4}button{background:#ffffff12;border-color:#c6a978}}';
        shadow.appendChild(style);
        var bar = document.createElement('div'); bar.className = 'bar'; bar.setAttribute('role', 'region'); bar.setAttribute('aria-label', 'Murmator');
        var status = document.createElement('div'); status.className = 'status'; status.setAttribute('role', 'status');
        var name = document.createElement('span'); name.className = 'name'; name.textContent = 'Murmator'; status.appendChild(name);
        var message = document.createElement('span'); message.className = 'message';
        var messageText = applied === 0 ? label('changedPage', 'The page changed. Translate it again.') : label('translated', 'Page translated');
        if (applied > 0 && (skipped || truncated)) messageText += ' ' + label('partial', 'Some text could not be translated.');
        message.textContent = messageText; status.appendChild(message); bar.appendChild(status);
        var toggle = document.createElement('button'); toggle.type = 'button'; toggle.id = 'murmator-toggle';
        toggle.textContent = label(active.view === 'original' ? 'showTranslation' : 'showOriginal', active.view === 'original' ? 'Show translation' : 'Show original');
        toggle.setAttribute('aria-pressed', active.view === 'original' ? 'true' : 'false');
        toggle.disabled = active.groups.length === 0;
        toggle.addEventListener('click', function () {
            var showingOriginal = active.view === 'translation';
            active.groups.forEach(function (group) {
                if (matches(group, showingOriginal ? 'translated' : 'original')) group.runs.forEach(function (run) {
                    run.node.nodeValue = showingOriginal ? run.original : run.translated;
                });
            });
            var expectedLanguage = showingOriginal ? active.language : active.originalLanguage;
            if (document.documentElement.getAttribute('lang') === expectedLanguage) setLanguage(showingOriginal ? active.originalLanguage : active.language);
            var expectedDirection = showingOriginal ? active.direction : active.originalDirection;
            if (document.documentElement.getAttribute('dir') === expectedDirection) setRootAttribute('dir', showingOriginal ? active.originalDirection : active.direction);
            active.view = showingOriginal ? 'original' : 'translation';
            toggle.textContent = showingOriginal ? label('showTranslation', 'Show translation') : label('showOriginal', 'Show original');
            toggle.setAttribute('aria-pressed', showingOriginal ? 'true' : 'false');
        });
        bar.appendChild(toggle);
        var close = document.createElement('button'); close.type = 'button'; close.className = 'close'; close.id = 'murmator-close'; close.textContent = '×'; close.setAttribute('aria-label', label('close', 'Close and restore original')); close.title = label('close', 'Close and restore original');
        close.addEventListener('click', function () { restore(active); host.remove(); if (session.active === active) session.active = null; session.pending = null; });
        bar.appendChild(close); shadow.appendChild(bar);
        document.body.insertBefore(host, document.body.firstChild);
        active.toolbar = host;
    }

    function prepareRequest() {
            var collected = collect();
            var runId = String(Date.now()) + '-' + (++session.sequence) + '-' + Math.random().toString(36).slice(2);
            session.pending = { runId: runId, groups: collected.groups, truncated: collected.truncated };
            return {
                version: 1, runId: runId, title: document.title, url: location.href,
                documentLanguage: session.active ? (session.active.originalLanguage || '') : (document.documentElement.getAttribute('lang') || ''),
                groups: collected.groups.map(function (group) { return { id: group.id, runs: group.runs.map(function (run) { return { id: run.id, text: run.original }; }) }; }),
                truncated: collected.truncated, totalCharacters: collected.totalCharacters
            };
    }

    function applyResult(args) {
            var pending = session.pending;
            if (!args || args.version !== 1 || !pending || args.runId !== pending.runId) return;
            session.pending = null;
            if (args.action !== 'apply' || !Array.isArray(args.translations) || !document.body) return;
            var outputs = new Map(), duplicates = new Set();
            args.translations.forEach(function (item) {
                if (!item || typeof item.id !== 'string' || typeof item.text !== 'string') return;
                if (outputs.has(item.id)) duplicates.add(item.id);
                outputs.set(item.id, item.text);
            });
            var currentByFirst = new Map();
            collect().groups.forEach(function (group) { currentByFirst.set(group.runs[0].node, group); });
            var eligible = pending.groups.filter(function (group) {
                var current = currentByFirst.get(currentNodeReference(group.runs[0].node));
                return current && sameNode(current.owner, group.owner) && current.runs.length === group.runs.length && matches(group, 'expected') && group.runs.every(function (run, index) {
                    return sameNode(current.runs[index].node, run.node) && outputs.has(run.id) && !duplicates.has(run.id) && (!/\S/u.test(run.original) || /\S/u.test(outputs.get(run.id)));
                });
            });
            var old = session.active;
            // A repeated invocation reads original text without touching the visible page.
            // Only an accepted result replaces the prior translation; cancellation is inert.
            if (eligible.length && old) restore(old);
            if (old && old.toolbar) old.toolbar.remove();
            var originalDirection = old ? old.originalDirection : document.documentElement.getAttribute('dir');
            var active = eligible.length ? { groups: eligible, originalLanguage: old ? old.originalLanguage : document.documentElement.getAttribute('lang'), originalDirection: originalDirection, view: 'translation' } : (old || { groups: [], originalLanguage: document.documentElement.getAttribute('lang'), originalDirection: originalDirection, direction: originalDirection, view: 'translation' });
            eligible.forEach(function (group) {
                group.runs.forEach(function (run) {
                    run.translated = /\S/u.test(run.original) ? run.original.match(/^\s*/u)[0] + outputs.get(run.id).trim() + run.original.match(/\s*$/u)[0] : run.original;
                    run.node.nodeValue = run.translated;
                });
            });
            var skipped = pending.groups.length - eligible.length;
            if (eligible.length) {
                active.language = !skipped && !pending.truncated && typeof args.target === 'string' && /^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$/.test(args.target) ? args.target : active.originalLanguage;
                setLanguage(active.language);
                active.direction = textDirection(args.target, active.originalDirection);
                setRootAttribute('dir', active.direction);
            } else if (!old) active.language = active.originalLanguage;
            session.active = active;
            toolbar(active, args, eligible.length, skipped, pending.truncated);
    }

    window.ExtensionPreprocessingJS = {
        run: function (args) {
            var response = relay('run');
            args.completionFunction(response && response.handled ? response.request : prepareRequest());
        },
        finalize: function (args) {
            var response = relay('finalize', args);
            if (!response || !response.handled) applyResult(args);
        }
    };
}());
