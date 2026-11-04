// ADE code viewer: file editor + multi-file diff, hosted in a WKWebView.
// Swift drives it through `window.octomux.*`; it reports back via webkit.messageHandlers.octomux.
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, highlightSpecialChars } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { syntaxHighlighting, HighlightStyle, foldGutter, codeFolding, foldKeymap, bracketMatching, indentOnInput, StreamLanguage } from "@codemirror/language";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { searchKeymap, highlightSelectionMatches, search } from "@codemirror/search";
import { unifiedMergeView, MergeView } from "@codemirror/merge";
import { tags as t } from "@lezer/highlight";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { yaml } from "@codemirror/lang-yaml";
import { sql } from "@codemirror/lang-sql";
import { java } from "@codemirror/lang-java";
import { cpp } from "@codemirror/lang-cpp";
import { php } from "@codemirror/lang-php";
import { xml } from "@codemirror/lang-xml";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { kotlin, csharp, scala, dart } from "@codemirror/legacy-modes/mode/clike";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { diff as diffMode } from "@codemirror/legacy-modes/mode/diff";
import { marked } from "marked";

const post = (msg) => { try { window.webkit.messageHandlers.octomux.postMessage(msg); } catch (_) {} };
const $ = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const legacy = (m) => StreamLanguage.define(m);

// ---------- languages ----------
function languageFor(path) {
  const name = (path || "").split("/").pop().toLowerCase();
  const ext = name.includes(".") ? name.split(".").pop() : "";
  if (name === "dockerfile" || name.endsWith(".dockerfile")) return legacy(dockerFile);
  if (name === "makefile" || name === "justfile") return legacy(shell);
  if (name.startsWith(".env") || name === ".gitignore" || name === ".dockerignore") return legacy(properties);
  switch (ext) {
    case "js": case "mjs": case "cjs": return javascript();
    case "jsx": return javascript({ jsx: true });
    case "ts": case "mts": case "cts": return javascript({ typescript: true });
    case "tsx": return javascript({ typescript: true, jsx: true });
    case "py": case "pyi": return python();
    case "rs": return rust();
    case "go": return go();
    case "json": case "jsonc": case "json5": case "lock": return json();
    case "md": case "markdown": case "mdx": return markdown();
    case "html": case "htm": case "vue": case "svelte": return html();
    case "css": case "scss": case "less": return css();
    case "yaml": case "yml": return yaml();
    case "sql": return sql();
    case "java": return java();
    case "c": case "h": case "cc": case "cpp": case "cxx": case "hpp": case "m": case "mm": return cpp();
    case "php": return php();
    case "xml": case "svg": case "plist": case "xib": case "storyboard": return xml();
    case "sh": case "bash": case "zsh": case "fish": return legacy(shell);
    case "swift": return legacy(swift);
    case "toml": return legacy(toml);
    case "rb": return legacy(ruby);
    case "lua": return legacy(lua);
    case "kt": case "kts": return legacy(kotlin);
    case "cs": return legacy(csharp);
    case "scala": return legacy(scala);
    case "dart": return legacy(dart);
    case "ini": case "conf": case "cfg": case "properties": return legacy(properties);
    case "diff": case "patch": return legacy(diffMode);
    default: return [];
  }
}

// ---------- theme (colors come from CSS variables Swift sets) ----------
const highlight = HighlightStyle.define([
  { tag: [t.keyword, t.modifier, t.controlKeyword, t.operatorKeyword, t.definitionKeyword, t.moduleKeyword], color: "var(--syn-keyword)" },
  { tag: [t.string, t.special(t.string), t.regexp, t.character], color: "var(--syn-string)" },
  { tag: [t.number, t.bool, t.null, t.atom], color: "var(--syn-number)" },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--syn-comment)", fontStyle: "italic" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], color: "var(--syn-func)" },
  { tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName)], color: "var(--syn-type)" },
  { tag: [t.propertyName, t.attributeName], color: "var(--syn-prop)" },
  { tag: [t.tagName, t.heading], color: "var(--syn-tag)", fontWeight: "600" },
  { tag: [t.definition(t.variableName), t.self], color: "var(--syn-def)" },
  { tag: [t.meta, t.annotation, t.processingInstruction], color: "var(--syn-meta)" },
  { tag: [t.link, t.url], color: "var(--syn-string)", textDecoration: "underline" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: t.inserted, color: "var(--green)" },
  { tag: t.deleted, color: "var(--red)" },
  { tag: t.invalid, color: "var(--red)" },
]);

