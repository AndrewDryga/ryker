#!/usr/bin/env python3
"""Exercise sustained cache pressure in a disposable 768 MiB daemon.

Uses an explicit local Docker-in-Docker image, no registry or model credentials.
The disposable daemon has no network and no persistent or host-mounted volumes.
"""
import argparse
import io
import json
import os
import subprocess
import tarfile
import tempfile
import time
import uuid

from storage_maintenance import inspect_builder, plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="local Docker-in-Docker image (never pulled)")
    arguments = parser.parse_args()
    # Freeze the CLI's selected engine for creation, builds and final cleanup.
    context = os.environ.get("DOCKER_CONTEXT")
    host = os.environ.get("DOCKER_HOST") if not context else None
    if host:
        docker = ["docker", "--host", host]
    else:
        context = context or subprocess.check_output(["docker", "context", "show"], text=True).strip()
        docker = ["docker", "--context", context]
    # Resolve local bytes before starting; no running installation is needed.
    image = subprocess.check_output(
        docker + ["image", "inspect", "--format", "{{.Id}}", arguments.image], text=True).strip()
    name = "ryker-storage-acceptance-" + uuid.uuid4().hex[:12]

    def run(args, data=None, timeout=45):
        with tempfile.TemporaryFile() as output:
            proc = subprocess.run(args, input=data, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            output.seek(0)
            response = output.read(8192).decode(errors="replace")
        if proc.returncode:
            raise RuntimeError(f"acceptance command failed ({proc.returncode}): {response}")
        return response
    nested = docker + ["exec", name, "docker"]
    records = []
    try:
        run(docker + ["run", "--pull=never", "--detach", "--name", name, "--network", "none", "--privileged",
                      "--memory", "1g", "--memory-swap", "1g", "--tmpfs", "/var/lib/docker:rw,size=768m",
                      "--tmpfs", "/tmp:rw,size=128m", "--env", "DOCKER_TLS_CERTDIR=", image,
                      "dockerd", "--host=unix:///var/run/docker.sock", "--storage-driver=vfs",
                      "--iptables=false", "--bridge=none"])
        deadline = time.monotonic() + 30
        while True:
            try:
                run(nested + ["info"], timeout=3)
                break
            except (RuntimeError, subprocess.TimeoutExpired):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.25)
        # Incompressible distinct inputs ensure each build actually consumes
        # storage. Removing only our image leaves its regenerable cache behind.
        payload = os.urandom(8 * 1024 * 1024)
        capacity = 768 * 1024 * 1024
        for iteration in range(16):
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w") as tar:
                for filename, contents in [("Dockerfile", b"FROM scratch\nCOPY payload /payload\n"),
                                           ("payload", str(iteration).encode() + payload)]:
                    entry = tarfile.TarInfo(filename)
                    entry.size = len(contents)
                    tar.addfile(entry, io.BytesIO(contents))
            tag = f"pressure-fixture:{iteration}"
            run(docker + ["exec", "-i", name, "docker", "build", "--network=none", "--progress=plain", "--tag", tag, "-"], archive.getvalue())
            run(nested + ["image", "rm", tag])
            cache = inspect_builder(nested, run)
            policy = plan(capacity, capacity // 2, cache, False)
            if policy["prune"]:
                run(nested + ["builder", "prune", "--builder", "default", "--force",
                              "--max-used-space", str(policy["cache_budget_bytes"]),
                              "--min-free-space", str(policy["target_free_bytes"]), "--reserved-space", "0"])
            after = inspect_builder(nested, run)
            # Docker rounds human-readable totals; allow one MiB for rounding.
            if after > policy["cache_budget_bytes"] + 1024 * 1024:
                raise AssertionError(f"cache did not converge: {after} > {policy['cache_budget_bytes']}")
            records.append({"iteration": iteration, "cache_before_bytes": cache, "cache_after_bytes": after})
        # Source-reference restart durability is covered by Coop's store tests.
        # This fixture proves real Docker cache convergence, not session custody.
        print(json.dumps({"daemon_capacity_bytes": capacity, "iterations": records,
                          "result": "bounded cache under repeated builds"}, indent=2))
    finally:
        subprocess.run(docker + ["rm", "--force", "--volumes", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
