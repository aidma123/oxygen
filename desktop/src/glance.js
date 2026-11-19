// Injected into the Glance preview panel.
(() => {
  if (window.__oxygenGlance) return;
  window.__oxygenGlance = true;
  const post = (m) => { try { window.ipc.postMessage(m); } catch (_) {} };
  addEventListener('keydown', (e) => { if (e.key === 'Escape') post('close'); }, true);
  const mount = () => {
    if (document.getElementById('__oxygen_glance')) return;
    const host = document.createElement('div');
    host.id = '__oxygen_glance';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      :host { all: initial; }
      .bar { position: fixed; top: 10px; right: 10px; z-index: 2147483647; display: flex; gap: 6px;
             font: 13px system-ui, sans-serif; }
      button { all: unset; cursor: pointer; width: 30px; height: 30px; border-radius: 9px; display: grid;
               place-items: center; background: rgba(21, 27, 36, .78); color: #e4ebf3;
               box-shadow: 0 0 0 1px rgba(255,255,255,.08), 0 4px 12px rgba(0,0,0,.25);
               transition: background-color .12s cubic-bezier(.22,.8,.24,1); }
      button:hover { background: rgba(111, 159, 216, .95); color: #fff; }
      svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    </style>
    <div class="bar">
      <button id="e" title="Open as a tab"><svg viewBox="0 0 24 24"><path d="M15 3h6v6"/><path d="M9 21H3v-6"/><path d="M21 3l-7 7"/><path d="M3 21l7-7"/></svg></button>
      <button id="c" title="Close (Esc)"><svg viewBox="0 0 24 24"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg></button>
    </div>`;
    root.getElementById('c').onclick = () => post('close');
    root.getElementById('e').onclick = () => post('expand');
    document.documentElement.appendChild(host);
  };
  if (document.readyState === 'loading') addEventListener('DOMContentLoaded', mount); else mount();
})();
