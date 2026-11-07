// The Octomux browser's agent side, injected into every frame of a browser page in its own content world (page
// scripts can't see or change it). The app calls `globalThis.__octomux.*` to read the page as an accessibility
// snapshot (Playwright's format, with [ref=eN] on elements an agent can act on) and to act on those elements.
import { generateAriaTree, renderAriaTreeAsJSON } from '../vendor/playwright/injected/ariaSnapshot';
import { renderAriaSnapshotAsYaml } from '../vendor/playwright/isomorphic/ariaSnapshotRenderer';

const MAX_TEXT = 300;
/** Elements of the last snapshot, by ref (iframe contents too, "f1e3"). */
let refs = new Map();
let snapshotCount = 0;

function frameDocs() {
  // Same-origin iframes are read from here; cross-origin ones stay an "iframe" node.
  const out = [];
  for (const f of document.querySelectorAll('iframe, frame')) {
    try { if (f.contentDocument && f.contentDocument.body) out.push(f); } catch { /* cross-origin */ }
  }
  return out;
}

function snapshot(opts = {}) {
  snapshotCount++;
  const mode = { mode: 'ai', depth: opts.depth };
  const tree = generateAriaTree(document.body || document.documentElement, mode);
  const { json, iframeDepths } = renderAriaTreeAsJSON(tree, mode);
  let yaml = renderAriaSnapshotAsYaml(json);
  const next = new Map();
  for (const [ref, info] of tree.info) next.set(ref, info.element);
  // Stitch same-origin iframe contents under their node, refs prefixed f1, f2, …
  let n = 0;
  for (const ref of tree.iframeRefs) {
    const el = next.get(ref);
    let doc = null;
    try { doc = el && el.contentDocument; } catch { doc = null; }
    if (!doc || !doc.body) continue;
    n++;
    const sub = generateAriaTree(doc.body, { mode: 'ai', refPrefix: `f${n}`, depth: opts.depth });
    const subJson = renderAriaTreeAsJSON(sub, { mode: 'ai', refPrefix: `f${n}` }).json;
    for (const [r, info] of sub.info) next.set(r, info.element);
    const pad = '  '.repeat((iframeDepths[ref] || 0) + 1);
    const body = renderAriaSnapshotAsYaml(subJson).split('\n').filter(Boolean).map(l => pad + l).join('\n');
    if (!body) continue;
    const lines = yaml.split('\n');
    const i = lines.findIndex(l => l.includes(`[ref=${ref}]`));
    if (i < 0) continue;
    if (!lines[i].endsWith(':')) lines[i] += ':';
    lines.splice(i + 1, 0, body);
    yaml = lines.join('\n');
  }
  refs = next;
  return { yaml, url: location.href, title: document.title };
}

function resolve(ref) {
  const el = refs.get(ref);
  if (!el || !el.isConnected)
    throw new Error(`Ref ${ref} not found in the current page snapshot. Take a new snapshot (browser_snapshot) and use a ref from it.`);
  return el;
}

/** The element's frame offset inside the top document (same-origin iframes). */
function frameOffset(el) {
  let x = 0, y = 0;
  let win = el.ownerDocument.defaultView;
  while (win && win !== window && win.frameElement) {
    const r = win.frameElement.getBoundingClientRect();
    const cs = getComputedStyle(win.frameElement);
    x += r.left + parseFloat(cs.borderLeftWidth || '0') + parseFloat(cs.paddingLeft || '0');
    y += r.top + parseFloat(cs.borderTopWidth || '0') + parseFloat(cs.paddingTop || '0');
    win = win.parent;
  }
  return { x, y };
}

