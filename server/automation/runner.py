"""Entry points run inside the per-attempt filesystem and network sandbox."""
import io
import json
import os
import socket
import subprocess
import sys
import tarfile

from catalog import init_git_env, validate
from sdk import JOB, OUTPUT, SOURCE, write_json
from studio_tools import HANDLERS


def prepare(commit, object_format, snapshot):
    env = init_git_env()
    subprocess.run(["git", "init", "--bare", f"--object-format={object_format}", "/job/git"],
                   env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env["GIT_OBJECT_DIRECTORY"] = "/objects"
    git = ["git", "--git-dir=/job/git"]
    source = subprocess.check_output([*git, "ls-tree", "-rlz", commit], env=env)
    records = []
    for entry in source.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, kind, _oid, size = metadata.split()
        if snapshot and mode in (b"120000", b"160000"):
            raise ValueError("Committed symlinks or submodules need a dedicated snapshot adapter")
        records.append({"path": os.fsdecode(name), "bytes": int(size) if kind == b"blob" else 0})
    if len(records) > 100_000:
        raise ValueError("Project tree exceeds the file-count limit")
    (JOB / "tree.json").write_text(json.dumps(records, ensure_ascii=True))
    if not snapshot:
        return
    if sum(row["bytes"] for row in records) > 2 * 1024**3:
        raise ValueError("Committed snapshot exceeds 2 GiB")
    with subprocess.Popen([*git, "archive", "--format=tar", commit], env=env, stdout=subprocess.PIPE) as process:
        try:
            with tarfile.open(fileobj=io.BufferedReader(process.stdout), mode="r|") as archive:
                archive.extractall(SOURCE, filter="data")
        except BaseException:
            process.kill()
            raise
        if process.wait():
            raise ValueError("Git snapshot could not be exported")


def run_tool():
    request = json.loads((JOB / "request.json").read_text())
    validate(request["tool"], request["inputs"])
    OUTPUT.mkdir(exist_ok=True)
    ok, result = HANDLERS[request["tool"]](request["inputs"])
    write_json(JOB / "result.json", {"ok": ok, "report": result})
    return 0 if ok else 2


def main():
    try:
        if sys.argv[1] == "probe":
            for family in (socket.AF_INET, socket.AF_UNIX):
                try:
                    with socket.socket(family):
                        return 1
                except PermissionError:
                    pass
            return 0
        if sys.argv[1] == "prepare":
            prepare(sys.argv[2], sys.argv[3], sys.argv[4] == "1")
            return 0
        return run_tool()
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        # Preparation has no project executable. Tool command output is handled by the SDK.
        write_json(JOB / "result.json", {"ok": False, "report": {"error": str(error)[:500]}})
        return 1


if __name__ == "__main__":
    sys.exit(main())
