"""Boot one hardware-isolated Coop host from its own durable guest disk."""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path("/opt/worker")
STATE = Path("/state")
DNS_LABEL = r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"


def controller_environment(url):
    match = re.fullmatch(r"https://([a-zA-Z0-9.-]+)(?::([0-9]{1,5}))?/?", url)
    if match:
        host, port = match.groups()
        port = int(port) if port else 443
        if len(host) <= 253 and 1 <= port <= 65535 and all(
            re.fullmatch(DNS_LABEL, label) for label in host.split(".")
        ):
            return (
                f"RYKER_WORKER_CONTROLLER={url}\n"
                f"RYKER_WORKER_HOST={host}\n"
                f"RYKER_WORKER_PORT={port}\n"
            )
    raise SystemExit("Expected an HTTPS controller origin with a DNS hostname or IPv4 address")


def main():
    worker = os.environ["WORKER_ID"]
    if worker != worker.lower() or not re.fullmatch(DNS_LABEL, worker):
        raise SystemExit("WORKER_ID must be a lowercase DNS label")
    controller = controller_environment(os.environ["RYKER_WORKER_CONTROLLER"])
    key = Path("/secrets/operator.pub").read_text().strip()
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/]+=*( [^\r\n]+)?", key):
        raise SystemExit("Expected one operator Ed25519 public key")
    os.umask(0o077)
    # Keep the lock for the VM lifetime, including its shutdown.
    lock = (STATE / ".owner.lock").open("a+")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    identity = STATE / "worker-id"
    disk = STATE / "guest.qcow2"
    if identity.exists():
        if identity.read_text().strip() != worker:
            raise SystemExit("Worker disk belongs to another identity")
    elif disk.exists():
        raise SystemExit("Existing worker disk has no identity")
    else:
        identity.write_text(worker + "\n")
    if not disk.exists():
        if (STATE / "initialized").exists():
            raise SystemExit("Initialized worker lost its guest disk; restore it")
        temporary = STATE / "guest.new"
        subprocess.run(["qemu-img", "convert", "-O", "qcow2", ROOT / "debian.qcow2", temporary], check=True)
        subprocess.run(["qemu-img", "resize", temporary, f"{int(os.environ['DATA_GIB'])}G"], check=True)
        temporary.replace(disk)
    (STATE / "initialized").touch()

    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        (work / "meta-data").write_text(f"instance-id: {worker}\nlocal-hostname: {worker}\n")
        (work / "user-data").write_text((ROOT / "user-data").read_text())
        (work / "operator.pub").write_text(key + "\n")
        (work / "controller.env").write_text(controller)
        subprocess.run(["genisoimage", "-quiet", "-V", "cidata", "-J", "-r", "-o", "seed.iso",
                        "meta-data", "user-data", "operator.pub", "controller.env"], cwd=work, check=True)
        qmp = work / "qmp"
        vm = subprocess.Popen([
            "qemu-system-x86_64", "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "4",
            "-m", "8192", "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-qmp", f"unix:{qmp},server=on,wait=off", "-no-reboot",
            "-drive", f"file={disk},format=qcow2,if=virtio,cache=none",
            "-drive", f"file={work}/seed.iso,format=raw,if=virtio,readonly=on",
            "-drive", f"file={ROOT}/tools.iso,format=raw,if=virtio,readonly=on",
            "-netdev", "user,id=guest,ipv6=off,hostfwd=tcp:127.0.0.1:2222-:22",
            "-device", "virtio-net-pci,netdev=guest",
        ], stdin=subprocess.DEVNULL)
        stopping = False

        def stop(_signal, _frame):
            nonlocal stopping
            stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while vm.poll() is None:
            if stopping:
                with socket.socket(socket.AF_UNIX) as control:
                    control.settimeout(5)
                    control.connect(str(qmp))
                    reader = control.makefile("rb")
                    reader.readline()
                    for command in ["qmp_capabilities", "system_powerdown"]:
                        control.sendall(json.dumps({"execute": command}).encode() + b"\n")
                        while True:
                            response = json.loads(reader.readline())
                            if "error" in response:
                                raise RuntimeError(response["error"])
                            if "return" in response:
                                break
                break
            time.sleep(0.5)
        return vm.wait()


if __name__ == "__main__":
    raise SystemExit(main())
