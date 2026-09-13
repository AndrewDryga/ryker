package service

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/completionpolicy"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskofferclaims"
)

func TestWatchedInputEffortAndAuthorityAreIndependent(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	cases := []struct {
		name      string
		input     core.SlackInput
		state     decisionpkg.WatchTurnState
		effort    core.EffortContract
		authority core.AuthorityBoundary
		coverage  []string
	}{
		{
			name:   "ordinary conversation",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "<@U999BOT> what does that mean?"},
			effort: core.EffortConversational, authority: core.AuthorityReadOnly,
		},
		{
			name:   "focused delivery check",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "<@U999BOT> check whether CI is green"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
			coverage: []string{"change"},
		},
		{
			name: "focused repository inspection",
			input: core.SlackInput{
				Kind: "mention", UserID: "UOTHER",
				Text: "<@U999BOT> inspect this repository and report its validation commands",
			},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
			coverage: []string{"change"},
		},
		{
			name:   "cost change analysis is focused",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "<@U999BOT> analyze recent changes in our GCP costs"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
			coverage: []string{"task"},
		},
		{
			name:   "rollout assessment is focused",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "Assess whether the production portal rollout recovered"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "application"},
		},
		{
			name:   "unassigned app event",
			input:  core.SlackInput{Kind: "bot_message", UserID: "BGRAFANA", Text: "Grafana notification"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
		},
		{
			name:   "broad health assessment",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "Give me a deep production health assessment"},
			effort: core.EffortOperationalAssessment, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "host", "runtime", "workload", "dependency", "application", "slo"},
		},
		{
			name:   "scheduled health review",
			input:  core.SlackInput{Kind: "scheduled", UserID: "UOTHER", Text: "Run the daily platform health review"},
			effort: core.EffortOperationalAssessment, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "host", "runtime", "workload", "dependency", "application", "slo"},
		},
		{
			name:   "health preference is configuration",
			input:  core.SlackInput{Kind: "mention", UserID: "U123ABC", Text: "When I ask for infrastructure health, always do a deep check"},
			effort: core.EffortConversational, authority: core.AuthorityReadOnly,
		},
		{
			name:   "assigned alert",
			input:  core.SlackInput{Kind: "bot_message", UserID: "BGRAFANA", Text: "High disk I/O latency on dbcas103"},
			state:  decisionpkg.WatchTurnState{MatchedRules: []core.StandingRule{{Trigger: "operational_alert", Action: "triage_alert"}}},
			effort: core.EffortIncidentInvestigation, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "application", "slo", "host"},
		},
		{
			name: "human engineering followup keeps alert history without inheriting its contract",
			input: core.SlackInput{
				Kind: "message", UserID: "U123ABC",
				Text: "Make a PR to add what you need",
			},
			state: decisionpkg.WatchTurnState{
				ConversationFollowup: true,
				MatchedRules: []core.StandingRule{{
					Trigger: "operational_alert", Action: "triage_alert",
				}},
			},
			effort: core.EffortConversational, authority: core.AuthorityReadOnly,
		},
		{
			name: "configured app alert without standing rule",
			input: core.SlackInput{
				Kind: "bot_message", UserID: "BGRAFANA",
				Text: "CRITICAL alert: Typesense node service is down",
			},
			state:  decisionpkg.WatchTurnState{AlertPolicy: "reply"},
			effort: core.EffortIncidentInvestigation, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "application", "slo", "host", "workload"},
		},
		{
			name:   "operator governed request",
			input:  core.SlackInput{Kind: "mention", UserID: "U123ABC", Text: "Can you restart the failed service now?"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityGovernedOperation,
			coverage: []string{"workload"},
		},
		{
			name:   "non operator cannot grant authority",
			input:  core.SlackInput{Kind: "mention", UserID: "UOTHER", Text: "Can you restart the failed service now?"},
			effort: core.EffortFocusedCheck, authority: core.AuthorityReadOnly,
			coverage: []string{"workload"},
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			episode := svc.episodeForWatchedInput(test.input, test.state)
			if episode.Effort != test.effort || episode.Authority != test.authority ||
				!slices.Equal(episode.RequiredCoverage, test.coverage) {
				t.Fatalf("episode = %+v", episode)
			}
		})
	}
}

func TestWorkEpisodeProgressIsDurableAndRateLimited(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.EpisodeProgressInterval.Duration = 30 * time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS",
		ConversationKey: "channel:COPS", SourceKind: "watch", SourceID: "input_progress",
		Episode: &core.WorkEpisode{
			Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "investigating", "Checking production health",
		"Complete the evidence plan", time.Now().UTC().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	svc := &Service{cfg: cfg, store: st}
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	progress, err := st.ListWorkEpisodeProgress(ctx, run.ID, 20)
	if err != nil || len(progress) != 3 || !strings.Contains(progress[0].Summary, "system layer") {
		t.Fatalf("progress = %+v, %v", progress, err)
	}
	if err := svc.refreshWorkEpisodeProgress(ctx, run); err != nil {
		t.Fatal(err)
	}
	progress, err = st.ListWorkEpisodeProgress(ctx, run.ID, 20)
	if err != nil || len(progress) != 3 {
		t.Fatalf("rate-limited progress = %+v, %v", progress, err)
	}
}

func TestIncidentEpisodeSeparatesEngineeringAndOperationalAuthority(t *testing.T) {
	svc := &Service{}
	incident := core.Incident{Title: "Checkout is failing"}
	readOnly := svc.episodeForIncident(incident, core.AgentRunIncident, "slack", "")
	if readOnly.Effort != core.EffortIncidentInvestigation ||
		readOnly.Authority != core.AuthorityReadOnly || len(readOnly.RequiredCoverage) == 0 {
		t.Fatalf("read-only incident episode = %+v", readOnly)
	}
	governed := svc.episodeForIncident(
		incident, core.AgentRunIncident, "emisar_approval:apr_1", "Apply exact remediation",
	)
	if governed.Effort != core.EffortIncidentInvestigation || governed.Authority != core.AuthorityGovernedOperation {
		t.Fatalf("governed incident episode = %+v", governed)
	}
	engineering := svc.episodeForIncident(incident, core.AgentRunEngineeringTask, "slack", "Fix the regression")
	if engineering.Effort != core.EffortEngineeringTask ||
		engineering.Authority != core.AuthorityRepositoryWrite || len(engineering.RequiredCoverage) != 0 {
		t.Fatalf("engineering episode = %+v", engineering)
	}
}

// A Host OOM investigation on 2026-08-20 found a kernel counter and stopped
// without reporting the killed process, Nomad restart outcome, or current task
// memory. These are the diagnosis, recovery, and impact checks an operator
// performs before answering; the generic host/workload/application labels did
// not tell the model that explicitly.
func TestOOMAlertContractNamesTheProcessRecoveryMemoryAndImpactChecks(t *testing.T) {
	svc := &Service{}
	episode := svc.episodeForWatchedInput(core.SlackInput{
		Kind:   "bot_message",
		UserID: "BGRAFANA",
		Text:   "[VA1 FIRING:1] WARNING | Host OOM kills\nKernel OOM-killed a process on nomad-hvn01",
	}, decisionpkg.WatchTurnState{AlertPolicy: "reply"})
	joined := strings.Join(episode.CompletionCriteria, "\n")
	for _, want := range []string{
		"killed process", "owning allocation or task", "restart or replacement",
		"current task memory", "host memory pressure", "user impact",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("OOM completion contract omits %q:\n%s", want, joined)
		}
	}
}

