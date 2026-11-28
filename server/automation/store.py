"""Persistent queue and immutable job lineage."""
import contextlib
import json
import re
import sqlite3
import time
import uuid
from pathlib import Path

from catalog import RequestError, TOOLS, revision, select_project, validate

TERMINAL = ("succeeded", "failed", "cancelled", "interrupted", "blocked")
JOB_ID = re.compile(r"[a-f0-9]{32}")
MAX_ACTIVE = 100
SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY, tool TEXT NOT NULL, version TEXT NOT NULL, revision TEXT NOT NULL,
    project TEXT NOT NULL, commit_sha TEXT NOT NULL, inputs TEXT NOT NULL, depends_on TEXT NOT NULL,
    created REAL NOT NULL, not_before REAL NOT NULL, priority INTEGER NOT NULL, state TEXT NOT NULL,
    started REAL, finished REAL, message TEXT, progress INTEGER NOT NULL DEFAULT 0,
    report TEXT, artifacts TEXT NOT NULL DEFAULT '[]', retry_of TEXT REFERENCES jobs(id)
);
CREATE INDEX IF NOT EXISTS jobs_due ON jobs(state, priority DESC, created);
CREATE TABLE IF NOT EXISTS worker (id INTEGER PRIMARY KEY CHECK(id=1), updated REAL NOT NULL, metrics TEXT NOT NULL);
"""


class Store:
    def __init__(self, data):
        self.data = data
        self.results = data / "artifacts"
        self.scratch = data / "scratch"
        for directory in (data, self.results, self.scratch):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript(SCHEMA)

    @contextlib.contextmanager
    def connect(self, write=False):
        with contextlib.closing(sqlite3.connect(self.data / "jobs.sqlite3", timeout=5)) as db:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA busy_timeout=5000")
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA foreign_keys=ON")
            with db:
                if write:
                    db.execute("BEGIN IMMEDIATE")
                yield db

    def enqueue(self, project_root, request, retry_of=None):
        allowed = {"tool", "project", "commit", "inputs", "priority", "notBefore", "dependsOn"}
        if not isinstance(request, dict) or request.keys() - allowed:
            raise RequestError("Unknown job request fields")
        tool, project, inputs = request.get("tool"), request.get("project"), request.get("inputs", {})
        validate(tool, inputs)
        commit, _, _ = select_project(project_root, project, request.get("commit"))
        priority, now = request.get("priority", 0), time.time()
        due = request.get("notBefore", now)
        dependencies = request.get("dependsOn", [])
        if type(priority) is not int or not -10 <= priority <= 10:
            raise RequestError("Priority must be an integer from -10 to 10")
        if type(due) not in (int, float) or not 0 <= due <= now + 365 * 86400:
            raise RequestError("notBefore must be a Unix timestamp within the next year")
        if (not isinstance(dependencies, list) or len(dependencies) > 16
                or not all(isinstance(item, str) and JOB_ID.fullmatch(item) for item in dependencies)):
            raise RequestError("Dependencies must be a list of up to 16 job IDs")
        job = uuid.uuid4().hex
        with self.connect(write=True) as db:
            count = db.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','paused','running','cancelling')").fetchone()[0]
            if count >= MAX_ACTIVE:
                raise RequestError("Automation queue is full", 429)
            for dep in set(dependencies):
                self.row(db, dep)
            db.execute("""
                INSERT INTO jobs(id,tool,version,revision,project,commit_sha,inputs,depends_on,created,not_before,priority,state,retry_of)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,'queued',?)
            """, (job, tool, TOOLS[tool]["version"], revision(), project, commit, json.dumps(inputs),
                  json.dumps(list(dict.fromkeys(dependencies))), now, due, priority, retry_of))
            return present(self.row(db, job))

    @staticmethod
    def row(db, job):
        if not isinstance(job, str) or not JOB_ID.fullmatch(job):
            raise RequestError("Job not found", 404)
        item = db.execute("SELECT * FROM jobs WHERE id=?", (job,)).fetchone()
        if item is None:
            raise RequestError("Job not found", 404)
        return item

    def state(self, job):
        with self.connect() as db:
            return self.row(db, job)["state"]

    def job(self, job):
        with self.connect() as db:
            return present(self.row(db, job))

    def list(self, project=None):
        with self.connect() as db:
            rows = db.execute("""
                SELECT * FROM jobs WHERE (? IS NULL OR project=?)
                ORDER BY state NOT IN ('queued','paused','running','cancelling'), created DESC LIMIT 100
            """, (project, project))
            return [present(row, include_report=False) for row in rows]

    def action(self, project_root, job, action):
        if action == "retry":
            old = self.job(job)
            if old["state"] not in {"failed", "cancelled", "interrupted", "blocked"}:
                raise RequestError("Only unsuccessful terminal jobs can be retried", 409)
            if old["revision"] != revision():
                raise RequestError("Original tool code changed. Queue a new job with the current version.", 409)
            return self.enqueue(project_root, {k: old[k] for k in ("tool", "project", "commit", "inputs", "priority", "dependsOn")},
                                retry_of=job)
        transitions = {"pause": {"queued": "paused"}, "resume": {"paused": "queued"},
                       "cancel": {"queued": "cancelled", "paused": "cancelled", "running": "cancelling"}}
        with self.connect(write=True) as db:
            state = self.row(db, job)["state"]
            target = transitions.get(action, {}).get(state)
            if not target:
                raise RequestError(f"Job does not support {action} in state {state}", 409)
            db.execute("UPDATE jobs SET state=?, message=?, finished=? WHERE id=?",
                       (target, None, time.time() if target == "cancelled" else None, job))
            return present(self.row(db, job))

    def claim(self):
        with self.connect(write=True) as db:
            busy = {row[0] for row in db.execute("SELECT project FROM jobs WHERE state IN ('running','cancelling')")}
            for row in db.execute("SELECT * FROM jobs WHERE state='queued' AND not_before<=? ORDER BY priority DESC, created",
                                  (time.time(),)).fetchall():
                deps = [self.row(db, dep)["state"] for dep in json.loads(row["depends_on"])]
                if any(dep in TERMINAL and dep != "succeeded" for dep in deps):
                    db.execute("UPDATE jobs SET state='blocked', finished=?, message=? WHERE id=?",
                               (time.time(), "A dependency did not succeed", row["id"]))
                    continue
                if row["project"] in busy or any(dep != "succeeded" for dep in deps):
                    continue
                db.execute("UPDATE jobs SET state='running', started=?, message=? WHERE id=?",
                           (time.time(), "Preparing isolated job", row["id"]))
                return present(self.row(db, row["id"]))
        return None

    def finish(self, job, state, message, report, artifacts):
        with self.connect(write=True) as db:
            current = self.row(db, job)["state"]
            if current not in {"running", "cancelling"}:
                return
            if current == "cancelling":
                state, message = "cancelled", "Cancellation requested"
            db.execute("UPDATE jobs SET state=?, finished=?, progress=?, message=?, report=?, artifacts=? WHERE id=?",
                       (state, time.time(), 100 if state == "succeeded" else self.row(db, job)["progress"],
                        message, json.dumps(report, allow_nan=False), json.dumps(artifacts), job))

    def update(self, job, status):
        with self.connect(write=True) as db:
            db.execute("UPDATE jobs SET progress=max(progress,?), message=? WHERE id=? AND state='running'",
                       (status["percent"], status["message"], job))

    def interrupt(self):
        with self.connect(write=True) as db:
            db.execute("""
                UPDATE jobs SET state=CASE state WHEN 'cancelling' THEN 'cancelled' ELSE 'interrupted' END,
                finished=?, message='Worker stopped before completion'
                WHERE state IN ('running','cancelling')
            """, (time.time(),))

    def heartbeat(self, metrics):
        with self.connect(write=True) as db:
            db.execute("INSERT OR REPLACE INTO worker VALUES (1,?,?)", (time.time(), json.dumps(metrics)))

    def health(self):
        with self.connect() as db:
            row = db.execute("SELECT * FROM worker WHERE id=1").fetchone()
            counts = dict(db.execute("SELECT state, count(*) FROM jobs GROUP BY state"))
        return {"online": bool(row and time.time() - row["updated"] < 15),
                "updated": row["updated"] if row else None,
                "resources": json.loads(row["metrics"]) if row else None, "counts": counts}

    def artifact(self, job, name):
        metadata = next((entry for entry in self.job(job)["artifacts"] if entry["name"] == name), None)
        path = self.results / job / name
        if metadata is None or path.is_symlink() or not path.is_file():
            raise RequestError("Artifact not found or expired", 404)
        return {"path": str(path), **metadata}


def present(row, include_report=True):
    data = {"id": row["id"], "project": row["project"], "tool": row["tool"], "version": row["version"],
            "revision": row["revision"], "commit": row["commit_sha"], "inputs": json.loads(row["inputs"]),
            "dependsOn": json.loads(row["depends_on"]), "retryOf": row["retry_of"], "priority": row["priority"],
            "notBefore": row["not_before"], "state": row["state"], "created": row["created"], "started": row["started"],
            "finished": row["finished"], "progress": row["progress"], "message": row["message"],
            "artifacts": json.loads(row["artifacts"])}
    if include_report:
        data["report"] = json.loads(row["report"]) if row["report"] else None
    return data
