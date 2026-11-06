// Chat view transcript, hosted in a WKWebView (UI/ChatWeb.swift). Swift parses the agent's JSONL transcript
// into items and sends them here (`window.octomux.chatUpdate`); this file groups them into turns and draws
// markdown, tool runs, edit diffs, todo lists and questions. It reports back through
// webkit.messageHandlers.octomux (links, files to open, text to copy). It never talks to the agent itself.
import { Marked } from "marked";
import { highlightCode } from "@lezer/highlight";
import { StyleModule } from "style-mod";
import { languageFor, highlight } from "./langs.js";
import { lineOps } from "./linediff.js";

const post = (msg) => { try { window.webkit.messageHandlers.octomux.postMessage(msg); } catch (_) {} };
const $ = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

if (highlight.module) StyleModule.mount(document, highlight.module);

// ---------- state ----------
const state = { items: new Map(), order: [], working: false, needsInput: false, cwd: "", home: "", agent: "Agent" };
const sentAnswers = new Set();      // tool ids answered from here (buttons stay disabled until the transcript has the result)
const toggled = new Map();          // key → open (only what the reader changed by hand)
const turnCache = new Map();        // turn key → { sig, el }
let list, jump, workingEl;

function hashStr(s) { let h = 0; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0; return h; }

// ---------- helpers ----------
function rel(p) {
  if (!p) return "";
  let s = String(p);
  for (const base of [state.cwd, "/private" + state.cwd]) if (base && s.startsWith(base + "/")) return s.slice(base.length + 1);
  if (state.home && s.startsWith(state.home + "/")) return "~" + s.slice(state.home.length);
  return s;
}
function firstLine(s) { return String(s || "").split("\n").find((l) => l.trim()) || ""; }
function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
function parseTs(s) { const t = Date.parse(s || ""); return isNaN(t) ? null : t; }
function duration(ms) {
  const s = Math.max(1, Math.round(ms / 1000));
  if (s < 60) return s + "s";
  const m = Math.floor(s / 60), r = s % 60;
  if (m < 60) return r ? `${m}m ${r}s` : `${m}m`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
function clock(ms) { const d = new Date(ms); return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }); }
// If the agent is still waiting a while after an answer was sent, the buttons work again.
function retryLater(id) { setTimeout(() => { if (sentAnswers.delete(id)) render(); }, 8000); }
function isOpen(key, dflt) { return toggled.has(key) ? toggled.get(key) : dflt; }
// The tool call the agent is waiting on: the last one, without a result, while the session needs input.
function isPending(it) {
  if (!state.needsInput || it.result != null) return false;
  for (let i = state.order.length - 1; i >= 0; i--) {
    const x = state.items.get(state.order[i]);
    if (x && x.kind === "tool") return x.id === it.id;
  }
  return false;
}

// ---------- syntax highlighting ----------
const fenceExt = {
  js: "js", javascript: "js", mjs: "js", jsx: "jsx", ts: "ts", typescript: "ts", tsx: "tsx", py: "py", python: "py",
  rs: "rs", rust: "rs", go: "go", golang: "go", json: "json", jsonc: "json", sh: "sh", bash: "sh", shell: "sh", zsh: "sh",
  console: "sh", shellscript: "sh", swift: "swift", yaml: "yaml", yml: "yaml", toml: "toml", sql: "sql", html: "html",
  css: "css", scss: "css", java: "java", c: "c", cpp: "cpp", "c++": "cpp", h: "h", rb: "rb", ruby: "rb", kotlin: "kt",
  kt: "kt", diff: "diff", patch: "diff", md: "md", markdown: "md", xml: "xml", php: "php", lua: "lua", dart: "dart",
  cs: "cs", csharp: "cs", scala: "scala", dockerfile: "dockerfile", ini: "ini",
};
function parserFor(langOrPath, isPath) {
  const name = isPath ? langOrPath : (fenceExt[(langOrPath || "").toLowerCase()] ? "x." + fenceExt[langOrPath.toLowerCase()] : "");
  if (!name) return null;
  const s = languageFor(name === "x.dockerfile" ? "Dockerfile" : name);
  if (!s || Array.isArray(s)) return null;
  const lang = s.language || s;
  return lang && lang.parser ? lang.parser : null;
}
function highlightInto(el, text, parser) {
  if (!parser || text.length > 200000) { el.textContent = text; return; }
  try {
    const tree = parser.parse(text);
    highlightCode(text, tree, highlight,
      (txt, cls) => { if (cls) { const s = $("span", cls); s.textContent = txt; el.append(s); } else el.append(document.createTextNode(txt)); },
      () => el.append(document.createTextNode("\n")));
  } catch (_) { el.textContent = text; }
}

