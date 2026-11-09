#!/usr/bin/env python3
"""Generates the Command Deck / Studio demo sessions in
MusaControl/Resources/Fixtures. Every event uses the gateway's real event
shapes (see server/src/transcripts.js); timestamps are relative to the fixture
anchor, which FixtureTransport rebases to "now" at run time.

  python3 ios/tools/make_deck_fixtures.py
"""
import json, os

A = 1794085331848  # fixture anchor (FixtureTransport.anchor)
OUT = os.path.join(os.path.dirname(__file__), "..", "MusaControl", "Resources", "Fixtures")
NEVER = "/home/dev/workspace/projects/NeverStop"
RESO = "/home/dev/workspace/projects/Reso"

_id = [20000]


def ev(sec_ago, kind, session, project, title, detail, notify=0):
    _id[0] += 1
    d = dict(detail)
    d.setdefault("agent", session.split(":")[0])
    return {"id": _id[0], "ts": A - int(sec_ago * 1000), "kind": kind, "project": project, "session": session,
            "title": title, "detail": d, "notify": notify}


def diff(old_start, old_lines, new_lines, ctx_before=(), ctx_after=()):
    """A one-hunk unified diff: context, removed, added, context."""
    o = len(ctx_before) + len(old_lines) + len(ctx_after)
    n = len(ctx_before) + len(new_lines) + len(ctx_after)
    out = [f"@@ -{old_start},{o} +{old_start},{n} @@"]
    out += [" " + l for l in ctx_before] + ["-" + l for l in old_lines] + ["+" + l for l in new_lines] + [" " + l for l in ctx_after]
    return "\n".join(out) + "\n"


def new_file(lines):
    return f"@@ -0,0 +1,{len(lines)} @@\n" + "\n".join("+" + l for l in lines) + "\n"


# ---------------------------------------------------------------- files

PAUSE_MENU = """extends CanvasLayer
## Pause menu: Esc toggles it; the tree pauses underneath.

signal resumed
signal quit_requested

@onready var panel: Control = $Panel
@onready var resume_button: Button = $Panel/VBox/Resume

func _ready() -> void:
\tprocess_mode = Node.PROCESS_MODE_ALWAYS
\tpanel.visible = false

func toggle() -> void:
\tvar paused := not get_tree().paused
\tget_tree().paused = paused
\tpanel.visible = paused
\tif paused:
\t\tresume_button.grab_focus()
\telse:
\t\tresumed.emit()

func _on_resume_pressed() -> void:
\ttoggle()

func _on_settings_pressed() -> void:
\t$Settings.popup_centered()

func _on_quit_pressed() -> void:
\tget_tree().paused = false
\tquit_requested.emit()
"""

PLAYER = """extends CharacterBody3D

@export var speed := 7.5
@export var pause_menu: CanvasLayer

func _unhandled_input(event: InputEvent) -> void:
\tif event.is_action_pressed("ui_cancel"):
\t\tpause_menu.toggle()
\t\tget_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
\tvar dir := Input.get_vector("left", "right", "forward", "back")
\tvelocity.x = dir.x * speed
\tvelocity.z = dir.y * speed
\tmove_and_slide()
"""

SPAWNER = """extends Node3D
## Spawns waves; the gap between waves shrinks as the run goes on.

@export var base_gap := 6.0
@export var min_gap := 1.8
@export var ramp := 0.92

var wave := 0

func next_gap() -> float:
\treturn maxf(min_gap, base_gap * pow(ramp, wave))

func _on_timer_timeout() -> void:
\twave += 1
\tspawn_wave(wave)
\t$Timer.start(next_gap())
"""

FALLBACK = """import { useEffect } from "react";
import { announce } from "../a11y/announce";
import { Step } from "./Step";

export function Fallback({ step, total, onNext }: Props) {
  useEffect(() => {
    announce(`Step ${step} of ${total}`);
  }, [step, total]);
  return (
    <Step title="Set up your account" step={step} total={total}>
      <p>VoiceOver users get the same steps in a simpler layout.</p>
      <button autoFocus onClick={onNext}>Continue</button>
    </Step>
  );
}
"""

files = {
    "file-pause_menu.gd.json": ("src/ui/pause_menu.gd", PAUSE_MENU),
    "file-player.gd.json": ("src/player/player.gd", PLAYER),
    "file-spawner.gd.json": ("src/enemies/spawner.gd", SPAWNER),
    "file-Fallback.tsx.json": ("src/onboarding/Fallback.tsx", FALLBACK),
}
for name, (rel, text) in files.items():
    with open(os.path.join(OUT, name), "w") as f:
        json.dump({"path": rel, "size": len(text), "mtime": A, "mime": "text/plain", "binary": False, "sha": "sample", "text": text}, f)

# ---------------------------------------------------------------- codex:sample-2 (editing + typing)

