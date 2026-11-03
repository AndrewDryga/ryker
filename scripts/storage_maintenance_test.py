"""Disk exhaustion stopped real message processing while cache remained reclaimable."""
import importlib.util
import contextlib
import io
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("storage_maintenance", pathlib.Path(__file__).with_name("storage_maintenance.py"))
storage = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = storage
spec.loader.exec_module(storage)


class StoragePolicyTest(unittest.TestCase):
    def test_healthy_volume_and_bounded_cache_do_not_prune(self):
        plan = storage.plan(100 * storage.GIB, 40 * storage.GIB, 2 * storage.GIB, False)
        self.assertFalse(plan["prune"])

    def test_pressure_reclaims_before_admission_reserve_is_spent(self):
        plan = storage.plan(100 * storage.GIB, 11 * storage.GIB, 2 * storage.GIB, False)
        self.assertTrue(plan["prune"])
        self.assertGreater(plan["target_free_bytes"], 11 * storage.GIB)

    def test_large_worker_reclaims_before_its_scaled_reserve_is_spent(self):
        capacity = 2 * 1024 * storage.GIB
        plan = storage.plan(capacity, 75 * storage.GIB, storage.GIB, False)
        self.assertTrue(plan["prune"])
        self.assertGreaterEqual(plan["target_free_bytes"], capacity // 10)

    def test_host_pressure_triggers_cleanup_even_if_vm_has_room(self):
        self.assertTrue(storage.plan(100 * storage.GIB, 40 * storage.GIB, 2 * storage.GIB, True)["prune"])

    def test_oversized_cache_is_bounded_without_low_free_space(self):
        self.assertTrue(storage.plan(100 * storage.GIB, 40 * storage.GIB, 12 * storage.GIB, False)["prune"])

    def test_successful_command_does_not_mean_capacity_recovered(self):
        self.assertFalse(storage.recovered(10, 20, 50))
        self.assertTrue(storage.recovered(10, 60, 50))

    def test_cache_sizes_are_parsed_without_guessing_unknown_units(self):
        self.assertEqual(storage.size_bytes("1.5GB"), 1500000000)
        self.assertEqual(storage.size_bytes("2GiB"), 2 * storage.GIB)
        with self.assertRaises(ValueError):
            storage.size_bytes("unknown")

    def test_df_uses_available_blocks_not_used_percentage(self):
        self.assertEqual(storage.parse_df("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vdb1 100 80 15 85% /var/lib/docker\n"), (102400, 15360))


class MaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.commands = []
        self.free = 40 * storage.GIB
        self.cache = "2GB"
        self.failure = None
        self.host_free = 40 * storage.GIB
        self.du_total = True
        self.endpoint = "unix:///var/run/docker.sock"

    def run_docker(self, argv, timeout=12):
        self.commands.append(argv)
        if "ps" in argv:
            return "a" * 64
        if argv[-4:-2] == ["buildx", "du"]:
            return f"Reclaimable:\t{self.cache}\n" + (f"Total:\t\t{self.cache}\n" if self.du_total else "")
        if "df" in argv and "-Pk" in argv:
            return f"Filesystem blocks Used Available Capacity Mounted\n/dev/vdb1 {100 * storage.GIB // 1024} 0 {self.free // 1024} 0% /\n"
        if "system" in argv:
            return storage.json.dumps({"Type": "Build Cache", "Size": self.cache})
        if "info" in argv:
            return storage.json.dumps([{"Name": "buildx", "Path": "/usr/libexec/docker/cli-plugins/docker-buildx"}])
        if "--help" in argv:
            return "--max-used-space --min-free-space --reserved-space --builder"
        if "context" in argv:
            if "inspect" in argv:
                return storage.json.dumps(self.endpoint)
            return argv[argv.index("--context") + 1] if "--context" in argv else "default"
        if "prune" in argv:
            if self.failure:
                raise RuntimeError(self.failure)
            return "Total reclaimed space: 0B"
        raise AssertionError(argv)

    def measure_host(self, path):
        return {"capacity_bytes": 500 * storage.GIB, "free_bytes": self.host_free,
                "target_free_bytes": 20 * storage.GIB, "pressure": self.host_free < 20 * storage.GIB}

    def maintain(self):
        return storage.maintain(pathlib.Path("/tmp/install/compose.env"), True, self.run_docker, self.measure_host)

    # `system df` sizes every volume: on a host holding 274 GB of them it took 9
    # of its 12 seconds idle, and a Docker busy with an upgrade timed it out and
    # refused the build (2026-11-03). The host's cache is read from Buildx alone.
    def test_host_cache_is_measured_without_sizing_every_volume(self):
        self.cache = "12GB"
        report = self.maintain()
        host = report["builders"][0]
        self.assertEqual((host["name"], host["cache_bytes"]), ("host", 12 * 1000**3))
        self.assertIn(["docker", "--context", "default", "buildx", "du", "--builder", "default"], self.commands)
        self.assertFalse(any(c[:4] == ["docker", "--context", "default", "system"] for c in self.commands))

    def test_owned_orbstack_quota_bounds_cleanup_even_when_df_reports_the_shared_disk(self):
        # The real isolated machine enforced 4 GiB while df reported 2.4 TiB.
        # Both writable layers and volumes must use the quota's remaining room.
        self.endpoint = "ssh://root%40ryker-worker@orb"
        report = storage.maintain(
            pathlib.Path("/tmp/install/compose.env"), True, self.run_docker, self.measure_host,
            context="orbstack-ryker-worker", orbstack_machine="ryker-worker",
            measure_quota=lambda: (4 * storage.GIB, storage.GIB))
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["docker"]["capacity_bytes"], 4 * storage.GIB)
        self.assertEqual(report["docker"]["free_bytes"], storage.GIB)

    def test_an_unrelated_ssh_endpoint_cannot_be_treated_as_local_orbstack_storage(self):
        self.endpoint = "ssh://root@another-host"
        report = storage.maintain(
            pathlib.Path("/tmp/install/compose.env"), True, self.run_docker, self.measure_host,
            context="orbstack-ryker-worker", orbstack_machine="ryker-worker")
        self.assertTrue(report["errors"])
        self.assertFalse(any("prune" in command for command in self.commands))

    def test_host_cache_without_a_total_is_a_failed_measurement(self):
        self.du_total = False
        report = self.maintain()
        self.assertIn("host: Docker cache measurement or cleanup failed", report["errors"])
        self.assertFalse(storage.build_ready(report))

    def test_healthy_install_runs_no_mutating_commands(self):
        report = self.maintain()
        self.assertEqual(storage.summary(report), "")
        self.assertFalse(any("prune" in c for c in self.commands))

    def test_separate_pool_maintenance_never_selects_the_controller_daemon(self):
        self.cache = "12GB"
        compose_file = pathlib.Path("/tmp/install/pool-compose.yml")
        report = storage.maintain(pathlib.Path("/tmp/install/pool/compose.env"), True,
                                 self.run_docker, self.measure_host,
                                 context="orbstack-ryker-worker", compose_file=compose_file)
        self.assertEqual(report["errors"], [])
        self.assertFalse(any(c == ["docker", "context", "show"] for c in self.commands))
        selected = [c for c in self.commands if "compose" in c]
        self.assertEqual(selected[0][1:3], ["--context", "orbstack-ryker-worker"])
        self.assertIn(str(compose_file), selected[0])
        for command in [c for c in self.commands if "--force" in c]:
            self.assertEqual(command[1:3], ["--context", "orbstack-ryker-worker"])

    def test_cache_pressure_targets_both_correct_daemons_only(self):
        self.cache = "12GB"
        report = self.maintain()
        prunes = [c for c in self.commands if "--force" in c]
        self.assertEqual(len(prunes), 2)
        self.assertEqual(prunes[0][:5], ["docker", "--context", "default", "builder", "prune"])
        self.assertEqual(prunes[1][:13], ["docker", "--context", "default", "exec", "a" * 64, "timeout", "-s", "TERM", "-k", "2", "16", "/usr/libexec/docker/cli-plugins/docker-buildx", "prune"])
        self.assertTrue(all(b["pruned"] for b in report["builders"]))
        self.assertFalse(any("rm" in c or "volume" in c or "restart" in c for c in self.commands))

    def test_cli_success_with_zero_reclaimed_bytes_keeps_pressure_visible(self):
        self.free = 2 * storage.GIB
        report = self.maintain()
        self.assertIn("docker disk", storage.summary(report))
        self.assertTrue(all(not b["recovered"] for b in report["builders"]))

    def test_failed_cleanup_attempts_other_daemon_and_preserves_failure(self):
        self.free = 2 * storage.GIB
        self.failure = "Docker command failed (exit 1)"
        report = self.maintain()
        self.assertEqual(len(report["errors"]), 2)
        self.assertTrue(all(not b["pruned"] for b in report["builders"]))

    def test_host_pressure_is_visible_when_vm_has_room(self):
        self.host_free = storage.GIB
        report = self.maintain()
        self.assertIn("host disk", storage.summary(report))
        self.assertTrue(all(b["pruned"] for b in report["builders"]))
        for args in (c for c in self.commands if "--force" in c):
            self.assertEqual(args[args.index("--max-used-space") + 1], "1")

    def test_build_reserve_is_checked_on_both_filesystems(self):
        self.assertTrue(storage.build_ready(self.maintain()))
        self.host_free = storage.GIB
        self.assertFalse(storage.build_ready(self.maintain()))
        self.host_free = 40 * storage.GIB
        self.free = storage.GIB
        self.assertFalse(storage.build_ready(self.maintain()))

    def test_unsupported_prune_never_falls_back_to_unbounded_deletion(self):
        self.free = storage.GIB
        def old_docker(argv, timeout=12):
            return "--force" if "--help" in argv else self.run_docker(argv, timeout)
        report = storage.maintain(pathlib.Path("/tmp/install/compose.env"), True, old_docker, self.measure_host)
        self.assertEqual(len(report["errors"]), 2)
        self.assertFalse(any("--force" in c for c in self.commands))

    def test_missing_nested_daemon_does_not_disable_outer_cache_recovery(self):
        self.cache = "20GB"
        def missing_worker(argv, timeout=12):
            return "" if "ps" in argv else self.run_docker(argv, timeout)
        report = storage.maintain(pathlib.Path("/tmp/install/compose.env"), True, missing_worker, self.measure_host)
        self.assertFalse(storage.build_ready(report))
        self.assertEqual(len(report["builders"]), 1)
        self.assertTrue(report["builders"][0]["pruned"])
        self.assertIn("unavailable", storage.summary(report))

    def test_local_pressure_cannot_prune_a_remote_docker_context(self):
        self.host_free = storage.GIB
        def remote_context(argv, timeout=12):
            if "context" in argv and "inspect" in argv:
                return '"ssh://another-host"'
            return self.run_docker(argv, timeout)
        report = storage.maintain(pathlib.Path("/tmp/install/compose.env"), True, remote_context, self.measure_host)
        self.assertIn("local Unix Docker endpoint", storage.summary(report))
        self.assertFalse(any("prune" in c or "exec" in c for c in self.commands))

    def test_missing_filesystem_measurement_is_unknown_not_healthy(self):
        for text in ("", "Filesystem\n/dev\n", "Filesystem\n/dev a b c\n"):
            with self.assertRaises(ValueError):
                storage.parse_df(text)