const baseTheme = EditorView.theme({
  "&": { color: "var(--text)", backgroundColor: "transparent", fontSize: "var(--code-size)" },
  ".cm-scroller": { fontFamily: "var(--mono)", lineHeight: "1.6" },
  ".cm-content": { caretColor: "var(--accent)", padding: "6px 0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent)", borderLeftWidth: "2px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: "var(--selection) !important" },
  ".cm-gutters": { backgroundColor: "transparent", color: "var(--text3)", border: "none" },
  ".cm-lineNumbers .cm-gutterElement": { padding: "0 10px 0 14px", minWidth: "32px" },
  ".cm-activeLine": { backgroundColor: "var(--hover)" },
  ".cm-activeLineGutter": { backgroundColor: "transparent", color: "var(--text)" },
  ".cm-foldGutter .cm-gutterElement": { color: "var(--text3)", cursor: "pointer", padding: "0 4px" },
  ".cm-foldPlaceholder": { background: "var(--hover)", border: "1px solid var(--border)", color: "var(--text2)", padding: "0 6px", borderRadius: "4px" },
  ".cm-matchingBracket": { backgroundColor: "var(--hover2)", outline: "1px solid var(--border)" },
  ".cm-selectionMatch": { backgroundColor: "var(--hover2)" },
  ".cm-searchMatch": { backgroundColor: "color-mix(in srgb, var(--amber) 30%, transparent)" },
  ".cm-searchMatch-selected": { backgroundColor: "color-mix(in srgb, var(--amber) 55%, transparent)" },
  ".cm-panels": { backgroundColor: "var(--raised)", color: "var(--text)", borderColor: "var(--border) !important" },
  ".cm-panel input, .cm-panel button": { fontFamily: "inherit", fontSize: "12px" },
  // merge (diff) styling
  ".cm-changedLine, &.cm-merge-b .cm-changedLine": { backgroundColor: "var(--add-bg) !important" },
  ".cm-insertedLine, .cm-deletedLine, .cm-deletedLine del": { textDecoration: "none", background: "transparent !important" },
  ".cm-deletedChunk": { backgroundColor: "var(--del-bg) !important", paddingLeft: "6px" },
  "&.cm-merge-a .cm-changedLine": { backgroundColor: "var(--del-bg) !important" },
  ".cm-changedText, &.cm-merge-b .cm-changedText": { background: "var(--add-word) !important" },
  "&.cm-merge-a .cm-changedText, .cm-deletedChunk .cm-deletedText": { background: "var(--del-word) !important" },
  ".cm-deletedChunk del": { textDecoration: "none" },
  ".cm-changeGutter": { width: "3px", paddingLeft: "0" },
  // .cm-gutterElement: more specific than the merge package's own dark/light colors, so ours always win.
  ".cm-changedLineGutter.cm-gutterElement": { background: "var(--green)" },
  "&.cm-merge-a .cm-changedLineGutter.cm-gutterElement, .cm-deletedLineGutter.cm-gutterElement": { background: "var(--red)" },
  ".cm-collapsedLines": {
    background: "var(--hunk-bg)", color: "var(--blue)", fontFamily: "var(--ui)", fontSize: "11.5px",
    padding: "4px 14px", cursor: "pointer", borderTop: "1px solid var(--border)", borderBottom: "1px solid var(--border)",
  },
  ".cm-collapsedLines:before": { content: '"⇕  "' },
  ".cm-collapsedLines:after": { content: '""' },
  ".cm-collapsedLines:hover": { background: "var(--hover2)" },
});

function common({ path, editable, wrap }) {
  return [
    highlightSpecialChars(),
    drawSelection(),
    EditorState.allowMultipleSelections.of(true),
    syntaxHighlighting(highlight),
    bracketMatching(),
    highlightSelectionMatches(),
    search({ top: true }),
    keymap.of([...searchKeymap, ...foldKeymap, ...defaultKeymap]),
    baseTheme,
    languageFor(path),
    EditorState.readOnly.of(!editable),
    EditorView.editable.of(!!editable),
    wrap ? EditorView.lineWrapping : [],
  ];
}

// ---------- file view ----------
let current = null;     // { kind, destroy() }
const root = () => document.getElementById("root");

function clearRoot() {
  if (current && current.destroy) current.destroy();
  current = null;
  root().replaceChildren();
}

function showFile(f) {
  clearRoot();
  const wrap = $("div", "file");
  const bar = $("div", "bar");
  const crumbs = $("div", "crumbs");
  const parts = (f.path || "").split("/");
  parts.forEach((p, i) => {
    if (i) crumbs.append($("span", "sep", "›"));
    crumbs.append($("span", i === parts.length - 1 ? "leaf" : "", p));
  });
  bar.append(crumbs);
  const right = $("div", "right");
  const status = $("span", "status", "");
  right.append(status);
  bar.append(right);
  const body = $("div", "body");
  wrap.append(bar, body);
  root().append(wrap);

  if (f.binary || f.error) {
    body.append($("div", "notice", f.error || "Binary file — not shown"));
    current = { kind: "file" };
    return;
  }

  const isMd = /\.(md|markdown|mdx)$/i.test(f.path || "");
  let saved = f.text;
  const editorHost = $("div", "editor");
  const preview = $("div", "markdown");
  body.append(editorHost, preview);

  const lang = new Compartment();
  const view = new EditorView({
    parent: editorHost,
    state: EditorState.create({
      doc: f.text,
      extensions: [
        lineNumbers(), highlightActiveLineGutter(), foldGutter({ markerDOM: (open) => { const s = $("span", "fold", open ? "⌄" : "›"); return s; } }), codeFolding(),
        history(), indentOnInput(), highlightActiveLine(),
        keymap.of([indentWithTab, ...historyKeymap, { key: "Mod-s", preventDefault: true, run: (v) => { post({ type: "save", text: v.state.doc.toString() }); return true; } }]),
        common({ path: f.path, editable: f.editable, wrap: isMd }),
        lang.of([]),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) {
            const dirty = u.state.doc.toString() !== saved;
            status.textContent = dirty ? "● Unsaved — ⌘S" : "";
            post({ type: "dirty", dirty });
            if (isMd && mode === "preview") renderMd();
          }
        }),
      ],
    }),
  });

  let mode = isMd ? (f.mode || "preview") : "source";
  const renderMd = () => { preview.innerHTML = marked.parse(view.state.doc.toString(), { gfm: true }); };
  const apply = () => {
    editorHost.style.display = mode === "source" ? "" : "none";
    preview.style.display = mode === "preview" ? "" : "none";
    if (mode === "preview") renderMd();
    seg && seg.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.m === mode));
  };
  let seg = null;
  if (isMd) {
    seg = $("div", "seg");
    for (const [m, label] of [["preview", "Preview"], ["source", "Source"]]) {
      const b = $("button", "", label);
      b.dataset.m = m;
      b.onclick = () => { mode = m; apply(); post({ type: "mdMode", mode }); };
      seg.append(b);
    }
    right.prepend(seg);
  }
  apply();
  preview.addEventListener("click", (e) => {
    const a = e.target.closest("a");
    if (a && a.getAttribute("href")) { e.preventDefault(); post({ type: "link", href: a.getAttribute("href") }); }
  });
  if (f.line) {
    const ln = Math.min(Math.max(1, f.line), view.state.doc.lines);
    view.dispatch({ selection: { anchor: view.state.doc.line(ln).from }, scrollIntoView: true });
  }
  if (!isMd || mode === "source") view.focus();
  current = {
    kind: "file", view,
    saved: (text) => { saved = text; status.textContent = ""; },
    reload: (text) => { if (view.state.doc.toString() === saved) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } }); saved = text; if (isMd && mode === "preview") renderMd(); } },
    destroy: () => view.destroy(),
  };
}

