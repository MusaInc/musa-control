import test from "node:test";
import assert from "node:assert/strict";
import { parseClaudeLine, parseCodexLine, parseGeminiLine } from "../src/transcripts.js";

test("transcripts: GUI commands (Blender, browsers, DISPLAY) tag follow.view = vnc", () => {
  const st = {};
  const evs = parseClaudeLine(JSON.stringify({
    type: "assistant", uuid: "u1", timestamp: "2026-11-27T12:00:00Z",
    message: { content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "DISPLAY=:99 blender -b scene.blend -o /tmp/frame_01.png -f 1" } }] }
  }), st);
  assert.equal(evs.length, 1);
  assert.equal(evs[0].kind, "agent.command");
  assert.equal(evs[0].follow?.view, "vnc");
  assert.equal(evs[0].detail?.guiApp, "blender");
});

test("transcripts: Codex and Gemini commands extract generated render/chart images", () => {
  const codexEvs = parseCodexLine(JSON.stringify({
    type: "event_msg", timestamp: "2026-11-27T12:01:00Z", ordinal: 1,
    payload: {
      type: "item_completed",
      item: {
        id: "cmd1", type: "CommandExecution",
        command: ["bash", "-lc", "python3 plot.py"],
        exit_code: 0,
        aggregated_output: "Saved plot to /home/abdul/proj/out/chart.png and /home/abdul/proj/out/contact_sheet.jpg\n",
      }
    }
  }), {});
  assert.deepEqual(codexEvs.map((e) => e.kind), ["agent.command", "agent.image", "agent.image"]);
  assert.equal(codexEvs[1].detail.path, "/home/abdul/proj/out/chart.png");
  assert.equal(codexEvs[2].detail.path, "/home/abdul/proj/out/contact_sheet.jpg");

  const geminiEvs = parseGeminiLine(JSON.stringify({
    id: "g1", type: "gemini", timestamp: "2026-11-27T12:02:00Z", content: "",
    toolCalls: [
      { id: "tc1", name: "run_shell_command", args: { command: "blender -b -P render.py" }, status: "success", resultDisplay: "Rendered /tmp/preview.webp\nExit Code: 0" },
      { id: "tc2", name: "read_file", args: { file_path: "/home/abdul/proj/main.py" }, status: "success" }
    ]
  }), {});
  assert.deepEqual(geminiEvs.map((e) => e.kind), ["agent.command", "agent.image", "agent.read"]);
  assert.equal(geminiEvs[0].follow?.view, "vnc");
  assert.equal(geminiEvs[1].detail.path, "/tmp/preview.webp");
  assert.equal(geminiEvs[2].detail.path, "/home/abdul/proj/main.py");
});