// ---------- markdown ----------
const md = new Marked({ gfm: true, breaks: false }, {
  renderer: {
    html(tok) { return esc(tok.text ?? tok.raw ?? ""); },          // agent output is text, never markup
    image(tok) { return esc(tok.text || tok.href || ""); },          // no remote loads
  },
});
function copyButton(getText, label = "Copy") {
  const b = $("button", "copybtn", label);
  b.title = "Copy";
  b.addEventListener("click", (e) => { e.stopPropagation(); post({ type: "copy", text: getText() }); b.textContent = "Copied"; setTimeout(() => (b.textContent = label), 1200); });
  return b;
}
function codeBlock(text, lang) {
  const box = $("div", "codeblock");
  const head = $("div", "cbhead");
  head.append($("span", "lang", lang || "text"), copyButton(() => text));
  const pre = $("pre"), code = $("code");
  highlightInto(code, text, parserFor(lang, false));
  pre.append(code);
  box.append(head, pre);
  return box;
}
function markdownEl(text, cls = "md") {
  const el = $("div", cls);
  el.innerHTML = md.parse(text || "");
  for (const pre of [...el.querySelectorAll("pre")]) {
    const code = pre.querySelector("code");
    const lang = ((code && code.className) || "").replace(/^language-/, "").split(/\s/)[0];
    pre.replaceWith(codeBlock((code ? code.textContent : pre.textContent).replace(/\n$/, ""), lang));
  }
  for (const t of el.querySelectorAll("table")) { const w = $("div", "tablewrap"); t.replaceWith(w); w.append(t); }
  return el;
}

// ---------- tools ----------
const PROMINENT = new Set(["TodoWrite", "AskUserQuestion", "ExitPlanMode", "update_plan", "request_user_input"]);
function patchFiles(p) {
  const out = [];
  for (const m of String(p || "").matchAll(/^\*\*\* (Update|Add|Delete) File: (.+)$/gm)) out.push({ op: m[1], path: m[2].trim() });
  return out;
}
function toolInfo(it) {
  const n = it.tool || "", inp = it.input || {};
  const path = inp.file_path || inp.path || inp.notebook_path || "";
  let m;
  if ((m = /^mcp__(.+?)__(.+)$/.exec(n))) return { cat: "other", verb: m[1].replace(/[_-]+/g, " "), target: m[2].replace(/_/g, " ") + (it.detail ? " · " + it.detail : "") };
  switch (n) {
    case "Read": case "read_file": case "view_image": return { cat: "read", verb: "Read", target: rel(path || it.detail), path };
    case "Edit": case "MultiEdit": case "NotebookEdit": case "str_replace_based_edit_tool": return { cat: "edit", verb: "Edited", target: rel(path || it.detail), path };
    case "Write": case "write_file": return { cat: "edit", verb: "Wrote", target: rel(path || it.detail), path };
    case "apply_patch": {
      const fs = patchFiles(inp.patch);
      return { cat: "edit", verb: "Edited", target: fs.length ? fs.map((f) => rel(f.path)).join(", ") : it.detail, path: fs.length === 1 ? fs[0].path : "", files: Math.max(1, fs.length) };
    }
    case "Bash": case "exec_command": case "shell": case "local_shell": case "unified_exec": case "write_stdin":
      return { cat: "run", verb: "Ran", target: firstLine(inp.command || it.detail) };
    case "BashOutput": case "KillShell": case "KillBash": return { cat: "run", verb: n === "BashOutput" ? "Checked output" : "Stopped", target: inp.bash_id || inp.shell_id || it.detail };
    case "Grep": case "grep": case "rg": return { cat: "search", verb: "Searched", target: (inp.pattern || it.detail) + (inp.path ? "  in " + rel(inp.path) : "") };
    case "Glob": case "LS": case "list_dir": return { cat: "search", verb: n === "Glob" ? "Found files" : "Listed", target: inp.pattern || rel(inp.path) || it.detail };
    case "WebFetch": return { cat: "web", verb: "Fetched", target: inp.url || it.detail };
    case "WebSearch": case "web_search": return { cat: "web", verb: "Searched the web", target: inp.query || it.detail };
    case "Task": case "Agent": return { cat: "agent", verb: "Subagent", target: inp.description || firstLine(inp.prompt) || it.detail };
    case "Skill": return { cat: "other", verb: "Skill", target: inp.skill || inp.command || it.detail };
    case "TodoWrite": return { cat: "other", verb: "Updated todos", target: "" };
    default: return { cat: "other", verb: n || "Tool", target: rel(it.detail) };
  }
}
function groupSummary(items) {
  const c = { read: 0, edit: 0, run: 0, search: 0, web: 0, agent: 0, other: 0 };
  const edited = new Set();
  let thoughts = 0;
  for (const it of items) {
    if (it.kind === "thinking") { thoughts++; continue; }
    const i = toolInfo(it);
    if (i.cat === "edit") { (i.target || it.id).split(", ").forEach((f) => edited.add(f)); continue; }
    c[i.cat] += 1;
  }
  c.edit = edited.size;
  const parts = [];
  if (c.read) parts.push("Read " + plural(c.read, "file", "files"));
  if (c.search) parts.push("Searched " + plural(c.search, "time", "times"));
  if (c.edit) parts.push("Edited " + plural(c.edit, "file", "files"));
  if (c.run) parts.push("Ran " + plural(c.run, "command", "commands"));
  if (c.web) parts.push(plural(c.web, "web lookup", "web lookups"));
  if (c.agent) parts.push(plural(c.agent, "subagent", "subagents"));
  if (c.other) parts.push(plural(c.other, "tool call", "tool calls"));
  if (!parts.length && thoughts) parts.push("Thought");
  return parts.join(" · ");
}

