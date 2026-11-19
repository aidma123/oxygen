// Injected into every web page tab (main frame only).
(() => {
  if (window.__oxygen) return;
  window.__oxygen = true;
  const post = (m) => { try { window.ipc.postMessage(JSON.stringify(m)); } catch (_) {} };

  // Browser shortcuts must work even while a page has focus. The browser
  // sets window.__OXYGEN_KEYS to the user's current shortcuts (and updates it
  // when they change); these defaults are only a fallback.
  const DEFAULT_KEYS = new Set([
    'ctrl+t', 'ctrl+l', 'ctrl+w', 'ctrl+shift+t', 'ctrl+tab', 'ctrl+shift+tab',
    'ctrl+alt+c', 'ctrl+alt+v', 'ctrl+alt+arrowleft', 'ctrl+alt+arrowright',
    'ctrl+shift+e', 'ctrl+alt+s', 'f11',
  ]);
  addEventListener('keydown', (e) => {
    const k = e.key.toLowerCase();
    if (['control', 'alt', 'shift', 'meta'].includes(k)) return;
    const combo = (e.ctrlKey || e.metaKey ? 'ctrl+' : '') + (e.altKey ? 'alt+' : '') +
      (e.shiftKey ? 'shift+' : '') + (k === ' ' ? 'space' : k);
    if (k === 'escape') { post({ t: 'key', k: 'escape' }); return; }
    const keys = window.__OXYGEN_KEYS instanceof Set ? window.__OXYGEN_KEYS : DEFAULT_KEYS;
    if (keys.has(combo) || /^ctrl\+[1-9]$/.test(combo)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      post({ t: 'key', k: combo });
    }
  }, true);

  // "Use this font on websites": the browser sets window.__OXYGEN_SITE_FONT
  // ({ family, face }) and calls __oxygenApplyFont() when it changes. Icon
  // fonts and code keep their own fonts so icons don't turn into letters.
  const applyFont = () => {
    const cfg = window.__OXYGEN_SITE_FONT;
    let el = document.getElementById('__oxygen_font');
    if (!cfg || !cfg.family) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('style');
      el.id = '__oxygen_font';
      (document.head || document.documentElement).appendChild(el);
    }
    const skip = ':not(i):not([class*="icon" i]):not([class*="fa-"]):not([class*="material" i]):not([class*="glyph" i])' +
      ':not([class*="symbol" i]):not(code):not(pre):not(kbd):not(samp):not(svg):not(svg *):not(math):not(math *)';
    el.textContent = (cfg.face || '') + `html, html body${skip}, html body *${skip} { font-family: ${cfg.family} !important; }`;
  };
  window.__oxygenApplyFont = applyFont;
  if (document.documentElement) applyFont();
  addEventListener('DOMContentLoaded', applyFont);

  // Clicking the page closes extension popups and menus, as in Chrome.
  addEventListener('mousedown', () => post({ t: 'pageclick' }), true);

  // Ctrl+click and middle-click open a link in a background tab, as in Chrome.
  const linkFrom = (e) => {
    const a = e.target && e.target.closest && e.target.closest('a[href]');
    return a && /^https?:/.test(a.href) ? a : null;
  };
  addEventListener('click', (e) => {
    if (e.button !== 0 || !(e.ctrlKey || e.metaKey) || e.altKey) return;
    const a = linkFrom(e);
    if (!a) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    post({ t: 'openTab', url: a.href, background: !e.shiftKey });
  }, true);
  addEventListener('auxclick', (e) => {
    if (e.button !== 1) return;
    const a = linkFrom(e);
    if (!a) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    post({ t: 'openTab', url: a.href, background: true });
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
