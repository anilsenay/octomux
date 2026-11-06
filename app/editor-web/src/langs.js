// Languages and the highlight style shared by the editor and the chat view.
import { HighlightStyle, StreamLanguage } from "@codemirror/language";
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

const legacy = (m) => StreamLanguage.define(m);


// ---------- languages ----------
export function languageFor(path) {
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
export const highlight = HighlightStyle.define([
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
