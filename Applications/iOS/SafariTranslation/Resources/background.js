/* Only our top-frame content script can reach the native translation service. */
'use strict';
const pageURL = value => {
    try { const url = new URL(value); if (!['http:', 'https:'].includes(url.protocol)) return null; url.hash = ''; return url.href; } catch (_) { return null; }
};
const failure = code => ({ ok: false, code });
function senderContext(sender) {
    if (sender?.id !== browser.runtime.id || !Number.isInteger(sender.tab?.id) || sender.frameId !== 0) return null;
    const url = pageURL(sender.url);
    return url ? { id: sender.tab.id, url, key: `${sender.tab.id}:${url}` } : null;
}
const native = async payload => {
    try { return await browser.runtime.sendNativeMessage('app.bshk.murmur.ios', payload); }
    catch (_) { return failure('translationFailed'); }
};
async function nativeRunId(context, runId) {
    // Deterministic tab isolation survives nonpersistent background suspension.
    // No page text or authorization state is persisted. Native also checks IDs.
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${context.key}:${runId}`));
    return 'web-' + Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
}
browser.runtime.onMessage.addListener(async (message, sender) => {
    const context = senderContext(sender);
    if (!context || !message || typeof message !== 'object') return failure('invalidRequest');
    // Activation authorization lives in our isolated content controller. A page
    // DOM event must claim a native one-use ticket there before any collection.
    // Webpages have no relay to this listener and no externally_connectable API.
    if (message.type === 'config') {
        if (typeof message.sample !== 'string' || message.sample.length > 1500 || typeof message.documentLanguage !== 'string' || message.documentLanguage.length > 64 || typeof message.url !== 'string' || message.url.length > 16384 || pageURL(message.url) !== context.url) return failure('invalidRequest');
        const ticket = message.ticket;
        if (ticket !== undefined && (typeof ticket !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ticket))) return failure('invalidTicket');
        return native({ type: 'config', sample: message.sample, documentLanguage: message.documentLanguage, url: message.url, ...(ticket ? { ticket } : {}) });
    }
    if (typeof message.runId !== 'string' || !message.runId.length || message.runId.length > 128 || typeof message.requestId !== 'string' || !message.requestId.length || message.requestId.length > 128) return failure('invalidRequest');
    if (message.type === 'translate') {
        if (typeof message.source !== 'string' || typeof message.target !== 'string' || !Array.isArray(message.groups) || !message.groups.length || message.groups.length > 8) return failure('invalidRequest');
        let characters = 0, runs = 0; const ids = new Set(), groupIds = new Set();
        for (const group of message.groups) {
            if (!group || typeof group.id !== 'string' || !group.id.length || group.id.length > 128 || groupIds.has(group.id) || !Array.isArray(group.runs) || !group.runs.length) return failure('invalidRequest');
            groupIds.add(group.id);
            for (const run of group.runs) {
                if (!run || typeof run.id !== 'string' || !run.id.length || run.id.length > 128 || ids.has(run.id) || typeof run.text !== 'string' || !run.text.length) return failure('invalidRequest');
                ids.add(run.id); characters += run.text.length; runs++;
            }
        }
        if (runs > 32 || characters > 4800 || message.totalCharacters !== characters) return failure('invalidRequest');
        const runId = await nativeRunId(context, message.runId);
        const result = await native({ type: 'translate', runId, requestId: message.requestId, source: message.source, target: message.target, groups: message.groups, totalCharacters: characters });
        if (result?.ok && result.runId !== runId) return failure('translationFailed');
        return result?.ok ? { ...result, runId: message.runId } : result;
    }
    if (!['cancel', 'progress'].includes(message.type)) return failure('invalidRequest');
    return native({ type: message.type, runId: await nativeRunId(context, message.runId), requestId: message.requestId });
});
browser.action.onClicked.addListener(async tab => {
    if (!Number.isInteger(tab.id) || !pageURL(tab.url)) return;
    try {
        await browser.scripting.executeScript({ target: { tabId: tab.id, frameIds: [0] }, files: ['content.js'] });
        await browser.tabs.sendMessage(tab.id, { type: 'open' }, { frameId: 0 });
    } catch (_) { /* Safari presents extension/site permissions in its own UI. */ }
});
