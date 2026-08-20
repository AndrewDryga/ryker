package service

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// Fifteen corrections on episode_run_6f5409ee1bc67c42adf6ed2c08040dda,
// among 745 corrections in two days, started when the model cited these exact
// host-recorded evidence IDs from episode-continuity and the validator said
// they did not exist. A correction the model cannot satisfy is a host bug.
func TestAnIncidentMayCiteHostRecordedEpisodeEvidence(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 10
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	now := time.Now().UTC()
	input := core.SlackInput{
		ID: "linked-ads-continuity", EnvelopeID: "env-linked-ads-continuity",
		EventID: "event-linked-ads-continuity", Kind: "bot_message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", UserID: "BGRAFANA",
		MessageTS: "1787186877.000000", ReceivedAt: now,
		Text: "FIRING: ads.txt timed out without response headers",
	}
	if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
		t.Fatalf("admit linked alert = %t, %v", created, admitErr)
	}
	state, err := json.Marshal(decisionWatchStateForEpisodeEvidence())
	if err != nil {
		t.Fatal(err)
	}
	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID,
		ConversationKey: "operation:COPS:alert:BGRAFANA:ads.txt",
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		SessionID: "session-linked-ads", Context: state,
		Episode: &core.WorkEpisode{
			Effort: core.EffortOperationalAssessment, Authority: core.AuthorityReadOnly,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{
		{
			ID: "e-application-ads-3915664-recheck2", ChannelID: input.ChannelID,
			SourceInput: input.ID, ClaimID: "application.functional_behavior",
			Claim:       "Representative user paths work without a current error or timeout spike.",
			Observation: "In the second consecutive five-node verification round, nomad-hst01 through nomad-hst03 returned HTTP 200 while nomad-hst04 and nomad-hst05 timed out.",
			Relation:    "contradicts", HealthEffect: "degraded", SourceType: "emisar",
			SourceID: "op_18W9WWTYHDWY2WYSEZTDTQ25Q7", SourceName: "Emisar five-node HTTP probe",
			Target: "https://tenant.example/ads.txt", Freshness: "live", Confidence: "high",
			ObservedAt: now.Add(-2 * time.Minute), CreatedAt: now.Add(-2 * time.Minute),
		},
		{
			ID: "e-change-ads-3915664", ChannelID: input.ChannelID, SourceInput: input.ID,
			ClaimID:     "change.recent",
			Claim:       "The observed state is consistent with the intended current revision and recent rollout.",
			Observation: "Authenticated PR 529 changes staged hostname TLS only for delta-builder and frontend-utilities; it does not change the standalone tenant.example website pull zone.",
			Relation:    "supports", SourceType: "repository", SourceID: "github-pr-529",
			SourceName: "Authenticated tenant-infra PR 529 snapshot",
			Target:     "Recent configuration affecting tenant.example", Freshness: "current authenticated PR snapshot",
			Confidence: "high", ObservedAt: now.Add(-3 * time.Minute), CreatedAt: now.Add(-3 * time.Minute),
		},
	}); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn-linked-ads", 1, 0); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRun(ctx, queued.ID)
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile("testdata/live_ads_continuity_first_turn.txt")
	if err != nil {
		t.Fatal(err)
	}
	result := freshenLinkedAdsTurn(string(contents), now)
	staged := stagedTurn{}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.clock = func() time.Time { return now }
	handled, err := svc.stageTriageTerminal(ctx, run, coop.Turn{
		ID: "turn-linked-ads", State: "completed", AssistantMessage: result,
	}, 1, &staged)
	if err != nil {
		t.Fatal(err)
	}
	requeued, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	corrected, err := decodeWatchRunContext(requeued)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(corrected.FailureDetail, "which is not a recorded evidence id") ||
		strings.Contains(corrected.FailureDetail, "cites absent evidence") {
		t.Fatalf("the host rejected evidence it put in episode-continuity: %s", corrected.FailureDetail)
	}
	if !handled || len(staged.result) != 0 {
		t.Fatalf("the first semantic refusal did not request a repair: handled=%t result=%q", handled, staged.result)
	}
	if corrected.StructuredCorrections != 1 ||
		!strings.Contains(corrected.FailureDetail, "cause_claim_ids") {
		t.Fatalf("the first repair did not name the real claim join: %+v", corrected)
	}

	// A model may still miss a dynamic join that JSON Schema cannot express.
	// The second refusal earns one retry on the stronger model rung. A third
	// must deliver the bounded answer, discard the unsafe assessment, and leave
	// the episode blocked instead of continuing the production loop.
	leased, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn-linked-ads-repair", 2, 0); err != nil {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, queued.ID)
	if err != nil {
		t.Fatal(err)
	}
	second := stagedTurn{}
	handled, err = svc.stageTriageTerminal(ctx, run, coop.Turn{
		ID: "turn-linked-ads-repair", State: "completed", AssistantMessage: result,
	}, 2, &second)
	if err != nil {
		t.Fatal(err)
	}
	if !handled || len(second.result) != 0 {
		t.Fatalf("the second semantic refusal did not request its stronger-model retry: handled=%t result=%q", handled, second.result)
	}
	leased, err = st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn-linked-ads-final", 3, 0); err != nil {
		t.Fatal(err)
	}
	run, err = st.GetAgentRun(ctx, queued.ID)
	if err != nil {
		t.Fatal(err)
	}
	third := stagedTurn{}
	handled, err = svc.stageTriageTerminal(ctx, run, coop.Turn{
		ID: "turn-linked-ads-final", State: "completed", AssistantMessage: result,
	}, 3, &third)
	if err != nil {
		t.Fatal(err)
	}
	if handled || len(third.result) == 0 {
		t.Fatalf("the third refusal did not stage the bounded reply: handled=%t result=%q", handled, third.result)
	}
	want, err := decisionpkg.ParseWatchDecision(result, now)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decisionpkg.DecodeWatchDecision(string(third.result), now)
	if err != nil {
		t.Fatal(err)
	}
	if got.Action != "reply" || got.Message != want.Message ||
		got.Completion == nil || got.Completion.Status != "blocked" ||
		got.AlertAssessment != nil || len(got.Operations) != 0 {
		t.Fatalf("third-refusal fallback = %+v", got)
	}
}

func decisionWatchStateForEpisodeEvidence() map[string]any {
	return map[string]any{
		"lane": "investigation", "alert_policy": "reply",
		"session_id": "session-linked-ads", "repository": "tenant-infra",
		"repository_pinned": true,
	}
}

func freshenLinkedAdsTurn(raw string, now time.Time) string {
	return strings.NewReplacer(
		"2026-08-20T00:41:11Z", now.Add(-3*time.Minute).Format(time.RFC3339),
		"2026-08-20T00:47:57Z", now.Add(-time.Minute).Format(time.RFC3339),
		"2026-08-20T00:50:00Z", now.Add(2*time.Minute).Format(time.RFC3339),
		"2026-08-20T01:00:00Z", now.Add(20*time.Minute).Format(time.RFC3339),
	).Replace(raw)
}