// ---------- diff view ----------
const diffState = {
  mode: localStorage.getItem("octomux.diffMode") || localStorage.getItem("ade.diffMode") || "unified",
  collapsed: new Set(),         // keys the user collapsed
  opened: new Set(),            // keys the user opened (large files start collapsed)
  cards: new Map(),             // key -> { el, sig, mount, unmount, file }
};

function fileSig(f) { return [f.status, f.original?.length, f.modified?.length, hash(f.original || ""), hash(f.modified || "")].join(":"); }
function hash(s) { let h = 0; for (let i = 0; i < s.length; i += Math.max(1, (s.length / 4000) | 0)) h = (h * 31 + s.charCodeAt(i)) | 0; return h; }

function startsCollapsed(f) {
  if (diffState.opened.has(f.key)) return false;
  if (diffState.collapsed.has(f.key)) return true;
  return !!(f.binary || f.tooLarge || (f.added + f.removed) > 1500 || f.status === "D");
}

function buildMerge(host, f) {
  const ext = [common({ path: f.path, editable: false }), lineNumbers(), EditorView.theme({ ".cm-content": { padding: "0" } })];
  const collapse = { margin: 3, minSize: 6 };
  // Word-level marks only help when both sides have text (not for added or deleted files).
  const words = !!(f.original && f.modified);
  if (diffState.mode === "split") {
    const mv = new MergeView({
      parent: host,
      a: { doc: f.original || "", extensions: ext },
      b: { doc: f.modified || "", extensions: ext },
      collapseUnchanged: collapse, gutter: true, highlightChanges: words,
    });
    return () => mv.destroy();
  }
  const view = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: f.modified || "",
      extensions: [ext, unifiedMergeView({ original: f.original || "", mergeControls: false, gutter: true, highlightChanges: words, syntaxHighlightDeletions: true, collapseUnchanged: collapse })],
    }),
  });
  return () => view.destroy();
}

