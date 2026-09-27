# RYKER.md

Written by Ryker from `e07c3c9` on 2026-09-27. This is only an outline from the file list: Ryker could not finish reading the repository, and replaces it on its next refresh.

## Purpose

Ryker is a persistent engineering and operations teammate backed by isolated [Coop](https://github.com/AndrewDryga/coop) sessions and governed Emisar access. Its core is platform-neutral: Slack, GitHub comments and pull-request reviews, and authenticated webhooks are adapters over the same ingress, episode, Work, and Delivery contracts. It can answer, investigate, change code, and prepare reviewed work without turning every request into an incident From [README.md](README.md).

## Components

- [.github/](.github/)
- [brand/](brand/)
- [config/](config/)
- [deploy/](deploy/)
- [docs/](docs/)
- [lib/](lib/)
- [priv/](priv/)
- [scripts/](scripts/)
- [site/](site/)
- [test/](test/)
- [testdata/](testdata/)

## Files that describe it

- [AGENTS.md](AGENTS.md)
- [CLAUDE.md](CLAUDE.md)
- [Dockerfile](Dockerfile)
- [GEMINI.md](GEMINI.md)
- [Makefile](Makefile)
- [README.md](README.md)
- [mix.exs](mix.exs)
- [.agent/Dockerfile](.agent/Dockerfile)
- [brand/README.md](brand/README.md)
- [.agent/tasks/README.md](.agent/tasks/README.md)
- [brand/ryker/README.md](brand/ryker/README.md)
- [deploy/compose/coop/Dockerfile](deploy/compose/coop/Dockerfile)
- [testdata/learning/livebook-intended-zero/README.md](testdata/learning/livebook-intended-zero/README.md)
- [testdata/scenarios/missing-project-answer-is-remembered/README.md](testdata/scenarios/missing-project-answer-is-remembered/README.md)
- [testdata/scenarios/missing-project-answer-unblocks-blocked-checks/README.md](testdata/scenarios/missing-project-answer-unblocks-blocked-checks/README.md)
- [testdata/scenarios/missing-project-candidates-need-one-question/README.md](testdata/scenarios/missing-project-candidates-need-one-question/README.md)
- [testdata/scenarios/missing-project-denied-access-asks-about-access/README.md](testdata/scenarios/missing-project-denied-access-asks-about-access/README.md)
- [testdata/scenarios/missing-project-discovery-failure-stays-honest/README.md](testdata/scenarios/missing-project-discovery-failure-stays-honest/README.md)
- [testdata/scenarios/missing-project-discovery-proves-one-target/README.md](testdata/scenarios/missing-project-discovery-proves-one-target/README.md)
- [testdata/scenarios/missing-project-empty-discovery-still-asks/README.md](testdata/scenarios/missing-project-empty-discovery-still-asks/README.md)
- [testdata/scenarios/missing-project-many-candidates-narrow-first/README.md](testdata/scenarios/missing-project-many-candidates-narrow-first/README.md)
- [testdata/scenarios/missing-project-review-asks-for-context/README.md](testdata/scenarios/missing-project-review-asks-for-context/README.md)
- [test/ryker/coop_fleet/fixtures/README.md](test/ryker/coop_fleet/fixtures/README.md)
- [test/ryker/emisar/fixtures/README.md](test/ryker/emisar/fixtures/README.md)
- [test/ryker/episodes/fixtures/README.md](test/ryker/episodes/fixtures/README.md)
- [test/ryker/slack/fixtures/README.md](test/ryker/slack/fixtures/README.md)

## CI

The GitHub Actions workflows are in [.github/workflows/](.github/workflows/).
