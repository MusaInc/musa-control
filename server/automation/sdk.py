"""Small SDK used by reviewed tools for progress, evidence and command execution."""
import json
import os
import re
import subprocess
import time
from pathlib import Path

JOB = Path("/job")
SOURCE = JOB / "source"
OUTPUT = JOB / "artifacts"
MAX_LOG_BYTES = 1024 * 1024
MAX_REPORT_BYTES = 256 * 1024
SENSITIVE = re.compile(
    r"-----BEGIN .*PRIVATE KEY-----|\b(?:gh[pousr]_|github_pat_|sk-|AKIA|ASIA|mc_)[A-Za-z0-9_-]{12,}"
    r"|\bAuthorization\s*[:=]\s*(?:Bearer|Basic)\s+\S+|://[^/\s:@]+:[^/\s@]+@"
    r"|\b[\w-]*(?:token|password|passphrase|secret|api[_-]?key)\s*[:=]\s*\S+", re.I,
)


def clean(line):
    return SENSITIVE.sub("[REDACTED]", line.rstrip()[:2000])


def write_json(path, data):
    encoded = json.dumps(data, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode()
    if len(encoded) > MAX_REPORT_BYTES:
        raise ValueError("Structured report exceeds its size limit")
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_bytes(encoded + b"\n")
    temp.replace(path)


def progress(percent, message):
    write_json(JOB / "progress.json", {"percent": percent, "message": message})


def artifact(name, data):
    write_json(OUTPUT / name, data)


def command(args, observe, cwd=SOURCE):
    """Drain a child process, retain bounded structured logs and report wall time."""
    start = time.monotonic()
    log_path = OUTPUT / "execution.jsonl"
    written = log_path.stat().st_size if log_path.exists() else 0
    omitted = 0
    with log_path.open("ab") as log, subprocess.Popen(
        args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ) as process:
        while raw := process.stdout.readline(4097):
            line = clean(raw.decode("utf-8", "replace"))
            if not raw.endswith(b"\n") and len(raw) == 4097:
                while tail := process.stdout.readline(4097):
                    if tail.endswith(b"\n"):
                        break
            observe(line)
            entry = json.dumps({"time": time.time(), "message": line}, ensure_ascii=True).encode() + b"\n"
            if written + len(entry) <= MAX_LOG_BYTES - 128:
                log.write(entry)
                written += len(entry)
            else:
                omitted += 1
        code = process.wait()
        if omitted:
            entry = json.dumps({"time": time.time(), "omittedLines": omitted}).encode() + b"\n"
            if written + len(entry) <= MAX_LOG_BYTES:
                log.write(entry)
    return {"exitCode": code, "wallSeconds": round(time.monotonic() - start, 3), "omittedLogLines": omitted}


def sandbox_path(value):
    path = (SOURCE / value).resolve(strict=True)
    if not path.is_relative_to(SOURCE):
        raise ValueError("Asset directory escapes the committed project")
    return path
