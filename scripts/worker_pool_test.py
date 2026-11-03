"""Containment cannot depend on the current Docker context or erase old custody."""
import copy
import json
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
    subject.refresh_networks = Mock()
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
    def test_private_cow_growth_memory_and_controller_reserve_all_need_physical_headroom(self):
        self.assertEqual(pool.required_free(), 74 * pool.GIB)
        self.assertEqual(pool.required_free(data_gib=4, memory_gib=1), 19 * pool.GIB)

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


class OrbStackMachineTest(unittest.TestCase):
    def fixture(self):
        return json.loads((pool.ROOT / "testdata/worker_pool/orbstack_machine.json").read_text())

    def test_machine_identity_isolation_and_each_quota_are_verified(self):
        subject = operator()
        subject.state["machine_id"] = "machine-identity"
        info = self.fixture()
        expected = pool.machine_config()
        for key in expected:
            expected[key] = info["record"]["config"][key]
        with patch.object(pool, "run", return_value=json.dumps(info)), \
             patch.object(pool, "machine_config", return_value=expected):
            self.assertEqual(subject.machine_info()["record"]["id"], "machine-identity")
        for key, value in (("isolated", False), ("forward_ssh_agent", True),
                           ("memory_limit_mib", 2048), ("cpu_limit", 8), ("disk_limit_bytes", 0),
                           ("mounts", ["/Users"])):
            changed = copy.deepcopy(info)
            changed["record"]["config"][key] = value
            with patch.object(pool, "run", return_value=json.dumps(changed)), \
                 patch.object(pool, "machine_config", return_value=expected), \
                 self.assertRaisesRegex(RuntimeError, "isolation or resource limits"):
                subject.machine_info()

    def test_start_refuses_a_replaced_machine_before_booting_it(self):
        subject = operator()
        subject.check_headroom = Mock()
        subject.machine_info = Mock(side_effect=RuntimeError("worker machine identity changed"))
        subject.state["image"] = "ryker-coop:11111111-aaaaaaaa"
        subject.running_image = Mock(return_value=("a" * 64, subject.state["image"]))
        with patch.object(pool, "run") as command, \
             self.assertRaisesRegex(RuntimeError, "identity changed"):
            subject.start()
        command.assert_not_called()

    def test_start_waits_for_boot_services_before_verifying_the_worker(self):
        # OrbStack start returned while both boot-required units were inactive;
        # the login agent exited before Docker became ready a second later.
        subject = operator()
        subject.check_headroom = Mock()
        subject.machine_info = Mock()
        subject.guest = Mock(side_effect=[RuntimeError("booting"), "active\nactive"])
        subject.verify = Mock()
        subject.state["image"] = "ryker-coop:11111111-aaaaaaaa"
        subject.running_image = Mock(return_value=("a" * 64, subject.state["image"]))
        with patch.object(pool, "run"), patch.object(pool.time, "sleep"):
            subject.start()
        self.assertEqual(subject.guest.call_count, 2)
        subject.verify.assert_called_once()

    def test_lost_create_response_recovers_only_its_cloud_init_ownership_nonce(self):
        for owner, allowed in (("fixture-owner", True), ("someone-else", False)):
            subject = operator()
            subject.state["owner"] = "fixture-owner"
            subject.machine_info = Mock(return_value={"record": {"id": "machine-identity"}})
            subject.guest = Mock(return_value=owner)
            with tempfile.TemporaryDirectory() as directory:
                subject.directory = Path(directory)
                with patch.object(pool, "run", return_value=json.dumps([{"name": pool.PROFILE}])) as command:
                    if allowed:
                        subject.create_machine()
                        self.assertEqual(subject.state["machine_id"], "machine-identity")
                    else:
                        with self.assertRaisesRegex(RuntimeError, "another operation"):
                            subject.create_machine()
                        subject.save.assert_not_called()
                    self.assertFalse(any("create" in call.args[0] for call in command.call_args_list))


class PhysicalStorageTest(unittest.TestCase):
    def test_headroom_follows_the_actual_orbstack_image_filesystem(self):
        # The first OrbStack preparation looked under ~/.orbstack/data, which
        # no longer exists. Measuring its metadata directory would also miss
        # a data image moved to another disk.
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            data = home / "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"
            data.mkdir(parents=True)
            external = home / "external"
            external.mkdir()
            (external / "data.img").touch()
            (data / "data.img").symlink_to(external / "data.img")
            with patch.object(pool.Path, "home", return_value=home):
                self.assertEqual(pool.orbstack_storage_root(), external.resolve())
                (data / "data.img").unlink()
                with self.assertRaisesRegex(RuntimeError, "OrbStack data image"):
                    pool.orbstack_storage_root()


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



