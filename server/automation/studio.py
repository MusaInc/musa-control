#!/usr/bin/env python3
"""Studio automation CLI. Commands submit or query; only worker executes jobs."""
import argparse
import json
import os
import sys
from pathlib import Path

from catalog import RequestError, TOOLS, discover, revision
from store import Store


def catalog(root):
    projects = discover(root)
    return {
        "revision": revision(), "projects": [{k: p[k] for k in ("id", "name")} for p in projects.values()],
        "tools": [{"id": key, **tool, "projects": list(projects),
                   "permissions": ["read-committed-project", "write-job-artifacts", "network-denied"],
                   "controls": ["pause-queued", "resume", "cancel", "retry"]}
                  for key, tool in TOOLS.items()],
    }


def main():
    default = Path.home() / ".local/share/musa-control/automation"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=os.environ.get("MUSA_AUTOMATION_DATA", default))
    parser.add_argument("--projects", type=Path, default=os.environ.get("MUSA_AUTOMATION_PROJECTS", Path.home() / "workspace/projects"))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("catalog")
    commands.add_parser("health")
    commands.add_parser("enqueue", help="Read an object with tool, project and inputs from JSON stdin")
    listing = commands.add_parser("jobs")
    listing.add_argument("--project")
    for name in ("get", "pause", "resume", "cancel", "retry", "artifact"):
        single = commands.add_parser(name)
        single.add_argument("id")
        if name == "artifact":
            single.add_argument("name")
    worker = commands.add_parser("worker")
    worker.add_argument("--concurrency", type=int, choices=range(1, 5), default=2)
    worker.add_argument("--min-ram-mib", type=int, default=2048)
    worker.add_argument("--min-disk-mib", type=int, default=8192)
    worker.add_argument("--retain-days", type=int, default=30)
    args = parser.parse_args()
    os.umask(0o077)
    root = args.projects.expanduser().resolve()
    store = Store(args.data.expanduser().resolve())
    try:
        if args.command == "worker":
            from worker import Worker
            if min(args.min_ram_mib, args.min_disk_mib, args.retain_days) < 1:
                parser.error("Worker resource and retention limits must be positive")
            Worker(store, root, args.concurrency, args.min_ram_mib * 1024**2,
                   args.min_disk_mib * 1024**2, args.retain_days).run()
            return 0
        if args.command == "enqueue":
            data = sys.stdin.buffer.read(32769)
            if len(data) > 32768:
                raise RequestError("Job request exceeds 32 KiB", 413)
            try:
                request = json.loads(data)
            except (ValueError, RecursionError):
                raise RequestError("Job request is not valid JSON") from None
            response = store.enqueue(root, request)
        elif args.command == "catalog":
            response = catalog(root)
        elif args.command == "jobs":
            response = store.list(args.project)
        elif args.command == "get":
            response = store.job(args.id)
        elif args.command == "health":
            response = store.health()
        elif args.command == "artifact":
            response = store.artifact(args.id, args.name)
        else:
            response = store.action(root, args.id, args.command)
        print(json.dumps(response, ensure_ascii=True))
        return 0
    except RequestError as error:
        print(json.dumps({"error": str(error), "status": error.status}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
