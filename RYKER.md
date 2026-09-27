# RYKER.md

> Repository knowledge generated from `67d5ee3dff091c293b20a209c648915807f0f2e7`. Facts below come from the linked files. Commands are detected, not executed, unless a later note says otherwise.

## Purpose

Ryker is a persistent engineering and operations teammate backed by isolated [Coop](https://github.com/AndrewDryga/coop) sessions and governed Emisar access. Its core is platform-neutral: Slack, GitHub comments and pull-request reviews, and authenticated webhooks are adapters over the same ingress, episode, Work, and Delivery contracts. It can answer, investigate, change code, and prepare reviewed work without turning every request into an incident.

## Repository map

- [`.agent/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.agent)
- [`.claude/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.claude)
- [`.codex/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.codex)
- [`.gemini/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.gemini)
- [`.githooks/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.githooks)
- [`.github/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.github)
- [`brand/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/brand)
- [`config/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/config)
- [`deploy/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/deploy)
- [`docs/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/docs)
- [`lib/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/lib)
- [`priv/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/priv)
- [`scripts/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/scripts)
- [`site/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/site)
- [`test/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/test)
- [`testdata/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/testdata)

## Languages and dependencies

- Elixir: 1254 source files
- Shell: 23 source files
- JavaScript: 2 source files
- Python: 2 source files

## Setup, build and test

- `mix deps.get` (detected from repository files; not run during setup)
- `mix test` (detected from repository files; not run during setup)
- `make test` (detected from repository files; not run during setup)

## CI and release

GitHub Actions workflows are under [`.github/workflows/`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/.github/workflows). Read the exact workflow before changing release or deployment behavior.

## Conventions and operational notes

Read [`AGENTS.md`](https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/AGENTS.md) before making changes. These files remain authoritative over this summary.

## Unresolved questions

- Confirm production deployment ownership and verification steps if they are not documented in the linked sources.
- Confirm any required secrets, external services, or generated files before running the detected commands.
