"""Check the connection settings shared by the guest connector and firewall."""

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

import launch
from launch import controller_environment


class ControllerSettingsTest(unittest.TestCase):
    def test_private_gateway_uses_the_deployed_host_and_port(self):
        self.assertEqual(
            controller_environment("https://fleet.internal:4322"),
            "RYKER_WORKER_CONTROLLER=https://fleet.internal:4322\n"
            "RYKER_WORKER_HOST=fleet.internal\n"
            "RYKER_WORKER_PORT=4322\n",
        )

    def test_default_https_port(self):
        self.assertIn(
            "RYKER_WORKER_PORT=443\n",
            controller_environment("https://192.0.2.5"),
        )

    def test_rejects_invalid_authorities_and_injection(self):
        for url in (
            "http://fleet.internal",
            "https://fleet.internal:0",
            "https://fleet.internal:65536",
            "https://fleet..internal",
            "https://user@fleet.internal",
            "https://fleet.internal/path",
            "https://fleet.internal:4322;accept",
            "https://fleet.internal\nPORT=22",
        ):
            with self.subTest(url=url), self.assertRaises(SystemExit):
                controller_environment(url)


class ExistingDiskTest(unittest.TestCase):
    # Previously a larger DATA_GIB left an already-enrolled worker at its old size.
    def test_existing_guest_expands_without_replacing_its_disk(self):
        with TemporaryDirectory() as directory:
            state = Path(directory)
            disk = state / "guest.qcow2"
            disk.touch()
            (state / "worker-id").write_text("worker-a\n")
            (state / "initialized").touch()
            key = state / "operator.pub"
            key.write_text("ssh-ed25519 QUJD fixture\n")
            env = dict(WORKER_ID="worker-a", DATA_GIB="300",
                       RYKER_WORKER_CONTROLLER="https://fleet.internal:4322")
            with (
                patch.dict("launch.os.environ", env),
                patch("launch.STATE", state),
                patch("launch.Path", return_value=key),
                patch("launch.os.umask"),
                patch("launch.fcntl.flock", side_effect=lambda lock, _mode: self.addCleanup(lock.close)),
                patch("launch.subprocess.check_output", return_value=b'{"virtual-size":154618822656}'),
                patch("launch.os.statvfs", return_value=SimpleNamespace(f_blocks=334, f_frsize=1024**3)),
                patch("launch.subprocess.run") as run,
                patch("launch.tempfile.TemporaryDirectory", side_effect=SystemExit("start VM")),
                self.assertRaisesRegex(SystemExit, "start VM"),
            ):
                launch.main()
            run.assert_called_once_with(["qemu-img", "resize", "-f", "qcow2", disk, "300G"], check=True)

    def test_larger_existing_disk_keeps_its_capacity_on_rollback(self):
        with patch("launch.subprocess.check_output", return_value=b'{"virtual-size":322122547200}'), \
             patch("launch.subprocess.run") as run:
            launch.grow_disk(Path("/state/guest.qcow2"), 144)
        run.assert_not_called()

    def test_guest_waits_for_backing_filesystem_growth(self):
        with patch("launch.subprocess.check_output", return_value=b'{"virtual-size":154618822656}'), \
             patch("launch.os.statvfs", return_value=SimpleNamespace(f_blocks=160, f_frsize=1024**3)), \
             patch("launch.subprocess.run") as run, \
             self.assertRaisesRegex(SystemExit, "backing filesystem"):
            launch.grow_disk(Path("/state/guest.qcow2"), 300)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
