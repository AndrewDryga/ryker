#!/usr/bin/env python3
"""A local fake Coop and ledger exercise the actual reconciliation, without model calls."""
import importlib.util
from pathlib import Path
import tempfile
import io
import subprocess
import sys
sys.dont_write_bytecode = True
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("flywheel_tasks", Path(__file__).with_name("tasks.py"))
TASKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TASKS)


class ReconciliationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.finding = {"id": "finding-one", "owner": "both", "task_id": None,
                        "history": [{"action": "select", "run_id": "run"}],
                        "proposal": {key: "A useful improvement" for key in
                                     ("title", "example", "benefit", "verification", "baseline", "change", "tradeoffs")}}
        self.report = {"findings": {"ready": [self.finding], "in_progress": []}}
        self.creations = 0
        self.links = 0

    def create(self, command, **_kwargs):
        self.creations += 1
        self.assertEqual(command[:3], ["coop", "tasks", "add"])
        task = self.root / (".agent/tasks/00_todo/2026-10-25-improve-" + str(self.creations) + "/task.md")
        task.parent.mkdir(parents=True)
        task.write_text(command[command.index("--context") + 1])

    def ledger(self, _root, command):
        if command["action"] == "report":
            return self.report
        if command["action"] == "heartbeat":
            return {"id": "run"}
        self.links += 1
        self.finding["task_id"] = command["task_id"]
        return self.finding

    def test_repeated_sync_creates_one_task(self):
        with patch.object(TASKS, "request", self.ledger), patch.object(TASKS.subprocess, "run", self.create):
            first = TASKS.synchronize(self.root, "run", "lease")
            second = TASKS.synchronize(self.root, "run", "lease")
        self.assertEqual(first, second)
        self.assertEqual(self.creations, 1)
        self.assertEqual(self.links, 1)

    def test_retry_after_creation_recovers_the_existing_task(self):
        def interrupted(root, command):
            if command["action"] == "decide":
                raise RuntimeError("connection lost after creation")
            return self.ledger(root, command)
        with patch.object(TASKS, "request", interrupted), patch.object(TASKS.subprocess, "run", self.create):
            with self.assertRaisesRegex(RuntimeError, "connection lost"):
                TASKS.synchronize(self.root, "run", "lease")
        with patch.object(TASKS, "request", self.ledger), patch.object(TASKS.subprocess, "run", self.create):
            TASKS.synchronize(self.root, "run", "lease")
        self.assertEqual(self.creations, 1)
        self.assertEqual(self.links, 1)

    def test_lost_lease_cannot_create_a_task(self):
        def fenced(root, command):
            if command["action"] != "report":
                raise RuntimeError("flywheel_lease_lost")
            return self.ledger(root, command)
        with patch.object(TASKS, "request", fenced), patch.object(TASKS.subprocess, "run", self.create):
            with self.assertRaisesRegex(RuntimeError, "flywheel_lease_lost"):
                TASKS.synchronize(self.root, "run", "old-lease")
        self.assertEqual(self.creations, 0)

    def test_user_action_cannot_be_exported_as_agent_work(self):
        self.finding["owner"] = "user"
        with patch.object(TASKS, "request", self.ledger), patch.object(TASKS.subprocess, "run", self.create):
            with self.assertRaisesRegex(RuntimeError, "user-only"):
                TASKS.synchronize(self.root, "run", "lease")
        self.assertEqual(self.creations, 0)

    def test_an_older_runs_work_is_not_exported(self):
        with patch.object(TASKS, "request", self.ledger), patch.object(TASKS.subprocess, "run", self.create):
            self.assertEqual(TASKS.synchronize(self.root, "later-run", "lease"), [])
        self.assertEqual(self.creations, 0)

    def test_a_regression_creates_one_new_task_and_preserves_the_archived_cycle(self):
        with patch.object(TASKS, "request", self.ledger), patch.object(TASKS.subprocess, "run", self.create):
            first = TASKS.synchronize(self.root, "run", "lease")
            original = self.root / ".agent/tasks/00_todo" / first[0]["task_id"]
            archived = self.root / ".agent/tasks/99_done" / first[0]["task_id"]
            archived.parent.mkdir(parents=True)
            original.rename(archived)
            self.finding["history"].extend([{"action": "ship", "run_id": "run"}, {"action": "select", "run_id": "run"}])
            self.finding["task_id"] = None
            second = TASKS.synchronize(self.root, "run", "lease")
            self.assertEqual(second, TASKS.synchronize(self.root, "run", "lease"))
        self.assertNotEqual(first[0]["task_id"], second[0]["task_id"])
        self.assertTrue(archived.exists())
        self.assertEqual(self.creations, 2)

    def test_lease_refusal_is_visible_without_task_creation(self):
        error = subprocess.CalledProcessError(1, ["scripts/flywheel.sh", "-"], stderr="flywheel_lease_lost")
        output = io.StringIO()
        with patch.object(sys, "argv", ["tasks.py", "--run", "run", "--lease", "old"]), patch.object(TASKS, "request", side_effect=error), patch.object(sys, "stderr", output), patch.object(TASKS.subprocess, "run", self.create):
            self.assertEqual(TASKS.main(), 1)
        self.assertIn("Flywheel ledger refused: flywheel_lease_lost", output.getvalue())
        self.assertEqual(self.creations, 0)


if __name__ == "__main__":
    unittest.main()
