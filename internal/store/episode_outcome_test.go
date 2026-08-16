package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/recall"
	"github.com/AndrewDryga/responder/internal/store/intelligencestore"
)

// The corpus was inert for as long as this product has existed: hundreds of
// fully traced episodes on the deployed databases and not one of them able to
// inform the next incident, because nothing ever flattened an episode into a
// row a later triage could read. These tests hold the projection shut at the
// exact place it is written — the transaction that makes an episode terminal —
// because a projection written anywhere else can be silently absent, and the
// symptom of that is no symptom at all: recall simply never mentions the
// episode and nobody learns it should have.

func finishedEpisodeFixture(t *testing.T, st *Store, channelID string) (core.AgentRun, core.WorkEpisode) {
	t.Helper()
	ctx := context.Background()
	input := core.SlackInput{
		ID: "input-" + channelID, EnvelopeID: "env-" + channelID, EventID: "event-" + channelID,
		Kind: "bot_message", TeamID: "T1", ChannelID: channelID, MessageTS: "1700.1",
		Text: "checkout latency alert firing: p99 above threshold on the payments gateway",
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: channelID, ConversationKey: "channel:" + channelID,
		SourceKind: "watch", SourceID: input.ID, Prompt: "Investigate " + input.ID,
	})
	if err != nil || !created {
		t.Fatalf("queue episode: created=%t err=%v", created, err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		ChannelID: channelID, SourceInput: input.ID, Claim: "p99 latency is elevated",
		Observation: "p99 3.4s", SourceType: "metrics", SourceName: "grafana",
		Target: "payments-gateway", Freshness: "fresh", Confidence: "high",
	}}); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(map[string]any{
		"id": "complete", "type": "complete_episode",
		"completion": map[string]any{
			"message": "resolved",
			"alert_assessment": map[string]any{
				"verdict": "real_issue", "impact": "checkout p99 tripled",
				"cause":            "connection pool exhaustion on the payments gateway",
				"immediate_action": "raised the pool ceiling to 200",
				"verification":     "p99 returned to 380ms and held for ten minutes",
			},
			"completion": map[string]any{"status": "decision_ready", "summary": "pool exhaustion"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.AppendWorkEpisodeEvent(ctx, run.ID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventCompletionSubmitted, Actor: "agent",
		IdempotencyKey: "result:complete", Payload: payload,
	}); err != nil {
		t.Fatal(err)
	}
	return run, episode
}

func TestACompletedEpisodeLeavesARecallableOutcome(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishedEpisodeFixture(t, st, "COPS")

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Resolved", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	outcome, err := st.Intelligence.GetEpisodeOutcome(ctx, episode.ID)
	if err != nil {
		t.Fatalf("completed episode left no recall row: %v", err)
	}
	if outcome.TerminalState != string(core.EpisodeCompleted) {
		t.Fatalf("terminal state = %q", outcome.TerminalState)
	}
	// The fingerprint has to come from the real trigger text, not the 180-byte
	// truncated objective: three of the first four replay fixtures were cut
	// that way and became questions nothing could answer.
	if outcome.FingerprintSource != intelligencestore.FingerprintFromTrigger {
		t.Fatalf("fingerprint source = %q, want the real trigger text", outcome.FingerprintSource)
	}
	if !strings.Contains(outcome.SymptomFingerprint, "checkout") ||
		!strings.Contains(outcome.SymptomFingerprint, "payments") {
		t.Fatalf("symptom fingerprint = %q", outcome.SymptomFingerprint)
	}
	if len(outcome.Services) != 1 || outcome.Services[0] != "payments-gateway" {
		t.Fatalf("services = %v, want the evidence target reached through source_input", outcome.Services)
	}
	if !strings.Contains(outcome.RootCause, "connection pool exhaustion") {
		t.Fatalf("root cause = %q", outcome.RootCause)
	}
	if !strings.Contains(outcome.Remediation, "raised the pool ceiling") {
		t.Fatalf("remediation = %q", outcome.Remediation)
	}
	if !outcome.Verified || outcome.Verification == "" {
		t.Fatalf("verified = %t, verification = %q", outcome.Verified, outcome.Verification)
	}
}

// A cancelled episode concluded nothing. Projecting it would put a row with an
// empty root cause into the corpus and let recall spend a prompt slot on it.
func TestACancelledEpisodeIsNotRecalledAsAnOutcome(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishedEpisodeFixture(t, st, "COPS")

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCancelled, "cancelled", "Cancelled", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.GetEpisodeOutcome(ctx, episode.ID); err == nil {
		t.Fatal("a cancelled episode was projected as a recallable outcome")
	}
}

// A blocked episode still diagnosed something, so it is a recall source — but
// it is never labelled verified, because nothing confirmed the fix it did not
// make.
func TestABlockedEpisodeIsRecalledButNeverAsVerified(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishedEpisodeFixture(t, st, "COPS")

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeBlocked, "blocked", "Blocked on access", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	outcome, err := st.Intelligence.GetEpisodeOutcome(ctx, episode.ID)
	if err != nil {
		t.Fatalf("blocked episode left no recall row: %v", err)
	}
	if outcome.Verified {
		t.Fatal("a blocked episode was recalled as a verified remediation")
	}
}

// A reopened episode is working again, so what it concluded is a claim that
// has been withdrawn. Leaving the row would offer a live investigation to the
// next incident as a resolved one — the exact failure this feature exists to
// avoid making.
func TestAReopenedEpisodeStopsBeingRecalledAsResolved(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishedEpisodeFixture(t, st, "COPS")

	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Resolved", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.GetEpisodeOutcome(ctx, episode.ID); err != nil {
		t.Fatalf("completed episode left no recall row: %v", err)
	}
	reopen, err := episodepkg.Encode(episodepkg.Transition{
		State: core.EpisodeAccepted, Phase: "accepted", Status: "Accepted",
		NextAction: "Continue the operational lifecycle",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.AppendEpisodeEvent(ctx, episode.ID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventEpisodeReopened, Actor: "host",
		IdempotencyKey: "reopen:1", Payload: reopen,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.GetEpisodeOutcome(ctx, episode.ID); err == nil {
		t.Fatal("a reopened episode is still offered to triage as a resolved outcome")
	}
}

// A private-channel incident must never surface its symptom, cause or
// remediation in a room whose members were not in it. The membership row is
// the only thing that says a channel is public, so a missing row has to read
// as private — the same intersection conversation summaries already use.
func TestAPrivateChannelEpisodeNeverCrossesIntoAnotherRoom(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, episode := finishedEpisodeFixture(t, st, "CSECRET")
	if err := st.ReconcileSlackChannelMemberships(ctx, []SlackChannelMembershipObservation{
		{ChannelID: "CSECRET", ChannelName: "security-private", Private: true, Present: true},
		{ChannelID: "COPS", ChannelName: "ops", Private: false, Present: true},
	}, time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Resolved", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	elsewhere, err := st.Intelligence.ListSimilarEpisodeCandidates(ctx, "", "COPS", "other", recall.SimilarEpisodeAnchor{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, candidate := range elsewhere {
		if candidate.EpisodeID == episode.ID {
			t.Fatal("a private-channel episode was offered to another channel's triage")
		}
	}
	inRoom, err := st.Intelligence.ListSimilarEpisodeCandidates(ctx, "", "CSECRET", "other", recall.SimilarEpisodeAnchor{}, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inRoom) != 1 || inRoom[0].EpisodeID != episode.ID {
		t.Fatalf("the private channel could not recall its own history: %+v", inRoom)
	}
}