// Covers: TestIncidentInvestigationVerdictRequiresMatchingVerifiedCoverage
func TestDeepEpisodeCompletionRequiresDecisionReadyCoverageOrExactBlocker(t *testing.T) {
	episode := core.WorkEpisode{
		Effort:           core.EffortOperationalAssessment,
		RequiredCoverage: []string{"host", "application", "slo"},
	}
	completeCoverage := []core.Coverage{
		{Layer: "host", Status: "healthy", Detail: "Both hosts are responsive"},
		{Layer: "application", Status: "healthy", Detail: "The probe passes"},
		{Layer: "slo", Status: "healthy", Detail: "No SLO alert is active"},
	}
	tests := []struct {
		name       string
		action     string
		coverage   []core.Coverage
		completion *CompletionAssessment
		want       string
	}{
		{name: "non final action", action: "ignore"},
		{name: "missing completion", action: "reply", coverage: completeCoverage, want: "no completion assessment"},
		{
			name: "missing layer", action: "reply", coverage: completeCoverage[:2],
			completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "Healthy"},
			want:       "has not assessed required coverage layers: slo",
		},
		{
			name: "unknown decision", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts respond"},
				{Layer: "application", Status: "unknown", Detail: "Probe access is unavailable"},
				{Layer: "slo", Status: "healthy", Detail: "No alert is active"},
			},
			completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "Healthy"},
			want:       "healthy verdict cannot leave material operational coverage unknown",
		},
		{
			name: "blocked without action", action: "reply", coverage: completeCoverage,
			completion: &CompletionAssessment{Status: "blocked", Summary: "Impact is unknown", MaterialGaps: []string{"SLO source"}},
			want:       "external blocker_kind",
		},
		{
			name: "unfinished investigation is not a blocker", action: "reply", coverage: completeCoverage,
			completion: &CompletionAssessment{
				Status: "blocked", Summary: "Impact needs more investigation.",
				MaterialGaps: []string{"SLO evidence"}, NextAction: "Query the SLO source",
			},
			want: "external blocker_kind",
		},
		{
			name: "exact blocker", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts respond"},
				{Layer: "application", Status: "unknown", Detail: "Probe access is unavailable"},
				{Layer: "slo", Status: "unknown", Detail: "The monitoring account is unavailable"},
			},
			completion: &CompletionAssessment{
				Status: "blocked", Summary: "Host health is known but customer impact is not.",
				MaterialGaps: []string{"application and SLO evidence"},
				BlockerKind:  "access_denied",
				Attempts: []string{
					"Queried the configured monitoring source; it returned permission denied",
				},
				NextAction: "Grant the monitoring account read access, then retry this assessment",
			},
		},
		{
			name: "decision ready", action: "reply", coverage: completeCoverage,
			completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "The checked scope is healthy."},
		},
		{
			name: "healthy without formal SLO", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts are responsive"},
				{Layer: "application", Status: "healthy", Detail: "Functional checks pass and error rates are normal"},
				{Layer: "slo", Status: "not_applicable", Detail: "No formal SLO is defined"},
			},
			completion: &CompletionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "The platform is healthy."},
		},
		{
			name: "verified errors decide degradation despite other unknowns", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "unknown", Detail: "One hardware inventory source is unavailable"},
				{Layer: "application", Status: "degraded", Detail: "Current request errors exceed baseline"},
				{Layer: "slo", Status: "not_applicable", Detail: "No formal SLO is defined"},
			},
			completion: &CompletionAssessment{Status: "decision_ready", Verdict: "degraded", Summary: "The platform is degraded."},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := investigation.CompletionCorrection(episode, test.action, test.coverage, test.completion)
			if test.want == "" && got != "" {
				t.Fatalf("unexpected correction: %s", got)
			}
			if test.want != "" && !strings.Contains(got, test.want) {
				t.Fatalf("correction %q lacks %q", got, test.want)
			}
		})
	}
}

func TestCompletionAssessmentIsStrictAndBounded(t *testing.T) {
	tests := []struct {
		name       string
		completion *CompletionAssessment
		wantError  bool
	}{
		{name: "omitted"},
		{name: "decision ready", completion: &CompletionAssessment{Status: "decision_ready", Summary: "Healthy"}},
		{name: "decision ready with follow-up", completion: &CompletionAssessment{Status: "decision_ready", Summary: "The schedule is ready for confirmation", NextAction: "Confirm the schedule"}},
		{name: "terminal failure with bounded gap", completion: &CompletionAssessment{Status: "decision_ready", Verdict: "failed", Summary: "The apply failed", MaterialGaps: []string{"partial effects are unknown"}, NextAction: "Reconcile state before retrying"}},
		{name: "terminal failure gap without action", completion: &CompletionAssessment{Status: "decision_ready", Verdict: "failed", Summary: "The apply failed", MaterialGaps: []string{"partial effects are unknown"}}, wantError: true},
		{name: "decision with gap", completion: &CompletionAssessment{Status: "decision_ready", Summary: "Healthy", MaterialGaps: []string{"database"}}, wantError: true},
		{name: "blocked", completion: &CompletionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", Attempts: []string{"Monitoring query returned permission denied"}, NextAction: "Restore access"}},
		{name: "blocked capability", completion: &CompletionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Install the observed pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "GitHub Actions run inspection", Status: "not_installed", PackID: "github-cli", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "Install the `github-cli` pack on the operations runner."}}}},
		{name: "capability blocker without gap", completion: &CompletionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Add the capability"}, wantError: true},
		{name: "pack id need not be duplicated in prose", completion: &CompletionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Install a pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "GitHub Actions run inspection", Status: "not_installed", PackID: "github-cli", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "Install the observed pack."}}}},
		{name: "no matching pack", completion: &CompletionAssessment{Status: "blocked", Summary: "The capability is unavailable", MaterialGaps: []string{"provider evidence"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Add a compatible governed pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "Vendor-specific evidence", Status: "not_found", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "No matching pack was found; add a governed pack for this provider."}}}},
		{name: "blocked with verdict", completion: &CompletionAssessment{Status: "blocked", Verdict: "degraded", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", Attempts: []string{"Monitoring query returned permission denied"}, NextAction: "Restore access"}, wantError: true},
		{name: "blocked without kind", completion: &CompletionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, Attempts: []string{"Queried monitoring"}, NextAction: "Restore access"}, wantError: true},
		{name: "blocked without attempts", completion: &CompletionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", NextAction: "Restore access"}, wantError: true},
		{name: "blocked without action", completion: &CompletionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}}, wantError: true},
		{name: "unknown state", completion: &CompletionAssessment{Status: "working", Summary: "Partial"}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := investigation.ValidateCompletion(test.completion)
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v", err)
			}
		})
	}
	if _, err := decisionpkg.DecodeWatchDecision(`{"action":"react","reaction":"eyes","completion":{"status":"decision_ready","summary":"Done"}}`, testDecodeClock); err == nil {
		t.Fatal("reaction accepted a completion assessment")
	}
}

