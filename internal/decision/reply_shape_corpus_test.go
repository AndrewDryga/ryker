package decision_test

import (
	"strings"
	"testing"

	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
)

// The calibration corpus: sixteen replies Ryker actually posted, with the
// verdict a reader gave each one after reading it.
//
// scripts/reply-shape-replay.sh replays every posted reply in the live state
// databases through this package. The first ladder to ship rejected 31 of 245,
// and reading all 31 said 22 of them were good answers being charged a whole
// extra model turn for a sentence. These sixteen are the messages that moved
// the numbers, so a later change to the ladder has to argue with real traffic
// rather than with taste.
//
// Slack user IDs and the tailnet Grafana host are replaced. Run identifiers,
// commit shas and workspace names are the ones the messages carried and already
// appear in this repository's other fixtures; nothing here is a credential.
func TestReplyShapeAgainstPostedReplies(t *testing.T) {
	for _, test := range postedReplies {
		t.Run(test.name, func(t *testing.T) {
			correction := decisionpkg.ReplyShapeCorrection(
				test.trigger, test.lane, "reply", test.reply,
			)
			got := ""
			switch {
			case strings.Contains(correction, "bound for a message"):
				got = "length"
			case strings.Contains(correction, "hands the question back"):
				got = "handback"
			}
			if got != test.expect {
				t.Fatalf("verdict %q, want %q for a %d-word reply to a %d-word trigger "+
					"(budget %d): %s",
					got, test.expect,
					decisionpkg.ProseWordCount(test.reply),
					len(strings.Fields(test.trigger)),
					decisionpkg.ReplyWordBudget(test.trigger, test.lane),
					correction)
			}
		})
	}
}

// postedReply is one real reply with the verdict a reader gave it. It is a
// package-level table rather than a literal inside one test because the quality
// judge has to be measured against the same traffic: a judge that disagrees
// with the host about these sixteen is a second bar, and two bars are worse
// than one.
type postedReply struct {
	name    string
	lane    string
	trigger string
	reply   string
	// expect is "" when the reply must post as written, "length" when the
	// word bound must reject it, "handback" when its closing must.
	expect string
}

