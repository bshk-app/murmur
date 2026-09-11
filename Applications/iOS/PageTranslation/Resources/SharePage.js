/* Non-UI Safari Share handoff. Native code never translates while Share is open. */
(function () {
    'use strict';
    var root = document.documentElement;
    function available() {
        if (!root) return false;
        root.removeAttribute('data-murmator-stream-ready');
        root.dispatchEvent(new Event('murmator-stream-probe'));
        var ready = root.getAttribute('data-murmator-stream-ready') === '1';
        root.removeAttribute('data-murmator-stream-ready');
        return ready;
    }
    function setup(args) {
        if (!document.body) return;
        var previous = document.getElementById('murmator-stream-setup');
        if (previous) previous.remove();
        var host = document.createElement('div');
        host.id = 'murmator-stream-setup';
        host.setAttribute('data-murmator-page-ignore', '');
        host.style.cssText = 'all:initial!important;display:block!important;position:sticky!important;top:0!important;z-index:2147483647!important';
        var shadow = host.attachShadow({ mode: 'open' });
        var style = document.createElement('style');
        style.textContent = '*{box-sizing:border-box}.panel{position:relative;font:15px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;background:#ffe2a8;color:#241d15}.panel:not([open]){display:none}.bar{display:flex;align-items:center;gap:10px;padding:12px 70px 12px 12px}.message{flex:1;min-width:0}a,summary{font:inherit;color:inherit;min-height:44px;display:inline-flex;align-items:center;justify-content:center;padding:8px;border:1px solid #76582a;border-radius:8px;background:#fff9;text-decoration:none}a{flex-shrink:0}summary{position:absolute;right:12px;top:50%;transform:translateY(-50%);min-width:44px;font-size:22px;list-style:none;cursor:pointer}summary::-webkit-details-marker{display:none}@media(max-width:420px){.bar{display:block}a{margin-top:8px}}@media(prefers-color-scheme:dark){.panel{background:#3c3020;color:#fff0d4}a,summary{background:#ffffff12;border-color:#c6a978}}';
        shadow.appendChild(style);
        var bar = document.createElement('details'); bar.open = true; bar.className = 'panel'; bar.setAttribute('aria-label', 'Murmator');
        var message = document.createElement('span'); message.className = 'message'; message.setAttribute('role', 'status'); message.textContent = args.message || 'Start from Safari’s page menu → Murmator. Allow website access if asked.';
        var link = document.createElement('a'); link.href = 'murmur://safari-setup'; link.textContent = args.openApp || 'Open Murmator';
        // Closing uses HTML's native disclosure action, without a retained JS callback.
        var close = document.createElement('summary'); close.textContent = '×'; close.setAttribute('role', 'button'); close.setAttribute('aria-label', args.close || 'Close');
        var content = document.createElement('div'); content.className = 'bar'; content.append(message, link);
        bar.append(close, content); shadow.appendChild(bar); document.body.prepend(host);
    }
    window.ExtensionPreprocessingJS = {
        run: function (args) {
            args.completionFunction({ version: 1, url: document.URL, extensionAvailable: available() });
        },
        finalize: function (args) {
            var previous = document.getElementById('murmator-stream-setup');
            if (previous) previous.remove();
            if (root && args.action === 'start' && typeof args.ticket === 'string') {
                root.removeAttribute('data-murmator-stream-received');
                root.setAttribute('data-murmator-stream-ticket', args.ticket);
                root.dispatchEvent(new Event('murmator-stream-start'));
                var received = root.getAttribute('data-murmator-stream-received') === '1';
                root.removeAttribute('data-murmator-stream-ticket');
                root.removeAttribute('data-murmator-stream-received');
                if (received) return;
            }
            setup(args);
        }
    };
})();