class NetworkBootTest(unittest.TestCase):
    def test_guest_dns_uses_the_allocated_address_and_unexpected_topology_never_applies_rules(self):
        # OrbStack sends the default route to its Mac uplink; the first isolated
        # machine timed out on the private controller until its /32 used the
        # Docker bridge instead. The allocated guest address can also change.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy.nft"
            policy.write_bytes((pool.FILES / "network.nft").read_bytes())
            networks = root / "networks"
            networks.write_text("172.30.42.0/24\n")
            commands = {
                "sysctl": '#!/bin/sh\nexit 0\n',
                "ip": '#!/bin/sh\ncase "$*" in "-4 route show default") printf "%s\\n" "$TEST_ROUTE";; "-6 route show default") printf "%s" "$TEST_IPV6";; "route replace 172.30.42.10/32 via 192.168.139.2 dev eth0") : > "$TEST_ROOT/routed";; *) printf "%s\\n" "$TEST_GUEST";; esac\n',
                "mktemp": '#!/bin/sh\nexec /usr/bin/mktemp "$TEST_ROOT/batch.XXXXXX"\n',
                "nft": '#!/bin/sh\ncase "$1" in list) exit 1;; --check) exit 0;; -f) cp "$2" "$TEST_ROOT/applied";; *) exit 90;; esac\n',
            }
            for name, content in commands.items():
                path = root / name
                path.write_text(content)
                path.chmod(0o700)
            script = (pool.FILES / "network.sh").read_text().replace(
                "cat /etc/ryker-worker-network.nft", "cat " + shlex.quote(str(policy))).replace(
                "/etc/ryker-worker-controller-networks", shlex.quote(str(networks)))
            env = {**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                   "TEST_ROOT": str(root), "TEST_ROUTE": "default via 192.168.139.1 dev eth0 proto dhcp",
                   "TEST_GUEST": "2: eth0 inet 192.168.139.4/24", "TEST_IPV6": ""}
            result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("define guest_ipv4 = 192.168.139.4", (root / "applied").read_text())
            self.assertTrue((root / "routed").exists(), "gateway must route through the Docker bridge, not the Mac uplink")
            for updates in ({"TEST_GUEST": "2: eth0 inet 192.168.139.1/24"},
                            {"TEST_GUEST": "2: eth0 inet 10.240.0.4/24"},
                            {"TEST_GUEST": "2: eth0 inet 192.168.139.4/24\n2: eth0 inet 192.168.139.5/24"},
                            {"TEST_ROUTE": "default via 192.168.139.9 dev eth0"},
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
    def test_a_moved_or_unreadable_backing_disk_holds_admission_before_recovery(self):
        subject = operator()
        subject.state.update(phase="active", storage_root="/original/disk")
        subject.lifecycle.side_effect = lambda _action, actor: {"admission_stopped_by": actor,
                                                               "admission_stopped_at": "2026-11-03T10:00:00Z"}
        with patch.object(pool, "orbstack_storage_root", return_value=Path("/replacement/disk")), \
             patch.object(pool.shutil, "disk_usage", return_value=Mock(free=100 * pool.GIB)):
            growth, error = subject.reconcile_headroom()
        self.assertIsNone(growth)
        self.assertIn("storage location changed", error)
        self.assertEqual(subject.lifecycle.call_args.args, ("stop_admission",))
        subject.release.assert_not_called()
        subject.lifecycle.reset_mock()
        with patch.object(pool, "orbstack_storage_root", return_value=Path("/original/disk")), \
             patch.object(pool.shutil, "disk_usage", side_effect=OSError("disk unavailable")):
            growth, error = subject.reconcile_headroom()
        self.assertIsNone(growth)
        self.assertIn("host storage cannot be measured", error)
        subject.lifecycle.assert_called_once()
        subject.release.assert_not_called()


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
        subject.state.update(phase="active", trimmed_at=time.time(), storage_root="/tmp")
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
        subject.state.update(phase="active", trimmed_at=time.time(), storage_root="/tmp")
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
    def test_interrupted_package_install_preserves_the_operators_existing_policy(self):
        # A signal ran the original cleanup handler, then EXIT ran it again
        # and deleted the operator's restored policy-rc.d.
        source = (pool.FILES / "install-docker.sh").read_text()
        cleanup = source[source.index("restore_policy() {"):source.index('rm -f "$policy"\nprintf')]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy"
            saved = root / "saved"
            saved.mkdir()
            original = b"operator service policy\n"
            (saved / "original").write_bytes(original)
            policy.write_text("temporary deny policy\n")
            result = subprocess.run(["sh", "-c", 'policy=$1; saved=$2\n' + cleanup +
                                     '\nkill -TERM $$\nprintf should-not-continue', "installer", str(policy), str(saved)],
                                    capture_output=True, check=False)
            self.assertTrue(policy.exists(), "interrupted bootstrap deleted the operator's policy")
            self.assertEqual(policy.read_bytes(), original)
            self.assertEqual(result.returncode, 143)
            self.assertNotIn(b"should-not-continue", result.stdout)


    def test_empty_pool_bootstraps_through_the_entrypoint_without_a_previous_box_context(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = operator()
            subject.state.update(phase="creating", storage_root=directory, owner="fixture-owner", machine_id="fixture-id")
            subject.machine_info = Mock()
            subject.guest = Mock()
            subject.create_machine = Mock()
            subject.ensure_context = Mock()
            subject.controller_networks = Mock(return_value=["172.30.42.0/24"])
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
            subject.state.update(storage_root=directory, owner="fixture-owner",
                                 image="ryker-coop:11111111-aaaaaaaa",
                                 upgrade_image="ryker-coop:22222222-bbbbbbbb")
            subject.check_headroom = Mock()
            subject.machine_info = Mock()
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