func TestFocusedChangeReviewUsesLifecycleVerdict(t *testing.T) {
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, Objective: "Review this Terraform plan",
		RequiredCoverage: []string{"change"},
	}
	coverage := []core.Coverage{{
		Layer: "change", Status: "unknown",
		Detail: "The Terraform run is applying; terminal verification is pending.",
	}}
	completion := &CompletionAssessment{
		Status: "decision_ready", Verdict: "in_progress",
		Summary: "The change is applying and needs terminal verification.",
	}
	if got := investigation.CompletionCorrection(episode, "reply", coverage, completion); got != "" {
		t.Fatalf("in-progress change rejected: %s", got)
	}
	completion.Verdict = "degraded"
	if got := investigation.CompletionCorrection(episode, "reply", coverage, completion); !strings.Contains(got, "change_review") {
		t.Fatalf("health verdict accepted for change review: %q", got)
	}
	completion.Verdict = "succeeded"
	if got := investigation.CompletionCorrection(episode, "reply", coverage, completion); got == "" {
		t.Fatalf("success without terminal evidence accepted: %q", got)
	}
	coverage[0].Status = "unhealthy"
	coverage[0].Detail = "The exact Terraform run is terminally errored after apply began."
	completion.Verdict = "failed"
	completion.Summary = "The apply failed; reconcile possible partial changes before retrying."
	completion.MaterialGaps = []string{"the exact partial infrastructure changes are not yet known"}
	completion.NextAction = "Inspect the terminal run diagnostics and refresh state before any retry."
	if got := investigation.CompletionCorrection(episode, "reply", coverage, completion); got != "" {
		t.Fatalf("bounded terminal failure rejected: %q", got)
	}
	completion.NextAction = ""
	if got := investigation.CompletionCorrection(episode, "reply", coverage, completion); got == "" {
		t.Fatal("terminal failure without a safe next action was accepted")
	}
}

func TestFocusedCoverageDoesNotTreatNegatedHealthLanguageAsRequestedCoverage(t *testing.T) {
	svc := &Service{}
	episode := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Review this exact Terraform plan. Do not infer operational health from change risk alone.",
	}, decisionpkg.WatchTurnState{})
	if got := investigation.Compile(*episode).Completion.ConclusionKind; got != "change_review" {
		t.Fatalf("conclusion kind = %q", got)
	}
	if !slices.Equal(episode.RequiredCoverage, []string{"change"}) {
		t.Fatalf("required coverage = %v", episode.RequiredCoverage)
	}

	recovery := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention", Text: "Assess whether checkout recovered after the deployment.",
	}, decisionpkg.WatchTurnState{})
	if got := investigation.Compile(*recovery).Completion.ConclusionKind; got != "operational_health" {
		t.Fatalf("recovery conclusion kind = %q", got)
	}
	if !slices.Contains(recovery.RequiredCoverage, "application") {
		t.Fatalf("recovery coverage = %v", recovery.RequiredCoverage)
	}
}

func TestRunbookWorkDoesNotUseHealthVerdictLanguage(t *testing.T) {
	svc := &Service{}
	episode := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Also extend that runbook and test it; make sure it is all we need for daily checkups.",
	}, decisionpkg.WatchTurnState{})
	contract := investigation.Compile(*episode)
	if episode.Effort != core.EffortFocusedCheck || contract.Completion.ConclusionKind != "factual_assessment" {
		t.Fatalf("runbook episode = %+v, completion = %+v", episode, contract.Completion)
	}
	if !slices.Equal(episode.RequiredCoverage, []string{"task"}) {
		t.Fatalf("runbook coverage = %v", episode.RequiredCoverage)
	}
	if got := investigation.ConclusionLanguageCorrection(
		*episode,
		"reply",
		"**Degraded** - the expanded runbook is validated but unpublished.",
	); !strings.Contains(got, "not an operational health assessment") {
		t.Fatalf("runbook health heading accepted: %q", got)
	}
	if got := investigation.ConclusionLanguageCorrection(
		*episode,
		"reply",
		"The expanded runbook is validated. Publication is the remaining step.",
	); got != "" {
		t.Fatalf("task-state answer rejected: %q", got)
	}
}