function describe(el) {
  if (!el || el.nodeType !== 1) return 'something';
  const tag = el.tagName.toLowerCase();
  const id = el.id ? `#${el.id}` : '';
  const cls = typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
  const text = (el.innerText || el.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ').slice(0, 40);
  return `<${tag}${id}${cls}>${text ? ` "${text}"` : ''}`;
}

/** Scrolls the element into view; its center in top-level viewport CSS pixels, and what a click there hits. */
function locate(ref) {
  const el = resolve(ref);
  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const r = el.getBoundingClientRect();
  const off = frameOffset(el);
  const box = { x: r.left + off.x, y: r.top + off.y, width: r.width, height: r.height };
  if (r.width === 0 && r.height === 0) return { box, center: { x: box.x, y: box.y }, hit: 'hidden' };
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  const hitEl = el.ownerDocument.elementFromPoint(cx, cy);
  let hit = 'ok';
  if (hitEl && hitEl !== el && !el.contains(hitEl) && !(hitEl.shadowRoot && hitEl.contains(el)) && !isLabelFor(hitEl, el))
    hit = `covered by ${describe(hitEl)}`;
  return { box, center: { x: cx + off.x, y: cy + off.y }, hit, hitEl: hit === 'ok' ? null : hitEl };
}

function isLabelFor(label, el) {
  return label.tagName === 'LABEL' && (label.control === el || label.contains(el));
}

function mouseInit(el, x, y, button, extra = {}) {
  const view = el.ownerDocument.defaultView;
  return { bubbles: true, cancelable: true, composed: true, view, clientX: x, clientY: y, screenX: x, screenY: y,
    button, buttons: extra.buttons ?? 0, detail: extra.detail ?? 1, ...extra };
}

function pointer(el, type, x, y, button, extra) {
  const P = el.ownerDocument.defaultView.PointerEvent || PointerEvent;
  el.dispatchEvent(new P(type, { ...mouseInit(el, x, y, button, extra), pointerId: 1, pointerType: 'mouse', isPrimary: true }));
}

function mouse(el, type, x, y, button, extra) {
  const M = el.ownerDocument.defaultView.MouseEvent || MouseEvent;
  return el.dispatchEvent(new M(type, mouseInit(el, x, y, button, extra)));
}

function hoverAt(el, x, y) {
  pointer(el, 'pointerover', x, y, 0); pointer(el, 'pointerenter', x, y, 0);
  mouse(el, 'mouseover', x, y, 0); mouse(el, 'mouseenter', x, y, 0);
  pointer(el, 'pointermove', x, y, 0); mouse(el, 'mousemove', x, y, 0);
}

function focusable(el) {
  let e = el;
  while (e && e.nodeType === 1) {
    if (typeof e.focus === 'function' && (e.tabIndex >= 0 || e.isContentEditable)) return e;
    e = e.parentElement;
  }
  return null;
}

function clickOnce(el, x, y, btn, detail) {
  const buttons = btn === 0 ? 1 : btn === 2 ? 2 : 4;
  pointer(el, 'pointerdown', x, y, btn, { buttons, detail });
  const go = mouse(el, 'mousedown', x, y, btn, { buttons, detail });
  if (go) { const f = focusable(el); if (f && f.ownerDocument.activeElement !== f) f.focus({ preventScroll: true }); }
  pointer(el, 'pointerup', x, y, btn, { detail });
  mouse(el, 'mouseup', x, y, btn, { detail });
  if (btn === 0) {
    // A synthetic click runs the element's default action too (follow a link, toggle a checkbox, submit).
    mouse(el, 'click', x, y, btn, { detail });
  } else if (btn === 1) {
    mouse(el, 'auxclick', x, y, btn, { detail });
  } else {
    mouse(el, 'contextmenu', x, y, btn, { detail });
  }
}

function click(ref, opts = {}) {
  const loc = locate(ref);
  const el = resolve(ref);
  // Clicking what covers the element would act on something else; tell the agent instead.
  if (loc.hit.startsWith('covered') && !opts.force) throw new Error(`Element ${ref} is ${loc.hit}. Close or scroll past it first, or act on that element.`);
  const target = el;
  const r = target.getBoundingClientRect();
  const x = r.left + r.width / 2, y = r.top + r.height / 2;
  const btn = opts.button === 'right' ? 2 : opts.button === 'middle' ? 1 : 0;
  hoverAt(target, x, y);
  clickOnce(target, x, y, btn, 1);
  if (opts.doubleClick) {
    clickOnce(target, x, y, btn, 2);
    mouse(target, 'dblclick', x, y, btn, { detail: 2 });
  }
  return { center: loc.center };
}

function hover(ref) {
  const loc = locate(ref);
  const el = resolve(ref);
  const r = el.getBoundingClientRect();
  hoverAt(el, r.left + r.width / 2, r.top + r.height / 2);
  return { center: loc.center };
}

const nativeSetter = (el) => {
  const W = el.ownerDocument.defaultView;
  const proto = el instanceof W.HTMLTextAreaElement ? W.HTMLTextAreaElement.prototype
    : el instanceof W.HTMLSelectElement ? W.HTMLSelectElement.prototype : W.HTMLInputElement.prototype;
  return Object.getOwnPropertyDescriptor(proto, 'value').set;
};

function key(el, type, k, extra = {}) {
  const K = el.ownerDocument.defaultView.KeyboardEvent || KeyboardEvent;
  return el.dispatchEvent(new K(type, { key: k, code: codeFor(k), bubbles: true, cancelable: true, composed: true, ...extra }));
}

function codeFor(k) {
  if (k.length === 1) {
    if (/[a-z]/i.test(k)) return 'Key' + k.toUpperCase();
    if (/[0-9]/.test(k)) return 'Digit' + k;
    if (k === ' ') return 'Space';
    return '';
  }
  return k;
}

function editable(el) {
  const W = el.ownerDocument.defaultView;
  if (el instanceof W.HTMLInputElement) {
    const t = (el.type || 'text').toLowerCase();
    if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden'].includes(t)) throw new Error(`Can't type into an <input type=${t}>; click it instead.`);
    return 'input';
  }
  if (el instanceof W.HTMLTextAreaElement) return 'input';
  if (el.isContentEditable) return 'editable';
  // A wrapper with a single editable inside (e.g. a labelled search box).
  const inner = el.querySelector && el.querySelector('input:not([type=hidden]), textarea, [contenteditable=""], [contenteditable=true]');
  if (inner) return 'inner';
  throw new Error(`Element is not editable: ${describe(el)}.`);
}

function insertText(el, text) {
  const doc = el.ownerDocument;
  return doc.execCommand && doc.execCommand('insertText', false, text);
}

function type(ref, text, opts = {}) {
  let el = resolve(ref);
  let kind = editable(el);
  if (kind === 'inner') { el = el.querySelector('input:not([type=hidden]), textarea, [contenteditable=""], [contenteditable=true]'); kind = editable(el); }
  const loc = locate(ref);
  el.focus({ preventScroll: true });
  const W = el.ownerDocument.defaultView;
  const special = kind === 'input' && el instanceof W.HTMLInputElement && ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range', 'number'].includes(el.type);
  if (kind === 'input') {
    if (special) {
      nativeSetter(el).call(el, text);
      el.dispatchEvent(new W.Event('input', { bubbles: true, composed: true }));
      el.dispatchEvent(new W.Event('change', { bubbles: true }));
    } else {
      el.select && el.select();
      if (opts.slowly) {
        if (el.value) { insertText(el, '') || nativeSetter(el).call(el, ''); }
        for (const ch of text) {
          key(el, 'keydown', ch);
          key(el, 'keypress', ch, { charCode: ch.charCodeAt(0) });
          if (!insertText(el, ch)) { nativeSetter(el).call(el, el.value + ch); el.dispatchEvent(new W.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: ch })); }
          key(el, 'keyup', ch);
        }
      } else if (!(text === '' ? (el.value === '' || insertText(el, '') || false) : insertText(el, text)) || el.value !== text) {
        // execCommand refused (or the page rewrote it): set the value the way frameworks notice it.
        nativeSetter(el).call(el, text);
        el.dispatchEvent(new W.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
      }
      el.dispatchEvent(new W.Event('change', { bubbles: true }));
    }
  } else {
    const sel = W.getSelection();
    const range = el.ownerDocument.createRange();
    range.selectNodeContents(el);
    sel.removeAllRanges(); sel.addRange(range);
    if (opts.slowly) {
      insertText(el, '') || document.execCommand('delete');
      for (const ch of text) { key(el, 'keydown', ch); insertText(el, ch); key(el, 'keyup', ch); }
    } else if (!insertText(el, text)) {
      el.textContent = text;
      el.dispatchEvent(new W.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
    }
  }
  if (opts.submit) press('Enter');
  return { center: loc.center };
}

const KEY_ALIASES = { Return: 'Enter', Esc: 'Escape', Del: 'Delete', Space: ' ', Up: 'ArrowUp', Down: 'ArrowDown', Left: 'ArrowLeft', Right: 'ArrowRight', Cmd: 'Meta', Command: 'Meta', Ctrl: 'Control', Option: 'Alt', ControlOrMeta: 'Meta' };

function activeDeep() {
  let a = document.activeElement;
  while (a) {
    if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
    if ((a.tagName === 'IFRAME' || a.tagName === 'FRAME')) {
      try { if (a.contentDocument && a.contentDocument.activeElement) { a = a.contentDocument.activeElement; continue; } } catch { /* cross-origin */ }
    }
    break;
  }
  return a || document.body;
}

function tabbables(doc) {
  return [...doc.querySelectorAll('a[href], button, input, select, textarea, summary, [tabindex], [contenteditable=""], [contenteditable=true]')]
    .filter(e => !e.disabled && e.tabIndex >= 0 && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden');
}

function press(combo) {
  const parts = String(combo).split('+').filter(Boolean);
  let k = parts.pop() || '';
  if (combo.endsWith('++')) k = '+';
  k = KEY_ALIASES[k] || k;
  const mods = new Set(parts.map(m => KEY_ALIASES[m] || m));
  const flags = { ctrlKey: mods.has('Control'), metaKey: mods.has('Meta'), altKey: mods.has('Alt'), shiftKey: mods.has('Shift') };
  const el = activeDeep();
  const W = el.ownerDocument.defaultView;
  const go = key(el, 'keydown', k, flags);
  const plain = !flags.ctrlKey && !flags.metaKey && !flags.altKey;
  if (go) {
    if (k.length === 1 && plain) {
      key(el, 'keypress', k, { ...flags, charCode: k.charCodeAt(0) });
      insertText(el, k);
    } else if (k === 'Enter') {
      key(el, 'keypress', k, { ...flags, charCode: 13 });
      if (el instanceof W.HTMLTextAreaElement || el.isContentEditable) insertText(el, '\n');
      else if (el instanceof W.HTMLInputElement && el.form) {
        // Implicit submission, which a synthetic key doesn't trigger by itself.
        const submit = el.form.querySelector('button:not([type]), button[type=submit], input[type=submit]');
        if (el.form.requestSubmit) el.form.requestSubmit(submit && !submit.disabled ? submit : undefined); else el.form.submit();
      } else if (el instanceof W.HTMLAnchorElement || el instanceof W.HTMLButtonElement || el.getAttribute('role') === 'button') el.click();
    } else if (k === ' ' && plain && (el instanceof W.HTMLButtonElement || (el instanceof W.HTMLInputElement && ['checkbox', 'radio', 'button', 'submit'].includes(el.type)))) {
      el.click();
    } else if (k === 'Backspace' || k === 'Delete') {
      el.ownerDocument.execCommand(k === 'Backspace' ? 'delete' : 'forwardDelete');
    } else if (k === 'Tab') {
      const list = tabbables(el.ownerDocument);
      const i = list.indexOf(el);
      const next = list[(i + (flags.shiftKey ? -1 : 1) + list.length) % list.length];
      if (next) next.focus();
    } else if (k === 'a' && (flags.metaKey || flags.ctrlKey)) {
      el.select ? el.select() : el.ownerDocument.execCommand('selectAll');
    } else if (k === 'Escape' && el.ownerDocument.activeElement && el !== el.ownerDocument.body) {
      // Nothing native to do; pages listen for the key.
    }
  }
  key(activeDeep(), 'keyup', k, flags);
  return {};
}

function selectOption(ref, values) {
  const el = resolve(ref);
  const W = el.ownerDocument.defaultView;
  if (!(el instanceof W.HTMLSelectElement)) throw new Error(`Element is not a <select>: ${describe(el)}. Click it and pick from the list instead.`);
  const loc = locate(ref);
  const wanted = values.map(String);
  const opts = [...el.options];
  const picked = [];
  for (const v of wanted) {
    const o = opts.find(o => o.value === v) || opts.find(o => o.label === v || o.text.trim() === v);
    if (!o) throw new Error(`No option "${v}" in the list. Options: ${opts.slice(0, 30).map(o => JSON.stringify(o.label || o.value)).join(', ')}`);
    picked.push(o);
  }
  if (!el.multiple && picked.length > 1) throw new Error('This list takes one option.');
  for (const o of opts) o.selected = picked.includes(o);
  el.dispatchEvent(new W.Event('input', { bubbles: true, composed: true }));
  el.dispatchEvent(new W.Event('change', { bubbles: true }));
  return { center: loc.center };
}

/** Resolves when the DOM has been quiet for `quiet` ms (or after `cap` ms). */
function settle(quiet = 120, cap = 3000) {
  return new Promise(res => {
    let t = setTimeout(done, quiet);
    const cap_t = setTimeout(done, cap);
    const mo = new MutationObserver(() => { clearTimeout(t); t = setTimeout(done, quiet); });
    mo.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
    function done() { mo.disconnect(); clearTimeout(t); clearTimeout(cap_t); res(true); }
  });
}

function pageText() {
  let s = document.body ? document.body.innerText : '';
  for (const f of frameDocs()) { try { s += '\n' + f.contentDocument.body.innerText; } catch { /* gone */ } }
  return s;
}

async function waitFor(opts = {}) {
  const limit = Math.min(Number(opts.time ?? 30), 30) * 1000;
  const start = Date.now();
  if (!opts.text && !opts.textGone) { await new Promise(r => setTimeout(r, limit)); return { waited: limit / 1000 }; }
  while (Date.now() - start < (opts.time ? limit : 30000)) {
    const t = pageText();
    if ((!opts.text || t.includes(opts.text)) && (!opts.textGone || !t.includes(opts.textGone))) return { waited: (Date.now() - start) / 1000 };
    await new Promise(r => setTimeout(r, 150));
  }
  throw new Error(opts.text ? `"${opts.text}" didn't appear within ${Math.round((Date.now() - start) / 1000)} s.` : `"${opts.textGone}" was still there after ${Math.round((Date.now() - start) / 1000)} s.`);
}

/** Marks an element so code in the page's own world can find it (browser_evaluate with a ref). */
function mark(ref) {
  const el = resolve(ref);
  const id = 'o' + Math.random().toString(36).slice(2);
  el.setAttribute('data-octomux-eval', id);
  return id;
}

function box(ref) {
  const el = resolve(ref);
  el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
  const r = el.getBoundingClientRect();
  const off = frameOffset(el);
  return { x: r.left + off.x, y: r.top + off.y, width: r.width, height: r.height };
}

function metrics() {
  const d = document.documentElement;
  return { width: Math.max(d.scrollWidth, document.body ? document.body.scrollWidth : 0), height: Math.max(d.scrollHeight, document.body ? document.body.scrollHeight : 0),
    viewportWidth: innerWidth, viewportHeight: innerHeight, scrollX, scrollY };
}

globalThis.__octomux = { snapshot, resolve, locate, click, hover, type, press, selectOption, settle, waitFor, mark, box, metrics,
  get snapshotCount() { return snapshotCount; }, MAX_TEXT };
