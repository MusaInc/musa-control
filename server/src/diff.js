// Line diff (Myers O(ND)) for comparing stored revisions. Produces unified
// diff text so the app renders revision diffs and git diffs the same way.

function myers(a, b) {
  const n = a.length, m = b.length, max = n + m;
  if (max === 0) return [];
  // Guard pathological inputs: fall back to a whole replace.
  if (n * m > 4e8 && Math.abs(n - m) > 20000) return [...a.map((l) => ["-", l]), ...b.map((l) => ["+", l])];
  const v = new Map([[1, 0]]);
  const trace = [];
  outer: for (let d = 0; d <= max; d++) {
    trace.push(new Map(v));
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && (v.get(k - 1) ?? -1) < (v.get(k + 1) ?? -1)) ? v.get(k + 1) ?? 0 : (v.get(k - 1) ?? 0) + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) { x++; y++; }
      v.set(k, x);
      if (x >= n && y >= m) break outer;
    }
    if (d > 6000) return [...a.map((l) => ["-", l]), ...b.map((l) => ["+", l])];
  }
  const ops = [];
  let x = n, y = m;
  for (let d = trace.length - 1; d >= 0; d--) {
    const vd = trace[d], k = x - y;
    const prevK = k === -d || (k !== d && (vd.get(k - 1) ?? -1) < (vd.get(k + 1) ?? -1)) ? k + 1 : k - 1;
    const prevX = vd.get(prevK) ?? 0, prevY = prevX - prevK;
    while (x > prevX && y > prevY) { ops.push([" ", a[x - 1]]); x--; y--; }
    if (d > 0) { if (x === prevX) ops.push(["+", b[y - 1]]); else ops.push(["-", a[x - 1]]); }
    x = prevX; y = prevY;
  }
  return ops.reverse();
}

const split = (t) => (t === "" ? [] : t.replace(/\n$/, "").split("\n"));

export function lineDiffCounts(oldText, newText) {
  let added = 0, removed = 0;
  for (const [op] of myers(split(oldText), split(newText))) { if (op === "+") added++; else if (op === "-") removed++; }
  return { added, removed };
}

export function unifiedDiff(oldText, newText, { path = "file", context = 3 } = {}) {
  const ops = myers(split(oldText ?? ""), split(newText ?? ""));
  const out = [`--- a/${path}`, `+++ b/${path}`];
  let i = 0, oldLine = 1, newLine = 1;
  const idx = ops.map((o) => { const r = { op: o[0], text: o[1], o: oldLine, n: newLine }; if (o[0] !== "+") oldLine++; if (o[0] !== "-") newLine++; return r; });
  while (i < idx.length) {
    if (idx[i].op === " ") { i++; continue; }
    let start = Math.max(0, i - context), end = i;
    // extend while changes are within 2*context of each other
    while (end < idx.length) {
      let j = end; while (j < idx.length && idx[j].op !== " ") j++;
      let k = j; while (k < idx.length && idx[k].op === " " && k - j < context * 2) k++;
      if (k < idx.length && idx[k].op !== " ") { end = k; continue; }
      end = Math.min(idx.length, j + context); break;
    }
    const hunk = idx.slice(start, end);
    const oStart = hunk.find((h) => h.op !== "+")?.o ?? hunk[0].o, nStart = hunk.find((h) => h.op !== "-")?.n ?? hunk[0].n;
    const oLen = hunk.filter((h) => h.op !== "+").length, nLen = hunk.filter((h) => h.op !== "-").length;
    out.push(`@@ -${oLen ? oStart : oStart - 1},${oLen} +${nLen ? nStart : nStart - 1},${nLen} @@`);
    for (const h of hunk) out.push(h.op + h.text);
    i = end;
  }
  return out.length > 2 ? out.join("\n") + "\n" : "";
}
