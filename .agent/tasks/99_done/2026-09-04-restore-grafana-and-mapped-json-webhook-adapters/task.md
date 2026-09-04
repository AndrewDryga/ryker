<!-- TASK SPEC — a fresh agent must work this from this file ALONE.
     FIRST, BEFORE ANY CODE: replace every <…> placeholder below — the real problem and
     where it lives (Context), what proves it's done incl. a green gate (Acceptance), and
     the boring plan (Approach). This thinking IS step one, not a formality. Can't fill it
     honestly? It isn't ready — run: coop tasks block 2026-09-04-restore-grafana-and-mapped-json-webhook-adapters
     Full format + examples: .agent/tasks/README.md -->
---
id: 2026-09-04-restore-grafana-and-mapped-json-webhook-adapters
title: Restore Grafana and mapped JSON webhook adapters
labels: []
updated: 2026-09-04T08:35:47+02:00
---

# Restore Grafana and mapped JSON webhook adapters

**Context:** Universal JSON ingress exists, but old Grafana alert identity and lifecycle semantics and bounded mapped routes were not rebuilt.

**Acceptance criteria:** Grafana firing and resolved cycles correlate deterministically, mapped JSON routes use bounded configured paths, generic ingress remains provider-neutral, and focused adapter tests pass.

**Approach:** Implement provider adapters above Webhooks.Input and route all accepted inputs through the existing Inbox contract.

## Subtasks
- [x] Implement behavior and focused regression tests
- [x] Run make dev-check, review, commit, and update the capability contract
