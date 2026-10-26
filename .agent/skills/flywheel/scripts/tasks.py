#!/usr/bin/env python3
"""Reconcile selected flywheel work with Coop, including a crash after task creation."""
import argparse
import fcntl
import json
import os
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
STATES = ("00_todo", "10_in_progress", "50_blocked", "99_done", "xx_backlog")


def request(root, document):
    result = subprocess.run(
        [str(root / "scripts/flywheel.sh"), "-"], input=json.dumps(document),
        text=True, capture_output=True, check=True, cwd=root,
    )
    return json.loads(result.stdout)


def locate(queue, marker):
    matches = []
    for state in STATES:
        for task in (queue / state).glob("*/task.md"):
            if marker in task.read_text():
                matches.append(task)
    if len(matches) > 1:
        raise RuntimeError("Several tasks carry this flywheel identity; reconcile them before continuing")
    return matches[0] if matches else None


def synchronize(root, run_id, lease_ref):
    queue = root / ".agent/tasks"
    state = root / ".ryker/flywheel"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = state / "tasks.lock"
    with lock_path.open("a") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        custody = {"action": "heartbeat", "run_id": run_id, "lease_ref": lease_ref}
        request(root, custody)
        report = request(root, {"action": "report"})
        findings = report["findings"]["ready"] + report["findings"]["in_progress"]
        linked = []
        for finding in findings:
            grants = [event for event in finding["history"] if event["action"] in ("select", "revise", "dismiss", "close")]
            if not grants or grants[-1]["action"] != "select" or grants[-1]["run_id"] != run_id:
                continue
            if finding["owner"] not in ("ryker", "both"):
                raise RuntimeError("A user-only action cannot enter the agent queue")
            cycle = 1 + sum(event["action"] in ("ship", "close") for event in finding["history"])
            marker = "flywheel-finding: " + finding["id"] + "\nflywheel-cycle: " + str(cycle) + "\n"
            task = locate(queue, marker)
            if task is None:
                if finding["task_id"]:
                    raise RuntimeError("The linked task is missing; restore or reconcile it before creating another")
                request(root, custody)
                proposal = finding["proposal"]
                subprocess.run([
                    "coop", "tasks", "add", "Flywheel: " + proposal["title"],
                    "--tasks", str(queue),
                    "--context", marker + "\n\n" + proposal["example"] + "\n\nBenefit: " + proposal["benefit"],
                    "--acceptance", proposal["verification"] + "\n\nBaseline: " + proposal["baseline"],
                    "--approach", proposal["change"] + "\n\nTradeoffs: " + proposal["tradeoffs"],
                    "--subtask", "Reproduce the evidence, implement, and run the owning tests.",
                    "--subtask", "Gate, review, commit, deploy, and record the deployed version in the flywheel.",
                    "--subtask", "Leave the outcome pending for the later measured comparison.",
                ], check=True, cwd=root, capture_output=True, text=True)
                task = locate(queue, marker)
                if task is None:
                    raise RuntimeError("Coop did not create the expected task")
            task_id = task.parent.name
            if finding["task_id"] and finding["task_id"] != task_id:
                raise RuntimeError("The ledger and queue disagree about task identity")
            if not finding["task_id"]:
                request(root, {"action": "decide", "run_id": run_id, "lease_ref": lease_ref,
                    "finding_id": finding["id"], "decision": "link", "task_id": task_id,
                    "note": "Reconciled the selected task with the local Coop queue"})
            linked.append({"finding_id": finding["id"], "task_id": task_id,
                           "state": task.parent.parent.name})
        return linked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True)
    parser.add_argument("--lease", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(synchronize(ROOT, args.run, args.lease)))
    except subprocess.CalledProcessError as error:
        # Provider/Coop diagnostics may contain supplied text. Keep only printable
        # characters, strip terminal controls, and cap the output for the operator.
        message = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", error.stderr or error.stdout or "")
        message = "".join(char for char in message if char.isprintable() or char in "\n\t")[:2000]
        operation = "Flywheel ledger" if "flywheel.sh" in str(error.cmd[0]) else "Coop task"
        print(operation + " refused: " + (message.strip() or str(error)), file=sys.stderr)
        return 1
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
