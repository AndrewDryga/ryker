# Releasing Responder

Responder releases are public, tag-driven GitHub Releases. GoReleaser is the single artifact
definition: it builds Linux amd64 and arm64 binaries, creates archives and `checksums.txt`, signs
the checksum manifest through GitHub OIDC and cosign, and publishes the finalized changelog
section. GitHub also records provenance for every archive.

Pushing a version tag is the release-publication boundary. All release preparation before that
push is reversible without rewriting a published release.

Local release checks require the Go version from `go.mod`, ShellCheck, and GoReleaser v2.16.0.

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

Responder has no automatic production deployment. The continuous-delivery boundary publishes
verified service artifacts; an operator explicitly installs and configures them on the target
host.

## Prepare

1. Work from a clean `main` that is not behind `origin/main`.
2. Run `make release-check`. It executes the complete gate, builds the exact unsigned release
   snapshot, verifies both checksums and archive contents, and smoke-tests the host binary. On
   Linux it also executes the packaged native binary.
3. Refuse a no-op release. Compare the latest version tag to `main`; if only documentation or the
   changelog changed, attribute those notes to the existing release instead of cutting a
   byte-identical binary.
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

- `responder_X.Y.Z_linux_amd64.tar.gz`;
- `responder_X.Y.Z_linux_arm64.tar.gz`;
- `checksums.txt`;
- `checksums.txt.bundle`.

The workflow creates a draft first, smoke-tests its local artifacts, records provenance, and only
then makes the release public. A failure after GoReleaser therefore leaves a non-public draft for
inspection rather than a partially verified public release.

Use the verification procedure in [`operations.md`](operations.md#release-verification) against
downloaded assets. It verifies GitHub-hosted provenance for both archives; attestations are not
release assets. Also extract one archive and run `responder version`.

## Failure policy

If the workflow fails before a release is published, inspect and delete any incomplete draft before
retrying. Fix the cause and replace the unpublished tag only after confirming no public asset
exists. Once any release is public, never rewrite its tag or assets; correct it with a new patch
release.
