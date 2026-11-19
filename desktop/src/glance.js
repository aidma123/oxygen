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
      button { all: unset; cursor: pointer; width: 30px; height: 30px; border-radius: 8px; display: grid;
               place-items: center; background: rgba(20,20,24,.82); color: #fff; box-shadow: 0 2px 8px rgba(0,0,0,.35); }
      button:hover { background: rgba(60,60,72,.95); }
    </style>
    <div class="bar">
      <button id="e" title="Open as a tab">⤢</button>
      <button id="c" title="Close (Esc)">✕</button>
    </div>`;
    root.getElementById('c').onclick = () => post('close');
    root.getElementById('e').onclick = () => post('expand');
    document.documentElement.appendChild(host);
  };
  if (document.readyState === 'loading') addEventListener('DOMContentLoaded', mount); else mount();
})();
