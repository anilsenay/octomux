// Diffs by line first, like git, then by character only inside the lines that changed.
//
// The merge view's own diff works on characters and gives up early (scanLimit 500): a file with a few dozen
// added lines came back as one big deleted-and-added block covering lines that never changed.
import { Change, diff } from "@codemirror/merge";

// Line starts, with the text's end as the last entry; each line keeps its "\n".
function starts(s) {
  const out = [0];
  for (let i = s.indexOf("\n"); i >= 0; i = s.indexOf("\n", i + 1)) out.push(i + 1);
  if (out[out.length - 1] !== s.length) out.push(s.length);
  return out;
}

// One character per distinct line, so the character diff below compares whole lines.
// Skips the surrogate range; past ~63k distinct lines it returns null (the caller falls back).
function encode(s, at, ids) {
  let out = "";
  for (let i = 0; i + 1 < at.length; i++) {
    const line = s.slice(at[i], at[i + 1]);
    let id = ids.get(line);
    if (id === undefined) {
      let code = 0x100 + ids.size;
      if (code >= 0xd800) code += 0x800;
      if (code > 0xffff) return null;
      id = String.fromCharCode(code);
      ids.set(line, id);
    }
    out += id;
  }
  return out;
}

const charConfig = { scanLimit: 1e9, timeout: 500 };

export function lineDiff(a, b) {
  const atA = starts(a), atB = starts(b);
  const ids = new Map();
  const ea = encode(a, atA, ids), eb = ea === null ? null : encode(b, atB, ids);
  if (ea === null || eb === null) return diff(a, b, charConfig);
  const out = [];
  for (const c of diff(ea, eb, { scanLimit: 1e9, timeout: 2000 })) {
    const fromA = atA[c.fromA], toA = atA[c.toA], fromB = atB[c.fromB], toB = atB[c.toB];
    // Inside a block that changed on both sides, mark the characters (word highlights).
    if (fromA < toA && fromB < toB) {
      for (const d of diff(a.slice(fromA, toA), b.slice(fromB, toB), charConfig))
        out.push(new Change(d.fromA + fromA, d.toA + fromA, d.fromB + fromB, d.toB + fromB));
    } else {
      out.push(new Change(fromA, toA, fromB, toB));
    }
  }
  return out;
}

export const diffConfig = { override: lineDiff };
