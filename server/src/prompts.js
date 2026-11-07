// Detects an interactive choice prompt (approval, trust, edit confirmation)
// on a Claude Code or Codex TUI screen captured from tmux, and turns a chosen
// option into keystrokes. Answering moves the TUI's own cursor and presses
// Enter, exactly as a person at the terminal would: nothing is bypassed, and
// the agent's permission system stays in charge.
import crypto from "node:crypto";

const FOOTER = /(enter to confirm|esc to cancel|press enter to confirm|enter to select|↑\/↓ to (move|navigate)|esc to (go back|exit|cancel))/i;
const CURSORS = "❯›>";
const OPTION = /^(\s*)(?:([❯›>])\s*)?(?:(\d+)[.)]\s+)?(\S.*?)\s*$/;
const SEPARATOR = /^[\s─━╌┄═\-_]+$/;

export function parsePrompt(screen) {
  if (!screen) return null;
  const lines = screen.replace(/\r/g, "").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  const tail = lines.slice(-70);
  let footer = -1;
  for (let i = tail.length - 1; i >= Math.max(0, tail.length - 8); i--) if (FOOTER.test(tail[i])) { footer = i; break; }
  if (footer < 0) return null;

  // Options block directly above the footer.
  let i = footer - 1;
  while (i >= 0 && !tail[i].trim()) i--;
  const block = [];
  for (; i >= 0; i--) {
    const l = tail[i];
    if (!l.trim()) break;
    const m = l.match(OPTION);
    if (!m || SEPARATOR.test(l)) break;
    block.unshift({ raw: l, indent: m[1].length, cursor: Boolean(m[2]), number: m[3] ? Number(m[3]) : null, text: m[4] });
  }
  if (block.length < 2) return null;
  // Text column of each option (where the label starts), to tell options from wrapped prose.
  const col = (o) => o.raw.indexOf(o.text);
  const cursorAt = block.findIndex((o) => o.cursor);
  if (cursorAt < 0) return null;
  const refCol = col(block[cursorAt]);
  const numbered = block.some((o) => o.number !== null);
  const isOption = (o) => (numbered ? o.number !== null : Math.abs(col(o) - refCol) <= 1);
  // Leading lines that aren't options (the question itself, when no blank
  // line separates it from the list) belong to the context.
  const firstOpt = block.findIndex(isOption);
  const lead = block.splice(0, Math.max(firstOpt, 0));
  i += lead.length;
  const options = [];
  for (const o of block) {
    if (isOption(o)) options.push(o);
    else if (options.length) options[options.length - 1].text += " " + o.text.trim(); // wrapped label
  }
  if (options.length < 2 || options.length > 9) return null;
  const selected = options.findIndex((o) => o.cursor);

  // Question + context: lines above the options, up to a separator.
  const context = [];
  for (let j = i; j >= 0 && context.length < 18; j--) {
    const l = tail[j];
    if (SEPARATOR.test(l) && l.trim().length > 10 && /[─━]/.test(l)) break;
    if (l.trim() && !SEPARATOR.test(l)) context.unshift(l.trim());
  }
  const question = [...context].reverse().find((l) => /\?\s*$/.test(l)) || context[context.length - 1] || "Choose an option";
  const text = context.join("\n");
  const kind = /trust|safety check|folder access/i.test(text) ? "trust"
    : /\$ |bash command|run the following command/i.test(text) ? "command"
    : /edit|write|create .*file|make this change/i.test(text) ? "edit"
    : /network|fetch|web/i.test(text) ? "network" : "choice";
  const command = (context.find((l) => l.startsWith("$ ")) || "").slice(2) || null;
  const items = options.map((o, idx) => ({
    index: idx, number: o.number, label: o.text.replace(/\s+\((y|p|a|n|esc)\)\s*$/i, "").trim(),
    tone: /^no\b|deny|reject|exit|cancel|back to/i.test(o.text) ? "deny" : /^yes\b|allow|trust|proceed|approve/i.test(o.text) ? "allow" : "neutral",
  }));
  const signature = crypto.createHash("sha1").update(question + "\n" + text + "\n" + items.map((x) => x.label).join("|")).digest("hex").slice(0, 16);
  return { kind, question, context: text, command, options: items, selected, signature };
}

// Keystrokes that select option `index` from the currently highlighted one.
export function keysFor(prompt, index) {
  if (!prompt || index < 0 || index >= prompt.options.length) throw Object.assign(new Error("No such option"), { status: 400 });
  const delta = index - prompt.selected;
  const keys = [];
  for (let k = 0; k < Math.abs(delta); k++) keys.push(delta > 0 ? "Down" : "Up");
  keys.push("Enter");
  return keys;
}
