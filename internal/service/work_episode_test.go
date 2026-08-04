package service

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestWatchedInputEffortAndAuthorityAreIndependent(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	cases := []struct {
		name      string
		input     core.SlackInput
		state     watchTurnState
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
			input:  core.SlackInput{Kind: "bot_message", UserID: "BGRAFANA", Text: "High disk I/O latency on dbzrk103"},
			state:  watchTurnState{MatchedRules: []core.StandingRule{{Trigger: "operational_alert", Action: "triage_alert"}}},
			effort: core.EffortIncidentInvestigation, authority: core.AuthorityReadOnly,
			coverage: []string{"change", "application", "slo", "host"},
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
	governed := svc.episodeForIncident(incident, core.AgentRunIncident, "proposal", "Apply exact remediation")
	if governed.Effort != core.EffortIncidentInvestigation || governed.Authority != core.AuthorityGovernedOperation {
		t.Fatalf("governed incident episode = %+v", governed)
	}
	engineering := svc.episodeForIncident(incident, core.AgentRunEngineeringTask, "slack", "Fix the regression")
	if engineering.Effort != core.EffortEngineeringTask ||
		engineering.Authority != core.AuthorityRepositoryWrite || len(engineering.RequiredCoverage) != 0 {
		t.Fatalf("engineering episode = %+v", engineering)
	}
}

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
		completion *completionAssessment
		want       string
	}{
		{name: "non final action", action: "ignore"},
		{name: "missing completion", action: "reply", coverage: completeCoverage, want: "no completion assessment"},
		{
			name: "missing layer", action: "reply", coverage: completeCoverage[:2],
			completion: &completionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "Healthy"},
			want:       "has not assessed required coverage layers: slo",
		},
		{
			name: "unknown decision", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts respond"},
				{Layer: "application", Status: "unknown", Detail: "Probe access is unavailable"},
				{Layer: "slo", Status: "healthy", Detail: "No alert is active"},
			},
			completion: &completionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "Healthy"},
			want:       "healthy verdict cannot leave material operational coverage unknown",
		},
		{
			name: "blocked without action", action: "reply", coverage: completeCoverage,
			completion: &completionAssessment{Status: "blocked", Summary: "Impact is unknown", MaterialGaps: []string{"SLO source"}},
			want:       "external blocker_kind",
		},
		{
			name: "unfinished investigation is not a blocker", action: "reply", coverage: completeCoverage,
			completion: &completionAssessment{
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
			completion: &completionAssessment{
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
			completion: &completionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "The checked scope is healthy."},
		},
		{
			name: "healthy without formal SLO", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts are responsive"},
				{Layer: "application", Status: "healthy", Detail: "Functional checks pass and error rates are normal"},
				{Layer: "slo", Status: "not_applicable", Detail: "No formal SLO is defined"},
			},
			completion: &completionAssessment{Status: "decision_ready", Verdict: "healthy", Summary: "The platform is healthy."},
		},
		{
			name: "verified errors decide degradation despite other unknowns", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "unknown", Detail: "One hardware inventory source is unavailable"},
				{Layer: "application", Status: "degraded", Detail: "Current request errors exceed baseline"},
				{Layer: "slo", Status: "not_applicable", Detail: "No formal SLO is defined"},
			},
			completion: &completionAssessment{Status: "decision_ready", Verdict: "degraded", Summary: "The platform is degraded."},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := episodeCompletionCorrection(episode, test.action, test.coverage, test.completion)
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
		completion *completionAssessment
		wantError  bool
	}{
		{name: "omitted"},
		{name: "decision ready", completion: &completionAssessment{Status: "decision_ready", Summary: "Healthy"}},
		{name: "decision ready with follow-up", completion: &completionAssessment{Status: "decision_ready", Summary: "The schedule is ready for confirmation", NextAction: "Confirm the schedule"}},
		{name: "decision with gap", completion: &completionAssessment{Status: "decision_ready", Summary: "Healthy", MaterialGaps: []string{"database"}}, wantError: true},
		{name: "blocked", completion: &completionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", Attempts: []string{"Monitoring query returned permission denied"}, NextAction: "Restore access"}},
		{name: "blocked capability", completion: &completionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Install the observed pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "GitHub Actions run inspection", Status: "not_installed", PackID: "github-cli", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "Install the `github-cli` pack on the operations runner."}}}},
		{name: "capability blocker without gap", completion: &completionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Add the capability"}, wantError: true},
		{name: "fabricated pack shape", completion: &completionAssessment{Status: "blocked", Summary: "GitHub Actions inspection is unavailable", MaterialGaps: []string{"exact workflow result"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Install a pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "GitHub Actions run inspection", Status: "not_installed", PackID: "made-up-pack", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "Install another pack."}}}, wantError: true},
		{name: "no matching pack", completion: &completionAssessment{Status: "blocked", Summary: "The capability is unavailable", MaterialGaps: []string{"provider evidence"}, BlockerKind: "capability_unavailable", Attempts: []string{"Searched find_actions and list_packs"}, NextAction: "Add a compatible governed pack", CapabilityGaps: []investigation.CapabilityGap{{Capability: "Vendor-specific evidence", Status: "not_found", EvidenceRefs: []string{"pack-catalog"}, Recommendation: "No matching pack was found; add a governed pack for this provider."}}}},
		{name: "blocked with verdict", completion: &completionAssessment{Status: "blocked", Verdict: "degraded", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", Attempts: []string{"Monitoring query returned permission denied"}, NextAction: "Restore access"}, wantError: true},
		{name: "blocked without kind", completion: &completionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, Attempts: []string{"Queried monitoring"}, NextAction: "Restore access"}, wantError: true},
		{name: "blocked without attempts", completion: &completionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", NextAction: "Restore access"}, wantError: true},
		{name: "blocked without action", completion: &completionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}}, wantError: true},
		{name: "unknown state", completion: &completionAssessment{Status: "working", Summary: "Partial"}, wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateCompletionAssessment(test.completion)
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v", err)
			}
		})
	}
	if _, err := decodeWatchDecision(`{"action":"react","reaction":"eyes","completion":{"status":"decision_ready","summary":"Done"}}`); err == nil {
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
	completion := &completionAssessment{
		Status: "decision_ready", Verdict: "in_progress",
		Summary: "The change is applying and needs terminal verification.",
	}
	if got := episodeCompletionCorrection(episode, "reply", coverage, completion); got != "" {
		t.Fatalf("in-progress change rejected: %s", got)
	}
	completion.Verdict = "degraded"
	if got := episodeCompletionCorrection(episode, "reply", coverage, completion); !strings.Contains(got, "change_review") {
		t.Fatalf("health verdict accepted for change review: %q", got)
	}
	completion.Verdict = "succeeded"
	if got := episodeCompletionCorrection(episode, "reply", coverage, completion); got == "" {
		t.Fatalf("success without terminal evidence accepted: %q", got)
	}
}