// A runbook is named after the assessment it performs, so the request to write
// one contains every word the assessment does. "Create reusable deep
// infrastructure health review runbook" was compiled as a whole-platform health
// assessment: seven required coverage layers and a mandatory healthy, degraded
// or unhealthy verdict, for a request to write a document. The model had built,
// validated and tested the draft and had no platform to grade, so it returned a
// bare blocked completion — which then failed validation for carrying none of
// the five fields a blocker needs. The reported error was the missing blocker
// fields; the mistake was made before the model saw the request.
func TestAuthoringAHealthRunbookIsNotAHealthAssessment(t *testing.T) {
	svc := &Service{}
	episode := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention", Text: "Create reusable deep infrastructure health review runbook",
	}, decisionpkg.WatchTurnState{})
	contract := investigation.Compile(*episode)
	if episode.Effort != core.EffortFocusedCheck ||
		contract.Completion.ConclusionKind != "factual_assessment" {
		t.Fatalf("authoring episode = %+v, completion = %+v", episode, contract.Completion)
	}
	if contract.Completion.RequireVerdict {
		t.Fatal("writing a runbook was made to require an operational health verdict")
	}
	if !slices.Equal(episode.RequiredCoverage, []string{"task"}) {
		t.Fatalf("authoring coverage = %v", episode.RequiredCoverage)
	}

	// Executing the same runbook to grade the platform is still an assessment.
	// Only authoring verbs may suppress the health contract.
	running := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Run the deep infrastructure health review runbook and tell me the overall health.",
	}, decisionpkg.WatchTurnState{})
	if got := investigation.Compile(*running).Completion.ConclusionKind; got != "operational_health" {
		t.Fatalf("running the runbook conclusion kind = %q", got)
	}

	plain := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention", Text: "How is the health of our infrastructure?",
	}, decisionpkg.WatchTurnState{})
	if plain.Effort != core.EffortOperationalAssessment {
		t.Fatalf("plain health request effort = %q", plain.Effort)
	}

	// "build" is what CI calls a run and "make" is mostly the filler in "make
	// sure", so neither counts as authoring. Otherwise an ordinary question
	// about a workflow would suppress the health contract it needs.
	incidental := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "The build for the deploy workflow failed. Make sure the health of our infrastructure is fine.",
	}, decisionpkg.WatchTurnState{})
	if incidental.Effort != core.EffortOperationalAssessment {
		t.Fatalf("incidental workflow mention effort = %q", incidental.Effort)
	}
}

func TestTypedTaskCoverageCompletesFocusedArtifactAssessment(t *testing.T) {
	decision, err := decisionpkg.ParseWatchDecision(`{
		"action":"reply",
		"operations":[
			{"id":"evidence-task","type":"record_evidence","evidence":{
				"claim_id":"task.requested_outcome","relation":"supports",
				"claim":"The runbook draft is validated but remains unpublished.",
				"observation":"The recorded runbook has 32 checks, validation passed, and state draft.",
				"source_type":"emisar","source_name":"runbook fixture","target":"whole-platform-health-review-v4",
				"observed_at":"2026-08-03T15:05:00Z","freshness":"recorded fixture","confidence":"high",
				"dimensions":{"artifact":"whole-platform-health-review-v4","revision":"draft-v4"}
			}},
			{"id":"coverage-task","type":"record_coverage","coverage":{
				"layer":"task","status":"healthy","source":"runbook fixture",
				"detail":"The requested extension and validation are complete; publication remains a separate next step.",
				"observed_at":"2026-08-03T15:05:00Z","claim_ids":["task.requested_outcome"]
			}},
			{"id":"complete","type":"complete_episode","completion":{
				"message":"The expanded runbook is validated. Publish it, then repin the daily schedule.",
				"completion":{"status":"decision_ready","verdict":"not_confirmed","summary":"Validated draft; publication remains."}
			}}
		]
	}`, testDecodeClock)
	if err != nil {
		t.Fatalf("parse typed decision: %v", err)
	}
	if len(decision.Coverage) != 1 || decision.Coverage[0].Layer != "task" {
		t.Fatalf("coverage = %+v, want task coverage", decision.Coverage)
	}
	if len(decision.Evidence) != 1 || decision.Evidence[0].ClaimID != "task.requested_outcome" {
		t.Fatalf("evidence = %+v, want requested outcome evidence", decision.Evidence)
	}
	decision.Coverage = decisionpkg.SanitizeCoverage(decision.Coverage, "eval", "CEVALUATION", "input", testDecodeClock)
	if len(decision.Coverage) != 1 || decision.Coverage[0].Layer != "task" {
		t.Fatalf("sanitized coverage = %+v, want task coverage", decision.Coverage)
	}

	service := Service{}
	episode := service.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Also extend that runbook and test it; make sure it is all we need for daily checkups.",
	}, decisionpkg.WatchTurnState{})
	if got := episode.RequiredCoverage; !slices.Equal(got, []string{"task"}) {
		t.Fatalf("required coverage = %v, want [task]", got)
	}
	if correction := investigation.CompletionCorrection(
		*episode,
		decision.Action,
		decision.Coverage,
		decision.Completion,
	); correction != "" {
		t.Fatalf("completion correction = %q", correction)
	}
	if correction := investigation.ClaimCorrection(
		*episode,
		decision.Action,
		decision.Evidence,
		decision.Coverage,
		decision.Completion,
		time.Date(2026, 8, 3, 15, 5, 0, 0, time.UTC),
		time.Date(2026, 8, 3, 15, 5, 0, 0, time.UTC),
		true,
	); correction != "" {
		t.Fatalf("claim correction = %q", correction)
	}
}

