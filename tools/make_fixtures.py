"""Writes the sample data the UI tests run against (ios/MusaControl/Resources/Fixtures).

The schemas match the real gateway responses, but every agent, prompt, command,
diff and file here is sample content: nothing comes from real transcripts.
Projects, displays and tmux names are plain structure captured from the server.
"""
import json, os, time

OUT = os.path.join(os.path.dirname(__file__), "..", "ios", "MusaControl", "Resources", "Fixtures")
now = int(time.time() * 1000)
P = "/home/dev/workspace/projects/CitySwing"

def ev(i, kind, title, project="cityswing", session="claude:sample-1", ago=0, **detail):
    return {"id": 9000 + i, "ts": now - ago * 1000, "kind": kind, "project": project, "session": session,
            "title": title, "detail": detail, "notify": 0}

timeline = [
    ev(1, "agent.prompt", "Sample task: smooth the swing camera when releasing a web", ago=900, text="Sample task: smooth the swing camera when releasing a web, then capture before/after screenshots.", agent="claude"),
    ev(2, "agent.message", "I'll look at the camera follow code first.", ago=880, text="I'll look at the camera follow code first.", agent="claude"),
    ev(3, "agent.command", "$ rg -n \"release\" src/camera", ago=870, command="rg -n \"release\" src/camera", agent="claude", follow={"view": "activity"}),
    ev(4, "agent.edit", "Edited swing_camera.gd", ago=820, path=P + "/src/camera/swing_camera.gd", tool="Edit", agent="claude",
       edits=[{"old": "var follow_rate := 6.0", "new": "var follow_rate := 4.5\nvar release_ease := 0.35"}], follow={"view": "diff", "path": P + "/src/camera/swing_camera.gd"}),
    ev(5, "file.changed", "Edited src/camera/swing_camera.gd (+2 −1)", ago=819, session=None, path="src/camera/swing_camera.gd", change="update", revision=1, added=2, removed=1),
    ev(6, "agent.test", "Running tests: godot --headless --script tests/run_tests.gd", ago=760, command="godot --headless --script tests/run_tests.gd", agent="claude", follow={"view": "tests"}),
    ev(7, "agent.command_done", "Finished: godot --headless --script tests/run_tests.gd", ago=700, command="godot --headless --script tests/run_tests.gd", output="Sample output\n159 passed, 0 failed", ok=True, agent="claude", follow={"view": "tests"}),
    ev(8, "agent.image", "Captured camera_after.png", ago=640, path=P + "/captures/camera_after.png", via="command", agent="claude", follow={"view": "screenshot", "path": P + "/captures/camera_after.png"}),
    ev(9, "agent.approval", "Claude Code needs approval: Do you want to proceed?", ago=60, kind_="command", question="Do you want to proceed?", context="Bash command\n$ bash tools/web/deploy_web.sh", agent="claude", follow={"view": "approval"}),
    ev(10, "build.finished", "npm run test succeeded", project="reso", session=None, ago=1500, exitCode=0, build="sample"),
    ev(11, "git.commit", "Committed a1b2c3d: Sample commit message", project="neverstop", session=None, ago=2400),
    ev(12, "agent.done", "Turn finished (184 s)", ago=600, durationMs=184000, last="Camera release now eases out; tests pass.", agent="claude"),
    ev(13, "agent.prompt", "Sample task: add a pause menu", project="neverstop", session="codex:sample-2", ago=300, text="Sample task: add a pause menu", agent="codex"),
    ev(14, "agent.edit", "Edited pause_menu.gd", project="neverstop", session="codex:sample-2", ago=200, path="/home/dev/workspace/projects/NeverStop/src/ui/pause_menu.gd", change="add",
       diff="@@ -0,0 +1,4 @@\n+extends Control\n+\n+func _ready() -> void:\n+\thide()\n", agent="codex", follow={"view": "diff", "path": "/home/dev/workspace/projects/NeverStop/src/ui/pause_menu.gd"}),
]

approval = {"kind": "command", "question": "Do you want to proceed?", "context": "Bash command\nDeploy the web build (sample)\n$ bash tools/web/deploy_web.sh",
            "command": "bash tools/web/deploy_web.sh", "options": [
                {"index": 0, "number": 1, "label": "Yes", "tone": "allow"},
                {"index": 1, "number": 2, "label": "Yes, and don't ask again for this command", "tone": "allow"},
                {"index": 2, "number": 3, "label": "No", "tone": "deny"}], "selected": 0, "signature": "sample"}

def agent(id, kind, title, project, status, text, ago, approval=None, tmux=None, counts=(3, 5, 1, 0)):
    return {"id": id, "agent": kind, "agentName": "Claude Code" if kind == "claude" else "Codex", "sessionId": id.split(":")[1], "project": project,
            "projectInferred": False, "cwd": P, "title": title, "lastPrompt": title, "lastMessage": None, "status": status, "statusText": text,
            "lastActivity": now - ago * 1000, "startedAt": now - 3600_000, "model": "sample-model", "pid": 1234 if status != "ended" else None,
            "mode": "interactive", "tmux": {"session": tmux, "target": tmux} if tmux else None, "managed": {"id": "m", "tmux": tmux} if tmux else None,
            "controllable": bool(tmux), "approval": approval,
            "counts": {"edits": counts[0], "commands": counts[1], "images": counts[2], "errors": counts[3]},
            "lastEvent": {"kind": "agent.edit", "title": "Edited swing_camera.gd", "ts": now - ago * 1000, "follow": None}}