function preEl(text, cls = "out", maxLines = 400) {
  const lines = String(text || "").replace(/\s+$/, "").split("\n");
  const pre = $("pre", cls);
  pre.textContent = lines.length > maxLines ? `… ${lines.length - maxLines} earlier lines\n` + lines.slice(-maxLines).join("\n") : lines.join("\n");
  return pre;
}

// Unified diff of a snippet; unchanged runs longer than 2×3 lines fold to "⋯ N unchanged lines".
function diffEl(ops, path) {
  const box = $("div", "diff");
  const parser = parserFor(path || "", true);
  const keep = new Array(ops.length).fill(false);
  ops.forEach((o, i) => { if (o.op !== " ") for (let j = Math.max(0, i - 3); j <= Math.min(ops.length - 1, i + 3); j++) keep[j] = true; });
  let skipped = 0;
  const flush = () => { if (skipped) { box.append($("div", "dl gap", `⋯ ${plural(skipped, "unchanged line", "unchanged lines")}`)); skipped = 0; } };
  const MAX = 600;
  let shown = 0;
  for (let i = 0; i < ops.length; i++) {
    if (!keep[i]) { skipped++; continue; }
    flush();
    if (shown++ >= MAX) { box.append($("div", "dl gap", `⋯ ${ops.length - i} more lines`)); break; }
    const o = ops[i];
    const row = $("div", "dl " + (o.op === "+" ? "add" : o.op === "-" ? "del" : "ctx"));
    const code = $("span", "code");
    highlightInto(code, o.text || " ", parser);
    row.append($("span", "sign", o.op === " " ? " " : o.op), code);
    box.append(row);
  }
  flush();
  return box;
}
function editOps(it) {
  const inp = it.input || {};
  switch (it.tool) {
    case "Edit": return lineOps(inp.old_string || "", inp.new_string || "");
    case "MultiEdit": {
      const out = [];
      (inp.edits || []).forEach((e, i) => { if (i) out.push({ op: "~" }); out.push(...lineOps(e.old_string || "", e.new_string || "")); });
      return out;
    }
    case "Write": case "write_file": return lineOps("", inp.content || "");
    default: return null;
  }
}
function patchEl(patch) {
  const box = $("div", "diff");
  for (const line of String(patch || "").split("\n")) {
    if (/^\*\*\* (Begin|End) Patch/.test(line)) continue;
    let cls = "ctx", sign = " ", text = line;
    if (line.startsWith("*** ")) { box.append($("div", "dl file", line.slice(4))); continue; }
    if (line.startsWith("@@")) { box.append($("div", "dl gap", line)); continue; }
    if (line.startsWith("+")) { cls = "add"; sign = "+"; text = line.slice(1); }
    else if (line.startsWith("-")) { cls = "del"; sign = "-"; text = line.slice(1); }
    else if (line.startsWith(" ")) text = line.slice(1);
    const row = $("div", "dl " + cls);
    row.append($("span", "sign", sign), $("span", "code", text || " "));
    box.append(row);
  }
  return box;
}
function stat(ops) {
  let a = 0, d = 0;
  for (const o of ops) { if (o.op === "+") a++; else if (o.op === "-") d++; }
  const s = $("span", "stat");
  if (a) s.append($("span", "plus", "+" + a));
  if (d) s.append($("span", "minus", "−" + d));
  return s;
}

