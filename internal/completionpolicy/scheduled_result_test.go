package completionpolicy

import (
	"strings"
	"testing"
)

const scheduledHealthTrigger = "Use the published Emisar runbook `whole-platform-health-review-v5@3` as the preferred reproducible baseline. If that exact version is unavailable, use a published read-only semantic replacement or run equivalent authorized read-only checks directly; still complete the health assessment unless a material evidence capability is unavailable. The runbook is not the whole assessment. Repeatedly discover claim-specific and equivalent routes. Use the configured VictoriaMetrics and VictoriaLogs routes for broad and service-level application error and timeout trends against equivalent recent windows; representative HTTP synthetics for functional behavior; Grafana for active alerts; scheduler and dependency checks for failures and capacity; and HCP Terraform plus deployment history for recent changes. Use Bunny CDN only as corroborating edge evidence, not as a substitute for application behavior. Do not treat one empty discovery result or a missing preferred connector as source unavailable while another read-only route exists. Do not infer platform health from a homepage probe or compare rates with different windows or denominators. Preserve each metric's exact query window and aggregation. Scope synthetic conclusions only to the exact endpoints tested. Keep every evidence claim atomic: do not add an upstream status code, causal conversion, or surrounding event unless the cited source directly shows it. Treat concurrent upstream and downstream errors as a bounded failure path, not a proven code-level conversion unless a direct source establishes it. Metrics can establish impact but not a safe mitigation: use affected-service logs, traces, functional checks, dependency evidence, or owning code before stating a cause or containment. Do not recommend rollback without an exact candidate version and evidence it was previously healthy, and do not invent edge shedding, caching, throttling, or failover controls. Reconcile conflicting sources. Decide healthy, degraded, or unhealthy. Missing evidence alone is not degradation. A degraded verdict does not prove the unnamed remainder is serving normally, so lead with the verified failure and do not add broad reassurance about the platform, website, or users. This organization has no formal SLOs; mark that layer not applicable and use operational indicators instead. Lead with the verdict and its practical meaning, follow anomalies to an actionable boundary, and use at most six concise evidence-rich bullets. Omit runbook IDs and execution mechanics unless the run failed or needs approval."

const scheduledHealthDeliveredReply = "**Platform health is degraded:** Rivals returned 2,670 downstream HTTP 500s in the latest 15 minutes versus 2,657 in the preceding 15 minutes. The failure is sustained, but its request share and user impact are not yet quantified.\n\nThe rest of the checked platform is stable: expected VA1 workloads and dependencies are running, Consul has no warning or critical checks, Traefik reports no down backends, and fresh probes of `tenant.example` and `app.tenant.example` returned HTTP 200. The preferred `whole-platform-health-review-v5@3` was no longer live, so the published read-only semantic replacement `whole-platform-health-review-v5@4` was used."

// The successful Aug 13 scheduled review exposed its preferred and substituted
// runbook versions even though its own task said those execution details were
// private on success. The status and approval controls matter: the same exact
// identifier is useful when it explains why the run is blocked or what an
// operator is being asked to approve.
// Covers finding: 20260813T150634Z-run_cd92f48631c5ecce45123f0ef3e5172e
func TestSuccessfulScheduledAssessmentKeepsExecutionReferencesPrivate(t *testing.T) {
	criteria := []string{ScheduledOutcomeOnlyCriterion}
	correction := ScheduledResultCorrection(
		criteria, scheduledHealthTrigger, "reply", scheduledHealthDeliveredReply,
		"decision_ready", false,
	)
	if correction == "" || !strings.Contains(correction, "whole-platform-health-review-v5@") {
		t.Fatalf("successful delivered reply was not corrected: %q", correction)
	}

	for _, control := range []struct {
		name            string
		status          string
		pendingApproval bool
	}{
		{name: "blocked run", status: "blocked"},
		{name: "approval required", status: "decision_ready", pendingApproval: true},
	} {
		t.Run(control.name, func(t *testing.T) {
			if got := ScheduledResultCorrection(
				criteria, scheduledHealthTrigger, "reply", scheduledHealthDeliveredReply,
				control.status, control.pendingApproval,
			); got != "" {
				t.Fatalf("necessary execution detail was rejected: %q", got)
			}
		})
	}
}
