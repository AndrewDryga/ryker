#!/usr/bin/env python3
"""Operate the bounded worker VM without moving controller or retained-worker custody."""
import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import storage_maintenance

ROOT = Path(__file__).resolve().parent.parent
FILES = ROOT / "deploy/worker-pool"
GIB = 1024 ** 3
PROFILE = "ryker-worker"
CONTEXT = "colima-" + PROFILE
WORKER = "ryker-pool"
WORKSPACE = "ryker-compose"
REFERENCE = re.compile(r"[A-Za-z0-9._:-]+")


def run(argv, data=None, timeout=30, env=None):
    result = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, check=False, env=env)
    if result.returncode:
        # Enrollment and provider responses can contain credentials. Never include output.
        tool = Path(argv[0]).name
        operation = next((value for value in argv[1:] if value in
                          {"eval", "psql", "load", "inspect", "up", "start", "exec", "run", "ssh"}), "command")
        context = argv[argv.index("--context") + 1] if "--context" in argv else None
        diagnostic = (f"docker --context {context} info" if context else
                      "colima --profile ryker-worker status" if tool == "colima" else
                      "check this installation's worker-pool startup.log")
        raise RuntimeError(f"{tool} {operation} failed (exit {result.returncode}); inspect with {diagnostic}")
    if len(result.stdout) > 1024 * 1024:
        raise RuntimeError("operator response exceeded 1 MiB")
    return result.stdout.decode()


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2) + "\n").encode())


