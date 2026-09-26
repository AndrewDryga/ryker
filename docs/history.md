# History

Short notes on documents and paths this repository retired, so that a reader who follows an old
link or an old commit message knows where the current description lives. Newest first.

## 2026-09-25 — the bare-host deployment path retired

`scripts/deploy.sh` used to build a release archive, install it under `~/.local/lib/ryker-elixir`
(macOS, launchd) or `/usr/local/lib/ryker` (Linux, systemd) and restart the service; `deploy/launchd`,
`deploy/systemd`, `scripts/install-elixir-release.sh`, `activate-elixir-release.sh`,
`check-running-elixir-release.sh`, `check-elixir-candidate.sh` and a launchd-only watchdog served
that path, and GitHub Releases shipped the installer scripts beside the archive. Docker Compose has
been the supported deployment since 2026-09-20 ([operations.md](operations.md)). `scripts/deploy.sh`
is now the Compose deploy of HEAD (the project instructions, "Finish by deploying"), the watchdog
reads `.ryker/compose.env` and checks the project's containers and the pinned version, live
acceptance runs inside the `ryker` container ([testing.md](testing.md#live-acceptance)), and a
release is the archive plus its signed checksum manifest ([releasing.md](releasing.md)).

## 2026-09-25 — planning documents folded into the current docs

Five planning documents from the Go-to-Elixir rewrite (August–September 2026) were deleted. They
described work as targets; the documents below describe it as it runs.

- `docs/architecture-next.md` (target architecture and verification plan, last updated 2026-09-05):
  the one durable episode/Work/Delivery ownership model it planned is the implementation described in
  [elixir-episode-kernel.md](elixir-episode-kernel.md), [elixir-ingress-admission.md](elixir-ingress-admission.md),
  [elixir-work-runtime.md](elixir-work-runtime.md) and [elixir-platform-adapters.md](elixir-platform-adapters.md);
  its testing strategy is [testing.md](testing.md) and its model evaluation is `make eval-world`.
- `docs/control-plane-redesign.md` (LiveView throughout, fast admission with unchanged host authority,
  model-request inspection, complete invocation accounting, organization-scoped learning, simpler
  configuration): the control plane as built is [control-plane.md](control-plane.md); its visual
  checks are [control-plane-visual-testing.md](control-plane-visual-testing.md).
- `docs/control-plane-ux-followup.md` (the 5 September 2026 usability pass): implemented. The accounting
  limits it recorded still hold — estimates use the rate card verified on 2026-09-05, Codex ACP fresh
  input excludes cache reads and output already includes reasoning, so reasoning is never charged
  twice — and the Usage page's own cost-method section states them.
- `docs/product-completion.md` (the 2026-09-05 completion checklist): superseded by the manual
  qualification journeys in [testing.md](testing.md#manual-qualification). Its standing rules
  survive elsewhere: Slack acceptance is confined to the joined test channel, and a Ryker deploy
  never restarts or installs Coop.
- `docs/elixir-slack-admission-corpus.md` (a read-only review of the Blitz and Emisar databases taken
  2026-08-27: 1,708 Work episodes, 2,812 agent runs, 148 retained Slack inputs, 391 reviewed quality
  findings). Its repeated failure shapes — prior work silently discarded by a newer lifecycle update,
  separate external runs merged because their cards shared an app or a time, one lifecycle split by
  a wording change, a new cycle inheriting an old thread, a later human message superseding an
  undelivered answer, provider phrase rules treating material changes as duplicates — became the
  admission contract in [elixir-ingress-admission.md](elixir-ingress-admission.md), and its cases are
  the harvested scenarios under `testdata/scenarios/`, each with its own provenance note. The corpus
  holds no cross-channel join: the only multi-thread joins on disk are root-to-root inside one
  channel, which is why the one cross-conversation scenario is authored and says so.
