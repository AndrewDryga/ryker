#!/usr/bin/env python3
"""Bound regenerable build cache in the installation's two Docker builders.

The worker's session GC cannot see the outer daemon. In November 2026 both
installations refused messages with unused build cache still filling their disks.
Run from the existing watchdog, and before builds; never delete work or volumes.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

GIB = 1024 ** 3
ROOT = Path(__file__).resolve().parent.parent


def size_bytes(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)", value)
    if not match:
        raise ValueError("unrecognized Docker cache size")
    units = {"B": 1, "kB": 1000, "KB": 1000, "MB": 1000**2, "GB": 1000**3,
             "TB": 1000**4, "KiB": 1024, "MiB": 1024**2, "GiB": GIB, "TiB": 1024**4}
    return int(float(match[1]) * units[match[2]])


def parse_df(output):
    lines = output.strip().splitlines()
    if len(lines) < 2:
        raise ValueError("missing Docker filesystem measurement")
    fields = lines[-1].split()
    if len(fields) < 4:
        raise ValueError("incomplete Docker filesystem measurement")
    capacity, available = int(fields[1]) * 1024, int(fields[3]) * 1024
    if capacity <= 0 or not 0 <= available <= capacity:
        raise ValueError("invalid Docker filesystem measurement")
    return capacity, available


def plan(capacity, free, cache, host_pressure):
    # Start reclaiming with twice the admission reserve left. Leave room for
    # builds/checkpoints; a byte budget also catches growth on large quiet hosts.
    target = min(capacity // 4, max(12 * GIB, capacity // 10))
    budget = min(8 * GIB, capacity // 20)
    # VM free space is not physical-host free space. Both normal Docker goals
    # can already be met while the sparse VM image has filled the host. A
    # positive one-byte cap makes every unused cache entry eligible in that
    # case; zero means "no maximum" to BuildKit.
    if host_pressure:
        budget = 1
    return {"prune": host_pressure or free < target or cache > budget,
            "target_free_bytes": target, "cache_budget_bytes": budget}


def recovered(before, after, target):
    return after >= target


def command(args, timeout=12):
    # Docker pruning can print one line per record. Keep it off the supervisor's
    # output and bound what gets read back; the CLI never sees credential files.
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Docker may launch Buildx as a child. End our whole process group,
            # not just the CLI that otherwise leaves cleanup outside the lock.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            # SIGKILL delivery is asynchronous. Reaping the CLI alone does not
            # prove its plugin has closed its API connection yet.
            termination_deadline = time.monotonic() + 2
            while True:
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    break
                if time.monotonic() >= termination_deadline:
                    raise RuntimeError("timed-out Docker process group has not finished exiting") from None
                time.sleep(0.01)
            raise
        length = output.tell()
        if length > 1024 * 1024:
            raise RuntimeError("Docker response exceeded 1 MiB")
        output.seek(0)
        text = output.read().decode("utf-8", errors="replace")
    if process.returncode:
        # Avoid persisting arbitrary daemon/registry responses or build context names.
        raise RuntimeError(f"Docker command failed (exit {process.returncode})")
    return text


def host_disk(path):
    usage = shutil.disk_usage(path)
    target = min(usage.total // 5, max(10 * GIB, min(usage.total // 20, 25 * GIB)))
    return {"capacity_bytes": usage.total, "free_bytes": usage.free,
            "target_free_bytes": target, "pressure": usage.free < target}


def inspect_builder(prefix, run):
    rows = run(prefix + ["system", "df", "--format", "{{json .}}"])
    caches = [json.loads(line) for line in rows.splitlines() if line.strip()]
    cache = next(row for row in caches if row["Type"] == "Build Cache")
    return size_bytes(cache["Size"])


def inspect_host_builder(prefix, run):
    # `system df` also sizes every volume. On a host holding 274 GB of them it
    # took 9 of its 12 seconds idle, and a Docker busy with an upgrade timed it
    # out and refused the build (2026-11-03). Buildx reads only the cache, and
    # its total is the figure a Docker 29 host's `system df` reports.
    builder = run(prefix + ["context", "show"]).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", builder):
        raise RuntimeError("Docker context identity is invalid")
    total = re.search(r"^Total:\s+(\S+)\s*$", run(prefix + ["buildx", "du", "--builder", builder]), re.MULTILINE)
    if not total:
        raise ValueError("missing Docker build cache total")
    return size_bytes(total[1])


def maintain(env_file, apply=False, run=command, measure_host=host_disk, *, context=None, compose_file=None):
    before_host = measure_host(env_file.parent)
    result = {"version": 1, "measured_at": int(time.time()), "host": before_host,
              "builders": [], "errors": []}
    docker = os.environ.get("RYKER_STORAGE_DOCKER", "docker")
    outer = [docker]
    # Freeze the container ID for this pass: a concurrent worker upgrade may
    # replace the worker, but cannot redirect exec into an unrelated container.
    try:
        if context is None and os.environ.get("DOCKER_HOST") and not os.environ.get("DOCKER_CONTEXT"):
            raise RuntimeError("storage maintenance requires an explicit Docker context when DOCKER_HOST is set")
        context = context or run(outer + ["context", "show"]).strip()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", context):
            raise RuntimeError("Docker context identity is invalid")
        endpoint = json.loads(run(outer + ["context", "inspect", context, "--format", "{{json .Endpoints.docker.Host}}"] ))
        if not isinstance(endpoint, str) or not endpoint.startswith("unix:///"):
            raise RuntimeError("storage maintenance requires a local Unix Docker endpoint; run it on the Docker host")
        outer += ["--context", context]
    except (RuntimeError, ValueError, subprocess.TimeoutExpired, OSError) as error:
        result["errors"].append(str(error) if isinstance(error, RuntimeError) else "Docker context measurement failed")
        return result
    container = None
    capacity = free = None
    builders = [("host", outer)]
    try:
        container = run(outer + ["compose", "--env-file", str(env_file), "--file",
                        str(compose_file or ROOT / "compose.yml"), "ps", "--quiet", "ryker-coop-docker"]).strip()
        if not re.fullmatch(r"[0-9a-f]{12,64}", container):
            raise RuntimeError("worker Docker daemon is unavailable")
        capacity, free = parse_df(run(outer + ["exec", container, "df", "-Pk", "/var/lib/docker"]))
        result["docker"] = {"capacity_bytes": capacity, "free_bytes": free,
                            "target_free_bytes": plan(capacity, free, 0, False)["target_free_bytes"]}
        builders.append(("worker", outer + ["exec", container, "docker"]))
    except (RuntimeError, ValueError, subprocess.TimeoutExpired, OSError) as error:
        result["errors"].append(str(error) if isinstance(error, RuntimeError) else "Docker storage measurement failed")
    for name, prefix in builders:
        item = {"name": name, "free_before_bytes": free, "pruned": False}
        result["builders"].append(item)
        try:
            inspect = inspect_host_builder if name == "host" else inspect_builder
            item["cache_bytes"] = inspect(prefix, run)
            host_pressure = measure_host(env_file.parent)["pressure"]
            if capacity is None:
                # Outer cache recovery remains available if the nested daemon
                # is down. Unknown VM headroom never passes a build preflight.
                budget = 1 if host_pressure else 8 * GIB
                item.update(prune=host_pressure or item["cache_bytes"] > budget,
                            cache_budget_bytes=budget, target_free_bytes=0)
            else:
                item.update(plan(capacity, free, item["cache_bytes"], host_pressure))
            if apply and item["prune"]:
                # Use the current Docker context's default builder, not a user's
                # buildx-selected remote builder. Modern Docker aliases builder to
                # buildx, so verify this contract before any cache mutation.
                help_text = run(prefix + ["builder", "prune", "--help"])
                for flag in ("--max-used-space", "--min-free-space", "--reserved-space", "--builder"):
                    if flag not in help_text:
                        raise RuntimeError("Docker builder lacks bounded prune options; upgrade Docker")
                builder = run(prefix + ["context", "show"]).strip()
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", builder):
                    raise RuntimeError("Docker context identity is invalid")
                prune_prefix = prefix
                prune_args = ["builder", "prune"]
                if name == "worker":
                    # The in-container process must end before its outer exec
                    # client times out, including when the API stops answering.
                    plugins = json.loads(run(prefix + ["info", "--format", "{{json .ClientInfo.Plugins}}"] ))
                    plugin = next(p["Path"] for p in plugins if p["Name"] == "buildx")
                    if not isinstance(plugin, str) or not os.path.isabs(plugin):
                        raise RuntimeError("nested Buildx plugin has no absolute executable path")
                    # BusyBox timeout signals one process. Invoking the plugin
                    # directly avoids leaving it behind a killed docker CLI.
                    prune_prefix = outer + ["exec", container, "timeout", "-s", "TERM", "-k", "2", "16", plugin]
                    prune_args = ["prune"]
                run(prune_prefix + prune_args + ["--builder", builder, "--force",
                              "--max-used-space", str(item["cache_budget_bytes"]),
                              "--min-free-space", str(item["target_free_bytes"]),
                              "--reserved-space", "0"], timeout=20)
                item["pruned"] = True
            if capacity is not None:
                _, free = parse_df(run(outer + ["exec", container, "df", "-Pk", "/var/lib/docker"]))
                item["free_after_bytes"] = free
                item["free_delta_bytes"] = free - item["free_before_bytes"]
                item["recovered"] = recovered(item["free_before_bytes"], free, item["target_free_bytes"])
        except (RuntimeError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired, OSError) as error:
            item["error"] = str(error) if isinstance(error, RuntimeError) else "Docker cache measurement or cleanup failed"
            result["errors"].append(name + ": " + item["error"])
    result["host"] = measure_host(env_file.parent)
    result["host"]["free_delta_bytes"] = result["host"]["free_bytes"] - before_host["free_bytes"]
    if "docker" in result:
        result["docker"]["free_bytes"] = free
    return result


def summary(report):
    issues = list(report.get("errors", []))
    for name in ("host", "docker"):
        disk = report.get(name)
        if disk and disk["free_bytes"] < disk["target_free_bytes"]:
            issues.append(f'{name} disk has {disk["free_bytes"] / GIB:.1f} GiB free; target {disk["target_free_bytes"] / GIB:.1f} GiB')
    return "; ".join(issues)


def build_ready(report):
    # Early-warning targets are deliberately higher than the build reserve.
    # Do not deadlock the repair release on space occupied by unrelated host data.
    return not report["errors"] and all(
        name in report and report[name]["free_bytes"] >= min(report[name]["capacity_bytes"] // 5, 12 * GIB)
        for name in ("host", "docker")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--maintain", action="store_true", help="reclaim unused build cache within byte budgets")
    parser.add_argument("--prepare-build", action="store_true", help="recover headroom or refuse a new build")
    parser.add_argument("--status", action="store_true", help="read the last measurement without contacting Docker")
    parser.add_argument("--env-file", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    install = Path(os.environ.get("RYKER_INSTALL_STATE", ROOT / ".ryker"))
    env_file = args.env_file or install / "compose.env"
    state = env_file.parent / "storage"
    if args.status:
        try:
            report = json.loads((state / "status.json").read_text())
            age = int(time.time()) - report["measured_at"]
            freshness = "STALE " if age > 600 else ""
            print(f"{freshness}storage measured {age}s ago: " + (summary(report) or "headroom available"))
        except (OSError, ValueError, KeyError):
            print("storage has no maintenance measurement")
        return
    if not env_file.is_file():
        parser.error("no Compose installation")
    state.mkdir(mode=0o700, exist_ok=True)
    with (state / "maintenance.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if args.prepare_build:
                print("storage maintenance is already running; retry the build after it completes")
                sys.exit(1)
            try:
                previous = json.loads((state / "status.json").read_text())
                if not 0 <= time.time() - previous["measured_at"] < 600:
                    raise ValueError("stale measurement")
                print(summary(previous))
            except (OSError, ValueError, KeyError):
                print("storage maintenance is running; no recent capacity measurement")
            return
        if args.maintain and not args.prepare_build:
            try:
                previous = json.loads((state / "status.json").read_text())
                if 0 <= time.time() - (previous.get("maintained_at") or 0) < 300:
                    print(summary(previous))
                    return
            except (OSError, ValueError, KeyError):
                pass
        deadline = time.monotonic() + 50
        def bounded_command(argv, timeout=12):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("storage maintenance reached its 50-second deadline")
            if "prune" in argv and "--force" in argv and remaining < 21:
                raise RuntimeError("storage maintenance has insufficient time for another bounded cleanup")
            return command(argv, min(timeout, remaining))
        report = maintain(env_file, args.maintain or args.prepare_build, bounded_command)
        report["maintained_at"] = int(time.time()) if args.maintain or args.prepare_build else None
        temporary = state / "status.json.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(state / "status.json")
        message = summary(report)
        print(message)
        if args.prepare_build and not build_ready(report):
            print("insufficient measured headroom for a new build")
            sys.exit(1)


if __name__ == "__main__":
    main()
