// ADE code viewer: file editor + multi-file diff, hosted in a WKWebView.
// Swift drives it through `window.octomux.*`; it reports back via webkit.messageHandlers.octomux.
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, highlightSpecialChars, gutter, GutterMarker } from "@codemirror/view";
import { EditorState, Compartment, StateField, StateEffect, RangeSet } from "@codemirror/state";
import { syntaxHighlighting, foldGutter, codeFolding, foldKeymap, bracketMatching, indentOnInput } from "@codemirror/language";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { searchKeymap, highlightSelectionMatches, search } from "@codemirror/search";
import { unifiedMergeView, MergeView } from "@codemirror/merge";
import { diffConfig } from "./linediff.js";
import { languageFor, highlight } from "./langs.js";
import { marked } from "marked";

const post = (msg) => { try { window.webkit.messageHandlers.octomux.postMessage(msg); } catch (_) {} };
const $ = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

const baseTheme = EditorView.theme({
  "&": { color: "var(--text)", backgroundColor: "transparent", fontSize: "var(--code-size)" },
  ".cm-scroller": { fontFamily: "var(--mono)", lineHeight: "1.6" },
  ".cm-content": { caretColor: "var(--accent)", padding: "6px 0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent)", borderLeftWidth: "2px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: "var(--selection) !important" },
  // Opaque: the gutter stays put while the code scrolls sideways under it.
  ".cm-gutters": { backgroundColor: "var(--bg)", color: "var(--text3)", border: "none" },
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

// ---------- change marks and notes (only when Swift turns them on: the default editor stays as it is) ----------
let features = { marks: false, notes: false };
let lastMarks = null;
const setMarksEffect = StateEffect.define();
class ChangeMark extends GutterMarker {
  constructor(k) { super(); this.k = k; }
  eq(o) { return o.k === this.k; }
  toDOM() { return $("div", "cm-mark cm-mark-" + this.k); }
}
const marksField = StateField.define({
  create: () => RangeSet.empty,
  update(v, tr) {
    v = v.map(tr.changes);
    for (const e of tr.effects) if (e.is(setMarksEffect)) v = e.value;
    return v;
  },
});
const marksExtension = [marksField, gutter({ class: "cm-changeGutter", markers: (v) => v.state.field(marksField) })];
function marksSet(doc, m) {
  const ranges = [];
  const at = (l, k) => { if (l >= 1 && l <= doc.lines) ranges.push(new ChangeMark(k).range(doc.line(l).from)); };
  for (const l of m.added || []) at(l, "added");
  for (const l of m.modified || []) at(l, "modified");
  for (const l of m.deleted || []) at(Math.max(1, l), "deleted");
  return RangeSet.of(ranges, true);
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
  const marksComp = new Compartment();
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
        marksComp.of(features.marks ? marksExtension : []),
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
  // A note on the selected lines, for the agent (Swift puts it in the agent's composer, unsent).
  let noteBtn = null, noteBox = null;
  const closeNote = () => { if (noteBox) { noteBox.remove(); noteBox = null; view.focus(); } };
  const openNote = () => {
    if (noteBox) { noteBox.querySelector("textarea").focus(); return; }
    const sel = view.state.selection.main, doc = view.state.doc;
    const from = doc.lineAt(sel.from).number, to = doc.lineAt(Math.max(sel.from, sel.to - (sel.to > sel.from && doc.lineAt(sel.to).from === sel.to ? 1 : 0))).number;
    const excerpt = doc.sliceString(doc.line(from).from, doc.line(to).to);
    noteBox = $("div", "notebox");
    const label = $("div", "notelabel", (from === to ? "Line " + from : "Lines " + from + "–" + to) + " → agent");
    const ta = $("textarea");
    ta.placeholder = "What should the agent do here? (↩ puts it in the agent's message, ⇧↩ new line, esc cancels)";
    const send = () => { const t = ta.value.trim(); if (!t) return; post({ type: "note", text: t, path: f.path, from, to, excerpt }); closeNote(); };
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { e.preventDefault(); closeNote(); }
      else if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
    });
    const row = $("div", "noterow");
    const cancel = $("button", "notebtn", "Cancel"); cancel.onclick = closeNote;
    const ok = $("button", "notebtn primary", "Add to agent's message"); ok.onclick = send;
    row.append(cancel, ok);
    noteBox.append(label, ta, row);
    wrap.insertBefore(noteBox, body);
    ta.focus();
  };
  const applyFeatures = () => {
    view.dispatch({ effects: marksComp.reconfigure(features.marks ? marksExtension : []) });
    if (features.marks && lastMarks) view.dispatch({ effects: setMarksEffect.of(marksSet(view.state.doc, lastMarks)) });
    if (features.notes && !noteBtn) {
      noteBtn = $("button", "notebtn", "✎ Note to agent");
      noteBtn.title = "A note on the selected lines for the project's agent (⌘⇧M)";
      noteBtn.onclick = openNote;
      right.prepend(noteBtn);
    } else if (!features.notes && noteBtn) { noteBtn.remove(); noteBtn = null; closeNote(); }
  };
  applyFeatures();
  view.dom.addEventListener("keydown", (e) => {
    if (features.notes && e.metaKey && e.shiftKey && (e.key === "m" || e.key === "M")) { e.preventDefault(); openNote(); }
  });
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
    applyFeatures,
    setMarks: () => { if (features.marks && lastMarks) view.dispatch({ effects: setMarksEffect.of(marksSet(view.state.doc, lastMarks)) }); },
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
  split: 0.5,                   // the left side's share in split mode (every file at once)
  wrap: (() => { try { return localStorage.getItem("octomux.diffWrap") === "1"; } catch { return false; } })(),
};

function setSplit(r) {
  diffState.split = Math.min(0.85, Math.max(0.15, r));
  document.documentElement.style.setProperty("--split", (diffState.split * 100).toFixed(2) + "%");
}
try { const v = parseFloat(localStorage.getItem("octomux.diffSplit")); if (v > 0 && v < 1) setSplit(v); } catch {}

/// The bar between the two sides: drag to resize (all files follow), double-click for half and half.
function splitHandle(editors) {
  const h = document.createElement("div");
  h.className = "split-handle";
  h.title = "Drag to resize · double-click to reset";
  h.addEventListener("pointerdown", (e) => {
    e.preventDefault(); e.stopPropagation();
    h.setPointerCapture(e.pointerId);
    h.classList.add("dragging");
    const box = editors.getBoundingClientRect();
    const move = (ev) => setSplit((ev.clientX - box.left) / box.width);
    const up = () => {
      h.classList.remove("dragging");
      h.removeEventListener("pointermove", move); h.removeEventListener("pointerup", up); h.removeEventListener("pointercancel", up);
      try { localStorage.setItem("octomux.diffSplit", String(diffState.split)); } catch {}
    };
    h.addEventListener("pointermove", move); h.addEventListener("pointerup", up); h.addEventListener("pointercancel", up);
  });
  h.addEventListener("dblclick", () => { setSplit(0.5); try { localStorage.setItem("octomux.diffSplit", "0.5"); } catch {} });
  editors.insertBefore(h, editors.children[1] || null);
}

function fileSig(f) { return [f.status, f.original?.length, f.modified?.length, hash(f.original || ""), hash(f.modified || "")].join(":"); }
function hash(s) { let h = 0; for (let i = 0; i < s.length; i += Math.max(1, (s.length / 4000) | 0)) h = (h * 31 + s.charCodeAt(i)) | 0; return h; }

function startsCollapsed(f) {
  if (diffState.opened.has(f.key)) return false;
  if (diffState.collapsed.has(f.key)) return true;
  return !!(f.binary || f.tooLarge || (f.added + f.removed) > 1500 || f.status === "D");
}

/// A horizontal scroll bar for each side, kept at the bottom of the window while the file is on screen
/// (the editor's own bar sits at the file's end, often far below). It lies over the code and shows only
/// while the pointer is over that side (or it is scrolling), like VS Code. Synced both ways with the editor.
function stickyScrollbars(host, sides) {
  const row = $("div", "hbars" + (sides.length > 1 ? " split" : ""));
  const cleanups = [];
  sides.forEach(({ scroller: sc, area }, i) => {
    if (i > 0) row.append($("div", "hbar-gap"));
    const bar = $("div", "hbar");
    const inner = $("div", "hbar-inner");
    bar.append(inner);
    row.append(bar);
    let from = null;   // which side moved first, so the echo doesn't bounce back
    let over = 0, idle;
    const show = () => bar.classList.toggle("show", over > 0);
    const flash = () => { bar.classList.add("show"); clearTimeout(idle); idle = setTimeout(show, 900); };
    const fit = () => {
      inner.style.width = sc.scrollWidth + "px";
      bar.classList.toggle("none", sc.scrollWidth <= sc.clientWidth + 1);
      row.classList.toggle("none", [...row.querySelectorAll(".hbar")].every((b) => b.classList.contains("none")));
      bar.scrollLeft = sc.scrollLeft;
    };
    const onBar = () => { if (from === "sc") { from = null; return; } from = "bar"; sc.scrollLeft = bar.scrollLeft; };
    const onSc = () => { flash(); if (from === "bar") { from = null; return; } from = "sc"; bar.scrollLeft = sc.scrollLeft; };
    const enter = () => { over++; show(); }, leave = () => { over = Math.max(0, over - 1); show(); };
    for (const el of [area, bar]) { el.addEventListener("mouseenter", enter); el.addEventListener("mouseleave", leave); }
    bar.addEventListener("scroll", onBar, { passive: true });
    sc.addEventListener("scroll", onSc, { passive: true });
    const ro = new ResizeObserver(fit);
    ro.observe(sc); ro.observe(sc.querySelector(".cm-content") || sc);
    requestAnimationFrame(fit);
    cleanups.push(() => {
      ro.disconnect(); clearTimeout(idle);
      sc.removeEventListener("scroll", onSc); area.removeEventListener("mouseenter", enter); area.removeEventListener("mouseleave", leave);
    });
  });
  host.append(row);
  return () => { cleanups.forEach((c) => c()); row.remove(); };
}

function buildMerge(host, f) {
  const ext = [common({ path: f.path, editable: false, wrap: diffState.wrap }), lineNumbers(), EditorView.theme({ ".cm-content": { padding: "0" } })];
  const collapse = { margin: 3, minSize: 6 };
  // Word-level marks only help when both sides have text (not for added or deleted files).
  const words = !!(f.original && f.modified);
  if (diffState.mode === "split") {
    const mv = new MergeView({
      parent: host,
      a: { doc: f.original || "", extensions: ext },
      b: { doc: f.modified || "", extensions: ext },
      collapseUnchanged: collapse, gutter: true, highlightChanges: words, diffConfig,
    });
    const editors = mv.dom.querySelector(".cm-mergeViewEditors");
    if (editors) splitHandle(editors);
    const bars = stickyScrollbars(host, [{ scroller: mv.a.scrollDOM, area: mv.a.dom }, { scroller: mv.b.scrollDOM, area: mv.b.dom }]);
    return () => { bars(); mv.destroy(); };
  }
  const view = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: f.modified || "",
      extensions: [ext, unifiedMergeView({ original: f.original || "", mergeControls: false, gutter: true, highlightChanges: words, syntaxHighlightDeletions: true, collapseUnchanged: collapse, diffConfig })],
    }),
  });
  const bars = stickyScrollbars(host, [{ scroller: view.scrollDOM, area: view.dom }]);
  return () => { bars(); view.destroy(); };
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
    const wrapBtn = $("button", "wrapbtn" + (diffState.wrap ? " on" : ""), "↩");
    wrapBtn.title = "Wrap long lines";
    wrapBtn.onclick = () => {
      diffState.wrap = !diffState.wrap;
      try { localStorage.setItem("octomux.diffWrap", diffState.wrap ? "1" : "0"); } catch {}
      wrapBtn.classList.toggle("on", diffState.wrap);
      for (const c of diffState.cards.values()) { if (c.mounted) { c.unmountNow(); c.mount(); } }
    };
    countEl = $("span", "count");
    right.append(wrapBtn, seg, countEl);
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
  setFeatures: (f) => { features = Object.assign({ marks: false, notes: false }, f); current && current.applyFeatures && current.applyFeatures(); },
  setMarks: (m) => { lastMarks = m; current && current.setMarks && current.setMarks(); },
  reload: (text) => current && current.reload && current.reload(text),
};
post({ type: "ready" });