function toolEl(it, live) {
  const info = toolInfo(it);
  const running = it.result == null && live;
  const el = $("div", "tool" + (it.failed ? " failed" : "") + (running ? " running" : ""));
  const line = $("div", "tline");
  const dot = $("span", "dot");
  const verb = $("span", "verb", it.failed ? "Failed: " + info.verb.toLowerCase() : info.verb);
  const target = $("span", "target", info.target);
  if (info.path && info.cat !== "run") { target.classList.add("path"); target.dataset.open = info.path; target.title = "Open " + rel(info.path); }
  line.append(dot, verb, target);

  // Details: diff for edits, command + output for shells, markdown for subagents, text for the rest.
  let detail = null, dflt = false;
  if (info.cat === "edit") {
    const ops = it.tool === "apply_patch" ? null : editOps(it);
    if (ops) {
      const changed = ops.filter((o) => o.op === "+" || o.op === "-").length;
      line.append(stat(ops));
      detail = diffEl(ops.filter((o) => o.op !== "~"), info.path);
      dflt = changed <= 60;
    } else if (it.input && it.input.patch) {
      detail = patchEl(it.input.patch);
      dflt = it.input.patch.split("\n").length <= 80;
    }
    if (it.failed && it.result) { const box = $("div"); if (detail) box.append(detail); box.append(preEl(it.result, "out err")); detail = box; dflt = true; }
  } else if (info.cat === "run") {
    detail = $("div");
    const cmd = (it.input && (it.input.command || it.input.cmd)) || it.detail || "";
    const head = $("pre", "cmd");
    head.textContent = "$ " + cmd;
    detail.append(head);
    if (it.result) detail.append(preEl(it.result, "out" + (it.failed ? " err" : "")));
    dflt = !!it.failed;
  } else if (info.cat === "agent") {
    if (it.result) { detail = markdownEl(it.result, "md sub"); }
  } else if (it.result) {
    detail = preEl(it.result, "out" + (it.failed ? " err" : ""), info.cat === "read" ? 120 : 300);
    dflt = !!it.failed;
  } else if (it.input && Object.keys(it.input).length && info.cat === "other") {
    detail = preEl(JSON.stringify(it.input, null, 2), "out");
  }
  el.append(line);
  if (isPending(it)) {
    const bar = $("div", "permit");
    bar.append($("span", "ptext", "Waiting for your permission"));
    const allow = $("button", "pbtn primary", "Allow");
    allow.dataset.permit = "allow"; allow.dataset.id = it.id;
    const deny = $("button", "pbtn", "Deny");
    deny.dataset.permit = "deny"; deny.dataset.id = it.id;
    if (sentAnswers.has(it.id)) { allow.disabled = deny.disabled = true; }
    bar.append(allow, deny);
    el.append(bar);
    dflt = true;
  }
  if (detail) {
    const key = "t:" + it.id;
    const chev = $("span", "chev", "›");
    line.append(chev);
    line.classList.add("toggle");
    line.dataset.toggle = key;
    const box = $("div", "tdetail");
    box.append(detail);
    el.append(box);
    if (isOpen(key, dflt)) el.classList.add("open");
  }
  return el;
}