class ProcessDeadlineTest(unittest.TestCase):
    def test_read_only_measurements_cannot_postpone_maintenance(self):
        with tempfile.TemporaryDirectory() as folder:
            env_file = pathlib.Path(folder) / "compose.env"
            env_file.write_text("")
            calls = []
            def measure(path, apply, run):
                calls.append(apply)
                return {"version": 1, "measured_at": int(storage.time.time()), "errors": [],
                        "host": {"free_bytes": 40 * storage.GIB, "target_free_bytes": 20 * storage.GIB}}
            with patch.object(storage, "maintain", measure), contextlib.redirect_stdout(io.StringIO()):
                for mode in ([], ["--maintain"], ["--maintain"]):
                    with patch.object(sys, "argv", ["storage", "--env-file", str(env_file)] + mode):
                        storage.main()
            self.assertEqual(calls, [False, True])

    def test_concurrent_maintenance_never_clears_a_pressure_alarm(self):
        with tempfile.TemporaryDirectory() as folder:
            install = pathlib.Path(folder)
            env_file = install / "compose.env"
            env_file.write_text("")
            state = install / "storage"
            state.mkdir()
            with (state / "maintenance.lock").open("a") as lock:
                storage.fcntl.flock(lock, storage.fcntl.LOCK_EX)
                args = [sys.executable, "-B", str(pathlib.Path(storage.__file__)), "--maintain", "--env-file", str(env_file)]
                unknown = storage.subprocess.check_output(args, text=True)
                self.assertIn("no recent capacity measurement", unknown)
                report = {"measured_at": int(storage.time.time()), "errors": [],
                          "host": {"free_bytes": storage.GIB, "target_free_bytes": 20 * storage.GIB}}
                (state / "status.json").write_text(storage.json.dumps(report))
                pressure = storage.subprocess.check_output(args, text=True)
                self.assertIn("host disk", pressure)

    def test_deadline_closes_the_plugin_child_before_releasing_cleanup(self):
        # Killing only Docker's CLI leaves its Buildx child running after the
        # maintenance lock is released. A held FIFO proves that child is gone.
        with tempfile.TemporaryDirectory() as folder:
            fifo = pathlib.Path(folder) / "plugin"
            pid_file = pathlib.Path(folder) / "pid"
            storage.os.mkfifo(fifo)
            reader = storage.os.open(fifo, storage.os.O_RDONLY | storage.os.O_NONBLOCK)
            child = """import os, sys, time
pid = os.fork()
if pid == 0:
    with open(sys.argv[2], 'w') as f:
        f.write(str(os.getpid()))
    fd = os.open(sys.argv[1], os.O_WRONLY)
    os.write(fd, b'ready')
    time.sleep(60)
else:
    time.sleep(60)
"""
            try:
                with self.assertRaises(storage.subprocess.TimeoutExpired):
                    storage.command([sys.executable, "-c", child, str(fifo), str(pid_file)], timeout=2)
                self.assertEqual(storage.os.read(reader, 1024), b"ready")
                try:
                    self.assertEqual(storage.os.read(reader, 1), b"")
                except BlockingIOError:
                    # Clean up only the test child whose live FIFO proved the bug.
                    storage.os.kill(int(pid_file.read_text()), storage.signal.SIGKILL)
                    self.fail("plugin child survived its CLI timeout")
            finally:
                storage.os.close(reader)


if __name__ == "__main__":
    unittest.main()
