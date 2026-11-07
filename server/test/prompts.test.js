import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parsePrompt, keysFor } from "../src/prompts.js";
const fx = (n) => fs.readFileSync(new URL(`./fixtures/${n}`, import.meta.url), "utf8");

test("Claude Code bash approval (real capture)", () => {
  const p = parsePrompt(fx("claude-bash-prompt.txt"));
  assert.equal(p.kind, "command");
  assert.equal(p.question, "Do you want to proceed?");
  assert.equal(p.options.length, 4);
  assert.equal(p.options[0].label, "Yes");
  assert.equal(p.options[3].tone, "deny");
  assert.equal(p.selected, 0);
  assert.match(p.context, /touch probe.txt/);
  assert.deepEqual(keysFor(p, 0), ["Enter"]);
  assert.deepEqual(keysFor(p, 3), ["Down", "Down", "Down", "Enter"]);
});

test("Claude Code folder trust (unnumbered options)", () => {
  const p = parsePrompt(fx("claude-trust-prompt.txt"));
  assert.equal(p.kind, "trust");
  assert.deepEqual(p.options.map((o) => o.label), ["No, exit", "Yes, I trust this folder"]);
  assert.deepEqual(keysFor(p, 1), ["Down", "Enter"]);
});

test("Codex command approval (real capture)", () => {
  const p = parsePrompt(fx("codex-command-prompt.txt"));
  assert.equal(p.kind, "command");
  assert.equal(p.question, "Reason: Allow creating probe2.txt in the current directory?");
  assert.equal(p.command, "touch probe2.txt");
  assert.equal(p.options[0].label, "Yes, proceed");
  assert.equal(p.options[2].label, "No, and tell Codex what to do differently");
  assert.equal(p.options[2].tone, "deny");
});

test("idle screens are not prompts", () => {
  assert.equal(parsePrompt(fx("codex-idle.txt")), null);
  assert.equal(parsePrompt(fx("claude-idle.txt")), null);
  assert.equal(parsePrompt(""), null);
});

test("Codex prompt in a narrow pane: folded-output hint is never the question", () => {
  const p = parsePrompt(fx("codex-narrow-prompt.txt"));
  assert.ok(p);
  assert.doesNotMatch(p.question, /ctrl \+ a/);
  assert.match(p.question, /^Reason: Allow configuring a dedicated VoIP key/);
  assert.equal(p.options.length, 2);
  assert.equal(p.options[0].label, "Yes, proceed");
  assert.equal(p.options[1].tone, "deny");
});
