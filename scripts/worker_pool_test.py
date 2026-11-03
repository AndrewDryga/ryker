"""Containment cannot depend on the current Docker context or erase old custody."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import worker_pool as pool


def ready_worker():
    return {"state": "eligible", "workspace": "ryker-compose", "protocol": "2", "age": 1,
            "drain_requested_at": None, "admission_stopped_at": "2026-11-03T10:00:00Z",
            "admission_stopped_by": "operator:worker-pool",
            "capabilities": [{"name": "controller-tools", "version": "1"}],
            "capacity": {"state": "eligible", "session_slots_free": 1,
                         "turn_slots_free": 1, "workspace_slots_free": 1}}


def operator():
    subject = object.__new__(pool.Pool)
    subject.state = {"phase": "qualified", "context": pool.CONTEXT, "controller_context": "controller",
                     "controller_endpoint": "unix:///controller.sock"}
    subject.save = Mock()
    subject.verify = Mock()
    subject.missing_accounts = Mock(return_value=[])
    subject.wait_qualified = Mock(return_value=ready_worker())
    subject.status = Mock(return_value={"phase": "active"})
    subject.release = Mock(return_value={})
    subject.lifecycle = Mock(return_value={})
    subject.compose = Mock(return_value=["docker", "--context", pool.CONTEXT, "compose"])
    subject.seed_file = Mock()
    subject.worker_status = Mock(return_value=ready_worker())
    return subject


class CapacityTest(unittest.TestCase):
    def test_sparse_disks_memory_and_controller_reserve_all_need_physical_headroom(self):
        self.assertEqual(pool.required_free(), 74 * pool.GIB)
        self.assertEqual(pool.required_free(allocated=12 * pool.GIB), 62 * pool.GIB)
        self.assertEqual(pool.required_free(allocated=100 * pool.GIB), 22 * pool.GIB)

    def test_private_host_routes_cannot_be_shadowed_by_worker_docker_networks(self):
        pool.check_route_ranges("Destination Gateway\ndefault 192.168.1.1\n100.64/10 link#1\n192.168.1/24 link#2")
        for route in ("10/8", "10.240/16", "10.241.18/24", "10.240.0.5"):
            with self.assertRaisesRegex(RuntimeError, "overlap"):
                pool.check_route_ranges(route + " link#1")

    def test_pool_accepts_only_fresh_qualified_capacity_and_preserves_the_hold(self):
        self.assertTrue(pool.qualified(ready_worker(), require_hold=True))
        for field, value in (("age", None), ("age", 60), ("state", "revoked"),
                             ("workspace", "foreign"), ("protocol", "1"),
                             ("admission_stopped_at", None), ("drain_requested_at", "now"),
                             ("capabilities", [])):
            worker = ready_worker()
            worker[field] = value
            self.assertFalse(pool.qualified(worker, require_hold=True), field)
        worker = ready_worker()
        worker["capacity"]["workspace_slots_free"] = 0
        self.assertFalse(pool.qualified(worker, require_hold=True))


class NetworkBootTest(unittest.TestCase):
    def test_guest_dns_uses_the_allocated_address_and_unexpected_topology_never_applies_rules(self):
        # The first source-configured VM received .4 while the earlier proof
        # held .3. Requiring .3 correctly refused Docker, but prevented boot.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy.nft"
            policy.write_bytes((pool.FILES / "network.nft").read_bytes())
            commands = {
                "ip": '#!/bin/sh\ncase "$*" in "-4 route show default") printf "%s\\n" "$TEST_ROUTE";; "-6 route show default") printf "%s" "$TEST_IPV6";; *) printf "%s\\n" "$TEST_GUEST";; esac\n',
                "mktemp": '#!/bin/sh\nexec /usr/bin/mktemp "$TEST_ROOT/batch.XXXXXX"\n',
                "nft": '#!/bin/sh\ncase "$1" in list) exit 1;; --check) exit 0;; -f) cp "$2" "$TEST_ROOT/applied";; *) exit 90;; esac\n',
            }
            for name, content in commands.items():
                path = root / name
                path.write_text(content)
                path.chmod(0o700)
            script = (pool.FILES / "network.sh").read_text().replace(
                "cat /etc/ryker-worker-network.nft", "cat " + shlex.quote(str(policy)))
            env = {**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                   "TEST_ROOT": str(root), "TEST_ROUTE": "default via 192.168.5.2 dev eth0 proto dhcp",
                   "TEST_GUEST": "2: eth0 inet 192.168.5.4/24", "TEST_IPV6": ""}
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("define guest_ipv4 = 192.168.5.4", (root / "applied").read_text())
            for updates in ({"TEST_GUEST": "2: eth0 inet 192.168.5.2/24"},
                            {"TEST_GUEST": "2: eth0 inet 10.240.0.4/24"},
                            {"TEST_GUEST": "2: eth0 inet 192.168.5.4/24\n2: eth0 inet 192.168.5.5/24"},
                            {"TEST_ROUTE": "default via 192.168.5.9 dev eth0"},
                            {"TEST_IPV6": "default via fe80::1 dev eth0"}):
                (root / "applied").unlink(missing_ok=True)
                result = subprocess.run(["sh", "-c", script], env={**env, **updates}, capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0, updates)
                self.assertFalse((root / "applied").exists())


class EnrollmentTest(unittest.TestCase):
    def test_expired_token_before_first_enrollment_still_creates_a_held_worker(self):
        subject = operator()
        subject.state["phase"] = "creating"
        subject.state["token_expires_at"] = time.time() - 10
        subject.release.return_value = {"token": "private-one-time-token", "expires_at": "2099-01-01T00:00:00Z"}
        with patch.object(pool, "run", return_value="absent\n"):
            subject.enroll()
        self.assertIn("stop_admission: true", subject.release.call_args.args[0])
        subject.seed_file.assert_called_once_with("enrollment-token", b"private-one-time-token")

    def test_identity_recovery_after_activation_does_not_replace_operator_admission(self):
        subject = operator()
        subject.state["phase"] = "active"
        subject.release.return_value = {"token": "private-token", "expires_at": "2099-01-01T00:00:00Z"}
        with patch.object(pool, "run", return_value="absent\n"):
            subject.enroll()
        self.assertIn("stop_admission: false", subject.release.call_args.args[0])

    def test_unexpired_bootstrap_token_is_reused(self):
        subject = operator()
        subject.state["token_expires_at"] = time.time() + 300
        with patch.object(pool, "run", return_value="absent\n"):
            subject.enroll()
        subject.release.assert_not_called()
        subject.seed_file.assert_not_called()

    def test_expiry_validation_remains_owned_by_the_worker(self):
        for status in ("expired\n", "invalid\n"):
            subject = operator()
            with patch.object(pool, "run", return_value=status), self.assertRaises(RuntimeError):
                subject.enroll()
            subject.release.assert_not_called()
            subject.seed_file.assert_not_called()

    def test_invalid_identity_command_never_mints_a_replacement(self):
        subject = operator()
        with patch.object(pool, "run", side_effect=RuntimeError("invalid identity")), self.assertRaises(RuntimeError):
            subject.enroll()
        subject.release.assert_not_called()


class CutoverTest(unittest.TestCase):
    def test_interrupted_old_worker_stop_keeps_new_custody_and_retries_only_the_stop(self):
        subject = operator()
        subject.lifecycle.side_effect = [RuntimeError("controller unavailable"), {}]
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            subject.activate()
        self.assertEqual(subject.state["phase"], "active")
        self.assertIn("resume_worker_admission", subject.release.call_args.args[0])
        subject.activate()
        self.assertEqual(subject.release.call_count, 1)
        self.assertEqual(subject.lifecycle.call_count, 2)
        for call in subject.lifecycle.call_args_list:
            self.assertEqual(call.args, ("stop_admission",))
            self.assertEqual(call.kwargs, {"worker": "ryker-compose"})

    def test_activation_cannot_clear_a_hold_owned_by_another_operator(self):
        subject = operator()
        subject.wait_qualified.return_value["admission_stopped_by"] = "operator:investigation"
        with self.assertRaisesRegex(RuntimeError, "another operator"):
            subject.activate()
        subject.release.assert_not_called()
        subject.lifecycle.assert_not_called()
        self.assertEqual(subject.state["phase"], "qualified")

    def test_activation_recovers_a_lost_local_save_after_the_controller_released_its_hold(self):
        subject = operator()
        subject.state.update(phase="activating", activation_hold="2026-11-03T10:00:00Z")
        subject.wait_qualified.return_value["admission_stopped_at"] = None
        subject.wait_qualified.return_value["admission_stopped_by"] = None
        subject.activate()
        self.assertEqual(subject.state["phase"], "active")
        subject.release.assert_not_called()
        subject.lifecycle.assert_called_once_with("stop_admission", worker="ryker-compose")

    def test_retry_does_not_release_a_new_hold_even_with_the_same_operator_name(self):
        subject = operator()
        subject.state.update(phase="activating", activation_hold="2026-11-03T09:00:00Z")
        with self.assertRaisesRegex(RuntimeError, "another operator"):
            subject.activate()
        subject.release.assert_not_called()
        subject.lifecycle.assert_not_called()

    def test_cutover_requires_separate_sign_ins_for_every_configured_account(self):
        subject = operator()
        subject.missing_accounts.return_value = ["codex@default"]
        with self.assertRaisesRegex(RuntimeError, "own model-login"):
            subject.activate()
        subject.release.assert_not_called()
        subject.lifecycle.assert_not_called()
        subject.wait_qualified.assert_not_called()

    def test_account_readiness_uses_current_controller_configuration(self):
        subject = operator()
        del subject.missing_accounts
        subject.sql = Mock(return_value='["codex@default", "claude@work"]')
        subject.state["signed_in_accounts"] = ["codex@default"]
        self.assertEqual(subject.missing_accounts(), ["claude@work"])
        subject.sql.return_value = '[]'
        with self.assertRaisesRegex(RuntimeError, "no valid model account"):
            subject.missing_accounts()

    def test_state_is_private_atomic_and_refuses_a_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "state.json"
            pool.atomic_json(path, {"phase": "qualified"})
            pool.atomic_json(path, {"phase": "active"})
            self.assertEqual(pool.read_private_json(path), {"phase": "active"})
            link = Path(root) / "link"
            link.symlink_to(path)
            with self.assertRaises(RuntimeError):
                pool.read_private_json(link)
            self.assertEqual(list(Path(root).glob("*.tmp")), [])

    def test_controller_context_drift_stops_before_contacting_another_daemon(self):
        subject = operator()
        with patch.object(pool, "run", return_value="unix:///another.sock\n"), self.assertRaisesRegex(RuntimeError, "context changed"):
            subject.controller()


class HeadroomRecoveryTest(unittest.TestCase):
    def test_lost_hold_response_can_be_recovered_after_host_space_returns(self):
        subject = operator()
        subject.state["phase"] = "active"
        subject.check_headroom = Mock(side_effect=RuntimeError("host reserve reached"))
        def acquired_before_response(action, actor):
            subject.worker_status.return_value.update(
                admission_stopped_by=actor, admission_stopped_at="2026-11-03T10:00:00.12345+00:00")
            raise RuntimeError("response lost")
        subject.lifecycle.side_effect = acquired_before_response
        with self.assertRaisesRegex(RuntimeError, "response lost"):
            subject.reconcile_headroom()
        receipt = subject.state["headroom_hold"]
        self.assertNotIn("at", receipt)
        subject.save.assert_called_once()
        subject.check_headroom.side_effect = None
        subject.check_headroom.return_value = {"free_bytes": 80 * pool.GIB}
        subject.reconcile_headroom()
        self.assertIn(receipt["actor"], subject.release.call_args.args[0])
        self.assertNotIn("headroom_hold", subject.state)

    def test_pressure_recovery_preserves_a_replacement_operator_hold(self):
        subject = operator()
        subject.state["headroom_hold"] = {"actor": "operator:worker-pool-host-space:old",
                                           "at": "2026-11-03T10:00:00Z"}
        subject.check_headroom = Mock(return_value={})
        subject.reconcile_headroom()
        subject.release.assert_not_called()
        self.assertNotIn("headroom_hold", subject.state)

    def test_new_admission_is_held_even_when_vm_inspection_is_unavailable(self):
        subject = operator()
        subject.state["phase"] = "active"
        subject.check_headroom = Mock(side_effect=RuntimeError("host reserve reached"))
        subject.lifecycle.side_effect = lambda action, actor: {
            "admission_stopped_by": actor, "admission_stopped_at": "2026-11-03T10:00:00Z"}
        subject.verify.side_effect = RuntimeError("VM unavailable")
        with self.assertRaisesRegex(RuntimeError, "VM unavailable"):
            subject.maintain()
        self.assertEqual(subject.state["headroom_hold"]["at"], "2026-11-03T10:00:00Z")


class MonitoringTest(unittest.TestCase):
    def test_healthy_disks_cannot_hide_an_unavailable_active_pool(self):
        subject = operator()
        subject.state.update(phase="active", trimmed_at=time.time(), colima_home="/tmp")
        subject.env_file = Path("/tmp/pool-monitoring.env")
        subject.reconcile_headroom = Mock(return_value=({}, None))
        subject.enroll = Mock()
        for worker in (None, {**ready_worker(), "age": 90}, {**ready_worker(), "state": "revoked"}):
            subject.worker_status.return_value = worker
            with patch.object(pool.storage_maintenance, "maintain", return_value={"errors": []}):
                self.assertIn("pool worker is not reporting fresh eligible capacity", subject.maintain())
        subject.worker_status.return_value = ready_worker()
        with patch.object(pool.storage_maintenance, "maintain", return_value={"errors": []}):
            self.assertEqual(subject.maintain(), "")

    def test_worker_health_alarm_does_not_block_a_repair_upgrade_with_healthy_storage(self):
        subject = operator()
        subject.state.update(phase="active", trimmed_at=time.time(), colima_home="/tmp")
        subject.env_file = Path("/tmp/pool-monitoring.env")
        subject.reconcile_headroom = Mock(return_value=({}, None))
        subject.enroll = Mock()
        busy = ready_worker()
        busy["capacity"]["turn_slots_free"] = 0
        for worker in (busy, {**ready_worker(), "state": "offline"}):
            subject.worker_status.return_value = worker
            disk = {"free_bytes": 20 * pool.GIB, "capacity_bytes": 32 * pool.GIB,
                    "target_free_bytes": 12 * pool.GIB}
            with patch.object(pool.storage_maintenance, "maintain", return_value={
                    "errors": [], "host": disk, "docker": disk}):
                self.assertIn("fresh eligible capacity", subject.maintain())
            self.assertTrue(pool.storage_maintenance.build_ready(subject.state["maintenance"]["storage"]))


class MissingInstallTest(unittest.TestCase):
    def test_interactive_commands_require_installation_but_optional_hooks_remain_noops(self):
        with tempfile.TemporaryDirectory() as directory:
            for command in ("activate", "model-login", "start", "maintain", "upgrade"):
                result = subprocess.run([pool.sys.executable, "-B", str(pool.ROOT / "scripts/worker_pool.py"),
                                         command, "--state-dir", directory], capture_output=True, check=False)
                if command in ("maintain", "upgrade"):
                    self.assertEqual(result.returncode, 0)
                else:
                    self.assertNotEqual(result.returncode, 0, command)
                    self.assertIn(b"worker_pool.py install", result.stderr)


class DeliveryTest(unittest.TestCase):
    def test_interrupted_image_pin_keeps_the_previous_complete_environment(self):
        subject = operator()
        with tempfile.TemporaryDirectory() as directory:
            subject.env_file = Path(directory) / "compose.env"
            subject.write_env("ryker-coop:11111111-aaaaaaaa")
            before = subject.env_file.read_bytes()
            with patch.object(pool.os, "replace", side_effect=OSError("interrupted")), \
                 self.assertRaises(OSError):
                subject.write_env("ryker-coop:22222222-bbbbbbbb")
            self.assertEqual(subject.env_file.read_bytes(), before)

    def test_abandoned_enrollment_delivery_never_blocks_a_new_atomic_delivery(self):
        subject = operator()
        del subject.seed_file
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            orphan = root / ".enrollment-token.tmp"
            orphan.write_text("interrupted previous delivery")
            def execute(argv, data, timeout):
                script = argv[-1].replace("/var/lib/ryker-coop", directory).replace("chown 1000:1000", "true")
                subprocess.run(["sh", "-ec", script], input=data, check=True, capture_output=True)
            with patch.object(pool, "run", side_effect=execute):
                subject.seed_file("enrollment-token", b"new-private-token")
            self.assertEqual((root / "enrollment-token").read_bytes(), b"new-private-token")
            self.assertEqual(orphan.read_text(), "interrupted previous delivery")


class BootstrapTest(unittest.TestCase):
    def test_empty_pool_bootstraps_through_the_entrypoint_without_a_previous_box_context(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = operator()
            subject.state.update(phase="creating", colima_home=directory, owner="fixture-owner")
            subject.check_headroom = Mock()
            subject.image = Mock(return_value="ryker-coop:22222222-bbbbbbbb")
            subject.copy_image = Mock()
            subject.write_env = Mock()
            subject.enroll = Mock()
            subject.prewarm = Mock(side_effect=RuntimeError("no previous box context"))
            subject.install_startup = Mock()
            with patch.object(pool, "run", return_value="-----BEGIN CERTIFICATE-----"), \
                 patch.object(subject, "controller", return_value=["controller"]):
                subject.install()
            subject.prewarm.assert_not_called()
            self.assertEqual(subject.state["phase"], "qualified")

    def test_restart_preserves_a_replacement_not_yet_pinned_after_interruption(self):
        subject = operator()
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            profile = home / pool.PROFILE
            profile.mkdir()
            (profile / ".ryker-owner").write_text("fixture-owner")
            subject.state.update(colima_home=directory, owner="fixture-owner",
                                 image="ryker-coop:11111111-aaaaaaaa",
                                 upgrade_image="ryker-coop:22222222-bbbbbbbb")
            subject.check_headroom = Mock()
            subject.running_image = Mock(return_value=("a" * 64, subject.state["upgrade_image"]))
            with patch.object(pool, "run") as command:
                subject.start()
            calls = [call.args[0] for call in command.call_args_list]
            self.assertFalse(any("up" in call for call in calls))
            self.assertIn(subject.compose() + ["start", "ryker-coop-docker", "ryker-coop"], calls)


class UpgradeTest(unittest.TestCase):
    def prepared(self):
        subject = operator()
        subject.image = Mock(return_value="ryker-coop:22222222-bbbbbbbb")
        subject.running_image = Mock(return_value=("a" * 64, "ryker-coop:11111111-aaaaaaaa"))
        subject.check_headroom = Mock()
        subject.maintain = Mock()
        subject.state["maintenance"] = {"storage": {}}
        subject.copy_image = Mock()
        subject.prewarm = Mock()
        subject.sql = Mock(return_value="0")
        subject.native_quiescent = Mock(return_value=True)
        subject.resume_upgrade = Mock()
        subject.write_env = Mock()
        subject.remove_old_images = Mock()
        subject.lifecycle.return_value = {"status": "draining", "drain_requested_at": "2026-11-03T10:00:00Z"}
        return subject

    def test_native_work_prevents_restart_and_releases_only_the_owned_drain(self):
        subject = self.prepared()
        subject.native_quiescent.return_value = False
        with patch.object(pool, "run", return_value="ryker-worker_state") as command, \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True), \
             patch.object(pool.time, "monotonic", side_effect=[0, 601]), \
             self.assertRaisesRegex(RuntimeError, "work in flight"):
            subject.upgrade()
        self.assertFalse(any("up" in call.args[0] for call in command.call_args_list))
        subject.write_env.assert_not_called()
        self.assertEqual(subject.resume_upgrade.call_count, 2)
        self.assertTrue(subject.state["upgrade_drain"]["actor"].startswith("operator:worker-upgrade:pool:"))

    def test_unknown_native_custody_is_not_treated_as_idle(self):
        subject = self.prepared()
        subject.native_quiescent.side_effect = RuntimeError("cannot inspect native work")
        with patch.object(pool, "run", return_value="ryker-worker_state") as command, \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True), \
             self.assertRaisesRegex(RuntimeError, "cannot inspect"):
            subject.upgrade()
        self.assertFalse(any("up" in call.args[0] for call in command.call_args_list))
        self.assertEqual(subject.resume_upgrade.call_count, 2)

    def test_an_existing_operator_drain_is_never_acquired_or_released_by_an_upgrade(self):
        subject = self.prepared()
        subject.lifecycle.return_value = {"status": "duplicate"}
        with patch.object(pool, "run", return_value="ryker-worker_state"), \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True), \
             self.assertRaisesRegex(RuntimeError, "already drained"):
            subject.upgrade()
        subject.resume_upgrade.assert_called_once()
        self.assertNotIn("at", subject.state["upgrade_drain"])

    def test_a_replacement_is_pinned_only_after_qualified_capacity_returns(self):
        subject = self.prepared()
        subject.wait_qualified.side_effect = RuntimeError("worker is not qualified")
        with patch.object(pool, "run", return_value="ryker-worker_state"), \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True), \
             self.assertRaisesRegex(RuntimeError, "not qualified"):
            subject.upgrade()
        self.assertEqual(subject.resume_upgrade.call_count, 2)
        subject.write_env.assert_not_called()
        subject.remove_old_images.assert_not_called()

    def test_interrupted_drain_acquisition_recovers_its_exact_controller_receipt(self):
        subject = operator()
        subject.state["upgrade_drain"] = {"actor": "operator:worker-upgrade:pool:unique"}
        subject.worker_status.return_value.update(
            drain_requested_by="operator:worker-upgrade:pool:unique",
            drain_requested_at="2026-11-03T10:00:00+00:00")
        subject.acquire_upgrade()
        subject.lifecycle.assert_not_called()
        self.assertEqual(subject.state["upgrade_drain"]["at"], "2026-11-03T10:00:00+00:00")
        # PostgreSQL and the release encode the same instant differently.
        subject.state["upgrade_drain"]["at"] = "2026-11-03T10:00:00Z"
        subject.resume_upgrade()
        self.assertNotIn("upgrade_drain", subject.state)
        subject.release.assert_called_once()

    def test_interrupted_resume_does_not_leave_an_unrecoverable_local_drain(self):
        subject = operator()
        subject.state["upgrade_drain"] = {"actor": "operator:worker-upgrade:pool:unique",
                                           "at": "2026-11-03T10:00:00Z"}
        subject.resume_upgrade()
        self.assertNotIn("upgrade_drain", subject.state)
        subject.release.assert_not_called()

    def test_auth_restart_preserves_the_previous_distinct_worker_image(self):
        subject = self.prepared()
        subject.running_image.return_value = ("a" * 64, subject.image())
        subject.state["previous_image"] = "ryker-coop:11111111-aaaaaaaa"
        with patch.object(pool, "run", return_value="ryker-worker_state"), \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True):
            subject.upgrade(force_restart=True)
        self.assertEqual(subject.state["previous_image"], "ryker-coop:11111111-aaaaaaaa")

    def test_native_probe_requires_successful_nonempty_evidence(self):
        subject = operator()
        for code, output in ((1, b""), (0, b"")):
            with patch.object(pool.subprocess, "run", return_value=Mock(returncode=code, stdout=output)), \
                 self.assertRaisesRegex(RuntimeError, "cannot be inspected"):
                subject.native_quiescent("image", "volume")
        with patch.object(pool.subprocess, "run", return_value=Mock(returncode=3, stdout=b"busy")):
            self.assertFalse(subject.native_quiescent("image", "volume"))


if __name__ == "__main__":
    unittest.main()
