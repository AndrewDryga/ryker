#!/usr/bin/env python3
"""Reuse qualified optional-model images; build only changed or missing images with headroom."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
from string import Template
import subprocess
import sys
import tempfile

LABEL = "dev.emisar.ryker.model-build"
SERVICES = ("whisper", "whisper-detect", "embeddings", "routing-model")


def command(argv):
    timeout = 1800 if "build" in argv else 240 if "up" in argv else 60 if "--prepare-build" in argv else 20
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        # Config can include credentials. Never print a command's arbitrary response here.
        raise RuntimeError("model command failed; inspect the model service logs")
    return result.stdout


def fingerprint(service):
    build = dict(service["build"])
    context = Path(build.pop("context"))
    dockerfile = context / build.pop("dockerfile", "Dockerfile")
    recipe = dockerfile.read_bytes()
    # The pinned recipes copy their build stage or download a checksum-pinned URL.
    # Refuse local inputs until their bytes are included in the identity.
    for line in recipe.decode().splitlines():
        if not re.match(r"\s*(COPY|ADD)\s", line, re.I):
            continue
        if re.match(r"\s*COPY\s+--from=", line, re.I):
            continue
        fields = shlex.split(Template(line).safe_substitute(build.get("args", {})))
        options = [field for field in fields[1:] if field.startswith("--")]
        sources = [field for field in fields[1:] if not field.startswith("--")][:-1]
        remote = (fields[0].upper() == "ADD" and sources
                  and all(source.startswith("https://") for source in sources)
                  and any(re.fullmatch(r"--checksum=sha256:[0-9a-f]{64}", option) for option in options))
        if not remote:
            raise ValueError("model recipe has local sources not covered by its build identity")
    ignored = context / ".dockerignore"
    material = {"build": build, "dockerfile": recipe.hex(),
                "dockerignore": ignored.read_bytes().hex() if ignored.exists() else "",
                "platform": service.get("platform")}
    return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def start_models(env_file, compose_file, run=command):
    compose = ["docker", "compose", "--env-file", str(env_file), "--file", str(compose_file)]
    enabled = run(compose + ["config", "--services"]).splitlines()
    names = [name for name in SERVICES if name in enabled]
    if not names:
        return True
    config = json.loads(run(compose + ["config", "--format", "json", *names]))
    success = True
    for name in names:
        try:
            service = config["services"][name]
            expected = fingerprint(service)
            try:
                actual = run(["docker", "image", "inspect", service["image"], "--format",
                              '{{ index .Config.Labels "' + LABEL + '" }}']).strip()
            except RuntimeError:
                actual = None
            if actual != expected:
                # A controller build's earlier measurement cannot authorize a later
                # multi-GB model download. This guard preserves sessions and volumes.
                run([sys.executable, str(Path(__file__).with_name("storage_maintenance.py")),
                     "--prepare-build", "--env-file", str(env_file)])
                with tempfile.TemporaryDirectory(prefix="ryker-model-build-") as directory:
                    override = Path(directory) / "models.json"
                    override.write_text(json.dumps({"services": {name: {"build": {"labels": {LABEL: expected}}}}}))
                    run(compose + ["--file", str(override), "build", name])
                observed = run(["docker", "image", "inspect", service["image"], "--format",
                                '{{ index .Config.Labels "' + LABEL + '" }}']).strip()
                if observed != expected:
                    raise RuntimeError("built model image does not match its build inputs")
                print(f"Built {name} for its current model inputs.", flush=True)
            else:
                print(f"Reusing {name}; its model inputs are unchanged.", flush=True)
            run(compose + ["up", "--detach", "--no-build", "--no-deps", "--wait",
                           "--wait-timeout", "180", name])
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired):
            print(f"{name} could not be qualified or started. The controller release is unchanged; inspect model logs and storage before retrying.", file=sys.stderr)
            success = False
    return success


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--compose-file", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        ready = start_models(args.env_file, args.compose_file)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired):
        print("Optional model configuration could not be read; the controller release is unchanged.", file=sys.stderr)
        ready = False
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