function thinkingEl(it) {
  const el = $("div", "tool thinking");
  const key = "k:" + it.id;
  const line = $("div", "tline toggle");
  line.dataset.toggle = key;
  line.append($("span", "dot"), $("span", "verb", "Thought"), $("span", "target", firstLine(it.text)), $("span", "chev", "›"));
  const box = $("div", "tdetail");
  box.append(markdownEl(it.text, "md thought"));
  el.append(line, box);
  if (isOpen(key, false)) el.classList.add("open");
  return el;
}

function groupEl(items, live, done) {
  const tools = items.filter((i) => i.kind === "tool");
  if (items.length === 1) return items[0].kind === "thinking" ? thinkingEl(items[0]) : toolEl(items[0], live);
  const key = "g:" + items[0].id;
  const el = $("div", "group" + (live ? " live" : ""));
  const head = $("div", "ghead toggle");
  head.dataset.toggle = key;
  const failed = tools.filter((t) => t.failed).length;
  head.append($("span", "chev", "›"), $("span", "gsum", groupSummary(items)));
  if (failed) head.append($("span", "gfail", plural(failed, "failed", "failed")));
  if (live) head.append($("span", "spin"));
  const body = $("div", "gbody");
  for (const it of items) body.append(it.kind === "thinking" ? thinkingEl(it) : toolEl(it, live));
  el.append(head, body);
  if (isOpen(key, live || !done)) el.classList.add("open");
  return el;
}

// ---------- prominent cards ----------
function checklist(entries) {
  const ul = $("ul", "todos");
  for (const e of entries) {
    const st = e.status || "pending";
    const li = $("li", "todo " + st);
    li.append($("span", "box", st === "completed" ? "✓" : st === "in_progress" ? "◐" : ""), $("span", "ttext", st === "in_progress" && e.activeForm ? e.activeForm : (e.content || e.step || "")));
    ul.append(li);
  }
  return ul;
}
function cardEl(it) {
  const inp = it.input || {};
  const card = $("div", "card");
  const head = $("div", "chead");
  switch (it.tool) {
    case "TodoWrite": case "update_plan": {
      const entries = it.tool === "TodoWrite" ? (inp.todos || []) : (inp.plan || []);
      const done = entries.filter((e) => e.status === "completed").length;
      head.append($("span", "ctitle", it.tool === "TodoWrite" ? "Todos" : "Plan"), $("span", "cmeta", `${done}/${entries.length} done`));
      card.append(head, checklist(entries));
      if (inp.explanation) card.append(markdownEl(inp.explanation, "md small"));
      break;
    }
    case "AskUserQuestion": case "request_user_input": {
      head.append($("span", "ctitle", "Question"));
      card.append(head);
      const qs = inp.questions || [];
      // One single-choice question can be answered here (arrow keys + return to the terminal); others there.
      const answerable = isPending(it) && qs.length === 1 && !qs[0].multiSelect && it.tool === "AskUserQuestion";
      for (const q of qs) {
        const box = $("div", "question");
        if (q.header) box.append($("div", "qhead", q.header));
        box.append($("div", "qtext", q.question || ""));
        const ol = $("ol", "options" + (answerable ? " choose" : ""));
        (q.options || []).forEach((o, i) => {
          const li = $("li");
          li.append($("span", "olabel", o.label || ""));
          if (o.description) li.append($("span", "odesc", o.description));
          if (answerable) {
            li.dataset.choose = String(i); li.dataset.id = it.id;
            if (sentAnswers.has(it.id)) li.classList.add("disabled");
          }
          ol.append(li);
        });
        box.append(ol);
        card.append(box);
      }
      if (answerable) { card.classList.add("pending"); card.append($("div", "hint", sentAnswers.has(it.id) ? "Sent…" : "Pick an answer, or answer in the terminal (other text, several questions)")); }
      else if (it.result) {
        const answers = [...it.result.matchAll(/"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"/g)].map((m) => m[2]);
        card.append($("div", "answer", "→ " + (answers.length ? answers.join(", ") : firstLine(it.result))));
      }
      else if (!it.result) card.append($("div", "hint", "Answer in the terminal"));
      break;
    }
    case "ExitPlanMode": {
      head.append($("span", "ctitle", "Plan"), it.result ? $("span", "cmeta", it.failed ? "Not approved" : "Approved") : $("span", "cmeta", "Waiting for approval"));
      card.append(head, markdownEl(inp.plan || "", "md"));
      break;
    }
    default:
      card.append(toolEl(it, false));
  }
  return card;
}