function badgeClass(s) { return { A: "add", U: "add", D: "del", R: "ren", M: "mod" }[s] || "mod"; }

function makeCard(f) {
  const el = $("div", "card");
  const head = $("div", "head");
  const chev = $("span", "chev", "›");
  const badge = $("span", "badge " + badgeClass(f.status), f.status);
  const name = $("span", "name", f.path.split("/").pop());
  const dir = $("span", "dir", f.path.includes("/") ? f.path.slice(0, f.path.lastIndexOf("/") + 1) : "");
  const sp = $("span", "spacer");
  const stat = $("span", "stat");
  if (f.added) stat.append($("span", "plus", "+" + f.added));
  if (f.removed) stat.append($("span", "minus", "−" + f.removed));
  const open = $("button", "open", "Open");
  open.title = "Open file";
  open.onclick = (e) => { e.stopPropagation(); post({ type: "open", path: f.path }); };
  head.append(chev, badge, name, dir, sp, stat);
  if (f.status !== "D") head.append(open);
  const body = $("div", "cbody");
  el.append(head, body);
  const card = { el, f, sig: fileSig(f), unmount: null, mounted: false };
  card.mount = () => {
    if (card.mounted) return;
    card.mounted = true;
    body.replaceChildren();
    if (f.binary) { body.append($("div", "notice small", "Binary file — not shown")); return; }
    if (f.tooLarge) { body.append($("div", "notice small", "File too large to show")); return; }
    card.unmount = buildMerge(body, f);
  };
  card.unmountNow = () => { if (card.unmount) card.unmount(); card.unmount = null; card.mounted = false; body.replaceChildren(); };
  const setOpen = (o) => {
    el.classList.toggle("collapsed", !o);
    if (o) { observer.observe(el); } else { card.unmountNow(); }
  };
  card.setOpen = setOpen;
  head.onclick = () => {
    const o = el.classList.contains("collapsed");
    if (o) { diffState.collapsed.delete(f.key); diffState.opened.add(f.key); } else { diffState.collapsed.add(f.key); diffState.opened.delete(f.key); }
    setOpen(o);
  };
  setOpen(!startsCollapsed(f));
  return card;
}

// Mount editors only when their card nears the viewport (long change lists stay fast).
const observer = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    for (const c of diffState.cards.values()) if (c.el === e.target && !c.el.classList.contains("collapsed")) c.mount();
    observer.unobserve(e.target);
  }
}, { rootMargin: "800px 0px" });

let diffPayload = null;

