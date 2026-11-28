---
name: verify-rollout
description: Check whether a requested release reached every intended installation and whether each installation is ready.
---

# Verify a rollout

1. Identify the intended release and installations from the request and its deployment configuration. Resolve a branch or tag to its exact revision. If the target is ambiguous, say what you could establish.
2. Find the build or deployment receipt for each installation. Record which revision it selected and whether the operation finished.
3. Use the available read-only checks for each installation. Compare the revision reported by the serving application with the intended revision and check readiness. If traffic is split across revisions, report the split.
4. Report each installation's observed revision, readiness and evidence. Identify mismatches and missing observations explicitly. A successful build or deployment receipt alone leaves the served version unverified.

Verification uses the access granted to this task. A discrepancy is a finding. Starting a deployment, changing traffic or restarting a service requires separate authority.