// ---------- rows ----------
function userEl(it) {
  const row = $("div", "user");
  const bubble = $("div", "bubble");
  const text = it.text || "";
  const long = text.split("\n").length > 14 || text.length > 1400;
  const key = "u:" + it.id;
  bubble.textContent = text;
  row.append(bubble);
  if (long) {
    bubble.classList.add("clamp");
    const more = $("button", "more", "Show more");
    more.dataset.toggle = key;
    row.append(more);
    if (isOpen(key, false)) row.classList.add("open");
  }
  return row;
}
function assistantEl(it) {
  const el = $("div", "assistant");
  el.append(markdownEl(it.text));
  const actions = $("div", "hoverbar");
  actions.append(copyButton(() => it.text));
  el.append(actions);
  return el;
}
function noteEl(it) { return $("div", "note", it.text); }

function footerEl(turn) {
  const start = parseTs(turn.user && turn.user.ts);
  const last = [...turn.items].reverse().find((i) => i.kind !== "note" && parseTs(i.ts));
  const end = last ? parseTs(last.ts) : null;
  const answer = [...turn.items].reverse().find((i) => i.kind === "assistant");
  const f = $("div", "footer");
  const bits = [];
  if (start && end && end >= start) bits.push(`${state.agent} worked for ${duration(end - start)}`);
  if (end) bits.push(clock(end));
  f.append($("span", "fmeta", bits.join(" · ")));
  if (answer) f.append(copyButton(() => answer.text));
  return f;
}

// ---------- turns ----------
function buildTurns() {
  const turns = [];
  let cur = null;
  for (const id of state.order) {
    const it = state.items.get(id);
    if (!it) continue;
    if (it.kind === "user") { cur = { key: it.id, user: it, items: [] }; turns.push(cur); continue; }
    if (!cur) { cur = { key: "start:" + it.id, user: null, items: [] }; turns.push(cur); }
    cur.items.push(it);
  }
  return turns;
}
function blocksOf(items) {
  const out = [];
  let g = null;
  for (const it of items) {
    const groupable = it.kind === "thinking" || (it.kind === "tool" && !PROMINENT.has(it.tool));
    if (groupable) { if (!g) { g = { type: "group", items: [] }; out.push(g); } g.items.push(it); continue; }
    g = null;
    out.push({ type: it.kind, item: it });
  }
  return out;
}
function renderTurn(turn, isLast) {
  const el = $("div", "turn");
  el.dataset.key = turn.key;
  if (turn.user) el.append(userEl(turn.user));
  const live = isLast && state.working;
  const bs = blocksOf(turn.items);
  bs.forEach((b, i) => {
    const lastBlock = i === bs.length - 1;
    if (b.type === "group") el.append(groupEl(b.items, live && lastBlock, !live));
    else if (b.type === "assistant") el.append(assistantEl(b.item));
    else if (b.type === "tool") el.append(cardEl(b.item));
    else if (b.type === "note") el.append(noteEl(b.item));
  });
  if (!live && !(isLast && state.needsInput) && turn.user && turn.items.length) el.append(footerEl(turn));
  return el;
}
function turnSig(turn, isLast) {
  let s = turn.key + "|" + (isLast && state.working ? "w" : "d") + (isLast && state.needsInput ? "n" : "") + "|" + state.agent + "|" + sentAnswers.size;
  for (const it of turn.items) s += "," + it.id + ":" + it.sig;
  return s + (turn.user ? "|" + turn.user.sig : "");
}

function nearBottom() { return list.scrollHeight - list.scrollTop - list.clientHeight < 48; }
function scrollToBottom(smooth) { list.scrollTo({ top: list.scrollHeight, behavior: smooth ? "smooth" : "auto" }); }

