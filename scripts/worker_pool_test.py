"""Containment cannot depend on the current Docker context or erase old custody."""
import json
import os
from pathlib import Path
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
    subject.state = {"phase": "qualified", "context": "deployment-engine", "controller_context": "controller",
                     "controller_endpoint": "unix:///controller.sock"}
    subject.save = Mock()
    subject.verify = Mock()
    subject.verify_engine = Mock()
    subject.missing_accounts = Mock(return_value=[])
    subject.wait_qualified = Mock(return_value=ready_worker())
    subject.status = Mock(return_value={"phase": "active"})
    subject.release = Mock(return_value={})
    subject.lifecycle = Mock(return_value={})
    subject.compose = Mock(return_value=["docker", "--context", "deployment-engine", "compose"])
    subject.seed_file = Mock()
    subject.worker_status = Mock(return_value=ready_worker())
    return subject


class CapacityTest(unittest.TestCase):

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


class SharedImageTest(unittest.TestCase):
    def test_retained_upgrade_prunes_only_images_outside_both_workers_pins(self):
        # A shared daemon has two independent rollback histories. Prune old
        # builds without deleting the other worker's way back or pending swap.
        source = (pool.ROOT / "scripts/compose.sh").read_text()
        start = source.index("remove_older_worker_images() {")
        function = source[start:source.index("\n}", start) + 2]
        images = ["ryker-coop:" + str(i) * 8 + "-" + "a" * 8 for i in range(1, 8)]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "worker-pool").mkdir()
            manifest = state / "worker-pool/state.json"
            manifest.write_text(json.dumps({"version": 3, "image": images[2],
                                           "previous_image": images[3], "upgrade_image": images[4]}))
            # Use a file for Docker's inventory; positional args belong to the function.
            inventory = state / "images"
            inventory.write_text("\n".join(images) + "\n")
            script = (function + '\ndocker() { if [ "$2" = ls ]; then cat "$inventory"; fi; }; '
                      'state_dir=$1; inventory=$2; remove_older_worker_images "$3" "$4"')
            result = subprocess.run(["sh", "-c", script, "proof", directory, str(inventory), *images[:2]],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["Removed the older worker image " + image + "." for image in images[5:]])
            manifest.write_text("{}")
            result = subprocess.run(["sh", "-c", script, "proof", directory, str(inventory), *images[:2]],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "", "unreadable pool custody must prevent image deletion")


class ModelLoginTest(unittest.TestCase):
    def test_sign_in_uses_the_prepared_worker_box_without_the_worker_entrypoint(self):
        # The first isolated worker could serve jobs, but its operator could
        # not sign in: compose run bypassed the entrypoint's box selection
        # and requested an unbuilt default Coop image instead.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "coop"
            binary.write_text('#!/bin/sh\n'
                              'if [ "${COOP_BASE_IMAGE-}" != ryker-coop-box ]; then\n'
                              '  echo "default box not built" >&2; exit 1\n'
                              'fi\n'
                              'printf "%s\\n" "$1" "$2" "$COOP_BASE_IMAGE"\n')
            binary.chmod(0o700)
            for inherited in (None, "unrelated-box"):
                with self.subTest(inherited=inherited):
                    env = {**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                           "COOP_CONFIG_DIR": str(root / "agents")}
                    env.pop("COOP_BASE_IMAGE", None)
                    if inherited is not None:
                        env["COOP_BASE_IMAGE"] = inherited
                    result = subprocess.run(
                        ["sh", str(pool.ROOT / "deploy/compose/coop/model-login.sh"), "codex@work"],
                        cwd=root, env=env, capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), ["login", "codex@work", "ryker-coop-box"])