var postedReplies = []postedReply{
	// blitz 2026-08-08
	{
		name:    "terraform triage two words over the old bound",
		lane:    "investigation",
		trigger: "Run notification for <https://app.terraform.io/app/SME-Blitz/blitz-infra|SME-Blitz/blitz-infra> <https://app.terraform.io/app/SME-Blitz/blitz-infra/runs/run-RfAD7Behw2dEE3s2|Run run-RfAD7Behw2dEE3s2> CI apply — e2181781dcf69f4f4fd891b6499cd3ccca2246a2 Run Planned - Needs Confirmation",
		reply:   "The production plan is clean and just needs a confirm click.\n\n`run-RfAD7Behw2dEE3s2` carries one line: `website_image_tag` `7abf8d9e` → `bdcbe2bf` in `terraform/versions/web.tf`. That's the entire delta since the last applied run (`59cfdf15`, applied 21:21 UTC yesterday) — no backlog riding along.\n\n`blitz-infra` is the **production** workspace, and production's website group is scaled to zero (`app_website.tf:187`, _\"migrated to VA1\"_). So the apply swaps the instance template and the group's version pointer and fires the Sentry release hook — it rolls no serving VMs.\n\nThe build users actually get ships from the separate `va1-apps` workspace, which resolves the same tag onto 4 Nomad replicas behind blitz.gg. Watch that run, not this one, to confirm the new site is live — assuming `va1-apps` doesn't pin its own `website_image_tag`, which I can't read from here.\n\nRun state is as of the 09:23:43Z notification. Separately, the tft_ks Reaper schedule cleared at 02:12 UTC — that backlog is closed.",
		expect:  "",
	},
	// emisar 2026-08-04
	{
		name:    "two-part question answered with structured evidence",
		lane:    "investigation",
		trigger: "<@ryker> why you did not comment on this one? how is health?",
		reply:   "I did not comment because `Run Applying` is an intermediate notification; the standing behavior waits for a terminal event or a reviewable plan to avoid noisy lifecycle narration. In this case, staying silent hid a useful distinction: **production is serving normally, but the rollout is not converged**.\n\nFresh checks show:\n\n- Both expected Portal backends are `HEALTHY` and `RUNNING`.\n- Cloud SQL is `RUNNABLE`.\n- Successful 2xx traffic continued through 20:44 UTC, with no 5xx series observed in the preceding 30-minute query.\n- The MIG is still unstable because creation of replacement instance `emisar-fc99` hit `ZONE_RESOURCE_POOL_EXHAUSTED` for `e2-small` capacity in `us-central1-f`.\n- Availability is currently preserved: two healthy instances remain serving and the rollout policy allows zero unavailable instances.\n\nSo the current assessment is: **service health is good; rollout health is degraded/stalled by zonal capacity**. The safest immediate course is to leave the healthy instances serving while the MIG retries. Escalate to a deliberate zone or machine-shape change only if the capacity error persists.\n\nOne gap remains: I could not independently read HCP’s terminal run state because the governed Terraform inspection action still fails on the runner’s jq/Oniguruma compatibility issue. That gap does not overturn the live serving-health evidence above.",
		expect:  "",
	},
	// blitz 2026-08-04
	{
		name:    "engineering report naming the commit and the gate",
		lane:    "incident",
		trigger: "Install the Emisar GitHub CLI pack",
		reply:   "**Completed and committed** as `ee64e015284b2b85e195ff5359288f1b27e50afd` (`Emisar: install GitHub CLI pack`).\n\n- Refreshed the [pack registry](https://emisar.example.com/packs/github-cli) and pinned `github-cli` v0.1.9 with SHA-256 `35ca71f4`.\n- Added `gh`, `gh.*` admission, and `GH_TOKEN` inheritance.\n- Added an ephemeral sensitive GitHub input, write-only Secret Manager version, secret-specific accessor, and service-start credential fetch. The token is absent from Terraform state, VM metadata, logs, and persistent runner configuration.\n- Documented repository-scoped read-only Actions, Checks, and Contents permissions, explicitly excluding merge, rerun, and workflow dispatch rights.\n- Updated render fixtures and post-apply checks.\n\nValidation passed: module fixture init/validate/render, rendered `bash -n`, recursive Terraform formatting, production offline init/validate, and `git diff --check`. Lock-file platform churn was restored. The working tree is clean.\n\nA state-aware production plan was not run because this isolated session has the backend disabled and does not expose the production HCP Terraform workspace variables. No credentials were fabricated, and nothing was pushed, deployed, applied, or otherwise mutated outside the repository.",
		expect:  "",
	},
	// blitz 2026-08-04
	{
		name:    "43-word apply report closing on remaining review",
		lane:    "investigation",
		trigger: "Run notification for <https://app.terraform.io/app/SME-Blitz/blitz-infra|SME-Blitz/blitz-infra> <https://app.terraform.io/app/SME-Blitz/blitz-infra/runs/run-JDCm9fFTK6uZq5BM|Run run-JDCm9fFTK6uZq5BM> Triggered via UI Run Planned - Needs Confirmation",
		reply:   "**Applied successfully:** `run-JDCm9fFTK6uZq5BM` completed with one addition, `google_billing_account_iam_member.emisar_runner_billing_viewer`, and no managed updates, deletions, or replacements.\n\nNo failed or partial execution was reported. Independent inspection of the resulting billing-account IAM policy was not available, and the separate **63 detected drift entries** still need review.",
		expect:  "",
	},
	// emisar 2026-08-07
	{
		name:    "44-word recovery note closing on a decision",
		lane:    "investigation",
		trigger: "*<https://console.cloud.google.com/monitoring/alerting/alerts/0.ob58yip74620?channelType=slack&amp;project=emisar|Emisar: Portal VM CPU High>* CPU utilization for emisar emisar-29qs with metric labels {instance_name=emisar-29qs} and metadata labels {cluster_name=emisar} is above the threshold of 0.850 with a value of 0.893. Alert status Alert open No severity *Documentation* Portal VM CPU utilization has remained above 85% for five minutes. Inspect the affected instance, application load, and most recent rollout before changing capacity. *<https://console.cloud.google.com/monitoring/alerting/alerts/0.ob58yip74620?channelType=slack&amp;project=emisar|View alert>* *<https://console.cloud.google.com/monitoring/alerting/alerts/0.ob58yip74620?channelType=slack&amp;project=emisar|Emisar: Portal VM CPU High>* CPU utilization for emisar emisar-29qs with metric labels {instance_name=emisar-29qs} and metadata labels {cluster_name=emisar} is above the threshold of 0.850 with a value of 0.893. Alert status Alert open No severity *Documentation* Portal VM CPU utilization has remained above 85% for five minutes. Inspect the affected instance, application load, and most recent rollout before changing capacity. *<https://console.cloud.google.com/monitoring/alerting/alerts/0.ob58yip74620?channelType=slack&amp;project=emisar|View alert>*",
		reply:   "Portal VM `emisar-29qs` **recovered at the metric level**: CPU fell to 63.7%, and fresh database-aware readiness checks pass. Full service recovery and cause remain unverified because the deployed revision and process-level host pressure aren’t observable; no restart, rollback, or capacity change is justified now.",
		expect:  "",
	},
	// emisar 2026-08-04
	{
		name:    "47-word commit report closing on the next step",
		lane:    "incident",
		trigger: "Add governed legacy-to-complimentary conversion",
		reply:   "Sorry—the short version: **the engineering change is done and committed as `ea94ab72`; both Portal and packs gates pass.** Nothing has been deployed or run against production. After deployment, we still need to verify the exact account with `account.show`, then request the conversion as a separate governed operation.",
		expect:  "",
	},
	// blitz 2026-08-04
	{
		name:    "apply verdict then the reconciliation that remains",
		lane:    "investigation",
		trigger: "Run notification for <https://app.terraform.io/app/SME-Blitz/blitz-infra|SME-Blitz/blitz-infra> <https://app.terraform.io/app/SME-Blitz/blitz-infra/runs/run-K3VvJKqxeCd2NzfQ|Run run-K3VvJKqxeCd2NzfQ> CI apply — a1830c265bfb21bd7159082a7668bd9f90b2e01e Run Planned - Needs Confirmation",
		reply:   "**Run `run-K3VvJKqxeCd2NzfQ` succeeded.** It applied revision `a1830c265bfb21bd7159082a7668bd9f90b2e01e`, replacing the blitz-website instance template and Sentry release trigger and updating the regional managed instance group.\n\nThe group is stable and has reached the new template. Its configured target size is zero, so this confirms Terraform convergence—not live website traffic. The 448 drift records, including sampled missing `blitz-cv` buckets, were observations rather than changes made by this run and still need separate reconciliation with the earlier errored apply.",
		expect:  "",
	},
	// emisar 2026-08-04
	{
		name:    "the fix, its verification, then the next read",
		lane:    "investigation",
		trigger: "Okay how do we make the pack work?",
		reply:   "**Install a standard `jq` build with Oniguruma support on `emisar-005x`.** That is the immediate way to make the currently published pack work unchanged.\n\nVerify the replacement first with:\n\n```sh\njq -n '\"abc\" | test(\"^a\")'\n```\n\nIt must return `true` rather than the “compiled without ONIGURUMA” error. Then restart or refresh the runner environment if needed and rerun `tfc.run_details` followed by `tfc.run_diagnostics` for `run-cbnzPMjkT9Tde264`.\n\nThat restores this runner, but it does not prove the Terraform apply is safe to retry; the two read actions still need to reveal the plan and apply error first.",
		expect:  "",
	},
	// blitz 2026-08-06
	{
		name:    "caveat in the middle, next action last",
		lane:    "investigation",
		trigger: "Run notification for <https://app.terraform.io/app/SME-Blitz/va1-postgres|SME-Blitz/va1-postgres> <https://app.terraform.io/app/SME-Blitz/va1-postgres/runs/run-wcrBspCmGj1t5ATz|Run...",
		reply:   "`va1-postgres` run `run-wcrBspCmGj1t5ATz` applied successfully: 16 resources were created, with no updates, replacements, or deletions. The change added migration identities and Cloud SQL/workload-identity grants for multiple services; Terraform also observed drift in the Tolgee migration-proxy Nomad job.\n\nCustomer impact remains unverified, and the applied configuration cannot be tied to this checkout because its reported auth/cms/nexus/payments resources aren’t present here. The safest follow-up is to verify the migration proxies through their representative connection path and reconcile the run’s configuration version with the repository revision.",
		expect:  "",
	},
	// blitz 2026-08-06
	{
		name:    "caveats announced as a section, cost note last",
		lane:    "investigation",
		trigger: "Let's deploy it to e2-micro on GCP (5$ per month, hopefully that will be enough), use GCS (gh actions can have WIF integration to upload files to it like our blitz-app-svelte alrea...",
		reply:   "That’s the right direction, and PR 514 now reflects it: **GCP `e2-micro` + private GCS bucket + keyless GitHub Actions WIF uploads**, with Symbolicator exposing both its API and WinDbg proxy over Tailscale.\n\nTwo things remain intentionally unproven: `e2-micro` has only 1 GiB RAM, so the PR adds 2 GiB swap but large-PDB/minidump workloads still need a load test; and Sentry has an integration path but isn’t actually wired to this instance yet. The `$5/month` estimate also doesn’t include the 50 GiB disk, GCS, network, or logging costs.",
		expect:  "",
	},
	// emisar 2026-08-07
	{
		name:    "245 words to the word hi",
		lane:    "investigation",
		trigger: "hi <@ryker>",
		reply:   "Still no change to the account, and nothing deployed. The conversion code is committed as `ea94ab72`, but only inside task fork `remote-4e2814e2b71e285012054c2d`. I'm in a different fork right now (`remote-0db8890588b42a7a54404e04`), where that commit isn't reachable — so I couldn't re-run its gate.\n\n**Readiness has two blockers, not one.** We diagnosed the missing `tflint`. But every readiness card also flagged that validation \"changed tracked files,\" and that half is still unaddressed — it's the sandbox, not the gate. Ten tracked files with secret-shaped names (5 `*.key`, 5 `*.tfstate` pack fixtures) get swapped for empty read-only decoys in any agent box: 0 bytes in the tree against 86–1704 bytes in `HEAD`, and those ten are exactly the files git reports as modified. The tree is dirty before a gate ever runs, so retrying will keep failing that check even once tflint is installed.\n\nSupporting detail: this box *does* have tflint v0.64.0, matching both `.tool-versions` and the CI checksum pin — so provisioning works in a normal box; the readiness runner just didn't get it. `refs/coop/session-parent` is missing here too, and `./run gate review` requires it (`tools/internal/devtool/gates.go:676`).\n\nSo the readiness environment needs tflint v0.64.0 plus that pinned ref. I've also prepared an optional repo change to rename those fixtures so agent boxes stop shadowing them — that's the durable fix for the dirty-tree half. One gap worth naming: no Emisar tool is exposed in this session, so I couldn't check the live account or whether anything has deployed.",
		expect:  "length",
	},
	// blitz 2026-08-08
	{
		name:    "266 words to an eight-word question",
		lane:    "investigation",
		trigger: "is it save to unlock the terraform workspace?",
		reply:   "I can't see the lock from here — Terraform Cloud isn't reachable in this session — so I can't tell you what's holding it. The rule that decides it: unlocking is safe when no run is genuinely still planning or applying. If the top run sits in `Applying` with no log progress because whatever was executing it died, that's a stale lock and force-unlock is the normal fix. If a run is really mid-apply, leave it alone — two Terraform processes writing the same state is how it gets corrupted.\n\nWhich workspace do you mean? It changes the answer. `va1-apps` is the one that actually deploys the website, and a lock there would explain the whole thing: CI keeps creating runs that can't execute. `blitz-infra` is production, where the website group sits at zero instances — unlocking that won't move the site either way.\n\nOne detail that fits the stale-lock story: VA1's in-cluster Terraform agent job has 2 lost allocations. If an apply was in flight when one died, TFC can be left holding a lock with nothing behind it. As of 14:19Z the agent has 1 running allocation and the website still shows the same 4 allocation IDs it's had all day, so nothing is rolling right now. Treat that as weak support, not proof — a scheduled agent allocation doesn't mean it's connected to TFC, and an apply could be running without touching `website`.\n\nOnce you unlock, queue a fresh run for the current commit instead of resuming the dead one, then watch the website allocation IDs change. That's the signal it actually deployed.",
		expect:  "length",
	},
	// blitz 2026-08-08
	{
		name:    "closes on one gap I cannot tell you",
		lane:    "investigation",
		trigger: "Run notification for <https://app.terraform.io/app/SME-Blitz/va1-apps|SME-Blitz/va1-apps> <https://app.terraform.io/app/SME-Blitz/va1-apps/runs/run-QmzuDtmYr4z9MwKJ|Run run-Qmzu...",
		reply:   "VA1's website has started rolling — first movement since Aug 5. The apply that actually deploys the site is the `va1-apps` one, and it's running now: `run-QmzuDtmYr4z9MwKJ` (CI apply, `1a9ec54a`) reached Applying at 16:31:15Z, and the website's running allocation count stepped 4 → 5 inside the last five minutes against 4 declared replicas. It had held the same four allocation IDs all week.\n\nIgnore the `failed: 22` on that job — it reads 22 at every offset back through 24h, so it's an accumulated counter, not this deploy.\n\nThe CLI-triggered run discarded a minute earlier is what let CI through, so whatever was holding `va1-apps` is clear. It's landed when all four allocation IDs have turned over. One gap: `1a9ec54a` isn't in this session's checkout, so I can't tell you which image tag it ships.",
		expect:  "handback",
	},
	// blitz 2026-08-05
	{
		name:    "closes on a caveat after the action was given",
		lane:    "investigation",
		trigger: "<https://grafana.example.com/alerting/grafana/va1-ecc-correctable/view?orgId=1|[VA1 EVALUATION ERROR:8] WARNING | High correctable ECC rate> *FIRING - 8 alerts* *High correctable ECC rate on cassandra-dbcas101* A DIMM is producing many correctable errors -- this usually precedes an uncorrectable fault (va1-host-ecc). Schedule replacement. *Evaluation error:* `[sse.dataQueryError] failed to execute query [A]: Get \"<http://victoriametrics.service.va1.consul:8428/api/v1/query?query=sum+by%28instance%29+%28increase%28node_edac_correctable_errors_total%5B1h%5D%29%29&amp;step=5m0s&amp;time=1785966410>\": dial tcp: lookup victoriametrics.service.va1.consul on 172.26.4.1:53: no such host` This notification was caused by an evaluation failure. Verify the datasource and query before treating it as a confirmed incident. *Instance:* `cassandra-dbcas101` *Started:* <!date^1785966410^{date_short_pretty} at {time_secs}|2026-08-05 21:46:50 UTC> *Evaluation:*",
		reply:   "**Cassandra is available, but VA1 hardware monitoring is degraded.** All three nodes are Up/Normal; the DIMM warning isn’t confirmed because Grafana and independent checks both fail to resolve `victoriametrics.service.va1.consul`.\n\nRestore that Consul DNS path first. Success means VictoriaMetrics queries run again, the ECC rule evaluates normally, and direct correctable/uncorrectable counters determine whether `dbcas101` actually needs a DIMM replacement. Recent Grafana, VictoriaMetrics, and alert-rule upgrades are relevant, but their deployed revision and connection to the DNS failure remain unverified.",
		expect:  "handback",
	},
	// blitz 2026-08-06. The first of the two rejections this calibration
	// knows it gets wrong and keeps anyway. A ranked five-item cost list
	// with a dollar figure on every line is a good answer to "any
	// opportunities to optimize?", and it runs 269 words against 210. It
	// cannot be released by length: the 266-word answer below it is the
	// reply the whole rule exists for, and no bound separates 266 from 269.
	{
		name:    "ranked cost list to an open four-word question",
		lane:    "investigation",
		trigger: "Any opportunities to optimize?",
		reply:   "Yes. The clearest opportunities, ranked by likely value:\n\n1. **Audit Cassandra Hyperdisks first.** Capacity, IOPS, and throughput cost **$826.15/10 days**. The repo keeps these disks when instances disappear, defines zero-replica restore groups with 5–9 TiB disks, and even has a `TODO: Delete disks`. Confirm attachment and utilization, then remove stale restore disks or lower provisioned IOPS/throughput. The $826 is spend at stake, not a savings estimate.\n\n2. **Stop Archive early-deletion charges.** They cost **$131.54/10 days**. Identify the bucket generating them and align its storage class with actual retention—objects moved to Archive and deleted too soon are a poor bargain. The repo’s 30-day Archive transition is a strong lead, but bucket-level attribution is still unverified.\n\n3. **Review CDN and load-balancer sprawl.** Cache lookups plus additional forwarding rules cost **$813.34/10 days**. There were **748.8M lookups** and roughly **105 additional rule equivalents** across the window. Check for legacy GCP CDN paths now that many app endpoints use Bunny, and consolidate unused frontends only after traffic verification.\n\n4. **Rightsize or commit the stable compute baseline.** Compute Engine is **$3,708.16/10 days**, the largest category. The repo declares no active compute commitments. Measure CPU/memory first; then rightsizing or CUDs for the non-Spot baseline is likely the largest durable lever.\n\n5. **Trim secondary usage:** Gemini is **$630.13/10 days**—route suitable calls to Flash, cap outputs, and improve cache reuse. Cloud Monitoring is **$291.12/10 days**—reduce high-cardinality/custom metric ingestion after identifying the noisiest series.\n\nAlso review **immersiveai**, which accounts for **$1,545.95 (18.2%)** of the total but isn’t owned by this infrastructure snapshot. I’d start with the Hyperdisk attachment/utilization audit; it has the strongest combination of spend and repository evidence.",
		expect:  "length",
	},
	// blitz 2026-08-08. The second known-wrong rejection: the best reply in
	// the corpus, 470 words against 390, six numbered findings and a stated
	// success criterion, answering a 364-word scheduled instruction sheet.
	// The bound stays where it is because 52 replies in the corpus answered
	// a trigger over fifty words and their 98th percentile is 209. Moving
	// the top of the ladder for one message would be fitting to one message.
	{
		name:    "scheduled whole-platform assessment",
		lane:    "investigation",
		trigger: "Use the published Emisar runbook `whole-platform-health-review-v5@3` as the preferred reproducible baseline. If that exact version is unavailable, use a published read-only semantic replacement or run equivalent authorized read-only checks directly; still complete the health assessment unless a material evidence capability is unavailable. The runbook is not the whole assessment. Repeatedly discover claim-specific and equivalent routes. Use the configured VictoriaMetrics and VictoriaLogs routes for broad and service-level application error and timeout trends against equivalent recent windows; representative HTTP synthetics for functional behavior; Grafana for active alerts; scheduler and dependency checks for failures and capacity; and HCP Terraform plus deployment history for recent changes. Use Bunny CDN only as corroborating edge evidence, not as a substitute for application behavior. Do not treat one empty discovery result or a missing preferred connector as source unavailable while another read-only route exists. Do not infer platform health from a homepage probe or compare rates with different windows or denominators. Preserve each metric's exact query window and aggregation. Scope synthetic conclusions only to the exact endpoints tested. Keep every evidence claim atomic: do not add an upstream status code, causal conversion, or surrounding event unless the cited source directly shows it. Treat concurrent upstream and downstream errors as a bounded failure path, not a proven code-level conversion unless a direct source establishes it. Metrics can establish impact but not a safe mitigation: use affected-service logs, traces, functional checks, dependency evidence, or owning code before stating a cause or containment. Do not recommend rollback without an exact candidate version and evidence it was previously healthy, and do not invent edge shedding, caching, throttling, or failover controls. Reconcile conflicting sources. Decide healthy, degraded, or unhealthy. Missing evidence alone is not degradation. A degraded verdict does not prove the unnamed remainder is serving normally, so lead with the verified failure and do not add broad reassurance about the platform, website, or users. This organization has no formal SLOs; mark that layer not applicable and use operational indicators instead. Lead with the verdict and its practical meaning, follow anomalies to an actionable boundary, and use at most six concise evidence-rich bullets. Omit runbook IDs and execution mechanics unless the run failed or needs approval.",
		reply:   "VA1 is **degraded** in one narrow place: two Marvel Rivals endpoints return 500s because a single upstream call times out. Everything else is clean — 4,240 req/s at the edge with a **0.014%** 5xx rate, and rivals is the only service above 1% errors.\n\n- **The cause is one vendor operation, not the dependency.** `query_match_summary` times out on **28.1%** of calls (0.61 of 2.17/s); `query_match_by_uuid` runs 0.58/s with **exactly zero**. Same two scraper replicas, same two Marvel accounts, same egress path — so scraper capacity, account health, the network path, and any general Gate API outage are all ruled out.\n- **It's a deadline, not a broken link.** Every failure lands between **5.008s and 5.367s** with **zero** 503s, while successful calls return in 0.117–0.732s. The scraper is up and answering; Marvel's Gate API just doesn't come back in time for that one query.\n- **Impact is two endpoints.** `player_profile` fails **32.7%**, `match_summary` **14.6%**, and `/rivals/match/{match_uuid}` — backed by the healthy call — sits at **0%**. rivals is 0.095% of platform traffic, so this stays inside the Rivals vertical.\n- **The fix is a fallback, and the data is already local.** Most `match_summary` 200s return in **3 ms** from storage, with Scylla at 0 errors and 0 retries. Serving the last-known summary on timeout turns those 500s into stale-but-useful 200s. That change is prepared. Raising the deadline would be wrong — successes finish under a second, so waiting longer only makes failures slower.\n- **Rollback is ruled out with evidence.** rivals runs `d5dcbeb…`, matching the declared pin, unchanged for 7 days, and no VA1 job changed image tag in 48 hours. That same build was at 94% errors on Aug 1 and 43% through Aug 6 — there's no healthy version to return to.\n- **Nothing alerted, and it structurally can't.** All 114 Grafana rules are inactive. `va1-traefik-5xx` (`gen_alerts.py:673`) divides *total* 5xx by *total* requests against a 5% threshold, so one service at 14.83% registers as 0.014%. A per-service companion rule is the durable follow-up, and I can prepare it separately.\n\n**How you'll know it worked:** 500s on `match_summary` and `player_profile` fall to roughly zero while their request rates hold near 2.82/s and 0.57/s, and rivals drops below 1%. The scraper's 504 rate will *not* move — that's Marvel's side, and it isn't the success criterion.\n\nThe task also picks up a second defect in the same service: `Match summary data is too large` has been discarding 230–430 records a day for a week at 20.5KB–67.7KB, unaffected by the timeout improvement.\n\n**One gap:** the runbook `whole-platform-health-review-v5@3` couldn't be used — no Emisar tooling was reachable this run — so I ran the equivalent read-only checks directly. The rivals source isn't on this host either, so the fix is specified by observed behavior and verification metrics rather than by reading the code.",
		expect:  "length",
	},
}
