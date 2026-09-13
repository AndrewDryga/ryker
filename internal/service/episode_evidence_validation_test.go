package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

func TestLostValidationResponseDoesNotStrandTheRun(t *testing.T) {
	// A successful Coop mutation can outlive its HTTP response. Replaying the
	// awaiting-validation event must recognize Coop's durable decision; otherwise
	// valid work remains stuck forever after an ordinary transport timeout.
	message := `{"reply":"accepted"}`
	digest := sha256.Sum256([]byte(message))
	candidateDigest := hex.EncodeToString(digest[:])
	client := newFakeCoop()
	svc := &Service{coop: client}

	accepted := coop.Turn{
		State: "completed", AssistantMessage: message,
		ValidationCandidateSHA256: candidateDigest,
		ValidationAttempt:         1, ValidationReceipt: "validation-receipt",
	}
	if err := svc.validateSemanticCandidate(context.Background(), core.AgentRun{}, accepted, 1); err != nil {
		t.Fatalf("recognize committed acceptance: %v", err)
	}
	if len(client.candidateAccepts) != 0 || len(client.candidateRejects) != 0 {
		t.Fatalf("committed acceptance was submitted again: accepts=%v rejects=%v", client.candidateAccepts, client.candidateRejects)
	}

	rejected := coop.Turn{
		State: "queued", ValidationCandidateSHA256: candidateDigest,
		ValidationAttempt: 1, ValidationError: "current evidence contradicts the completion",
	}
	if err := svc.validateSemanticCandidate(context.Background(), core.AgentRun{}, rejected, 1); err != nil {
		t.Fatalf("recognize committed rejection: %v", err)
	}
	if len(client.candidateAccepts) != 0 || len(client.candidateRejects) != 0 {
		t.Fatalf("committed rejection was submitted again: accepts=%v rejects=%v", client.candidateAccepts, client.candidateRejects)
	}
}

// Fifteen corrections on episode_run_6f5409ee1bc67c42adf6ed2c08040dda,
// among 745 corrections in two days, started when the model cited evidence
// gathered earlier in the same run and the validator said it did not exist. A
// correction the model cannot satisfy is a host bug. Correlation ancestry is
// different: it is history and must be observed again before proving today.
func TestAnIncidentMayCiteEvidenceCarriedByItsCurrentRun(t *testing.T) {
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
	currentEvidence := []core.Evidence{
		{
			ID: "e-application-ads-3915664-recheck2", ChannelID: input.ChannelID,
			SourceInput: input.ID, ClaimID: "application.functional_behavior",
			Claim:       "Representative user paths work without a current error or timeout spike.",
			Observation: "In the second consecutive five-node verification round, nomad-hvn01 through nomad-hvn03 returned HTTP 200 while nomad-hvn04 and nomad-hvn05 timed out.",
			Relation:    "contradicts", HealthEffect: "degraded", SourceType: "emisar",
			SourceID: "op_18W9WWTYHDWY2WYSEZTDTQ25Q7", SourceName: "Emisar five-node HTTP probe",
			Target: "https://blitz.gg/ads.txt", Freshness: "live", Confidence: "high",
			ObservedAt: now.Add(-2 * time.Minute), CreatedAt: now.Add(-2 * time.Minute),
		},
		{
			ID: "e-change-ads-3915664", ChannelID: input.ChannelID, SourceInput: input.ID,
			ClaimID:     "change.recent",
			Claim:       "The observed state is consistent with the intended current revision and recent rollout.",
			Observation: "Authenticated PR 529 changes staged hostname TLS only for delta-builder and frontend-utilities; it does not change the standalone blitz.gg website pull zone.",
			Relation:    "supports", SourceType: "repository", SourceID: "github-pr-529",
			SourceName: "Authenticated blitz-infra PR 529 snapshot",
			Target:     "Recent configuration affecting blitz.gg", Freshness: "current authenticated PR snapshot",
			Confidence: "high", ObservedAt: now.Add(-3 * time.Minute), CreatedAt: now.Add(-3 * time.Minute),
		},
	}
	watchState := decisionWatchStateForEpisodeEvidence()
	watchState["carried_evidence"] = currentEvidence
	state, err := json.Marshal(watchState)
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
	if _, err := st.Intelligence.RecordEvidence(ctx, currentEvidence); err != nil {
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
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.clock = func() time.Time { return now }
	coopClient.turn = coop.Turn{
		ID: "turn-linked-ads", SessionID: run.SessionID, State: "awaiting_validation",
		Candidate: &coop.TurnCandidate{Message: result, SHA256: "candidate-linked-ads", Attempt: 1},
	}
	coopClient.events = []coop.Event{{
		ID: "event-candidate", SessionID: run.SessionID, Sequence: 1,
		TurnID: run.CoopTurnID, Type: "turn.awaiting_validation", Version: 1,
	}}
	if err := svc.pollAgentRunOnce(ctx, run); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.candidateRejects) != 1 ||
		!strings.Contains(coopClient.candidateViolations[0][0], "cause_claim_ids") {
		t.Fatalf("semantic candidate was not rejected with the host's exact correction: rejects=%v violations=%v",
			coopClient.candidateRejects, coopClient.candidateViolations)
	}
	unchanged, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	unchangedState, err := decodeWatchRunContext(unchanged)
	if err != nil {
		t.Fatal(err)
	}
	if unchangedState.StructuredCorrections != 0 {
		t.Fatalf("pre-completion rejection spent Ryker's old correction budget: %+v", unchangedState)
	}
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
		t.Fatalf("the host rejected evidence carried by the current run: %s", corrected.FailureDetail)
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
		"session_id": "session-linked-ads", "repository": "blitz-infra",
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
