# Releasing Ryker

Ryker releases are public, tag-driven GitHub Releases. The canonical service artifact is the
self-contained Linux amd64 Elixir release. The workflow builds and structurally checks it, adds the
three installation helpers, signs `checksums.txt` through GitHub OIDC and cosign, and publishes the
finalized changelog section. GitHub records build provenance for the archive.

Pushing a version tag is the release-publication boundary. All release preparation before that
push is reversible without rewriting a published release.

Local release checks require the Erlang and Elixir versions from `.tool-versions` and ShellCheck.
Commit first, then prove the exact Elixir artifact without touching a production listener:

```bash
make elixir-release-check
make elixir-candidate-check
```

The release identity is the semantic tag for a public release and otherwise the exact Git commit.
The candidate check installs that archive immutably, migrates a disposable PostgreSQL database,
boots and restarts the release against it, takes and restores a custom-format backup into a fresh
database, boots from the restored state, requires health/readiness/metrics throughout, and stops it
cleanly. Production deployment is
one normal writer replacement; durable recovery is in PostgreSQL, not in canary/promote metadata.
CI still runs the full gate independently on a clean runner.

## Repository setup

Before the first release:

1. create `AndrewDryga/responder` and configure this checkout's `origin`;
2. enable GitHub private vulnerability reporting;
3. protect `main`, require the CI `check` and `release-snapshot` jobs, require current branches,
   and block force pushes and branch deletion;
4. add a tag ruleset for `v*` that restricts tag creation and deletion to release maintainers;
5. create a protected `release` environment with required reviewers and no deployment branches
   except protected branches and `v*` tags;
6. restrict allowed Actions to GitHub-authored actions and the SHA-pinned third-party actions in
   the workflows, and require approval for first-time external contributors;
7. keep the default Actions token read-only; the release job declares its narrow write and OIDC
   permissions itself.

Ryker has no automatic production deployment. The continuous-delivery boundary publishes
verified service artifacts; an operator explicitly installs and configures them on the target
host.

## Prepare

1. Work from a clean `main` that is not behind `origin/main`.
2. Run `make release-check`. It executes the complete gate, builds and inspects the exact unsigned
   Elixir release, and boots the candidate against disposable PostgreSQL.
3. Refuse a no-op release. Compare the latest version tag to `main`; if only documentation or the
   changelog changed, attribute those notes to the existing release instead of cutting a
   byte-identical archive.
4. Treat the `## Unreleased` entries as the release scope. Replace placeholders and ensure they
   describe user-visible behavior rather than commit history.

## Finalize

1. Choose semantic version `X.Y.Z`: new functionality is a minor bump, fixes and hardening are a
   patch bump, and incompatible behavior is a major bump. An explicitly requested version wins.
2. Rename the top `## Unreleased` heading to `## X.Y.Z`; keep it as the first changelog section.
3. Commit only that finalization, then create an annotated tag on the commit:

   ```bash
   git tag -a vX.Y.Z -m vX.Y.Z
   ```

4. Add a fresh empty `## Unreleased` section above `## X.Y.Z` in a later commit. The workflow
   requires the tagged commit to remain reachable from protected `origin/main`.

The workflow rejects a non-semantic tag, a lightweight tag, a changelog heading that does not
match the tag, or empty release notes.

## Publish

Show the version and release summary and obtain explicit confirmation before pushing. Publication
is intentionally two commands:

```bash
git push origin main
git push origin vX.Y.Z
```

Watch `.github/workflows/release.yml` to completion, then confirm the GitHub Release contains:

- `ryker_X.Y.Z_elixir_linux_amd64.tar.gz`;
- `install-elixir-release.sh`, `check-elixir-release.sh`, and `activate-elixir-release.sh`;
- `checksums.txt`;
- `checksums.txt.bundle`.

The workflow smoke-tests its local artifacts before creating the draft, records provenance, and
only then makes the release public.

Use the verification and installation procedure in
[`operations.md`](operations.md#release-verification) against downloaded assets. It verifies the
OIDC-signed manifest and GitHub-hosted provenance before any archive is listed, extracted, or
executed. Attestations are not release assets.

## Failure policy

If the workflow fails before a release is published, inspect and delete any incomplete draft before
retrying. Fix the cause and replace the unpublished tag only after confirming no public asset
exists. Once any release is public, never rewrite its tag or assets; correct it with a new patch
release.