class NativeEngineTest(unittest.TestCase):
    def prepared(self):
        subject = operator()
        del subject.verify_engine
        subject.install_env = Path("/tmp/controller.env")
        subject.state.update(context="deployment-engine", controller_context="deployment-engine",
                             controller_endpoint="unix:///engine.sock", owner="fixture-owner",
                             daemon="engine-identity", configuration=pool.configuration_digest())
        records = [{"Name": name, "Driver": "local", "Options": None,
                    "Labels": {"io.ryker.worker-pool.owner": "fixture-owner"}}
                   for name in ("ryker-worker_state", "ryker-worker_config", "ryker-worker_docker", "ryker-worker_socket")]
        return subject, records

    def command(self, records):
        def run(arguments, **kwargs):
            # The extra VM and capacity reservation blocked a simple migration.
            # A native worker must only inspect the existing Docker engine.
            self.assertEqual(arguments[0], "docker", "native workers must not provision a Linux machine")
            if "context" in arguments:
                return "unix:///engine.sock"
            if "info" in arguments:
                return "engine-identity"
            if "volume" in arguments and "inspect" in arguments:
                return json.dumps(records)
            self.fail("unexpected mutating command during verification")
        return run

    def test_interrupted_install_checks_engine_identity_before_creating_volumes(self):
        subject = operator()
        subject.state["phase"] = "creating"
        subject.create_volumes = Mock()
        subject.verify.side_effect = RuntimeError("engine identity changed")
        subject.verify_engine = subject.verify
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            subject.install()
        subject.create_volumes.assert_not_called()

    def test_install_uses_the_operators_docker_context_on_any_platform(self):
        # A host migration was incorrectly made a product dependency on one
        # desktop runtime. Docker owns endpoint selection and transport.
        for endpoint in ("unix:///engine.sock", "ssh://operator@docker-host", "tcp://docker-host:2376"):
            with self.subTest(endpoint=endpoint):
                subject = operator()
                subject.state = None
                subject.worker_status.return_value = None
                commands = []
                def run(arguments):
                    commands.append(arguments)
                    if arguments == ["docker", "context", "show"]:
                        return "deployment-engine"
                    if arguments[:4] == ["docker", "context", "inspect", "deployment-engine"]:
                        return endpoint
                    if arguments[:4] == ["docker", "--context", "deployment-engine", "info"]:
                        return "engine-identity"
                    raise AssertionError(arguments)
                with patch.dict(os.environ, {}, clear=True), patch.object(pool, "run", side_effect=run):
                    subject.initialize()
                self.assertEqual(subject.state["context"], "deployment-engine")
                self.assertEqual(subject.state["controller_endpoint"], endpoint)
                self.assertEqual(subject.state["daemon"], "engine-identity")
                self.assertTrue(all(command[0] == "docker" for command in commands))

    def test_explicit_docker_host_is_pinned_without_switching_to_the_default_socket(self):
        subject = operator()
        subject.state = None
        subject.worker_status.return_value = None
        endpoint = "tcp://docker-host:2376"
        with patch.dict(os.environ, {"DOCKER_HOST": endpoint, "DOCKER_CONTEXT": ""}, clear=True), \
             patch.object(pool, "run", return_value="engine-identity") as command:
            subject.initialize()
        self.assertIsNone(subject.state["context"])
        self.assertEqual(subject.docker(), ["docker", "--host", endpoint])
        command.assert_called_once_with(["docker", "--host", endpoint, "info", "--format", "{{.ID}}"])

    def test_saved_context_is_not_replaced_by_a_desktop_vendor_default(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "worker-pool").mkdir()
            pool.atomic_json(state / "worker-pool/state.json", {
                "version": 3, "context": "deployment-engine", "controller_context": "deployment-engine",
                "controller_endpoint": "ssh://operator@docker-host", "worker": pool.WORKER,
                "workspace": pool.WORKSPACE, "repository": str(pool.ROOT)})
            subject = pool.Pool(state)
            self.assertEqual(subject.docker(), ["docker", "--context", "deployment-engine"])

    def test_native_engine_needs_no_machine_or_capacity_reservation(self):
        subject, records = self.prepared()
        with patch.object(pool, "run", side_effect=self.command(records)):
            self.assertEqual(pool.Pool.verify(subject), "engine-identity")

    def test_another_installations_volume_is_never_adopted(self):
        subject, records = self.prepared()
        records[0]["Labels"]["io.ryker.worker-pool.owner"] = "someone-else"
        with patch.object(pool, "run", side_effect=self.command(records)), \
             self.assertRaisesRegex(RuntimeError, "another installation"):
            pool.Pool.verify(subject)

    def test_existing_unowned_volumes_prevent_any_creation(self):
        subject, records = self.prepared()
        records[0]["Labels"] = {}
        names = [record["Name"] for record in records]
        def run(arguments):
            if "ls" in arguments:
                return "\n".join(names)
            self.assertNotIn("create", arguments)
            return json.dumps(records)
        with patch.object(pool, "run", side_effect=run), self.assertRaisesRegex(RuntimeError, "another installation"):
            subject.create_volumes()