function showDiff(p) {
  const same = current && current.kind === "diff";
  diffPayload = p;
  let list, countEl, header;
  if (!same) {
    clearRoot();
    for (const c of diffState.cards.values()) c.unmount && c.unmount();
    diffState.cards.clear();
    const wrap = $("div", "diff");
    header = $("div", "bar");
    const left = $("div", "crumbs");
    const toggleAll = $("button", "link", "Collapse All");
    toggleAll.onclick = () => {
      const anyOpen = [...diffState.cards.values()].some((c) => !c.el.classList.contains("collapsed"));
      for (const c of diffState.cards.values()) {
        if (anyOpen) { diffState.collapsed.add(c.f.key); diffState.opened.delete(c.f.key); } else { diffState.collapsed.delete(c.f.key); diffState.opened.add(c.f.key); }
        c.setOpen(!anyOpen);
      }
      toggleAll.textContent = anyOpen ? "Expand All" : "Collapse All";
    };
    left.append(toggleAll, $("span", "title", p.title || ""));
    const right = $("div", "right");
    const seg = $("div", "seg");
    for (const [m, label, tip] of [["unified", "☰", "Unified"], ["split", "◫", "Side by side"]]) {
      const b = $("button", diffState.mode === m ? "on" : "", label);
      b.title = tip;
      b.onclick = () => {
        if (diffState.mode === m) return;
        diffState.mode = m; localStorage.setItem("octomux.diffMode", m);
        seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === b));
        for (const c of diffState.cards.values()) { if (c.mounted) { c.unmountNow(); c.mount(); } }
      };
      seg.append(b);
    }
    countEl = $("span", "count");
    right.append(seg, countEl);
    header.append(left, right);
    list = $("div", "list");
    wrap.append(header, list);
    root().append(wrap);
    current = { kind: "diff", list, countEl, destroy: () => { for (const c of diffState.cards.values()) c.unmount && c.unmount(); diffState.cards.clear(); } };
  }
  list = current.list; countEl = current.countEl;
  const total = p.sections.reduce((n, s) => n + s.files.length, 0);
  countEl.textContent = total === 1 ? "1 change" : `${total} changes`;

  // Rebuild the list, reusing cards whose content did not change.
  const seen = new Set();
  const nodes = [];
  for (const s of p.sections) {
    if (!s.files.length) continue;
    if (p.sections.length > 1 || s.title) {
      const add = s.files.reduce((n, f) => n + (f.added || 0), 0), rem = s.files.reduce((n, f) => n + (f.removed || 0), 0);
      const h = $("div", "section");
      h.append($("span", "", `${s.title} (${s.files.length})`));
      const st = $("span", "stat");
      if (add) st.append($("span", "plus", "+" + add));
      if (rem) st.append($("span", "minus", "−" + rem));
      h.append(st);
      nodes.push(h);
    }
    for (const f of s.files) {
      seen.add(f.key);
      let c = diffState.cards.get(f.key);
      if (c && c.sig !== fileSig(f)) { c.unmount && c.unmount(); c = null; }
      if (!c) { c = makeCard(f); diffState.cards.set(f.key, c); }
      nodes.push(c.el);
    }
  }
  for (const [k, c] of diffState.cards) if (!seen.has(k)) { c.unmount && c.unmount(); diffState.cards.delete(k); }
  if (!total) nodes.push($("div", "notice", p.empty || "No changes"));
  list.replaceChildren(...nodes);
  if (p.scrollTo) scrollToFile(p.scrollTo);
}

function scrollToFile(key) {
  const bare = /^[sucb]:/.test(key) ? key.slice(2) : key;
  const c = diffState.cards.get(key) || [...diffState.cards.values()].find((x) => x.f.path === key || x.f.path === bare);
  if (!c) return;
  if (c.el.classList.contains("collapsed")) { diffState.collapsed.delete(c.f.key); diffState.opened.add(c.f.key); c.setOpen(true); }
  // Mount everything above (and the target) first, so late-mounting editors don't push it away.
  for (const x of diffState.cards.values()) { if (!x.el.classList.contains("collapsed")) x.mount(); if (x === c) break; }
  const list = c.el.closest(".list");
  const go = () => { if (list) list.scrollTop = c.el.offsetTop - 8; };
  go(); requestAnimationFrame(() => { go(); requestAnimationFrame(go); });
  c.el.classList.add("flash");
  setTimeout(() => c.el.classList.remove("flash"), 900);
}

// ---------- API ----------
function setTheme(th) {
  const r = document.documentElement.style;
  for (const [k, v] of Object.entries(th.vars || {})) r.setProperty("--" + k, v);
  document.documentElement.classList.toggle("dark", !!th.dark);
}

window.octomux = {
  setTheme,
  showFile,
  showDiff,
  scrollToFile,
  saved: (text) => current && current.saved && current.saved(text),
  reload: (text) => current && current.reload && current.reload(text),
};
post({ type: "ready" });