def atomic_bytes(path, content):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_private_json(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("worker pool state must be an owner-only regular file")
    if info.st_size > 65536:
        raise RuntimeError("worker pool state is too large")
    return json.loads(path.read_text())


def required_free(data_gib=32, root_gib=20, memory_gib=8, allocated=0):
    # Sparse virtual disks are maxima, not reservations. Include VM memory's
    # possible host swap and 12 GiB for the controller/builds, plus metadata.
    return max(0, (data_gib + root_gib) * GIB - allocated) + (memory_gib + 14) * GIB


def provisioning(owner):
    destinations = {
        "network.nft": "/etc/ryker-worker-network.nft",
        "network.sh": "/usr/local/sbin/ryker-worker-network",
        "network.service": "/etc/systemd/system/ryker-worker-network.service",
        "docker-network.conf": "/etc/systemd/system/docker.service.d/ryker-network.conf",
        "journald.conf": "/etc/systemd/journald.conf.d/ryker-worker.conf",
    }
    lines = ["#!/bin/sh", "set -eu", "systemctl stop docker.service docker.socket",
             "mkdir -p /etc/systemd/system/docker.service.d /etc/systemd/journald.conf.d"]
    for source, target in destinations.items():
        encoded = base64.b64encode((FILES / source).read_bytes()).decode()
        lines.append(f"printf '%s' '{encoded}' | base64 -d > '{target}'")
    lines += ["chmod 0700 /usr/local/sbin/ryker-worker-network",
              f"printf '%s\\n' '{owner}' > /etc/ryker-worker-owner",
              "chmod 0600 /etc/ryker-worker-owner", "systemctl daemon-reload",
              "systemctl enable ryker-worker-network.service fstrim.timer",
              "systemctl restart systemd-journald",
              "systemctl start ryker-worker-network.service",
              "systemctl start docker.service"]
    return "\n".join(lines) + "\n"


def vm_config(owner):
    return {"cpu": 4, "memory": 8, "disk": 32, "rootDisk": 20, "arch": "aarch64",
            "runtime": "docker", "vmType": "vz", "mounts": [], "sshAgent": False,
            "autoActivate": False, "portForwarder": "none",
            "network": {"mode": "shared", "address": False},
            "docker": {"bip": "10.240.0.1/24",
                       "default-address-pools": [{"base": "10.240.0.0/16", "size": 24}],
                       "log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}},
            "provision": [{"mode": "system", "script": provisioning(owner)}]}


def configuration_digest():
    digest = hashlib.sha256()
    for path in sorted(FILES.iterdir()):
        if path.is_file():
            digest.update(path.name.encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def check_route_ranges(output):
    reserved = [ipaddress.ip_network(net) for net in ("10.240.0.0/16", "10.241.0.0/16")]
    for line in output.splitlines():
        fields = line.split()
        if not fields or not re.match(r"^\d", fields[0]):
            continue
        address, slash, prefix = fields[0].partition("/")
        octets = address.split(".")
        if len(octets) > 4:
            continue
        address = ".".join(octets + ["0"] * (4 - len(octets)))
        network = ipaddress.ip_network(address + "/" + (prefix if slash else str(8 * len(octets))), strict=False)
        if any(network.overlaps(net) for net in reserved):
            raise RuntimeError("worker Docker ranges overlap a host route; do not create this pool")


class Pool:
    def __init__(self, state_dir):
        self.directory = state_dir / "worker-pool"
        self.manifest = self.directory / "state.json"
        self.install_env = state_dir / "compose.env"
        self.env_file = self.directory / "compose.env"
        self.state = read_private_json(self.manifest) if self.manifest.exists() else None
        if self.state:
            for key, expected in (("profile", PROFILE), ("context", CONTEXT),
                                  ("worker", WORKER), ("workspace", WORKSPACE)):
                if self.state.get(key) != expected:
                    raise RuntimeError("worker pool identity does not match this installation")
            if self.state.get("repository") != str(ROOT):
                raise RuntimeError("worker pool belongs to another checkout")

    def save(self):
        atomic_json(self.manifest, self.state)

    def docker(self):
        return ["docker", "--context", self.state["context"]]

    def controller(self):
        endpoint = run(["docker", "context", "inspect", self.state["controller_context"],
                        "--format", "{{.Endpoints.docker.Host}}"] ).strip()
        if endpoint != self.state["controller_endpoint"]:
            raise RuntimeError("controller Docker context changed; refusing a different installation")
        return ["docker", "--context", self.state["controller_context"], "compose",
                "--env-file", str(self.install_env), "--file", str(ROOT / "compose.yml")]

    def compose(self):
        return self.docker() + ["compose", "--env-file", str(self.env_file),
                                "--file", str(FILES / "compose.yml")]

    def guest(self, command, data=None, timeout=30):
        return run(["colima", "ssh", "--profile", PROFILE, "--", "sudo"] + command, data, timeout,
                   env={**os.environ, "COLIMA_HOME": self.state["colima_home"]})

    def release(self, call):
        expression = (f"case {call} do {{:ok, value}} -> IO.puts(Jason.encode!(value)); "
                      "error -> IO.inspect(:stderr, error); System.halt(1) end")
        return json.loads(run(self.controller() + ["exec", "-T", "ryker", "/opt/ryker/bin/ryker",
                                                   "eval", expression]))

    def lifecycle(self, action, worker=WORKER, actor="operator:worker-pool"):
        if action not in ("stop_admission", "start_admission", "drain") or not REFERENCE.fullmatch(worker) or not REFERENCE.fullmatch(actor):
            raise RuntimeError("invalid worker lifecycle action")
        return self.release(f'Ryker.Release.worker_lifecycle(:{action}, "{worker}", "{actor}", log: false)')

    def sql(self, query):
        return run(self.controller() + ["exec", "-T", "database", "psql", "-X", "-v",
                   "ON_ERROR_STOP=1", "-U", "ryker", "-d", "ryker", "-Atc", query]).strip()

    def worker_status(self):
        result = self.sql("SELECT json_build_object('state', state, 'workspace', workspace_ref, "
                          "'age', EXTRACT(EPOCH FROM now()-last_seen_at), 'capacity', capacity, "
                          "'admission_stopped_at', admission_stopped_at, 'admission_stopped_by', admission_stopped_by, "
                          "'drain_requested_at', drain_requested_at, 'drain_requested_by', drain_requested_by, 'protocol', protocol_version, "
                          "'capabilities', capabilities) FROM coop_workers WHERE id = 'ryker-pool'")
        if not result:
            return None
        worker = json.loads(result)
        # CanonicalJSON.Type is stored as text, and utc_datetime_usec as a
        # timestamp without a zone. Decode the same types Ecto exposes.
        for field, shape in (("capacity", dict), ("capabilities", list)):
            value = json.loads(worker[field]) if worker[field] is not None else shape()
            if not isinstance(value, shape):
                raise RuntimeError(f"worker {field} has an invalid stored shape")
            worker[field] = value
        for field in ("admission_stopped_at", "drain_requested_at"):
            if worker[field] is not None:
                value = datetime.fromisoformat(worker[field])
                if value.tzinfo is None:
                    value = value.replace(tzinfo=timezone.utc)
                worker[field] = value.astimezone(timezone.utc).isoformat()
        return worker

    def verify(self):
        if self.state["configuration"] != configuration_digest():
            raise RuntimeError("worker VM configuration changed; qualify that change before updating the pool")
        home = Path(self.state["colima_home"])
        marker = home / PROFILE / ".ryker-owner"
        if marker.is_symlink() or marker.read_text().strip() != self.state["owner"]:
            raise RuntimeError("worker profile ownership does not match")
        if self.guest(["cat", "/etc/ryker-worker-owner"]).strip() != self.state["owner"]:
            raise RuntimeError("worker VM ownership does not match")
        endpoint = run(self.docker() + ["context", "inspect", CONTEXT, "--format", "{{.Endpoints.docker.Host}}"] ).strip()
        expected = "unix://" + str(home / PROFILE / "docker.sock")
        if endpoint != expected:
            raise RuntimeError("worker Docker context points outside the owned VM")
        daemon = run(self.docker() + ["info", "--format", "{{.ID}}"] ).strip()
        if self.state.get("daemon") and daemon != self.state["daemon"]:
            raise RuntimeError("worker Docker daemon identity changed")
        self.guest(["systemctl", "is-active", "ryker-worker-network", "docker"])
        sizes = self.guest(["sh", "-ec", "blockdev --getsize64 /dev/vda; blockdev --getsize64 /dev/vdb"]).split()
        if list(map(int, sizes)) != [20 * GIB, 32 * GIB]:
            raise RuntimeError("worker disks no longer have their qualified size limits")
        mounts = self.guest(["sh", "-ec", "findmnt -rn -t virtiofs,9p,fuse.sshfs || test $? -eq 1"])
        if mounts.strip():
            raise RuntimeError("worker VM has host directory mounts")
        return daemon

    def write_env(self, image):
        if not re.fullmatch(r"ryker-coop:[0-9a-f]{8}-[0-9a-f]{8}", image):
            raise RuntimeError("worker image is not a pinned build")
        text = f"RYKER_POOL_IMAGE={image}\nRYKER_POOL_WORKER_ID={WORKER}\nRYKER_POOL_WORKSPACE={WORKSPACE}\n"
        if self.env_file.is_symlink():
            raise RuntimeError("worker environment must not be a symlink")
        atomic_bytes(self.env_file, text.encode())

    def image(self):
        return run(["sh", "-c", '. "$1/scripts/compose-lifecycle.sh"; worker_image "$1"',
                    "pool", str(ROOT)]).strip()

    def copy_image(self, image):
        run(["docker", "--context", self.state["controller_context"], "image", "inspect", image,
             "--format", "{{.Id}}"])
        with tempfile.TemporaryFile() as output:
            producer = subprocess.Popen(["docker", "--context", self.state["controller_context"],
                                         "image", "save", image], stdout=subprocess.PIPE, stderr=output)
            consumer = subprocess.Popen(self.docker() + ["image", "load"], stdin=producer.stdout,
                                        stdout=output, stderr=output)
            producer.stdout.close()
            try:
                if consumer.wait(timeout=300) or producer.wait(timeout=30):
                    raise RuntimeError("worker image transfer failed")
            finally:
                for child in (producer, consumer):
                    if child.poll() is None:
                        child.kill()
                        child.wait()

    def seed_file(self, destination, content):
        if destination not in ("worker-ca.pem", "enrollment-token"):
            raise RuntimeError("invalid enrollment file")
        script = ('set -eu; umask 077; mkdir -p /var/lib/ryker-coop; '
                  f'tmp=$(mktemp /var/lib/ryker-coop/.{destination}.XXXXXX); '
                  'trap \'rm -f "$tmp"\' EXIT HUP INT TERM; '
                  'cat > "$tmp"; chmod 600 "$tmp"; chown 1000:1000 "$tmp"; '
                  f'mv "$tmp" /var/lib/ryker-coop/{destination}')
        run(self.compose() + ["run", "--rm", "--no-deps", "-T", "--entrypoint", "sh",
                              "volume-init", "-ec", script], content, timeout=60)

    def enroll(self):
        status = run(self.compose() + ["run", "--rm", "--no-deps", "-T", "--entrypoint",
                     "ryker-coop-entrypoint", "ryker-coop", "enrollment-status"], timeout=60).strip()
        if status == "valid":
            run(self.compose() + ["run", "--rm", "--no-deps", "-T", "--entrypoint", "sh",
                "volume-init", "-ec", "rm -f /var/lib/ryker-coop/enrollment-token"], timeout=60)
            self.state.pop("token_expires_at", None)
            self.save()
            return
        if status == "expired":
            raise RuntimeError("worker must finish its own expired-identity recovery")
        if status != "absent":
            raise RuntimeError("worker identity is not valid for enrollment recovery")
        if self.state.get("token_expires_at", 0) > time.time() + 30:
            return
        issued = self.release('Ryker.Release.issue_worker_token("ryker-pool", "ryker-compose", '
                              f'"operator:worker-pool", stop_admission: {str(self.state["phase"] != "active").lower()}, log: false)')
        self.seed_file("enrollment-token", issued["token"].encode())
        self.state["token_expires_at"] = datetime.fromisoformat(issued["expires_at"].replace("Z", "+00:00")).timestamp()
        self.save()

    def status(self):
        self.verify()
        return {"worker": WORKER, "context": CONTEXT, "phase": self.state["phase"],
                "image": self.state["image"], "model_accounts_needed": self.missing_accounts(),
                "controller": self.worker_status()}

    def initialize(self):
        home = Path(os.environ.get("COLIMA_HOME", Path.home() / ".colima")).resolve()
        measured = home if home.exists() else home.parent
        free = shutil.disk_usage(measured).free
        if free < required_free():
            raise RuntimeError(f"dedicated worker needs {required_free() / GIB:.0f} GiB free; "
                               f"this disk has {free / GIB:.1f} GiB")
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("this worker pool requires a qualified Apple Silicon Colima host")
        if shutil.which("colima") is None:
            raise RuntimeError("Colima is required for the isolated worker VM")
        check_route_ranges(run(["netstat", "-rn", "-f", "inet"]))
        context = run(["docker", "context", "show"]).strip()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", context) or context == CONTEXT:
            raise RuntimeError("select the controller's Docker context before installing the pool")
        endpoint = run(["docker", "context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"] ).strip()
        if not endpoint.startswith("unix:///"):
            raise RuntimeError("controller must use a local Unix Docker endpoint")
        if (home / PROFILE).exists() or CONTEXT in run(["docker", "context", "ls", "--format", "{{.Name}}"] ).splitlines():
            raise RuntimeError("worker profile/context already exists without this installation's ownership")
        self.state = {"version": 1, "owner": uuid.uuid4().hex, "repository": str(ROOT),
                      "profile": PROFILE, "context": CONTEXT, "worker": WORKER, "workspace": WORKSPACE,
                      "controller_context": context, "controller_endpoint": endpoint,
                      "colima_home": str(home), "phase": "creating", "configuration": configuration_digest()}
        if self.worker_status() is not None:
            raise RuntimeError("worker ID already has controller custody; refusing to replace its identity")
        self.save()

    def install(self):
        if self.state is None:
            self.initialize()
        if self.state["phase"] in ("qualified", "active"):
            self.install_startup()
            return self.status()
        home = Path(self.state["colima_home"])
        self.check_headroom()
        profile = home / PROFILE
        if not profile.exists():
            profile.mkdir(mode=0o700, parents=True)
            marker = profile / ".ryker-owner"
            marker.write_text(self.state["owner"] + "\n")
            marker.chmod(0o600)
            atomic_json(profile / "colima.yaml", vm_config(self.state["owner"]))
        elif (profile / ".ryker-owner").read_text().strip() != self.state["owner"]:
            raise RuntimeError("existing Colima profile is not owned by this installation")
        run(["colima", "start", PROFILE, "--activate=false", "--template=false", "--mount", "none",
             "--port-forwarder", "none", "--runtime", "docker", "--vm-type", "vz",
             "--cpus", "4", "--memory", "8", "--disk", "32", "--root-disk", "20"], timeout=600,
            env={**os.environ, "COLIMA_HOME": self.state["colima_home"]})
        self.state["daemon"] = self.verify()
        self.save()
        image = self.image()
        self.copy_image(image)
        self.write_env(image)
        self.state["image"] = image
        self.save()
        run(self.compose() + ["up", "--detach", "--no-build", "--wait", "ryker-coop-docker"], timeout=180)
        ca = run(self.controller() + ["exec", "-T", "ryker", "cat", "/var/lib/ryker/pki/ca.pem"])
        if "BEGIN CERTIFICATE" not in ca:
            raise RuntimeError("controller did not supply its public worker CA")
        self.seed_file("worker-ca.pem", ca.encode())
        self.enroll()
        # A fresh volume has no previous trusted box context to prewarm.
        # The entrypoint builds it from the seeded CA before connecting.
        run(self.compose() + ["up", "--detach", "--no-build", "--wait", "ryker-coop"], timeout=600)
        run(self.compose() + ["exec", "-T", "ryker-coop", "coop", "net", "setup"], timeout=180)
        self.wait_qualified(require_hold=True)
        self.state["phase"] = "qualified"
        self.save()
        self.install_startup()
        return self.status()

    def prewarm(self, image):
        run(self.compose() + ["run", "--rm", "--no-deps", "-T", "--entrypoint", "sh", "ryker-coop", "-s"],
            (ROOT / "deploy/compose/coop/prewarm.sh").read_bytes(), timeout=600,
            env={**os.environ, "RYKER_POOL_IMAGE": image})

    def acquire_upgrade(self):
        receipt = self.state.get("upgrade_drain")
        if not receipt:
            receipt = {"actor": "operator:worker-upgrade:pool:" + uuid.uuid4().hex}
            self.state["upgrade_drain"] = receipt
            # Persist intent before requesting the durable controller hold.
            self.save()
        worker = self.worker_status()
        if worker and worker.get("drain_requested_at"):
            if worker.get("drain_requested_by") != receipt["actor"]:
                raise RuntimeError("another operation already drained the pool")
            if receipt.get("at") and not same_time(receipt["at"], worker["drain_requested_at"]):
                raise RuntimeError("pool upgrade drain changed")
            receipt["at"] = worker["drain_requested_at"]
        elif receipt.get("at"):
            raise RuntimeError("pool upgrade drain was released; retry after recovering its receipt")
        else:
            drained = self.lifecycle("drain", actor=receipt["actor"])
            if drained["status"] != "draining":
                raise RuntimeError("another operation already drained the pool")
            receipt["at"] = drained["drain_requested_at"]
        self.save()

    def resume_upgrade(self):
        receipt = self.state.get("upgrade_drain")
        if not receipt:
            return
        worker = self.worker_status()
        if not worker:
            raise RuntimeError("pool worker custody is unavailable")
        if not worker.get("drain_requested_at"):
            del self.state["upgrade_drain"]
            self.save()
            return
        actor = receipt["actor"]
        timestamp = receipt.get("at") or worker["drain_requested_at"]
        if (worker.get("drain_requested_by") != actor or
                not same_time(timestamp, worker["drain_requested_at"])):
            raise RuntimeError("pool upgrade drain changed; refusing another operator's decision")
        if not REFERENCE.fullmatch(actor) or not re.fullmatch(r"[0-9T:.+Z-]+", timestamp):
            raise RuntimeError("invalid upgrade drain receipt")
        self.release(f'case Ryker.Release.resume_worker_upgrade("ryker-pool", "{actor}", '
                     f'"{timestamp}", log: false) do {{:ok, _}} -> {{:ok, %{{}}}}; error -> error end')
        del self.state["upgrade_drain"]
        self.save()

    def running_image(self):
        container = run(self.compose() + ["ps", "--all", "--quiet", "ryker-coop"]).strip()
        if not re.fullmatch(r"[0-9a-f]{12,64}", container):
            raise RuntimeError("pool worker container is unavailable")
        image = run(self.docker() + ["inspect", "--format", "{{.Config.Image}}", container]).strip()
        return container, image

    def upgrade(self, force_restart=False):
        self.verify()
        self.resume_upgrade()
        image = self.image()
        container, running = self.running_image()
        if running == image and not force_restart:
            run(self.compose() + ["exec", "-T", "ryker-coop", "coop", "sessions", "doctor",
                                  "--socket", "/var/lib/coop/sessions/control.sock"])
            self.wait_qualified()
            self.write_env(image)
            self.state["image"] = image
            self.state.pop("upgrade_image", None)
            self.save()
            return self.status()
        self.check_headroom()
        self.maintain()
        if not storage_maintenance.build_ready(self.state["maintenance"]["storage"]):
            raise RuntimeError("pool lacks measured build headroom; its existing worker stays running")
        self.copy_image(image)
        # Preserve provider state before a binary that may migrate its format.
        backup = "agents.pool-pre-" + str(int(time.time()))
        run(self.compose() + ["exec", "-T", "ryker-coop", "sh", "-ec",
                              f'cd /var/lib/coop; cp -a agents {backup}; '
                              'ls -dt agents.pool-pre-* | tail -n +3 | xargs rm -rf'])
        self.prewarm(image)
        volume = run(self.docker() + ["inspect", "--format",
                     '{{range .Mounts}}{{if eq .Destination "/var/lib/coop"}}{{.Name}}{{end}}{{end}}', container]).strip()
        if volume != "ryker-worker_state":
            raise RuntimeError("pool worker state is not its owned named volume")
        self.acquire_upgrade()
        try:
            deadline = time.monotonic() + 600
            while True:
                busy = int(self.sql("SELECT count(*) FROM coop_worker_commands AS command "
                                    "WHERE command.worker_id = 'ryker-pool' AND command.status IN ('delivered','acknowledged') "
                                    "AND EXISTS (SELECT 1 FROM coop_session_placements AS placement "
                                    "WHERE placement.session_id = command.session_id AND placement.generation = command.placement_generation "
                                    "AND placement.state NOT IN ('replaced','retired'))"))
                if not busy and self.native_quiescent(image, volume):
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("pool still has work in flight; existing worker stays running")
                time.sleep(5)
            self.state["upgrade_image"] = image
            self.save()
            flags = ["--force-recreate"] if force_restart else []
            run(self.compose() + ["up", "--detach", "--no-build", "--wait", "--no-deps"] + flags + ["ryker-coop"],
                timeout=300, env={**os.environ, "RYKER_POOL_IMAGE": image})
        finally:
            self.resume_upgrade()
        self.wait_qualified()
        self.write_env(image)
        if running != image:
            self.state["previous_image"] = running
        self.state["image"] = image
        self.state.pop("upgrade_image", None)
        self.save()
        self.remove_old_images()
        return self.status()

    def remove_old_images(self):
        previous = self.state.get("previous_image")
        if not previous:
            return
        tags = run(self.docker() + ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}", "ryker-coop"])
        for tag in tags.splitlines():
            if re.fullmatch(r"ryker-coop:[0-9a-f]{8}-[0-9a-f]{8}", tag) and tag not in (self.state["image"], previous):
                # An in-use image is retained by Docker; never force removal.
                subprocess.run(self.docker() + ["image", "rm", tag], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)

    def native_quiescent(self, image, volume):
        command = self.docker() + ["run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                    "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,noexec,nosuid,size=8m",
                    "-e", "HOME=/tmp", "-e", "COOP_CONFIG_DIR=/tmp/agents", "-e", "TMPDIR=/tmp",
                    "--mount", f"type=volume,source={volume},target=/var/lib/coop,readonly",
                    "--entrypoint", "coop", image, "sessions", "quiescence", "--state", "/var/lib/coop/sessions", "--json"]
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30, check=False)
        if result.returncode == 3:
            return False
        if result.returncode or not result.stdout.strip():
            raise RuntimeError("native pool work cannot be inspected; refusing to restart it")
        return True

    def model_login(self, provider):
        self.verify()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:@[A-Za-z0-9_.-]+)?", provider):
            raise RuntimeError("use a provider account name, optionally followed by @profile")
        script = (ROOT / "deploy/compose/coop/model-login.sh").read_text()
        result = subprocess.run(self.compose() + ["run", "--rm", "--no-deps", "-w", "/tmp",
                                "--entrypoint", "sh", "ryker-coop", "-c", script, "pool-model-login", provider], check=False)
        if result.returncode:
            raise RuntimeError("pool model sign-in did not complete; previous sign-in stays")
        account = provider if "@" in provider else provider + "@default"
        self.state["signed_in_accounts"] = sorted(set(self.state.get("signed_in_accounts", [])) | {account})
        self.save()
        if self.state["phase"] in ("qualified", "active"):
            self.upgrade(force_restart=True)
        return {"worker": WORKER, "provider": provider, "signed_in": True}

    def missing_accounts(self):
        accounts = json.loads(self.sql(
            "SELECT COALESCE(json_agg(DISTINCT account), '[]') FROM work_settings "
            "CROSS JOIN LATERAL unnest(model_accounts) AS account WHERE workspace_ref = 'ryker-compose'"))
        if not accounts or not all(isinstance(account, str) and
                                   re.fullmatch(r"(?:codex|claude)@[a-z0-9][a-z0-9_-]{0,63}", account)
                                   for account in accounts):
            raise RuntimeError("pool workspace has no valid model account configuration")
        return sorted(set(accounts) - set(self.state.get("signed_in_accounts", [])))

    def wait_qualified(self, require_hold=False):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            worker = self.worker_status()
            if worker and qualified(worker, require_hold):
                return worker
            time.sleep(2)
        raise RuntimeError("worker did not report qualified capacity; admission remains unchanged")

    def activate(self):
        self.verify()
        missing = self.missing_accounts()
        if missing:
            raise RuntimeError("pool needs its own model-login for: " + ", ".join(missing))
        if self.state["phase"] not in ("qualified", "activating", "active"):
            raise RuntimeError("qualify the worker before activating its admission")
        worker = self.wait_qualified(require_hold=self.state["phase"] == "qualified")
        if self.state["phase"] != "active":
            if self.state["phase"] == "qualified":
                if worker["admission_stopped_by"] != "operator:worker-pool":
                    raise RuntimeError("another operator owns the pool's admission hold")
                self.state["activation_hold"] = worker["admission_stopped_at"]
                self.state["phase"] = "activating"
                self.save()
            timestamp = self.state["activation_hold"]
            held = worker.get("admission_stopped_at")
            if held and (worker["admission_stopped_by"] != "operator:worker-pool" or held != timestamp):
                raise RuntimeError("another operator owns the pool's admission hold")
            if not re.fullmatch(r"[0-9T:.+Z-]+", timestamp):
                raise RuntimeError("invalid admission receipt timestamp")
            if held:
                self.release('case Ryker.Release.resume_worker_admission("ryker-pool", '
                             f'"operator:worker-pool", "{timestamp}", log: false) do '
                             '{:ok, _} -> {:ok, %{}}; error -> error end')
            self.state["phase"] = "active"
            self.save()
        # Failure here deliberately retains both workers. Existing custody is
        # never revoked, and retrying only repeats this admission-only stop.
        self.lifecycle("stop_admission", worker="ryker-compose")
        self.state["retained_admission_stopped"] = True
        self.save()
        return self.status()

    def maintain(self):
        growth, pressure_error = self.reconcile_headroom()
        self.verify()
        self.enroll()
        deadline = time.monotonic() + 50

        def bounded(argv, timeout=12):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or ("--force" in argv and "prune" in argv and remaining < 21):
                raise RuntimeError("pool storage maintenance reached its bounded deadline")
            return storage_maintenance.command(argv, min(timeout, remaining))

        report = storage_maintenance.maintain(
            self.env_file, apply=True, run=bounded, context=CONTEXT, compose_file=FILES / "compose.yml",
            measure_host=lambda _path: storage_maintenance.host_disk(Path(self.state["colima_home"])))
        health_error = None
        if self.state["phase"] == "active" and not qualified(self.worker_status() or {}):
            health_error = "pool worker is not reporting fresh eligible capacity"
        if time.time() - self.state.get("trimmed_at", 0) >= 1800:
            # A successful trim is not claimed as physical space reclaimed.
            self.guest(["fstrim", "--all"], timeout=30)
            self.state["trimmed_at"] = int(time.time())
        report["remaining_growth"] = growth
        if pressure_error:
            report["errors"].append(pressure_error)
        self.state["maintenance"] = {"at": int(time.time()), "storage": report, "worker_error": health_error}
        self.save()
        return "; ".join(message for message in (storage_maintenance.summary(report), health_error) if message)

    def reconcile_headroom(self):
        try:
            growth, error = self.check_headroom(), None
        except RuntimeError as caught:
            growth, error = None, str(caught)
        receipt = self.state.get("headroom_hold")
        if error and self.state["phase"] == "active":
            if not receipt:
                receipt = {"actor": "operator:worker-pool-host-space:" + uuid.uuid4().hex}
                self.state["headroom_hold"] = receipt
                self.save()
            held = self.lifecycle("stop_admission", actor=receipt["actor"])
            if held["admission_stopped_by"] == receipt["actor"]:
                receipt["at"] = held["admission_stopped_at"]
            else:
                # The other operator's hold already prevents admission.
                self.state.pop("headroom_hold", None)
            self.save()
        elif not error and receipt:
            worker = self.worker_status()
            if not worker:
                raise RuntimeError("pool admission custody is unavailable")
            timestamp = worker.get("admission_stopped_at")
            if timestamp and worker.get("admission_stopped_by") == receipt["actor"]:
                if receipt.get("at") and not same_time(receipt["at"], timestamp):
                    raise RuntimeError("host-space admission receipt changed")
                actor = receipt["actor"]
                if not REFERENCE.fullmatch(actor) or not re.fullmatch(r"[0-9T:.+Z-]+", timestamp):
                    raise RuntimeError("invalid host-space admission receipt")
                self.release('case Ryker.Release.resume_worker_admission("ryker-pool", '
                             f'"{actor}", "{timestamp}", log: false) do '
                             '{:ok, _} -> {:ok, %{}}; error -> error end')
            # A manual release or replacement leaves no hold owned by us.
            del self.state["headroom_hold"]
            self.save()
        return growth, error

    def check_headroom(self):
        home = Path(self.state["colima_home"])
        disks = [home / "_lima" / ("colima-" + PROFILE) / "disk",
                 home / "_lima" / "_disks" / ("colima-" + PROFILE) / "datadisk"]
        allocated = 0
        for path in disks:
            if path.exists():
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode):
                    raise RuntimeError("worker disk path is not a regular file")
                allocated += info.st_blocks * 512
        free = shutil.disk_usage(home if home.exists() else home.parent).free
        needed = required_free(allocated=allocated)
        if free < needed:
            raise RuntimeError(f"worker VM can still grow; needs {needed / GIB:.1f} GiB host headroom, "
                               f"has {free / GIB:.1f} GiB")
        return {"free_bytes": free, "required_bytes": needed, "allocated_disk_bytes": allocated}

    def start(self):
        home = Path(self.state["colima_home"])
        if (home / PROFILE / ".ryker-owner").read_text().strip() != self.state["owner"]:
            raise RuntimeError("worker profile ownership changed")
        self.check_headroom()
        run(["colima", "start", PROFILE, "--activate=false", "--template=false"], timeout=600,
            env={**os.environ, "COLIMA_HOME": self.state["colima_home"]})
        self.verify()
        _container, image = self.running_image()
        if image not in (self.state["image"], self.state.get("upgrade_image")):
            raise RuntimeError("worker image changed outside the guarded upgrade; refusing to replace it")
        # Start existing containers only: a crash after replacement can leave
        # the previous env pin, which must never recreate an older worker.
        run(self.compose() + ["start", "ryker-coop-docker", "ryker-coop"], timeout=60)
        return {"worker": WORKER, "started": True}

    def install_startup(self):
        label = "ai.ryker.worker-pool"
        directory = Path.home() / "Library/LaunchAgents"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / (label + ".plist")
        arguments = [shutil.which("python3"), "-B", str(ROOT / "scripts/worker_pool.py"),
                     "start", "--state-dir", str(self.directory.parent)]
        document = {"Label": label, "ProgramArguments": arguments, "RunAtLoad": True,
                    "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
                    "StandardOutPath": str(self.directory / "startup.log"),
                    "StandardErrorPath": str(self.directory / "startup.log")}
        if path.exists():
            if path.is_symlink() or plistlib.loads(path.read_bytes()) != document:
                raise RuntimeError("worker startup agent already belongs to another configuration")
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                plistlib.dump(document, stream)
        domain = "gui/" + str(os.getuid())
        found = subprocess.run(["launchctl", "print", domain + "/" + label],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if found.returncode:
            run(["launchctl", "bootstrap", domain, str(path)])


def same_time(left, right):
    return datetime.fromisoformat(left.replace("Z", "+00:00")) == datetime.fromisoformat(right.replace("Z", "+00:00"))


def qualified(worker, require_hold=False):
    capacity = worker.get("capacity") or {}
    return (worker.get("state") == "eligible" and worker.get("protocol") == "2"
            and worker.get("workspace") == WORKSPACE and isinstance(worker.get("age"), (int, float))
            and 0 <= worker["age"] < 60 and not worker.get("drain_requested_at")
            and (not require_hold or bool(worker.get("admission_stopped_at")))
            and capacity.get("state") == "eligible"
            and all(isinstance(capacity.get(kind + "_slots_free"), int)
                    and capacity[kind + "_slots_free"] > 0 for kind in ("session", "turn", "workspace"))
            and {"name": "controller-tools", "version": "1"} in (worker.get("capabilities") or []))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "start", "status", "maintain", "activate", "upgrade", "model-login"])
    parser.add_argument("provider", nargs="?")
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("RYKER_INSTALL_STATE", ROOT / ".ryker")))
    args = parser.parse_args()
    if args.provider and args.command != "model-login":
        parser.error("only model-login takes a provider")
    state_dir = args.state_dir.resolve()
    directory = state_dir / "worker-pool"
    if not directory.exists() and args.command != "install":
        if args.command == "status":
            print("No dedicated worker pool is installed.")
        elif args.command not in ("maintain", "upgrade"):
            raise RuntimeError("no worker pool is installed; run python3 -B scripts/worker_pool.py install")
        return
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
        raise RuntimeError("worker pool directory must be private and owned by this operator")
    fd = os.open(directory / "operation.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            # Login-time startup must eventually run if maintenance got the
            # lock first; silently skipping it can leave the VM off all day.
            flags = fcntl.LOCK_EX if args.command == "start" else fcntl.LOCK_EX | fcntl.LOCK_NB
            fcntl.flock(lock, flags)
        except BlockingIOError:
            if args.command == "maintain":
                return
            raise RuntimeError("another worker pool operation is running") from None
        pool = Pool(state_dir)
        if pool.state is None and args.command != "install":
            if args.command == "status":
                print("No dedicated worker pool is installed.")
            elif args.command not in ("maintain", "upgrade"):
                raise RuntimeError("no worker pool is installed; run python3 -B scripts/worker_pool.py install")
            return
        if args.command == "model-login":
            result = pool.model_login(args.provider or "codex")
        else:
            result = getattr(pool, args.command)()
        if isinstance(result, str):
            if result:
                print(result)
        else:
            print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"worker pool: {error}", file=sys.stderr)
        sys.exit(1)