// Elliptical follow-ups in the same Slack thread still belong to the artifact
// contract the operator opened. The exact production sequence updated a draft
// twice and then claimed the next scheduled review was covered even though the
// published revision was unchanged.
// Covers finding: 20260813T165711Z-run_7acb144748b2946aa3408d011dd36470
func TestRunbookFollowupsRetainPublicationContract(t *testing.T) {
	publicationCriterion := completionpolicy.PublishedArtifactCriterion
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := &Service{cfg: cfg, store: st}

	origin := core.SlackInput{
		ID: "runbook-origin", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CRUNBOOK", ThreadTS: "1700.100", MessageTS: "1700.100",
		UserID: cfg.Slack.Operators[0],
		Text:   "Create and publish a platform-health runbook so the next daily review uses it.",
	}
	conversationKey := watchConversationKey(origin)
	parent := svc.episodeForWatchedInput(origin, decisionpkg.WatchTurnState{})
	parent.Conversation = core.ConversationRef{
		Platform: "slack", ChannelID: origin.ChannelID, ThreadTS: origin.ThreadTS,
		AnchorTS: origin.ID, Visibility: "channel",
	}
	parent.Destination = core.BoundDestination{
		ChannelID: origin.ChannelID, ThreadTS: origin.ThreadTS,
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: origin.ChannelID, ThreadTS: origin.ThreadTS,
		ConversationKey: conversationKey, SourceKind: "watch", SourceID: origin.ID,
		UserID: origin.UserID, Episode: parent,
	})
	if err != nil {
		t.Fatal(err)
	}
	storedParent, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	parent = &storedParent
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Published runbook task answered", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	for index, text := range []string{
		"Also include Sentry issues and failed Terraform applies next time.",
		"And HTTP 500 rates too.",
	} {
		followup := origin
		followup.ID = fmt.Sprintf("runbook-followup-%d", index+1)
		followup.MessageTS = fmt.Sprintf("1700.%d", 200+index)
		followup.Text = text
		state := decisionpkg.WatchTurnState{ConversationFollowup: true, ResponseThreadTS: origin.ThreadTS}
		child, same, err := svc.correlateWatchEpisode(ctx, followup, conversationKey, &state)
		if err != nil {
			t.Fatal(err)
		}
		if same || child.ParentEpisodeID != parent.ID {
			t.Fatalf("follow-up %d correlation = same=%t episode=%+v", index+1, same, child)
		}
		if !slices.Contains(child.RequiredCoverage, "task") ||
			!slices.Contains(child.CompletionCriteria, publicationCriterion) {
			t.Fatalf("follow-up %d lost publication contract: %+v", index+1, child)
		}

		now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
		coverage := []core.Coverage{{
			Layer: "task", ClaimIDs: []string{"task.requested_outcome"}, Status: "healthy",
			Detail: "The requested checks were added to the draft.",
		}}
		completion := &CompletionAssessment{
			Status: "decision_ready", Verdict: "confirmed", Summary: "The draft was updated.",
		}
		draft := []core.Evidence{{
			ID: "draft", ClaimID: "task.requested_outcome", Relation: "supports",
			SourceType: "emisar", SourceName: "runbook draft", Observation: "The draft contains the new checks.",
			ObservedAt: now, Dimensions: map[string]string{
				"artifact": "whole-platform-health-review", "revision": "draft-v5",
				"artifact_state": "draft", "adoption_state": "inactive",
			},
		}}
		if correction := investigation.ClaimCorrection(
			*child, "reply", draft, coverage, completion, now, now, true,
		); !strings.Contains(correction, "published") {
			t.Fatalf("draft-only follow-up %d completed: %q", index+1, correction)
		}
		published := append([]core.Evidence(nil), draft...)
		published[0].ID = "published"
		published[0].SourceID = "op_publish_v5"
		published[0].Target = "whole-platform-health-review"
		published[0].Dimensions = maps.Clone(draft[0].Dimensions)
		published[0].Dimensions["revision"] = "v5"
		published[0].Dimensions["artifact_state"] = "published"
		published[0].Dimensions["adoption_state"] = "active"
		if correction := investigation.ClaimCorrection(
			*child, "reply", published, coverage, completion, now, now, true,
		); correction != "" {
			t.Fatalf("published follow-up %d rejected: %q", index+1, correction)
		}
	}
}

