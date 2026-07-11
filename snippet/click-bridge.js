/**
 * click-bridge universal snippet — Alt+Click ile elementi + tanı bağlamını Claude Code'a gönderir.
 * Kullanım (dev-only): <script src="http://127.0.0.1:7823/snippet.js"></script>
 * Gönderilen: component adı (data-component > React fiber > tag), kaynak dosya:satır (data-file/line >
 * React _debugSource), CSS selector, metin, box-model, SON CONSOLE HATALARI, BAŞARISIZ NETWORK İSTEKLERİ, viewport.
 */
(() => {
  if (window.__clickBridgeLoaded) return;
  window.__clickBridgeLoaded = true;
  const BRIDGE = 'http://127.0.0.1:7823/click';

  // ── tanı tamponları (sayfa yüklendiğinden beri biriktir) ──────────────────
  const consoleBuf = [];
  const netBuf = [];
  const push = (buf, item, max = 25) => { buf.push(item); if (buf.length > max) buf.shift(); };

  ['error', 'warn'].forEach(level => {
    const orig = console[level].bind(console);
    console[level] = (...args) => {
      try {
        push(consoleBuf, { level, msg: args.map(a => String((a && a.stack) || a)).join(' ').slice(0, 300), t: Date.now() });
      } catch (_) { /* tanı asla uygulamayı bozmasın */ }
      orig(...args);
    };
  });
  window.addEventListener('error', e =>
    push(consoleBuf, { level: 'uncaught', msg: `${e.message || ''} @${e.filename || '?'}:${e.lineno || '?'}`, t: Date.now() }));
  window.addEventListener('unhandledrejection', e =>
    push(consoleBuf, { level: 'unhandledrejection', msg: String(e.reason).slice(0, 300), t: Date.now() }));

  const origFetch = window.fetch.bind(window);
  window.fetch = async (...a) => {
    const url = String((a[0] && a[0].url) || a[0] || '');
    if (url.includes('127.0.0.1:7823')) return origFetch(...a); // köprünün kendisini izleme
    const start = performance.now();
    try {
      const r = await origFetch(...a);
      if (!r.ok) push(netBuf, { url: url.slice(0, 200), status: r.status, ms: Math.round(performance.now() - start) });
      return r;
    } catch (err) {
      push(netBuf, { url: url.slice(0, 200), status: 'NETWORK_FAIL', err: String(err).slice(0, 120) });
      throw err;
    }
  };
  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u, ...r) { this.__cbUrl = String(u); return origOpen.call(this, m, u, ...r); };
  XMLHttpRequest.prototype.send = function (...a) {
    this.addEventListener('loadend', () => {
      if (this.status === 0 || this.status >= 400)
        push(netBuf, { url: (this.__cbUrl || '').slice(0, 200), status: this.status || 'NETWORK_FAIL' });
    });
    return origSend.apply(this, a);
  };

  // ── React fiber'dan component zinciri + kaynak (best-effort) ──────────────
  function reactInfo(el) {
    try {
      const key = Object.keys(el).find(k => k.startsWith('__reactFiber$'));
      if (!key) return null;
      let fiber = el[key];
      const chain = [];
      let src = null;
      while (fiber && chain.length < 8) {
        const t = fiber.type;
        const name = typeof t === 'function' ? (t.displayName || t.name)
          : (t && typeof t === 'object' ? (t.displayName || null) : null);
        if (name && !chain.includes(name)) chain.push(name);
        if (!src && fiber._debugSource)
          src = { file: fiber._debugSource.fileName, line: fiber._debugSource.lineNumber };
        fiber = fiber.return;
      }
      return (chain.length || src) ? { components: chain, source: src } : null;
    } catch (_) { return null; }
  }

  function cssPath(el) {
    const parts = [];
    while (el && el.nodeType === 1 && parts.length < 6) {
      let s = el.tagName.toLowerCase();
      if (el.id) { parts.unshift(s + '#' + el.id); break; }
      if (el.classList.length) s += '.' + [...el.classList].slice(0, 2).join('.');
      parts.unshift(s);
      el = el.parentElement;
    }
    return parts.join(' > ');
  }

  // ── görsel geri bildirim ───────────────────────────────────────────────────
  const style = document.createElement('style');
  style.textContent = '.__cb-hover{outline:2px solid #f7768e !important;outline-offset:2px;cursor:crosshair !important}';
  document.head.appendChild(style);
  let hovered = null;
  document.addEventListener('mousemove', e => {
    if (!e.altKey) { if (hovered) { hovered.classList.remove('__cb-hover'); hovered = null; } return; }
    const t = e.target.closest('[data-component]') || e.target;
    if (hovered !== t) { if (hovered) hovered.classList.remove('__cb-hover'); hovered = t; t.classList.add('__cb-hover'); }
  });

  function toast(msg, ok) {
    const d = document.createElement('div');
    d.textContent = msg;
    d.style.cssText = 'position:fixed;bottom:24px;right:24px;z-index:2147483647;background:' +
      (ok ? '#9ece6a' : '#f7768e') + ';color:#111;padding:10px 16px;border-radius:8px;font:600 14px system-ui;transition:opacity .3s';
    document.body.appendChild(d);
    setTimeout(() => { d.style.opacity = 0; setTimeout(() => d.remove(), 350); }, 1600);
  }

  // ── Alt+Click → topla + gönder ─────────────────────────────────────────────
  document.addEventListener('click', async e => {
    if (!e.altKey) return;
    e.preventDefault(); e.stopPropagation();
    const t = e.target.closest('[data-component]') || e.target;
    const r = t.getBoundingClientRect();
    const cs = getComputedStyle(t);
    const react = reactInfo(t);
    const ds = t.dataset || {};
    const payload = {
      component: ds.component || (react && react.components[0]) || t.tagName.toLowerCase(),
      component_chain: react ? react.components : [],
      source: ds.file ? { file: ds.file, line: ds.line ? Number(ds.line) : null } : (react && react.source) || null,
      selector: cssPath(t),
      text: (t.innerText || '').trim().slice(0, 200),
      url: location.href,
      box: {
        w: Math.round(r.width), h: Math.round(r.height), x: Math.round(r.x), y: Math.round(r.y),
        padding: cs.padding, margin: cs.margin, display: cs.display, position: cs.position, fontSize: cs.fontSize,
      },
      console_errors: consoleBuf.slice(-10),
      failed_requests: netBuf.slice(-10),
      viewport: { w: innerWidth, h: innerHeight, dpr: devicePixelRatio },
    };
    try {
      await fetch(BRIDGE, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      toast('→ Claude Code ✓ ' + payload.component, true);
    } catch (err) {
      toast('click-bridge kapalı? (systemctl --user start click-bridge) ' + err, false);
    }
  }, true);

  console.log('%c🖱️🎯 click-bridge aktif — Alt+Click ile Claude Code\'a gönder', 'color:#7aa2f7;font-weight:bold');
})();
