"""Reviewed studio tools. Registration is a code change, never a job payload."""
import hashlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROJECTS = {
    "cityempire": ("CityEmpire", "WorldState"),
    "cityswing": ("CitySwing", "CitySwing"),
    "neverstop": ("NeverStop", "NEVER STOP"),
    "motionsports": ("MotionSports", "Motion Sports"),
}
EMPTY = {"type": "object", "properties": {}, "additionalProperties": False}
FILTER = {"type": "string", "title": "Test filter", "pattern": r"[A-Za-z0-9_.-]{0,80}"}
TOOLS = {
    "godot.audit": {
        "version": "1.0.0", "title": "Game audit",
        "description": "Inventory the committed Godot project, verify its entry points and run its regression suite.",
        "dependencies": ["Git", "Godot 4"], "snapshot": True, "timeoutSeconds": 1200,
        "inputSchema": EMPTY,
        "outputSchema": {"type": "object", "required": ["inventory", "regression"],
                         "properties": {"inventory": {"type": "object"}, "regression": {"type": "object"}}},
        "artifacts": ["audit.json", "inventory.json", "regression.json", "execution.jsonl"],
    },
    "godot.regression": {
        "version": "1.0.0", "title": "Godot regression",
        "description": "Import a clean committed project and run its existing tests/run_tests.gd harness.",
        "dependencies": ["Git", "Godot 4"], "snapshot": True, "timeoutSeconds": 1200,
        "inputSchema": {**EMPTY, "properties": {"filter": FILTER}},
        "outputSchema": {"type": "object", "required": ["stage", "errors", "command"],
                         "properties": {"stage": {"type": "string"}, "errors": {"type": "array"},
                                        "command": {"type": "array"}, "passed": {"type": "integer"},
                                        "failed": {"type": "integer"}}},
        "artifacts": ["regression.json", "execution.jsonl"],
    },
    "project.inventory": {
        "version": "1.0.0", "title": "Project inventory",
        "description": "Inspect a Git tree for the game entry points, test and tool files, and asset sizes.",
        "dependencies": ["Git"], "snapshot": False, "timeoutSeconds": 45, "inputSchema": EMPTY,
        "outputSchema": {"type": "object", "required": ["trackedFiles", "trackedBytes", "entryPoints"],
                         "properties": {"trackedFiles": {"type": "integer"}, "trackedBytes": {"type": "integer"},
                                        "entryPoints": {"type": "array"}}},
        "artifacts": ["inventory.json"],
    },
    "blender.inspect": {
        "version": "1.0.0", "title": "Blender asset inspection",
        "description": "Import a directory of committed GLB or glTF assets and measure their mesh topology and bounds.",
        "dependencies": ["Git", "Blender 4"], "snapshot": True, "timeoutSeconds": 600,
        "inputSchema": {**EMPTY, "required": ["directory"], "properties": {
            "directory": {"type": "string", "title": "Asset directory",
                          "pattern": r"[ A-Za-z0-9_.-]{1,80}(/[ A-Za-z0-9_.-]{1,80}){0,10}"},
        }},
        "outputSchema": {"type": "object", "required": ["assets", "errors"],
                         "properties": {"assets": {"type": "array"}, "errors": {"type": "array"}}},
        "artifacts": ["meshes.json", "execution.jsonl"],
    },
}


class RequestError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def revision():
    digest = hashlib.sha256()
    for source in sorted(ROOT.glob("*.py")):
        digest.update(source.name.encode() + b"\0" + source.read_bytes() + b"\0")
    return digest.hexdigest()


def init_git_env():
    return {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C.UTF-8",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"}


def git(project, *args):
    return subprocess.check_output(["git", "-C", str(project), *args], env=init_git_env(),
                                   stderr=subprocess.DEVNULL, text=True, timeout=6).strip()


def discover(project_root):
    projects = {}
    for key, (directory, name) in PROJECTS.items():
        path = project_root / directory
        if not path.is_symlink() and path.is_dir() and (path / "project.godot").is_file():
            projects[key] = {"id": key, "name": name, "path": path.resolve()}
    return projects


def select_project(project_root, key, commit=None):
    projects = discover(project_root)
    if not isinstance(key, str) or key not in projects:
        raise RequestError("Studio game project not found", 404)
    path = projects[key]["path"]
    if commit is not None and (not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit)):
        raise RequestError("Commit must be a full Git object ID")
    try:
        resolved = git(path, "rev-parse", "--verify", f"{commit or 'HEAD'}^{{commit}}")
        objects = Path(git(path, "rev-parse", "--path-format=absolute", "--git-path", "objects")).resolve()
        if not objects.is_dir() or (objects / "info/alternates").exists():
            raise RequestError("Project needs a local, self-contained Git object store", 422)
        object_format = git(path, "rev-parse", "--show-object-format")
    except (OSError, subprocess.SubprocessError):
        raise RequestError("Git commit is unavailable in this project", 422) from None
    return resolved, objects, object_format


def validate(tool_id, inputs):
    if not isinstance(tool_id, str) or tool_id not in TOOLS:
        raise RequestError("Registered tool not found", 404)
    schema = TOOLS[tool_id]["inputSchema"]
    if not isinstance(inputs, dict) or not inputs.keys() <= schema["properties"].keys():
        raise RequestError("Input fields do not match the registered tool")
    if not set(schema.get("required", ())) <= inputs.keys():
        raise RequestError("Required tool input is missing")
    for name, value in inputs.items():
        if not isinstance(value, str) or not re.fullmatch(schema["properties"][name]["pattern"], value):
            raise RequestError(f"Invalid input: {name}")
        if any(part.strip() in {"", ".", ".."} for part in value.split("/")) and (name == "directory" or value):
            raise RequestError(f"Invalid input: {name}")