S2, P2 = "codex:sample-2", "neverstop"
pm = PAUSE_MENU.rstrip("\n").split("\n")
s2 = [
    ev(300, "agent.prompt", S2, P2, "Sample task: add a pause menu with resume, settings and quit",
       {"text": "Sample task: add a pause menu with resume, settings and quit"}),
    ev(290, "agent.plan", S2, P2, "Updated plan", {"items": [
        {"text": "Find where input is handled", "status": "completed"},
        {"text": "Create pause_menu.gd", "status": "in_progress"},
        {"text": "Wire Esc to toggle the menu", "status": "pending"},
        {"text": "Run the scene tests", "status": "pending"}]}),
    ev(270, "agent.command", S2, P2, "$ rg -n \"ui_cancel\" src",
       {"command": "rg -n \"ui_cancel\" src", "exitCode": 0, "ok": True, "cwd": NEVER,
        "output": "src/player/player.gd:7:\tif event.is_action_pressed(\"ui_cancel\"):\n"}),
    ev(250, "agent.edit", S2, P2, "Created pause_menu.gd",
       {"path": f"{NEVER}/src/ui/pause_menu.gd", "change": "add", "diff": new_file(pm[:20]),
        "follow": {"view": "diff", "path": f"{NEVER}/src/ui/pause_menu.gd"}}),
    ev(200, "agent.message", S2, P2, "The menu scene is in place; next I'll hook Esc in the player and add the button handlers.",
       {"text": "The menu scene is in place; next I'll hook **Esc** in the player and add the button handlers.", "phase": "commentary"}),
    ev(150, "agent.edit", S2, P2, "Edited player.gd",
       {"path": f"{NEVER}/src/player/player.gd", "change": "update",
        "diff": diff(5, ["\tif event.is_action_pressed(\"ui_cancel\"):", "\t\tget_tree().quit()"],
                     ["\tif event.is_action_pressed(\"ui_cancel\"):", "\t\tpause_menu.toggle()", "\t\tget_viewport().set_input_as_handled()"],
                     ctx_before=["func _unhandled_input(event: InputEvent) -> void:"]),
        "follow": {"view": "diff", "path": f"{NEVER}/src/player/player.gd"}}),
    ev(120, "agent.plan", S2, P2, "Updated plan", {"items": [
        {"text": "Find where input is handled", "status": "completed"},
        {"text": "Create pause_menu.gd", "status": "completed"},
        {"text": "Wire Esc to toggle the menu", "status": "in_progress"},
        {"text": "Run the scene tests", "status": "pending"}]}),
]

# ---------------------------------------------------------------- codex:sample-5 (tests fail, then pass)

S5, P5 = "codex:sample-5", "reso"
FAIL_OUT = """> reso@1.4.0 test
> jest onboarding

PASS src/onboarding/__tests__/linking.test.tsx
  ✓ links an account (41 ms)
  ✓ skips linking when offline (12 ms)
  ✓ primes push permission after linking (9 ms)
FAIL src/onboarding/__tests__/fallback.test.tsx
  ✓ renders the fallback for VoiceOver users (18 ms)
  ✕ announces the step change (9 ms)
  ✓ keeps focus on the primary button (7 ms)

  ● Fallback › announces the step change

    expect(announce).toHaveBeenCalledWith("Step 2 of 4")
    Received: "Step 2"

Tests:       1 failed, 5 passed, 6 total
Time:        2.31 s"""
PASS_OUT = """> reso@1.4.0 test
> jest onboarding

PASS src/onboarding/__tests__/linking.test.tsx
  ✓ links an account (39 ms)
  ✓ skips linking when offline (11 ms)
  ✓ primes push permission after linking (9 ms)
PASS src/onboarding/__tests__/fallback.test.tsx
  ✓ renders the fallback for VoiceOver users (17 ms)
  ✓ announces the step change (8 ms)
  ✓ keeps focus on the primary button (7 ms)

Tests:       6 passed, 6 total
Time:        2.18 s"""

fb_break = diff(6, ["    announce(`Step ${step} of ${total}`);"], ["    announce(`Step ${step}`);"], ctx_before=["  useEffect(() => {"])
fb_fix = diff(6, ["    announce(`Step ${step}`);"], ["    announce(`Step ${step} of ${total}`);"], ctx_before=["  useEffect(() => {"])
fb_path = f"{RESO}/src/onboarding/Fallback.tsx"


def test_ev(sec_ago, ok):
    return ev(sec_ago, "agent.test", S5, P5, "Running tests: npm test -- onboarding",
              {"command": "npm test -- onboarding", "exitCode": 0 if ok else 1, "ok": ok, "cwd": RESO,
               "output": PASS_OUT if ok else FAIL_OUT, "follow": {"view": "tests"}})