func TestFocusedCoverageDoesNotTreatNegatedHealthLanguageAsRequestedCoverage(t *testing.T) {
	svc := &Service{}
	episode := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Review this exact Terraform plan. Do not infer operational health from change risk alone.",
	}, watchTurnState{})
	if got := investigation.Compile(*episode).Completion.ConclusionKind; got != "change_review" {
		t.Fatalf("conclusion kind = %q", got)
	}
	if !slices.Equal(episode.RequiredCoverage, []string{"change"}) {
		t.Fatalf("required coverage = %v", episode.RequiredCoverage)
	}

	recovery := svc.episodeForWatchedInput(core.SlackInput{
		Kind: "mention", Text: "Assess whether checkout recovered after the deployment.",
	}, watchTurnState{})
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
	}, watchTurnState{})
	contract := investigation.Compile(*episode)
	if episode.Effort != core.EffortFocusedCheck || contract.Completion.ConclusionKind != "factual_assessment" {
		t.Fatalf("runbook episode = %+v, completion = %+v", episode, contract.Completion)
	}
	if !slices.Equal(episode.RequiredCoverage, []string{"task"}) {
		t.Fatalf("runbook coverage = %v", episode.RequiredCoverage)
	}
	if got := episodeConclusionLanguageCorrection(
		*episode,
		"reply",
		"**Degraded** - the expanded runbook is validated but unpublished.",
	); !strings.Contains(got, "not an operational health assessment") {
		t.Fatalf("runbook health heading accepted: %q", got)
	}
	if got := episodeConclusionLanguageCorrection(
		*episode,
		"reply",
		"The expanded runbook is validated. Publication is the remaining step.",
	); got != "" {
		t.Fatalf("task-state answer rejected: %q", got)
	}
}

