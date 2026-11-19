// Injected into every web page tab (main frame only).
(() => {
  if (window.__oxygen) return;
  window.__oxygen = true;
  const post = (m) => { try { window.ipc.postMessage(JSON.stringify(m)); } catch (_) {} };

  // Browser shortcuts must work even while a page has focus.
  const KEYS = new Set([
    'ctrl+t', 'ctrl+l', 'ctrl+w', 'ctrl+shift+t', 'ctrl+tab', 'ctrl+shift+tab',
    'ctrl+alt+c', 'ctrl+alt+v', 'ctrl+alt+arrowleft', 'ctrl+alt+arrowright',
    'ctrl+shift+e', 'f11',
  ]);
  addEventListener('keydown', (e) => {
    const k = e.key.toLowerCase();
    const combo = (e.ctrlKey || e.metaKey ? 'ctrl+' : '') + (e.altKey ? 'alt+' : '') +
      (e.shiftKey ? 'shift+' : '') + k;
    if (k === 'escape') { post({ t: 'key', k: 'escape' }); return; }
    if (KEYS.has(combo) || /^ctrl\+[1-9]$/.test(combo)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      post({ t: 'key', k: combo });
    }
  }, true);

  // Glance: Alt+click a link to preview it in a floating panel.
  addEventListener('click', (e) => {
    if (!e.altKey || e.button !== 0) return;
    const a = e.target && e.target.closest && e.target.closest('a[href]');
    if (!a || !/^https?:/.test(a.href)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    post({ t: 'glance', url: a.href });
  }, true);

  // Single-page apps change the URL without a page load; report those too.
  const report = () => post({ t: 'url', url: location.href });
  for (const f of ['pushState', 'replaceState']) {
    const orig = history[f];
    history[f] = function () { const r = orig.apply(this, arguments); report(); return r; };
  }
  addEventListener('popstate', report);
  addEventListener('hashchange', report);
})();