function render() {
  const stick = nearBottom();
  const turns = buildTurns();
  const els = [];
  const keep = new Set();
  turns.forEach((t, i) => {
    const isLast = i === turns.length - 1;
    const sig = turnSig(t, isLast);
    let c = turnCache.get(t.key);
    if (!c || c.sig !== sig) { c = { sig, el: renderTurn(t, isLast) }; turnCache.set(t.key, c); }
    keep.add(t.key);
    els.push(c.el);
  });
  for (const k of [...turnCache.keys()]) if (!keep.has(k)) turnCache.delete(k);
  els.push(workingEl);
  const inner = list.firstElementChild;
  let i = 0;
  for (const el of els) { if (inner.children[i] !== el) inner.insertBefore(el, inner.children[i] || null); i++; }
  while (inner.children.length > i) inner.lastElementChild.remove();
  updateWorking();
  if (stick) scrollToBottom(false);
  updateJump();
}

function updateWorking() {
  workingEl.style.display = state.working ? "" : "none";
  if (!state.working) return;
  const turns = buildTurns();
  const last = turns[turns.length - 1];
  const start = last && last.user ? parseTs(last.user.ts) : null;
  workingEl.querySelector(".wtext").textContent = start ? `Working… ${duration(Date.now() - start)}` : "Working…";
}
function updateJump() { jump.classList.toggle("show", !nearBottom()); }

// ---------- API ----------
function chatUpdate(p) {
  if (p.reset) { state.items.clear(); turnCache.clear(); toggled.clear(); }
  for (const it of p.items || []) { it.sig = hashStr(JSON.stringify(it)); state.items.set(it.id, it); }
  if (p.order) {
    state.order = p.order;
    const ids = new Set(p.order);
    for (const k of [...state.items.keys()]) if (!ids.has(k)) state.items.delete(k);
  }
  if ("working" in p) state.working = !!p.working;
  if ("needsInput" in p) state.needsInput = !!p.needsInput;
  if (p.cwd != null) state.cwd = p.cwd;
  if (p.home != null) state.home = p.home;
  if (p.agent) state.agent = p.agent;
  render();
}
function setTheme(th) {
  const r = document.documentElement.style;
  for (const [k, v] of Object.entries(th.vars || {})) r.setProperty("--" + k, v);
  document.documentElement.classList.toggle("dark", !!th.dark);
}

function init() {
  list = document.getElementById("chat");
  jump = document.getElementById("jump");
  workingEl = $("div", "working");
  workingEl.append($("span", "spin"), $("span", "wtext", "Working…"));
  workingEl.style.display = "none";
  list.addEventListener("scroll", updateJump, { passive: true });
  jump.addEventListener("click", () => scrollToBottom(true));
  setInterval(() => { if (state.working) updateWorking(); }, 1000);
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a");
    if (a) { e.preventDefault(); const href = a.getAttribute("href"); if (href) post({ type: "link", href }); return; }
    const ch = e.target.closest("[data-choose]");
    if (ch && !ch.classList.contains("disabled") && !sentAnswers.has(ch.dataset.id)) {
      sentAnswers.add(ch.dataset.id); retryLater(ch.dataset.id);
      post({ type: "choose", id: ch.dataset.id, index: Number(ch.dataset.choose) });
      render();
      return;
    }
    const pm = e.target.closest("[data-permit]");
    if (pm && !pm.disabled && !sentAnswers.has(pm.dataset.id)) {
      sentAnswers.add(pm.dataset.id); retryLater(pm.dataset.id);
      post({ type: "permit", id: pm.dataset.id, allow: pm.dataset.permit === "allow" });
      render();
      return;
    }
    const op = e.target.closest("[data-open]");
    if (op) { e.stopPropagation(); post({ type: "open", path: op.dataset.open }); return; }
    const t = e.target.closest("[data-toggle]");
    if (t) {
      if (window.getSelection && String(window.getSelection()).length) return;   // selecting text, not toggling
      const host = t.classList.contains("more") ? t.parentElement : t.parentElement;
      const open = !host.classList.contains("open");
      host.classList.toggle("open", open);
      toggled.set(t.dataset.toggle, open);
    }
  });
  window.addEventListener("resize", updateJump);
}

window.octomux = { chatUpdate, setTheme, scrollToBottom: () => scrollToBottom(false) };
init();
post({ type: "ready" });
