"""Adapters for existing studio development workflows."""
import json
import re
from collections import Counter
from pathlib import Path

from sdk import JOB, OUTPUT, SOURCE, artifact, command, progress, sandbox_path

ENTRY_POINTS = ("project.godot", "tests/run_tests.gd", "export_presets.cfg",
                ".github/workflows/testflight.yml", "tools/test.sh")
ASSETS = {".glb", ".gltf", ".blend", ".png", ".jpg", ".webp", ".wav", ".ogg", ".ttf", ".svg"}
SUMMARY = re.compile(r"(\d+) passed, (\d+) failed\b")
ERROR = re.compile(r"^(?:SCRIPT ERROR|Parse Error|ERROR:|FAIL\b|Assertion failed)")
SANDBOX_EDITOR_MESSAGES = {
    'ERROR: Condition "_sock == -1" is true. Returning: FAILED': "drivers/unix/net_socket_unix.cpp",
    'ERROR: Condition "err != OK" is true. Returning: ERR_CANT_CREATE': "core/io/tcp_server.cpp",
}
LOCATION = re.compile(r"""(?P<file>res://[^\s:()'"]+)(?::(?P<line>\d+))?""")
GODOT = Path("/runtime/godot")
BLENDER = Path("/runtime/blender/blender")


def inventory(_inputs):
    records = json.loads((JOB / "tree.json").read_text())
    paths = {row["path"] for row in records}
    counts = Counter(Path(row["path"]).suffix.lower() for row in records)
    report = {
        "trackedFiles": len(records), "trackedBytes": sum(row["bytes"] for row in records),
        "entryPoints": [name for name in ENTRY_POINTS if name in paths],
        "missingEntryPoints": [name for name in ENTRY_POINTS[:2] if name not in paths],
        "testScripts": sum(p.startswith("tests/") and p.endswith(".gd") for p in paths),
        "developmentScripts": sum(p.startswith("tools/") and p.endswith((".py", ".sh", ".gd")) for p in paths),
        "assetCounts": {ext: counts[ext] for ext in sorted(ASSETS) if counts[ext]},
    }
    artifact("inventory.json", report)
    return not report["missingEntryPoints"], report


def regression(inputs):
    if not GODOT.is_file():
        raise ValueError("Godot executable is unavailable on the worker")
    test_args = ["godot", "--headless", "--fixed-fps", "60", "--script", "res://tests/run_tests.gd"]
    if inputs.get("filter"):
        test_args += ["--", inputs["filter"]]
    report = {"stage": "import", "errors": [], "errorCount": 0, "command": test_args,
              "measurementEnvironment": "linux-server-headless", "rendererPerformanceVerified": False}
    seen = set()
    summary_matched = False
    previous_error = None
    editor_socket = None

    def record_error(line):
        if line in seen:
            return None
        if len(seen) < 512:
            seen.add(line)
        report["errorCount"] += 1
        if len(report["errors"]) >= 24:
            return None
        item = {"message": line}
        add_location(item, line)
        report["errors"].append(item)
        return item

    def add_location(item, text):
        if location := LOCATION.search(text):
            item["file"] = location["file"]
            if location["line"]:
                item["line"] = int(location["line"])

    def observe(line):
        nonlocal summary_matched, previous_error, editor_socket
        line = line.strip()
        if editor_socket:
            message, location = editor_socket
            editor_socket = None
            if line.startswith("at:") and location in line:
                report["sandboxEditorSocketMessages"] = report.get("sandboxEditorSocketMessages", 0) + 1
                return
            previous_error = record_error(message)
        if previous_error is not None and line.startswith("at:"):
            add_location(previous_error, line)
            previous_error = None
            return
        previous_error = None
        match = SUMMARY.search(line)
        if match and report["stage"] == "tests":
            report["passed"], report["failed"] = map(int, match.groups())
            summary_matched = True
        if report["stage"] == "import" and line in SANDBOX_EDITOR_MESSAGES:
            editor_socket = (line, SANDBOX_EDITOR_MESSAGES[line])
        elif ERROR.search(line):
            previous_error = record_error(line)

    progress(30, "Importing committed Godot project")
    import_args = ["godot", "--headless", "--import"]
    report["import"] = command([str(GODOT), *import_args[1:]], observe)
    if editor_socket:
        record_error(editor_socket[0])
        editor_socket = None
    ok = report["import"]["exitCode"] == 0 and report["errorCount"] == 0
    if ok:
        report["stage"] = "tests"
        progress(65, "Running project regression suite")
        report["run"] = command([str(GODOT), *test_args[1:]], observe)
        ok = (report["run"]["exitCode"] == 0 and summary_matched and report["errorCount"] == 0
              and report["failed"] == 0 and report["passed"] > 0)
        if not summary_matched:
            report["errors"].append({"message": "Test harness did not emit a complete summary"})
        elif report["passed"] == 0 and report["failed"] == 0:
            report["errors"].append({"message": "No tests matched the selected filter"})
    else:
        report["command"] = import_args
    artifact("regression.json", report)
    return ok, report


def audit(inputs):
    inventory_ok, summary = inventory(inputs)
    if inventory_ok:
        ok, tests = regression(inputs)
    else:
        ok, tests = False, {"skipped": "Project entry point or regression harness is missing"}
    report = {"inventory": summary, "regression": tests}
    artifact("audit.json", report)
    return ok, report


def inspect_meshes(inputs):
    if not BLENDER.is_file():
        raise ValueError("Blender executable is unavailable on the worker")
    directory = sandbox_path(inputs["directory"])
    assets = sorted(p for p in directory.iterdir() if p.suffix.lower() in {".glb", ".gltf"} and p.is_file())
    if not 1 <= len(assets) <= 64:
        raise ValueError("Choose a directory with 1–64 GLB or glTF files")
    progress(35, f"Inspecting {len(assets)} assets in Blender")
    raw = JOB / "mesh-output.json"
    execution = command([str(BLENDER), "-b", "--factory-startup", "--disable-autoexec",
                         "--threads", "2", "--python-exit-code", "1",
                         "--python", "/toolkit/blender_meshes.py", "--", str(raw), *map(str, assets)],
                        lambda _line: None)
    report = json.loads(raw.read_text()) if raw.is_file() else {"assets": [], "errors": ["Blender produced no report"]}
    report["execution"] = execution
    artifact("meshes.json", report)
    return execution["exitCode"] == 0 and not report["errors"] and len(report["assets"]) == len(assets), report


HANDLERS = {"project.inventory": inventory, "godot.regression": regression, "godot.audit": audit,
            "blender.inspect": inspect_meshes}