agents = [
    agent("claude:sample-1", "claude", "Sample: smooth the swing camera", "cityswing", "approval", "Do you want to proceed?", 60, approval, "mc-claude-cityswing-a1b2"),
    agent("codex:sample-2", "codex", "Sample: add a pause menu", "neverstop", "working", "Edited pause_menu.gd", 20, None, "mc-codex-neverstop-c3d4"),
    agent("claude:sample-3", "claude", "Sample: tidy the gallery grid", "reso", "idle", "Waiting for instructions", 400, None, "mc-claude-reso-e5f6"),
    agent("claude:sample-4", "claude", "Sample: review hero section copy", "client-site", "ended", "Not running", 7200, None, None, (0, 2, 0, 0)),
]

shots = [{"id": i + 6, "ts": now - i * 600_000, "project": "cityswing", "session": "claude:sample-1" if i == 0 else None,
          "path": f"{P}/captures/sample-{i}.jpg", "width": 1920, "height": 1440, "bytes": 180000, "source": "agent" if i == 0 else "project", "note": None} for i in range(4)]

overview = {
    "system": {"healthy": True, "issues": [], "load": [1.42, 1.31, 1.2], "cpus": 8,
               "memory": {"total": 16e9, "available": 9.8e9, "swapTotal": 8e9, "swapFree": 4e9},
               "disk": {"size": 5.4e11, "used": 1.64e11, "available": 3.5e11}, "uptime": 1_210_000,
               "services": [{"name": n, "active": "active", "sub": "running", "since": None} for n in
                            ["vps-dashboard", "caddy", "musa-control", "firedev", "reso-api", "musa-live-work-x11vnc", "vpn", "ssh"]]},
    "agents": agents, "attention": [agents[0]],
    "changingProjects": [{"project": "cityswing", "files": 3, "sample": ["src/camera/swing_camera.gd", "tests/test_camera.gd"], "last": now - 820_000},
                         {"project": "neverstop", "files": 1, "sample": ["src/ui/pause_menu.gd"], "last": now - 200_000}],
    "screenshots": shots,
    "builds": [{"id": "sample", "project": "reso", "label": "npm run test", "command": "npm run test", "tmux": "mcb-reso-sample", "startedAt": now - 1600_000, "endedAt": now - 1500_000, "exitCode": 0, "status": "succeeded"}],
    "recent": list(reversed(timeline)), "watching": [{"project": "cityswing", "dirs": 148, "until": now + 1800_000}],
}

files = {
    "agents.json": agents, "overview.json": overview, "timeline.json": timeline,
    "agent-timeline.json": [e for e in timeline if e["session"] == "claude:sample-1"],
    "agent-screen.json": {"text": "\u001b[1mSample screen\u001b[0m\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n", "controllable": True, "tmux": "mc-claude-cityswing-a1b2"},
    "screenshots.json": shots,
    "file.json": {"path": "src/camera/swing_camera.gd", "size": 412, "mtime": now, "mime": "application/octet-stream", "binary": False, "sha": "sample",
                  "text": "# Sample file for UI tests\nextends Camera3D\n\nvar follow_rate := 4.5\nvar release_ease := 0.35\n\nfunc _process(delta: float) -> void:\n\t# ease toward the target after a web release\n\tvar t := clampf(delta * follow_rate, 0.0, 1.0)\n\tglobal_position = global_position.lerp(target(), t)\n"},
    "git-diff.json": {"diff": "diff --git a/src/camera/swing_camera.gd b/src/camera/swing_camera.gd\n--- a/src/camera/swing_camera.gd\n+++ b/src/camera/swing_camera.gd\n@@ -1,4 +1,5 @@\n extends Camera3D\n \n-var follow_rate := 6.0\n+var follow_rate := 4.5\n+var release_ease := 0.35\n \n"},
    "git-log.json": [{"sha": f"{i:040x}", "short": f"{i:07x}", "author": "Sample", "date": "2026-11-0%dT12:00:00+01:00" % (7 - i % 6), "subject": f"Sample commit {i}", "refs": "HEAD -> main" if i == 1 else ""} for i in range(1, 12)],
    "git-status.json": {"git": True, "branch": "main", "upstream": "origin/main", "ahead": 1, "behind": 0, "files": [
        {"path": "src/camera/swing_camera.gd", "from": None, "staged": False, "unstaged": True, "x": ".", "y": "M"},
        {"path": "tests/test_camera.gd", "from": None, "staged": True, "unstaged": False, "x": "M", "y": "."},
        {"path": "captures/camera_after.png", "from": None, "staged": False, "unstaged": True, "untracked": True, "x": "?", "y": "?"}]},
    "revisions.json": [{"id": 2, "ts": now - 200_000, "sha": "b", "size": 412, "source": "agent", "session": "claude:sample-1", "added": 2, "removed": 1},
                       {"id": 1, "ts": now - 820_000, "sha": "a", "size": 380, "source": "disk", "session": None, "added": None, "removed": None}],
    "revision-diff.json": {"id": 2, "path": "src/camera/swing_camera.gd", "previousId": 1, "diff": "--- a/src/camera/swing_camera.gd\n+++ b/src/camera/swing_camera.gd\n@@ -3,1 +3,2 @@\n-var follow_rate := 6.0\n+var follow_rate := 4.5\n+var release_ease := 0.35\n"},
    "runs.json": [{"databaseId": 100 + i, "displayTitle": f"Sample run {i}", "status": "completed", "conclusion": "success" if i % 3 else "failure", "workflowName": "iOS",
                   "headBranch": "main", "headSha": "0" * 40, "event": "push", "createdAt": "2026-11-07T1%d:00:00Z" % (i % 10), "updatedAt": None, "url": "https://github.com/", "number": i} for i in range(1, 8)],
    "builds.json": overview["builds"],
    "empty-array.json": [],
}
for name, data in files.items():
    with open(os.path.join(OUT, name), "w") as f: json.dump(data, f)
print("wrote", len(files), "fixtures")