class StoredStatusTest(unittest.TestCase):
    def test_held_worker_receipt_decodes_canonical_json_and_preserves_utc_authority(self):
        # The first real isolated worker enrolled and passed network checks,
        # then qualification crashed because canonical JSON columns are text.
        # PostgreSQL also emits these UTC timestamp columns without a zone.
        subject = operator()
        del subject.worker_status
        subject.sql = Mock(return_value=(pool.ROOT / "testdata/worker_pool/held_worker_status.json").read_text())
        worker = subject.worker_status()
        self.assertTrue(pool.qualified(worker, require_hold=True))
        self.assertTrue(pool.same_time(worker["admission_stopped_at"], "2026-11-03T12:15:02.381218Z"))


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


class MonitoringTest(unittest.TestCase):
    def test_healthy_disks_cannot_hide_an_unavailable_active_pool(self):
        subject = operator()
        subject.state.update(phase="active")
        subject.env_file = Path("/tmp/pool-monitoring.env")
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
        subject.state.update(phase="active")
        subject.env_file = Path("/tmp/pool-monitoring.env")
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
            subject.state.update(phase="creating", owner="fixture-owner")
            subject.image = Mock(return_value="ryker-coop:22222222-bbbbbbbb")
            subject.write_env = Mock()
            subject.enroll = Mock()
            subject.create_volumes = Mock()
            subject.prewarm = Mock(side_effect=RuntimeError("no previous box context"))
            with patch.object(pool, "run", return_value="-----BEGIN CERTIFICATE-----"), \
                 patch.object(subject, "controller", return_value=["controller"]):
                subject.install()
            subject.prewarm.assert_not_called()
            self.assertEqual(subject.state["phase"], "qualified")

    def test_restart_preserves_a_replacement_not_yet_pinned_after_interruption(self):
        subject = operator()
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            subject.state.update(owner="fixture-owner",
                                 image="ryker-coop:11111111-aaaaaaaa",
                                 upgrade_image="ryker-coop:22222222-bbbbbbbb")
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
        subject.maintain = Mock()
        subject.state["maintenance"] = {"storage": {}}
        subject.prewarm = Mock()
        subject.sql = Mock(return_value="0")
        subject.native_quiescent = Mock(return_value=True)
        subject.resume_upgrade = Mock()
        subject.write_env = Mock()
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
        self.assertFalse(any("cp -a agents" in " ".join(map(str, call.args[0]))
                             for call in command.call_args_list),
                         "worker upgrades must not accumulate automatic sign-in copies")
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

    def test_pool_upgrade_keeps_other_workers_rollback_images(self):
        subject = self.prepared()
        subject.state["previous_image"] = "ryker-coop:11111111-aaaaaaaa"
        def command(arguments, **_kwargs):
            if "ls" in arguments and "image" in arguments:
                return "ryker-coop:33333333-cccccccc\n"
            return "ryker-worker_state"
        with patch.object(pool, "run", side_effect=command), \
             patch.object(pool.subprocess, "run") as mutation, \
             patch.object(pool.storage_maintenance, "build_ready", return_value=True):
            subject.upgrade(force_restart=True)
        mutation.assert_not_called()

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