// A parent revision being live is history, not proof that this follow-up's new
// revision is live. The first policy scan read the whole correlation ancestry,
// so v4 published/active let a child that only drafted v5 complete.
func TestPublishedParentArtifactCannotCompleteDraftOnlyFollowup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	parentRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CRUNBOOK", ConversationKey: "thread:CRUNBOOK:1",
		SourceKind: "watch", SourceID: "runbook-v4", Episode: &core.WorkEpisode{
			Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"task"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	parent, err := st.GetWorkEpisodeByRun(ctx, parentRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		ID: "published-v4", ChannelID: "CRUNBOOK", SourceInput: "runbook-v4",
		ClaimID: "task.requested_outcome", Relation: "supports",
		Claim: "v4 is published", Observation: "The scheduled review uses v4.",
		SourceType: "emisar", SourceID: "op_publish_v4", SourceName: "runbook publish receipt",
		Target: "whole-platform-health-review", ObservedAt: time.Now().UTC(),
		Dimensions: map[string]string{
			"artifact": "whole-platform-health-review", "revision": "v4",
			"artifact_state": "published", "adoption_state": "active",
		},
	}}); err != nil {
		t.Fatal(err)
	}
	childRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CRUNBOOK", ConversationKey: "thread:CRUNBOOK:1",
		SourceKind: "watch", SourceID: "runbook-v5", Episode: &core.WorkEpisode{
			ParentEpisodeID: parent.ID, Effort: core.EffortFocusedCheck,
			RequiredCoverage:   []string{"task"},
			CompletionCriteria: []string{completionpolicy.PublishedArtifactCriterion},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	child, err := st.GetWorkEpisodeByRun(ctx, childRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	draft := []core.Evidence{{
		ID: "draft-v5", ClaimID: "task.requested_outcome", Relation: "supports",
		Claim: "v5 is drafted", Observation: "The workspace contains validated v5.",
		SourceType: "repository", SourceID: "commit-v5", SourceName: "runbook workspace",
		Target: "whole-platform-health-review", ObservedAt: now,
		Dimensions: map[string]string{
			"artifact": "whole-platform-health-review", "revision": "v5",
			"artifact_state": "draft", "adoption_state": "inactive",
		},
	}}
	coverage := []core.Coverage{{
		Layer: "task", ClaimIDs: []string{"task.requested_outcome"}, Status: "healthy",
		Detail: "v5 is validated in the workspace.", ObservedAt: now,
	}}
	completion := &CompletionAssessment{Status: "decision_ready", Verdict: "confirmed", Summary: "v5 is ready."}
	svc := &Service{cfg: cfg, store: st}
	strictOperations := []investigation.ResultOperation{{Type: "record_evidence"}}
	correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx, child, "reply", draft, coverage, completion, now, now, strictOperations, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(correction, "published") {
		t.Fatalf("published v4 completed draft-only v5: %q", correction)
	}

	published := append([]core.Evidence(nil), draft...)
	published[0].ID = "published-v5"
	published[0].SourceType = "emisar"
	published[0].SourceID = "op_publish_v5"
	published[0].SourceName = "runbook publish receipt"
	published[0].Dimensions = maps.Clone(draft[0].Dimensions)
	published[0].Dimensions["artifact_state"] = "published"
	published[0].Dimensions["adoption_state"] = "active"
	correction, err = svc.episodeClaimCorrectionWithHistory(
		ctx, child, "reply", published, coverage, completion, now, now, strictOperations, nil,
	)
	if err != nil || correction != "" {
		t.Fatalf("current published v5 rejected: %q, %v", correction, err)
	}

	// The same ancestry boundary applies to a healthy operational verdict.
	// A fresh parent check is useful history, but it is not a measurement made
	// by the child assessment that is claiming the platform is healthy now.
	historicalHealth := healthyTrendEvidence(now)
	for index := range historicalHealth {
		historicalHealth[index].ChannelID = "CRUNBOOK"
		historicalHealth[index].SourceInput = "runbook-v4"
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, historicalHealth); err != nil {
		t.Fatal(err)
	}
	healthRun, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CRUNBOOK", ConversationKey: "thread:CRUNBOOK:1",
		SourceKind: "watch", SourceID: "health-v5", Episode: &core.WorkEpisode{
			ParentEpisodeID: parent.ID, Effort: core.EffortOperationalAssessment,
			RequiredCoverage: []string{"application"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	healthChild, err := st.GetWorkEpisodeByRun(ctx, healthRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	healthCoverage := []core.Coverage{{
		Layer: "application", ClaimIDs: []string{"application.functional_behavior"},
		Status: "healthy", Detail: "Current assessment claims the checked application scope is healthy.",
	}}
	healthCompletion := &CompletionAssessment{
		Status: "decision_ready", Verdict: "healthy", Summary: "The checked scope is healthy.",
	}
	correction, err = svc.episodeClaimCorrectionWithHistory(
		ctx, healthChild, "reply", nil, healthCoverage, healthCompletion, now, now, strictOperations, nil,
	)
	if err != nil || !strings.Contains(correction, "functional_probe") {
		t.Fatalf("historical parent trends satisfied current healthy verdict: %q, %v", correction, err)
	}
	correction, err = svc.episodeClaimCorrectionWithHistory(
		ctx, healthChild, "reply", healthyTrendEvidence(now), healthCoverage,
		healthCompletion, now, now, strictOperations, nil,
	)
	if err != nil || correction != "" {
		t.Fatalf("current fresh health evidence rejected: %q, %v", correction, err)
	}
}

func healthyTrendEvidence(now time.Time) []core.Evidence {
	result := []core.Evidence{{
		ID: "current-functional", ClaimID: "application.functional_behavior",
		Claim: "the checked path works", Observation: "the functional request passed",
		Relation: "supports", SourceType: "monitoring", SourceName: "functional probe",
		ObservedAt: now, Dimensions: map[string]string{
			"measurement_kind": "functional_probe", "service": "checked services",
			"endpoint": "/health", "environment": "production", "window": "point-in-time",
		},
	}}
	for _, scope := range []string{"broad", "service"} {
		population := scope + " requests"
		for _, kind := range []string{"error_rate", "timeout_rate"} {
			result = append(result, core.Evidence{
				ID: scope + "-" + kind, ClaimID: "application.functional_behavior",
				Claim: kind + " is stable", Observation: "the current and comparison windows agree",
				Relation: "supports", SourceType: "monitoring", SourceName: "request metrics",
				ObservedAt: now, Dimensions: map[string]string{
					"measurement_kind": kind, "measurement_scope": scope,
					"window": "10m", "comparison_window": "previous 10m",
					"population": population, "denominator": population,
				},
			})
		}
	}
	return result
}

// The candidate assessment has not been persisted yet, so its zero timestamp
// used to lose to any older row from the same layer. Stamp the candidate as
// current before the ledger merge; otherwise a coherent degraded result is
// repeatedly corrected against history it was explicitly replacing.
// Covers finding: 20260812T143515Z-run_cd8cfa2e93faa769da04d55ca948c0d5
func TestCurrentCoverageOutranksPersistedHistoryForTheSameLayer(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	prior := core.Coverage{
		Layer: "application", ClaimIDs: []string{"application.functional_behavior"},
		Status: "healthy", Detail: "The earlier point probe passed.",
		CreatedAt: now.Add(-10 * time.Minute),
	}
	candidate := core.Coverage{
		Layer: "application", ClaimIDs: []string{"application.functional_behavior"},
		Status: "degraded", Detail: "Current traffic contains 5xx responses.",
	}
	stamped := completionpolicy.CurrentCoverage([]core.Coverage{candidate}, now)
	if len(stamped) != 1 || !stamped[0].CreatedAt.Equal(now) {
		t.Fatalf("current coverage was not stamped: %+v", stamped)
	}
	contract := investigation.Compile(core.WorkEpisode{
		Effort:           core.EffortOperationalAssessment,
		RequiredCoverage: []string{"application"},
	})
	ledger := investigation.BuildLedger(contract, []core.Evidence{
		{ID: "probe", ClaimID: "application.functional_behavior", Relation: "supports", HealthEffect: "none", ObservedAt: now.Add(-10 * time.Minute), Dimensions: map[string]string{"service": "checkout", "endpoint": "/ready", "environment": "production", "window": "point-in-time"}},
		{ID: "errors", ClaimID: "application.functional_behavior", Relation: "contradicts", HealthEffect: "degraded", ObservedAt: now, Dimensions: map[string]string{"service": "checkout", "endpoint": "requests", "environment": "production", "window": "10m"}},
	}, append([]core.Coverage{prior}, stamped...), now)
	view := ledger.Claims["application.functional_behavior"]
	if !view.Resolved || view.CoverageStatus != "degraded" {
		t.Fatalf("current degraded coverage lost to persisted history: %+v", view)
	}
}

func TestDeepEpisodeActiveDegradationRequiresDiagnosticClosure(t *testing.T) {
	episode := core.WorkEpisode{Effort: core.EffortOperationalAssessment}
	coverage := []core.Coverage{
		{Layer: "application", Status: "degraded", Detail: "LoL and Rivals errors persist"},
	}
	completion := &CompletionAssessment{
		Status: "decision_ready", Summary: "Production is operational but degraded.",
	}
	unfinished := &decisionpkg.AlertAssessment{
		Verdict:          "confirmed_issue",
		Impact:           "LoL and Rivals requests are failing, but affected endpoints remain unattributed.",
		ImmediateAction:  "Prioritize endpoint attribution and trace the timeout source.",
		LongTermSolution: "Fix the LoL and Rivals request paths.",
	}
	if got := decisionpkg.EpisodeDiagnosisCorrection(
		episode, "reply", nil, coverage, unfinished, completion,
	); !strings.Contains(got, "identified or bounded cause") {
		t.Fatalf("unfinished diagnosis correction = %q", got)
	}

	bounded := &decisionpkg.AlertAssessment{
		Verdict:             "confirmed_issue",
		Impact:              "LoL requests using the ranked-profile endpoint fail for affected accounts.",
		CauseStatus:         "bounded",
		Cause:               "The ranked-profile decoder rejects the newly returned rank values.",
		CauseClaimIDs:       []string{"application.functional_behavior"},
		EvidenceRefs:        []string{"decoder-values"},
		ImmediateAction:     "Disable ranked-profile enrichment while preserving the base request.",
		ImmediateActionKind: "mitigation",
		Verification:        "Repeat affected requests and confirm ingress 5xx returns below 0.1 percent.",
		LongTermSolution:    "Accept the new rank values and add compatibility fixtures.",
		Scope: &decisionpkg.OperationalScope{
			Status: "bounded", CheckedTargets: []string{"ranked-profile endpoint"},
			UnverifiedTargets: []string{"other LoL endpoints"}, EvidenceRefs: []string{"decoder-values"},
		},
	}
	evidence := []core.Evidence{{
		ID: "decoder-values", ClaimID: "application.functional_behavior", Relation: "supports", Claim: "the decoder rejects the new values",
		Observation: "repository and request logs show the strict decoder on the failing request path", Target: "ranked-profile endpoint",
	}}
	if got := decisionpkg.EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, bounded, completion,
	); got != "" {
		t.Fatalf("bounded diagnosis rejected: %s", got)
	}
	unsupported := *bounded
	unsupported.EvidenceRefs = []string{"missing-cause-evidence"}
	// The refusal has to name the reference it rejected and the one on record:
	// "absent" was the whole of it for eight rounds on 2026-08-16, and a model
	// cannot repair a citation the host will not name.
	got := decisionpkg.EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, &unsupported, completion,
	)
	for _, want := range []string{"missing-cause-evidence", "decoder-values"} {
		if !strings.Contains(got, want) {
			t.Fatalf("unsupported diagnosis correction never named %q: %q", want, got)
		}
	}

	unfinishedAction := *bounded
	unfinishedAction.ImmediateAction = "Inspect the current allocations and service registrations."
	unfinishedAction.ImmediateActionKind = "investigation"
	if got := decisionpkg.EpisodeDiagnosisCorrection(
		episode, "reply", evidence, coverage, &unfinishedAction, completion,
	); !strings.Contains(got, "investigative handoff") {
		t.Fatalf("unfinished action correction = %q", got)
	}

	blocked := &CompletionAssessment{
		Status: "blocked", Summary: "Endpoint attribution is unavailable.",
		MaterialGaps: []string{"endpoint labels"}, BlockerKind: "source_unavailable",
		Attempts:   []string{"Queried the configured log and trace sources; neither contains endpoint labels"},
		NextAction: "Restore endpoint labels in the application telemetry, then retry",
	}
	if got := decisionpkg.EpisodeDiagnosisCorrection(
		episode, "reply", nil, coverage, nil, blocked,
	); got != "" {
		t.Fatalf("exact diagnostic blocker rejected: %s", got)
	}
}

func TestEpisodeClaimCorrectionRequiresTypedEvidenceAndCoverageBinding(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
	}
	completion := &CompletionAssessment{Status: "decision_ready", Summary: "Validation commands identified."}
	coverage := []core.Coverage{{
		Layer: "change", Status: "healthy", Detail: "Current repository manuals define the validation commands.",
	}}
	if got := investigation.ClaimCorrection(episode, "reply", nil, coverage, completion, now, now, true); !strings.Contains(got, "no typed evidence") {
		t.Fatalf("missing evidence correction = %q", got)
	}
	evidence := []core.Evidence{{
		ClaimID: "change.recent", Relation: "supports", SourceType: "repository", SourceName: "AGENTS.md",
		Observation: "The repository defines ./run gate all.", ObservedAt: now, Confidence: "high",
		Dimensions: map[string]string{"repository": "emisar", "environment": "checkout", "revision": "current"},
	}}
	if got := investigation.ClaimCorrection(episode, "reply", evidence, coverage, completion, now, now, true); !strings.Contains(got, "must include its exact claim_id") {
		t.Fatalf("unbound coverage correction = %q", got)
	}
	coverage[0].ClaimIDs = []string{"change.recent"}
	if got := investigation.ClaimCorrection(episode, "reply", evidence, coverage, completion, now, now, true); got != "" {
		t.Fatalf("bound evidence rejected = %q", got)
	}
}

// A task offer changes which outcome is being completed; it does not let an
// ungrounded repository guess become a confirmable engineering action.
func TestAnEngineeringOfferStillNeedsTypedEvidenceAndCoverage(t *testing.T) {
	now := time.Now().UTC()
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
	}
	coverage := []core.Coverage{{
		Layer: "change", ClaimIDs: []string{"change.recent"}, Status: "healthy",
		Detail: "The exact candidate revision was inspected.", CreatedAt: now,
	}}
	if got := taskofferclaims.Correction(
		episode, nil, coverage, "ryker", now, now,
	); !strings.Contains(got, "no typed evidence") {
		t.Fatalf("ungrounded task offer correction = %q", got)
	}
	evidence := []core.Evidence{{
		ClaimID: "change.recent", Relation: "supports", ObservedAt: now,
		SourceType: "repository", SourceName: "candidate checkout",
		Dimensions: map[string]string{
			"repository": "ryker", "environment": "candidate", "revision": "abc123",
		},
	}}
	if got := taskofferclaims.Correction(
		episode, evidence, coverage, "ryker", now, now,
	); got != "" {
		t.Fatalf("evidence-backed task offer rejected = %q", got)
	}

	for _, testCase := range []struct {
		name     string
		episode  core.WorkEpisode
		evidence core.Evidence
	}{
		{
			name:    "contradicted",
			episode: episode,
			evidence: core.Evidence{
				ClaimID: "change.recent", Relation: "contradicts", ObservedAt: now,
				Dimensions: evidence[0].Dimensions,
			},
		},
		{
			name: "missing dimensions", episode: episode,
			evidence: core.Evidence{ClaimID: "change.recent", Relation: "supports", ObservedAt: now},
		},
		{
			name: "stale live evidence",
			episode: core.WorkEpisode{
				Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"host"},
			},
			evidence: core.Evidence{
				ClaimID: "host.current_state", Relation: "supports", ObservedAt: now.Add(-time.Hour),
				Dimensions: map[string]string{"host": "node-1", "environment": "production"},
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			itemCoverage := coverage
			if testCase.episode.RequiredCoverage[0] == "host" {
				itemCoverage = []core.Coverage{{
					Layer: "host", ClaimIDs: []string{"host.current_state"}, Status: "healthy",
					Detail: "One production host was checked.", CreatedAt: now,
				}}
			}
			if got := taskofferclaims.Correction(
				testCase.episode, []core.Evidence{testCase.evidence}, itemCoverage,
				strings.TrimSpace(testCase.evidence.Dimensions["repository"]), now, now,
			); got == "" {
				t.Fatal("unsafe task offer was authorized")
			}
		})
	}
	if got := taskofferclaims.Correction(
		core.WorkEpisode{RequiredCoverage: []string{"task"}}, nil, nil, "", now, now,
	); got != "" {
		t.Fatalf("future task outcome was not exempted: %q", got)
	}
}

