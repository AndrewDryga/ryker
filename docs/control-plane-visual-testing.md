# Screenshot acceptance

Use the actual running control plane and a separately installed Playwright with
Chromium. The harness does not install dependencies, start runtime workers,
send messages, post to Slack, or call a model.

```sh
node scripts/control-plane-visual.cjs http://127.0.0.1:4321 /tmp/responder-visual-review
```

If Playwright is installed outside Node's normal module search path, set
`RESPONDER_PLAYWRIGHT_MODULE` to that installation's `playwright` directory.
Pass `--filters` for the smaller activity/filters pass during iteration.

The harness captures viewport and full-page PNGs at 1440px and 390px, checks
HTTP responses, LiveView connection, browser/CSP errors, horizontal overflow,
whether the mobile composer covers the transcript, and that the retired pages
(`/card-lab`, `/manual-tests`, `/decisions`, `/calibration`) answer a real 404
without a redirect and never return to navigation.

Detail routes are discovered from real rows. Missing incident/schedule/etc.
records are reported in `manifest.json`; they are not counted as tested populated
states. The manifest records the release version returned with every response.

Screenshots contain organization data. Output must remain outside the repository;
the harness creates a fresh private directory with a random suffix and prints
its path (the parent directory must already exist). It does not reuse an existing
directory or follow a symlink into the repository. Inspect the PNGs at readable scale,
including the dedicated usage-chart captures. A successful script is not a
visual-quality verdict, nor does it establish backend or live Slack parity.

For a focused timeline regression, use a populated real episode:

```sh
node scripts/timeline-visual.cjs http://127.0.0.1:4321/timeline/EPISODE_REFERENCE /tmp/responder-timeline-review
```

This captures 1440px, 900px and 390px layouts, asserts that message/event/request
rows share the same rail, checks prompt source labels, and expands retained
instructions through a server-acknowledged live refresh. It uses the same private
artifact-directory protections and never submits a message or runs a model.
