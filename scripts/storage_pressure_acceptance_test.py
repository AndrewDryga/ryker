"""Manual cache acceptance must not depend on or change a running installation."""
import contextlib
import io
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch

import storage_pressure_acceptance as acceptance


class StorageAcceptanceTest(unittest.TestCase):
    image = "sha256:" + "a" * 64

    def exercise(self, fail_build=False, docker_env=None):
        commands = []

        def run(command, **options):
            commands.append(command)
            if "build" in command and fail_build:
                raise subprocess.TimeoutExpired(command, 45)
            if "df" in command:
                options["stdout"].write(b'{"Type":"Build Cache","Size":"1MB"}\n')
            return subprocess.CompletedProcess(command, 0)

        with patch.dict(os.environ, docker_env or {"DOCKER_CONTEXT": "fixture-engine"}, clear=True), \
                patch.object(sys, "argv", ["acceptance", "--image", "fixture-daemon:local"]), \
                patch.object(acceptance.subprocess, "check_output", return_value=self.image) as inspect, \
                patch.object(acceptance.subprocess, "run", side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            if fail_build:
                with self.assertRaises(subprocess.TimeoutExpired):
                    acceptance.main()
            else:
                acceptance.main()
                self.assertEqual(len(json.loads(output.getvalue())["iterations"]), 16)

        return inspect, commands

    def test_explicit_local_image_needs_no_running_installation(self):
        # The original one-off experiment inspected a hardcoded production
        # container before it could run. A renamed or absent install broke it.
        inspect, commands = self.exercise()
        inspect.assert_called_once_with(
            ["docker", "--context", "fixture-engine", "image", "inspect", "--format",
             "{{.Id}}", "fixture-daemon:local"],
            text=True)
        create = commands[0]
        name = create[create.index("--name") + 1]
        self.assertIn("--pull=never", create)
        self.assertIn("--network", create)
        self.assertEqual(create[create.index("--network") + 1], "none")
        self.assertIn(self.image, create)
        self.assertTrue(name.startswith("ryker-storage-acceptance-"))
        prefix = ["docker", "--context", "fixture-engine"]
        self.assertEqual(commands[-1], prefix + ["rm", "--force", "--volumes", name])
        for command in commands[1:-1]:
            self.assertEqual(command[:4], prefix + ["exec"])
            self.assertIn(name, command)

    def test_failed_build_still_removes_only_the_disposable_daemon(self):
        _inspect, commands = self.exercise(fail_build=True)
        create = commands[0]
        name = create[create.index("--name") + 1]
        self.assertEqual(commands[-1], ["docker", "--context", "fixture-engine",
                                       "rm", "--force", "--volumes", name])

    def test_explicit_host_stays_selected_through_cleanup(self):
        inspect, commands = self.exercise(docker_env={"DOCKER_HOST": "unix:///fixture.sock"})
        inspect.assert_called_once_with(
            ["docker", "--host", "unix:///fixture.sock", "image", "inspect", "--format",
             "{{.Id}}", "fixture-daemon:local"], text=True)
        self.assertTrue(all(command[:3] == ["docker", "--host", "unix:///fixture.sock"]
                            for command in commands))

    def test_missing_image_exits_before_contacting_docker(self):
        with patch.object(sys, "argv", ["acceptance"]), \
                patch.object(acceptance.subprocess, "check_output",
                             side_effect=AssertionError("Docker called without --image")) as inspect, \
                patch.object(acceptance.subprocess, "run"), \
                contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit) as result:
            acceptance.main()
        self.assertEqual(result.exception.code, 2)
        inspect.assert_not_called()

    def test_absent_local_image_creates_no_daemon(self):
        with patch.dict(os.environ, {"DOCKER_CONTEXT": "fixture-engine"}, clear=True), \
                patch.object(sys, "argv", ["acceptance", "--image", "missing-image"]), \
                patch.object(acceptance.subprocess, "check_output",
                             side_effect=subprocess.CalledProcessError(1, "docker image inspect")), \
                patch.object(acceptance.subprocess, "run") as run, \
                self.assertRaises(subprocess.CalledProcessError):
            acceptance.main()
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
