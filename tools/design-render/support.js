// Minimal local renderer for our own design/directions/*.dc.html (holes, sc-for, sc-if, dc-import).
// Written for ADE so the directions can be reviewed offline without the canvas editor's runtime.
(function () {
  class DCLogic { constructor(props) { this.props = props || {}; this.state = {}; } setState(s) { Object.assign(this.state, s); } }
  window.DCLogic = DCLogic;
  function load(name) {
    const x = new XMLHttpRequest(); x.open('GET', name + '.dc.html', false); x.send();
    return new DOMParser().parseFromString(x.responseText, 'text/html');
  }
  function component(doc, props) {
    const src = doc.querySelector('script[data-dc-script]').textContent;
    const Component = new Function('DCLogic', src + '\nreturn Component;')(DCLogic);
    return { tpl: doc.querySelector('x-dc'), vals: new Component(props).renderVals() };
  }
  function resolve(path, scope) {
    path = path.trim();
    if (path === 'true') return true; if (path === 'false') return false;
    if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
    return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope);
  }
  const whole = /^\{\{\s*([^}]+?)\s*\}\}$/;
  const interp = (s, scope) => s.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_, p) => { const v = resolve(p, scope); return v == null ? '' : String(v); });
  function renderInto(parent, nodes, scope) {
    for (const n of nodes) {
      if (n.nodeType === 3) { if (!n.textContent.trim() && /\n/.test(n.textContent)) continue; parent.appendChild(document.createTextNode(interp(n.textContent, scope))); continue; }
      if (n.nodeType !== 1) continue;
      const tag = n.tagName.toLowerCase();
      if (tag === 'helmet') { for (const c of n.children) document.head.appendChild(c.cloneNode(true)); continue; }
      if (tag === 'sc-for') {
        const m = whole.exec(n.getAttribute('list')); const list = (m && resolve(m[1], scope)) || [];
        const as = n.getAttribute('as') || 'item';
        list.forEach((it, i) => renderInto(parent, n.childNodes, Object.assign({}, scope, { [as]: it, $index: i })));
        continue;
      }
      if (tag === 'sc-if') { const m = whole.exec(n.getAttribute('value')); if (m && resolve(m[1], scope)) renderInto(parent, n.childNodes, scope); continue; }
      if (tag === 'dc-import') {
        const props = {}; for (const a of n.attributes) if (!a.name.startsWith('hint') && a.name !== 'name') props[a.name] = a.value;
        const c = component(load(n.getAttribute('name')), props);
        renderInto(parent, c.tpl.childNodes, c.vals); continue;
      }
      const el = document.createElementNS(n.namespaceURI, n.localName);
      for (const a of n.attributes) el.setAttribute(a.name, interp(a.value, scope));
      renderInto(el, n.childNodes, scope);
      parent.appendChild(el);
    }
  }
  document.addEventListener('DOMContentLoaded', () => {
    const c = component(document, {});
    const root = document.createElement('div');
    renderInto(root, c.tpl.childNodes, c.vals);
    c.tpl.replaceWith(root);
    document.documentElement.setAttribute('data-rendered', '1');
  });
})();