func TestTypedTaskCoverageCompletesFocusedArtifactAssessment(t *testing.T) {
	decision, err := parseWatchDecision(`{
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
	}`)
	if err != nil {
		t.Fatalf("parse typed decision: %v", err)
	}
	if len(decision.Coverage) != 1 || decision.Coverage[0].Layer != "task" {
		t.Fatalf("coverage = %+v, want task coverage", decision.Coverage)
	}
	if len(decision.Evidence) != 1 || decision.Evidence[0].ClaimID != "task.requested_outcome" {
		t.Fatalf("evidence = %+v, want requested outcome evidence", decision.Evidence)
	}
	decision.Coverage = sanitizeCoverage(decision.Coverage, "eval", "CEVALUATION", "input")
	if len(decision.Coverage) != 1 || decision.Coverage[0].Layer != "task" {
		t.Fatalf("sanitized coverage = %+v, want task coverage", decision.Coverage)
	}

	service := Service{}
	episode := service.episodeForWatchedInput(core.SlackInput{
		Kind: "mention",
		Text: "Also extend that runbook and test it; make sure it is all we need for daily checkups.",
	}, watchTurnState{})
	if got := episode.RequiredCoverage; !slices.Equal(got, []string{"task"}) {
		t.Fatalf("required coverage = %v, want [task]", got)
	}
	if correction := episodeCompletionCorrection(
		*episode,
		decision.Action,
		decision.Coverage,
		decision.Completion,
	); correction != "" {
		t.Fatalf("completion correction = %q", correction)
	}
	if correction := episodeClaimCorrection(
		*episode,
		decision.Action,
		decision.Evidence,
		decision.Coverage,
		decision.Completion,
		time.Date(2026, 8, 3, 15, 5, 0, 0, time.UTC),
		true,
	); correction != "" {
		t.Fatalf("claim correction = %q", correction)
	}
}

func TestDeepEpisodeActiveDegradationRequiresDiagnosticClosure(t *testing.T) {
	episode := core.WorkEpisode{Effort: core.EffortOperationalAssessment}
	coverage := []core.Coverage{
		{Layer: "application", Status: "degraded", Detail: "LoL and Rivals errors persist"},
	}
	completion := &completionAssessment{
		Status: "decision_ready", Summary: "Production is operational but degraded.",
	}
	unfinished := &alertAssessment{
		Verdict:          "confirmed_issue",
		Impact:           "LoL and Rivals requests are failing, but affected endpoints remain unattributed.",
		ImmediateAction:  "Prioritize endpoint attribution and trace the timeout source.",
		LongTermSolution: "Fix the LoL and Rivals request paths.",
	}
	if got := episodeDiagnosisCorrection(
		episode, "reply", coverage, unfinished, completion,
	); !strings.Contains(got, "identified or bounded cause") {
		t.Fatalf("unfinished diagnosis correction = %q", got)
	}

	bounded := &alertAssessment{
		Verdict:          "confirmed_issue",
		Impact:           "LoL requests using the ranked-profile endpoint fail for affected accounts.",
		CauseStatus:      "bounded",
		Cause:            "The ranked-profile decoder rejects the newly returned rank values.",
		ImmediateAction:  "Disable ranked-profile enrichment while preserving the base request.",
		Verification:     "Repeat affected requests and confirm ingress 5xx returns below 0.1 percent.",
		LongTermSolution: "Accept the new rank values and add compatibility fixtures.",
	}
	if got := episodeDiagnosisCorrection(
		episode, "reply", coverage, bounded, completion,
	); got != "" {
		t.Fatalf("bounded diagnosis rejected: %s", got)
	}

	blocked := &completionAssessment{
		Status: "blocked", Summary: "Endpoint attribution is unavailable.",
		MaterialGaps: []string{"endpoint labels"}, BlockerKind: "source_unavailable",
		Attempts:   []string{"Queried the configured log and trace sources; neither contains endpoint labels"},
		NextAction: "Restore endpoint labels in the application telemetry, then retry",
	}
	if got := episodeDiagnosisCorrection(
		episode, "reply", coverage, nil, blocked,
	); got != "" {
		t.Fatalf("exact diagnostic blocker rejected: %s", got)
	}
}

func TestEpisodeClaimCorrectionRequiresTypedEvidenceAndCoverageBinding(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	episode := core.WorkEpisode{
		Effort: core.EffortFocusedCheck, RequiredCoverage: []string{"change"},
	}
	completion := &completionAssessment{Status: "decision_ready", Summary: "Validation commands identified."}
	coverage := []core.Coverage{{
		Layer: "change", Status: "healthy", Detail: "Current repository manuals define the validation commands.",
	}}
	if got := episodeClaimCorrection(episode, "reply", nil, coverage, completion, now, true); !strings.Contains(got, "no typed evidence") {
		t.Fatalf("missing evidence correction = %q", got)
	}
	evidence := []core.Evidence{{
		ClaimID: "change.recent", Relation: "supports", SourceType: "repository", SourceName: "AGENTS.md",
		Observation: "The repository defines ./run gate all.", ObservedAt: now, Confidence: "high",
		Dimensions: map[string]string{"repository": "emisar", "environment": "checkout", "revision": "current"},
	}}
	if got := episodeClaimCorrection(episode, "reply", evidence, coverage, completion, now, true); !strings.Contains(got, "must include its exact claim_id") {
		t.Fatalf("unbound coverage correction = %q", got)
	}
	coverage[0].ClaimIDs = []string{"change.recent"}
	if got := episodeClaimCorrection(episode, "reply", evidence, coverage, completion, now, true); got != "" {
		t.Fatalf("bound evidence rejected = %q", got)
	}
}
