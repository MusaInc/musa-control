"""Cover queue transition races and recovery without requiring game binaries."""
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "automation"))
from store import Store


class QueueTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.store = Store(self.root)
        git = patch("store.select_project", return_value=("a" * 40, self.root, "sha1"))
        git.start()
        self.addCleanup(git.stop)

    def queue(self, project="cityswing", **fields):
        return self.store.enqueue(self.root, {
            "tool": "project.inventory", "project": project, **fields,
        })

    def test_priority_due_time_project_limit_and_dependencies(self):
        low = self.queue(priority=-1)
        high = self.queue(priority=4)
        future = self.queue(priority=10, notBefore=time.time() + 600)
        ready = self.queue("neverstop", dependsOn=[high["id"]])
        self.assertEqual(self.store.claim()["id"], high["id"])
        self.assertIsNone(self.store.claim())
        self.store.finish(high["id"], "succeeded", "Completed", {}, [])
        self.assertEqual(self.store.claim()["id"], ready["id"])
        self.assertEqual(self.store.claim()["id"], low["id"])
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.store.state(future["id"]), "queued")

    def test_restart_keeps_queued_jobs_and_interrupts_previous_attempt(self):
        lost = self.queue()
        self.assertEqual(self.store.claim()["id"], lost["id"])
        waiting = self.queue("neverstop")
        blocked = self.queue("motionsports", dependsOn=[lost["id"]])
        resumed = Store(self.root)
        resumed.interrupt()
        self.assertEqual(resumed.state(lost["id"]), "interrupted")
        self.assertEqual(resumed.claim()["id"], waiting["id"])
        self.assertIsNone(resumed.claim())
        self.assertEqual(resumed.state(blocked["id"]), "blocked")
        retry = resumed.action(self.root, lost["id"], "retry")
        self.assertEqual((retry["commit"], retry["retryOf"]), (lost["commit"], lost["id"]))

    def test_cancel_wins_against_concurrent_completion(self):
        job = self.queue()
        self.store.claim()
        self.store.action(self.root, job["id"], "cancel")
        self.store.finish(job["id"], "succeeded", "Completed", {}, [])
        self.assertEqual(self.store.state(job["id"]), "cancelled")


if __name__ == "__main__":
    unittest.main()
