package service

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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
			completion: &completionAssessment{Status: "decision_ready", Summary: "Healthy"},
			want:       "has not assessed required coverage layers: slo",
		},
		{
			name: "unknown decision", action: "reply",
			coverage: []core.Coverage{
				{Layer: "host", Status: "healthy", Detail: "Both hosts respond"},
				{Layer: "application", Status: "unknown", Detail: "Probe access is unavailable"},
				{Layer: "slo", Status: "healthy", Detail: "No alert is active"},
			},
			completion: &completionAssessment{Status: "decision_ready", Summary: "Healthy"},
			want:       "claims decision_ready",
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
			completion: &completionAssessment{Status: "decision_ready", Summary: "The checked scope is healthy."},
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
		{name: "decision with gap", completion: &completionAssessment{Status: "decision_ready", Summary: "Healthy", MaterialGaps: []string{"database"}}, wantError: true},
		{name: "blocked", completion: &completionAssessment{Status: "blocked", Summary: "Impact unknown", MaterialGaps: []string{"monitoring"}, BlockerKind: "access_denied", Attempts: []string{"Monitoring query returned permission denied"}, NextAction: "Restore access"}},
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
