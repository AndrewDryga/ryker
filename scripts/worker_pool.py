#!/usr/bin/env python3
"""Operate the worker pool on the installation’s selected Docker engine."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
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
VOLUMES = tuple("ryker-worker_" + name for name in ("state", "config", "docker", "socket"))
OWNER_LABEL = "io.ryker.worker-pool.owner"
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
                      "python3 -B scripts/worker_pool.py status")
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


def configuration_digest():
    digest = hashlib.sha256()
    for path in sorted(FILES.iterdir()):
        if path.is_file():
            digest.update(path.name.encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


class Pool:
    def __init__(self, state_dir):
        self.directory = state_dir / "worker-pool"
        self.manifest = self.directory / "state.json"
        self.install_env = state_dir / "compose.env"
        self.env_file = self.directory / "compose.env"
        self.state = read_private_json(self.manifest) if self.manifest.exists() else None
        if self.state:
            if self.state.get("version") != 3:
                raise RuntimeError("worker pool needs an explicit Docker custody migration")
            if self.state.get("controller_context") != self.state.get("context"):
                raise RuntimeError("pool and controller must use the same Docker installation")
            for key, expected in (("worker", WORKER), ("workspace", WORKSPACE)):
                if self.state.get(key) != expected:
                    raise RuntimeError("worker pool identity does not match this installation")
            if self.state.get("repository") != str(ROOT):
                raise RuntimeError("worker pool belongs to another checkout")

    def save(self):
        atomic_json(self.manifest, self.state)

    def docker(self):
        if self.state["context"] is None:
            return ["docker", "--host", self.state["controller_endpoint"]]
        return ["docker", "--context", self.state["context"]]

    def controller(self):
        if self.state["controller_context"] is not None:
            endpoint = run(["docker", "context", "inspect", self.state["controller_context"],
                            "--format", "{{.Endpoints.docker.Host}}"] ).strip()
            if endpoint != self.state["controller_endpoint"]:
                raise RuntimeError("controller Docker context changed; refusing a different installation")
        return self.docker() + ["compose", "--env-file", str(self.install_env),
                                "--file", str(ROOT / "compose.yml")]

    def compose(self):
        return self.docker() + ["compose", "--env-file", str(self.env_file),
                                "--file", str(FILES / "compose.yml")]

    def release(self, call):
        expression = (f"case ({call}) do {{:ok, value}} -> IO.puts(Jason.encode!(value)); "
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

    def verify_volumes(self, names):
        records = json.loads(run(self.docker() + ["volume", "inspect", *names]))
        if ({record.get("Name") for record in records} != set(names) or
                any(record.get("Driver") != "local" or record.get("Options") or
                    (record.get("Labels") or {}).get(OWNER_LABEL) != self.state["owner"]
                    for record in records)):
            raise RuntimeError("worker volumes belong to another installation")

    def create_volumes(self):
        existing = set(run(self.docker() + ["volume", "ls", "--quiet"]).splitlines())
        owned = [name for name in VOLUMES if name in existing]
        if owned:
            self.verify_volumes(owned)
        for name in VOLUMES:
            if name not in existing:
                run(self.docker() + ["volume", "create", "--label", OWNER_LABEL + "=" + self.state["owner"],
                                    "--label", "com.docker.compose.project=ryker-worker",
                                    "--label", "com.docker.compose.volume=" + name.removeprefix("ryker-worker_"), name])

    def verify_engine(self):
        if self.state["configuration"] != configuration_digest():
            raise RuntimeError("worker configuration changed; qualify it before updating the pool")
        self.controller()
        daemon = run(self.docker() + ["info", "--format", "{{.ID}}"] ).strip()
        if daemon != self.state["daemon"]:
            raise RuntimeError("Docker engine identity changed")
        return daemon

    def verify(self):
        daemon = self.verify_engine()
        self.verify_volumes(VOLUMES)
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
        return {"worker": WORKER, "context": self.state["context"], "phase": self.state["phase"],
                "image": self.state["image"], "model_accounts_needed": self.missing_accounts(),
                "controller": self.worker_status()}

    def initialize(self):
        context = os.environ.get("DOCKER_CONTEXT") or None
        endpoint = os.environ.get("DOCKER_HOST") if not context else None
        if not endpoint:
            context = context or run(["docker", "context", "show"]).strip()
            endpoint = run(["docker", "context", "inspect", context,
                            "--format", "{{.Endpoints.docker.Host}}"] ).strip()
        self.state = {"version": 3, "owner": uuid.uuid4().hex, "repository": str(ROOT),
                      "context": context, "worker": WORKER, "workspace": WORKSPACE,
                      "controller_context": context, "controller_endpoint": endpoint,
                      "phase": "creating", "configuration": configuration_digest()}
        self.state["daemon"] = run(self.docker() + ["info", "--format", "{{.ID}}"] ).strip()
        if self.worker_status() is not None:
            raise RuntimeError("worker ID already has controller custody; refusing to replace its identity")
        self.save()

    def install(self):
        if self.state is None:
            self.initialize()
        if self.state["phase"] in ("qualified", "active"):
            return self.status()
        self.verify_engine()
        self.create_volumes()
        self.verify()
        image = self.image()
        run(self.docker() + ["image", "inspect", image, "--format", "{{.Id}}"])
        self.write_env(image)
        self.state["image"] = image
        self.save()
        run(self.compose() + ["up", "--detach", "--no-build", "--wait", "ryker-coop-docker"], timeout=180)
        ca = run(self.controller() + ["exec", "-T", "ryker", "cat", "/var/lib/ryker/pki/ca.pem"])
        if "BEGIN CERTIFICATE" not in ca:
            raise RuntimeError("controller did not supply its public worker CA")
        self.seed_file("worker-ca.pem", ca.encode())
        self.enroll()
        run(self.compose() + ["up", "--detach", "--no-build", "--wait", "ryker-coop"], timeout=600)
        run(self.compose() + ["exec", "-T", "ryker-coop", "coop", "net", "setup"], timeout=180)
        self.wait_qualified(require_hold=True)
        self.state["phase"] = "qualified"
        self.save()
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
        self.maintain()
        if not storage_maintenance.build_ready(self.state["maintenance"]["storage"]):
            raise RuntimeError("pool lacks measured build headroom; its existing worker stays running")
        run(self.docker() + ["image", "inspect", image, "--format", "{{.Id}}"] )
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
        return self.status()

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
        self.verify()
        self.enroll()
        deadline = time.monotonic() + 50

        def bounded(argv, timeout=12):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or ("--force" in argv and "prune" in argv and remaining < 21):
                raise RuntimeError("pool storage maintenance reached its bounded deadline")
            return storage_maintenance.command(argv, min(timeout, remaining))

        report = storage_maintenance.maintain(
            self.env_file, apply=True, run=bounded, context=self.state["context"],
            host=self.state["controller_endpoint"] if self.state["context"] is None else None,
            compose_file=FILES / "compose.yml")
        health_error = None
        if self.state["phase"] == "active" and not qualified(self.worker_status() or {}):
            health_error = "pool worker is not reporting fresh eligible capacity"
        self.state["maintenance"] = {"at": int(time.time()), "storage": report, "worker_error": health_error}
        self.save()
        return "; ".join(message for message in (storage_maintenance.summary(report), health_error) if message)

    def start(self):
        self.verify()
        _container, image = self.running_image()
        if image not in (self.state["image"], self.state.get("upgrade_image")):
            raise RuntimeError("worker image changed outside the guarded upgrade; refusing to replace it")
        run(self.compose() + ["start", "ryker-coop-docker", "ryker-coop"], timeout=60)
        return {"worker": WORKER, "started": True}


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
            # An explicit start waits for maintenance rather than silently skipping it.
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