s5 = [
    ev(400, "agent.prompt", S5, P5, "Sample task: rebuild the onboarding flow with account linking, push priming and a VoiceOver fallback",
       {"text": "Sample task: rebuild the onboarding flow with account linking, push permission priming and an accessible fallback for VoiceOver users"}),
    ev(390, "agent.plan", S5, P5, "Updated plan", {"items": [
        {"text": "Account linking step", "status": "completed"},
        {"text": "Push permission priming", "status": "completed"},
        {"text": "VoiceOver fallback", "status": "in_progress"},
        {"text": "Run the onboarding tests", "status": "pending"},
        {"text": "Update the changelog", "status": "pending"}]}),
    ev(110, "agent.edit", S5, P5, "Edited Fallback.tsx",
       {"path": fb_path, "change": "update",
        "diff": diff(1, [], ["import { announce } from \"../a11y/announce\";"], ctx_before=["import { useEffect } from \"react\";"]),
        "follow": {"view": "diff", "path": fb_path}}),
    test_ev(60, False),
    ev(45, "agent.message", S5, P5, "One assertion fails: the announcement drops the step total. Fixing the label.",
       {"text": "One assertion fails: the announcement drops the step total (`Step 2` instead of `Step 2 of 4`). Fixing the label.", "phase": "commentary"}),
]

# ---------------------------------------------------------------- claude:sample-6 (reading, plan, edits)

S6, P6 = "claude:sample-6", "neverstop"
sp_path = f"{NEVER}/src/enemies/spawner.gd"
s6 = [
    ev(240, "agent.prompt", S6, P6, "Sample: tune enemy spawn pacing so the first minute is calmer",
       {"text": "Sample: tune enemy spawn pacing so the first minute is calmer"}),
    ev(235, "agent.plan", S6, P6, "Updated plan", {"items": [
        {"text": "Read the spawner and wave timer", "status": "in_progress"},
        {"text": "Slow the first waves", "status": "pending"},
        {"text": "Check with the pacing test", "status": "pending"}]}),
    ev(230, "agent.tool", S6, P6, "Grep base_gap",
       {"tool": "Grep", "input": "{\"pattern\":\"base_gap\",\"path\":\"src\"}"}),
    ev(225, "agent.read", S6, P6, "Reading spawner.gd", {"path": sp_path, "follow": {"view": "file", "path": sp_path}}),
    ev(200, "agent.message", S6, P6, "The gap starts at 4 s and ramps by 0.85 per wave, which front-loads the pressure.",
       {"text": "The gap starts at 4 s and ramps by 0.85 per wave, which front-loads the pressure. I'll start wider and ramp more gently."}),
    ev(180, "agent.edit", S6, P6, "Edited spawner.gd",
       {"path": sp_path, "tool": "Edit", "edits": [{"old": "@export var base_gap := 4.0\n@export var min_gap := 1.8\n@export var ramp := 0.85",
                                                       "new": "@export var base_gap := 6.0\n@export var min_gap := 1.8\n@export var ramp := 0.92"}],
        "follow": {"view": "diff", "path": sp_path}}),
    ev(170, "agent.command", S6, P6, "$ godot --headless --script tests/test_pacing.gd",
       {"command": "godot --headless --script tests/test_pacing.gd", "description": "Run the pacing test", "tool": "Bash"}),
    ev(161, "agent.command_done", S6, P6, "Finished: godot --headless --script tests/test_pacing.gd",
       {"command": "godot --headless --script tests/test_pacing.gd", "ok": True, "test": False,
        "output": "pacing: first minute 7 waves (was 12)\npacing: minute five 21 waves (was 22)\nOK (2 checks)"}),
    ev(150, "agent.plan", S6, P6, "Updated plan", {"items": [
        {"text": "Read the spawner and wave timer", "status": "completed"},
        {"text": "Slow the first waves", "status": "completed"},
        {"text": "Check with the pacing test", "status": "in_progress"}]}),
]

# ---------------------------------------------------------------- claude:sample-3 (finished turn, idle)

S3, P3 = "claude:sample-3", "reso"
s3 = [
    ev(900, "agent.prompt", S3, P3, "Sample: tidy the gallery grid", {"text": "Sample: tidy the gallery grid"}),
    ev(880, "agent.edit", S3, P3, "Edited Gallery.css",
       {"path": f"{RESO}/src/gallery/Gallery.css", "tool": "Edit",
        "edits": [{"old": "  gap: 6px;", "new": "  gap: 12px;\n  grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));"}]}),
    ev(860, "agent.command", S3, P3, "$ npm run lint -- src/gallery", {"command": "npm run lint -- src/gallery", "tool": "Bash"}),
    ev(855, "agent.command_done", S3, P3, "Finished: npm run lint -- src/gallery",
       {"command": "npm run lint -- src/gallery", "ok": True, "output": "✔ No problems found"}),
    ev(850, "agent.message", S3, P3, "Done: the grid now fills the row with 180 pt minimum columns.",
       {"text": "Done: the grid now fills the row with 180 pt minimum columns and a 12 px gap."}),
    ev(845, "agent.done", S3, P3, "Turn finished (55 s)", {"durationMs": 55000, "last": "Done: the grid now fills the row."}),
]