// A confirmation control does not change what the assessment claims about the
// system that motivated it. One production path returned "healthy" beside an
// engineering offer and bypassed the fresh functional/trend gate entirely.
func TestAHealthyAssessmentWithATaskOfferStillNeedsCurrentTrends(t *testing.T) {
	now := time.Now().UTC()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := &Service{store: st}
	correction, err := svc.episodeClaimCorrectionWithHistory(
		context.Background(),
		core.WorkEpisode{Effort: core.EffortOperationalAssessment},
		"reply", nil, nil,
		&CompletionAssessment{Status: "decision_ready", Verdict: "healthy"},
		now, now,
		[]investigation.ResultOperation{{
			ID: "offer-fix", Type: "offer_task",
			Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix the unhealthy path"},
		}}, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(correction, "typed functional_probe") {
		t.Fatalf("healthy offer bypassed current trend validation: %q", correction)
	}
}

// A blocked investigation may still offer a repair, but the button must be
// grounded in the same current evidence as any other confirmable task.
func TestABlockedTaskOfferStillNeedsCurrentClaimEvidence(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := &Service{store: st}
	now := time.Now().UTC()
	correction, err := svc.episodeClaimCorrectionWithHistory(
		ctx,
		core.WorkEpisode{Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"}},
		"reply",
		[]core.Evidence{{
			ClaimID: "change.recent", Relation: "contradicts", ObservedAt: now,
			Dimensions: map[string]string{
				"repository": "ryker", "environment": "candidate", "revision": "abc123",
			},
		}},
		[]core.Coverage{{
			Layer: "change", ClaimIDs: []string{"change.recent"}, Status: "healthy",
			CreatedAt: now,
		}},
		&CompletionAssessment{
			Status: "blocked", Summary: "The repair needs operator confirmation.",
			MaterialGaps: []string{"write authority"}, BlockerKind: "approval_required",
			Attempts: []string{"Inspected the candidate"}, NextAction: "Confirm the offered task",
		},
		now, now,
		[]investigation.ResultOperation{{
			ID: "offer-fix", Type: "offer_task",
			Task: &investigation.TaskOffer{Kind: "engineering", Title: "Apply the repair"},
		}}, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if correction == "" {
		t.Fatal("blocked task offer bypassed contradictory current evidence")
	}
}

// A root episode is shown the evidence its own work already produced.
//
// The continuity block used to return early unless the episode had a parent.
// Every incident episode on the busy deployment is a root, so that test was
// never true and the block never fired — while thirteen of the fourteen sat on
// an incident whose evidence they were not shown. The second attempt at an
// investigation rediscovered what the first had proved.
func TestARootEpisodeSeesTheEvidenceItsOwnWorkProduced(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CINC",
		ConversationKey: "channel:CINC",
		SourceKind:      "watch", SourceID: "input_continuity",
		Episode: &core.WorkEpisode{
			Effort: core.EffortIncidentInvestigation, Authority: core.AuthorityReadOnly,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.ParentEpisodeID != "" {
		t.Fatalf("this episode has a parent, so it does not test the gate: %q", episode.ParentEpisodeID)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		ChannelID: "CINC", SourceInput: "input_continuity",
		ClaimID: "system.disk_pressure", Claim: "disk latency",
		Observation: "p99 write latency is 40ms on va1-cass-3",
		SourceType:  "metric", SourceName: "grafana", ObservedAt: time.Now().UTC(),
	}}); err != nil {
		t.Fatal(err)
	}

	svc := &Service{cfg: cfg, store: st}
	prompt := svc.episodeContinuityPrompt(ctx, episode)
	if prompt == "" {
		t.Fatal("a root episode was shown none of the evidence its own work produced")
	}
	if !strings.Contains(prompt, "p99 write latency is 40ms on va1-cass-3") {
		t.Fatalf("the evidence did not reach the turn: %s", prompt)
	}
}

// A Slack follow-up is shown the findings its earlier episode already recorded.
//
// The continuity block above was wired into the incident lane only. An
// ordinary Slack follow-up creates a child episode on the triage path — the
// exact "continue this work" case — and that path never called it, so the
// second turn re-derived what the first had proved from at most a ten-row
// channel evidence slice, spending its tool budget rediscovering its own
// conclusions.
func TestASlackFollowupSeesThePriorEpisodesFindings(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CFOLLOW"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State: "completed",
			AssistantMessage: `{"action":"reply",
				"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":2},
				"reason":"direct question with evidence",
				"operations":[
					{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"application.functional_behavior","claim":"checkout latency cause","observation":"p99 write latency is 40ms on va1-cass-3","relation":"supports","health_effect":"risk","source_type":"monitoring","source_name":"grafana","confidence":"high","freshness":"live query","dimensions":{"service":"checkout","environment":"production"}}},
					{"id":"complete","type":"complete_episode","completion":{"message":"Checkout is slow because va1-cass-3 writes at 40ms p99.","completion":{"status":"decision_ready","summary":"cause identified"}}}]}`,
		},
		{
			State: "completed",
			AssistantMessage: `{"action":"reply",
				"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":1,"ownership":2},
				"reason":"follow-up answered from established findings",
				"operations":[{"id":"complete","type":"complete_episode","completion":{"message":"Still the same cause; nothing new since the last check.","completion":{"status":"decision_ready","summary":"unchanged"}}}]}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	first := core.SlackInput{
		ID: "slack-follow-1", EnvelopeID: "env-follow-1", EventID: "event-follow-1",
		Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CFOLLOW", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@U999BOT> why is checkout slow?",
	}
	if created, err := st.AdmitSlackInput(ctx, first); err != nil || !created {
		t.Fatalf("admit first input = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	followup := core.SlackInput{
		ID: "slack-follow-2", EnvelopeID: "env-follow-2", EventID: "event-follow-2",
		Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CFOLLOW", MessageTS: "1700.200", UserID: "U123ABC",
		Text: "<@U999BOT> anything new on that?",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit follow-up = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	followupRun, err := st.GetAgentRunBySource(ctx, "watch", followup.ID)
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, followupRun.ID)
	if err != nil {
		t.Fatal(err)
	}
	if episode.ParentEpisodeID == "" {
		t.Fatal("the follow-up did not create a child episode, so this test no " +
			"longer exercises the continuity chain it was written for")
	}
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("expected two model turns, got %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[1]
	if !strings.Contains(prompt, "<episode-continuity>") {
		t.Fatal("the follow-up turn carries no episode-continuity block; " +
			"the prior episode's findings never reached the model")
	}
	if !strings.Contains(prompt, "p99 write latency is 40ms on va1-cass-3") {
		t.Fatalf("the parent episode's evidence did not reach the follow-up turn:\n%.2000s", prompt)
	}
	if !strings.Contains(prompt, "history, not current proof") ||
		!strings.Contains(prompt, "re-record any observation this result relies on") {
		t.Fatalf("the continuity block does not keep historical evidence out of the current verdict:\n%.2000s", prompt)
	}
}