for name, evs in {"agent-timeline-codex-sample-2.json": s2, "agent-timeline-codex-sample-5.json": s5,
                  "agent-timeline-claude-sample-6.json": s6, "agent-timeline-claude-sample-3.json": s3}.items():
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(sorted(evs, key=lambda e: e["ts"]), f, indent=0, ensure_ascii=False)

# ---------------------------------------------------------------- live script (replayed in a loop)

def step(after, e):
    e = dict(e)
    e.pop("id", None)
    e["ts"] = 0
    return {"after": after, "event": e}


live = [
    step(1.2, ev(0, "agent.edit", S2, P2, "Edited pause_menu.gd",
                 {"path": f"{NEVER}/src/ui/pause_menu.gd", "change": "update",
                  "diff": diff(20, [], pm[20:], ctx_before=[pm[19]]),
                  "follow": {"view": "diff", "path": f"{NEVER}/src/ui/pause_menu.gd"}})),
    step(1.0, ev(0, "agent.read", S6, P6, "Reading test_pacing.gd", {"path": f"{NEVER}/tests/test_pacing.gd"})),
    step(1.4, ev(0, "agent.edit", S5, P5, "Edited Fallback.tsx",
                 {"path": fb_path, "change": "update", "diff": fb_fix, "follow": {"view": "diff", "path": fb_path}})),
    step(2.2, ev(0, "agent.command", S2, P2, "$ godot --headless --check-only src/ui/pause_menu.gd",
                 {"command": "godot --headless --check-only src/ui/pause_menu.gd", "exitCode": 0, "ok": True, "cwd": NEVER,
                  "output": "Script check passed: src/ui/pause_menu.gd"})),
    step(1.6, test_ev(0, True)),
    step(1.2, ev(0, "agent.plan", S5, P5, "Updated plan", {"items": [
        {"text": "Account linking step", "status": "completed"},
        {"text": "Push permission priming", "status": "completed"},
        {"text": "VoiceOver fallback", "status": "completed"},
        {"text": "Run the onboarding tests", "status": "completed"},
        {"text": "Update the changelog", "status": "in_progress"}]})),
    step(1.0, ev(0, "agent.command", S6, P6, "$ godot --headless --script tests/test_pacing.gd",
                 {"command": "godot --headless --script tests/test_pacing.gd", "description": "Re-run the pacing test", "tool": "Bash"})),
    step(2.4, ev(0, "agent.command_done", S6, P6, "Finished: godot --headless --script tests/test_pacing.gd",
                 {"command": "godot --headless --script tests/test_pacing.gd", "ok": True,
                  "output": "pacing: first minute 7 waves (was 12)\nOK (2 checks)"})),
    step(1.5, ev(0, "agent.plan", S2, P2, "Updated plan", {"items": [
        {"text": "Find where input is handled", "status": "completed"},
        {"text": "Create pause_menu.gd", "status": "completed"},
        {"text": "Wire Esc to toggle the menu", "status": "completed"},
        {"text": "Run the scene tests", "status": "in_progress"}]})),
    step(1.8, ev(0, "agent.message", S6, P6, "Pacing test passes; the first minute now has 7 waves instead of 12.",
                 {"text": "Pacing test passes; the first minute now has 7 waves instead of 12."})),
    # The cycle repeats: the label regresses, the tests catch it, it's fixed again.
    step(4.0, ev(0, "agent.edit", S5, P5, "Edited Fallback.tsx",
                 {"path": fb_path, "change": "update", "diff": fb_break, "follow": {"view": "diff", "path": fb_path}})),
    step(1.5, test_ev(0, False)),
    step(2.5, ev(0, "agent.edit", S2, P2, "Edited player.gd",
                 {"path": f"{NEVER}/src/player/player.gd", "change": "update",
                  "diff": diff(11, ["\tvelocity.x = dir.x * 7.5", "\tvelocity.z = dir.y * 7.5"], ["\tvelocity.x = dir.x * speed", "\tvelocity.z = dir.y * speed"],
                               ctx_before=["\tvar dir := Input.get_vector(\"left\", \"right\", \"forward\", \"back\")"]),
                  "follow": {"view": "diff", "path": f"{NEVER}/src/player/player.gd"}})),
    {"after": 4.0, "event": None},  # pause before the loop restarts
]
with open(os.path.join(OUT, "live.json"), "w") as f:
    json.dump(live, f, indent=0, ensure_ascii=False)
print("ok")
