package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/operationalkey"
	"github.com/AndrewDryga/ryker/internal/recall"
)

// seedRecallableOutcomes writes n finished episodes straight to the three
// tables the projection touches.
//
// Raw rather than driven through the lifecycle because the point of the test is
// the SHAPE of the candidate window, and a hundred real episodes would spend a
// second of fsyncs proving something the projection tests already prove.
func seedRecallableOutcomes(
	t *testing.T,
	st *Store,
	channelID string,
	count int,
	terminalAt time.Time,
) {
	t.Helper()
	tx, err := st.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	for index := range count {
		id := fmt.Sprintf("%s-%03d", channelID, index)
		stamp := terminalAt.Add(time.Duration(index) * time.Minute).
			UTC().Format(core.TimestampFormat)
		if _, err := tx.Exec(`
			INSERT INTO agent_runs (id, mode, conversation_key, source_kind, source_id,
			  idempotency_key, state, next_attempt_at, created_at, updated_at)
			VALUES (?, 'triage', ?, 'watch', ?, ?, 'completed', ?, ?, ?)`,
			"run-"+id, "channel:"+channelID, "input-"+id, "key-"+id, stamp, stamp, stamp,
		); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(`
			INSERT INTO work_episodes (id, agent_run_id, effort, authority,
			  objective, channel_id, lifecycle_state, created_at, updated_at)
			VALUES (?, ?, 'operational_assessment', 'read_only',
			  'disk write latency is elevated on the log shipper', ?, 'completed', ?, ?)`,
			"ep-"+id, "run-"+id, channelID, stamp, stamp,
		); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(`
			INSERT INTO episode_outcomes (episode_id, channel_id, terminal_state,
			  terminal_at, objective, symptom_fingerprint, services_json, created_at)
			VALUES (?, ?, 'completed', ?, 'disk write latency', 'disk latency shipper',
			  '["log-shipper"]', ?)`,
			"ep-"+id, channelID, stamp, stamp,
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func anchoredOutcome(
	t *testing.T,
	st *Store,
	channelID string,
	episodeID string,
	alertGroupKey string,
	services string,
	terminalAt time.Time,
) {
	t.Helper()
	stamp := terminalAt.UTC().Format(core.TimestampFormat)
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO agent_runs (id, mode, conversation_key, source_kind, source_id,
		    idempotency_key, state, next_attempt_at, created_at, updated_at)
		  VALUES (?, 'triage', ?, 'watch', ?, ?, 'completed', ?, ?, ?)`,
			[]any{"run-" + episodeID, "channel:" + channelID, "input-" + episodeID,
				"key-" + episodeID, stamp, stamp, stamp}},
		{`INSERT INTO work_episodes (id, agent_run_id, effort, authority,
		    objective, channel_id, lifecycle_state, created_at, updated_at)
		  VALUES (?, ?, 'operational_assessment', 'read_only',
		    'va1 nomad OOM risk on traefik', ?, 'completed', ?, ?)`,
			[]any{episodeID, "run-" + episodeID, channelID, stamp, stamp}},
		{`INSERT INTO episode_outcomes (episode_id, channel_id, terminal_state,
		    terminal_at, objective, symptom_fingerprint, alert_group_key,
		    services_json, root_cause, created_at)
		  VALUES (?, ?, 'completed', ?, 'va1 nomad OOM risk', 'nomad oom risk va1', ?, ?,
		    'website version 73 rollout churn triggered reload-correlated memory growth', ?)`,
			[]any{episodeID, channelID, stamp, alertGroupKey, services, stamp}},
	}
	for _, statement := range statements {
		if _, err := st.db.Exec(statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}
}

// Recency is a budget, not a filter, and for three days it silently acted as
// one. Blitz finishes about seventy episodes a day, so the hundred most recent
// outcomes reached back roughly thirty-six hours: when va1-nomad-oom-risk fired
// on 2026-08-16 the investigations of the SAME alert from 2026-08-13 — same
// channel, one of them holding a completed and committed fix — were not
// candidates at all. Five investigations then re-derived "raise the cap" at
// about $15 each and lost both the mechanism and the fix that already existed.
//
// So the same alert is looked up by its identity before anything is looked up
// by its age, and this test buries it under more unrelated outcomes than the
// window can hold.
func TestSameAlertOutsideTheRecencyWindowIsStillACandidate(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const anchorKey = "alert-link:https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view"
	anchoredOutcome(
		t, st, "COPS", "ep-oom-risk", anchorKey, `["traefik"]`,
		time.Date(2026, 8, 13, 9, 0, 0, 0, time.UTC),
	)
	seedRecallableOutcomes(
		t, st, "COPS", 101, time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC),
	)

	recent, err := st.Intelligence.ListSimilarEpisodeCandidates(
		ctx, "", "COPS", "other", recall.SimilarEpisodeAnchor{}, recall.SimilarEpisodeCandidates,
	)
	if err != nil {
		t.Fatal(err)
	}
	if candidatesInclude(recent, "ep-oom-risk") {
		t.Fatal("the fixture does not bury the anchored outcome; the window still reaches it")
	}

	byAlert, err := st.Intelligence.ListSimilarEpisodeCandidates(
		ctx, "", "COPS", "other",
		recall.SimilarEpisodeAnchor{AlertGroupKey: anchorKey},
		recall.SimilarEpisodeCandidates,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !candidatesInclude(byAlert, "ep-oom-risk") {
		t.Fatalf(
			"the same alert three days old was not a candidate under %d newer outcomes",
			len(byAlert),
		)
	}

	byService, err := st.Intelligence.ListSimilarEpisodeCandidates(
		ctx, "", "COPS", "other",
		recall.SimilarEpisodeAnchor{Services: []string{"Traefik"}},
		recall.SimilarEpisodeCandidates,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !candidatesInclude(byService, "ep-oom-risk") {
		t.Fatal("an outcome naming the same implicated service was not a candidate")
	}
	// The recency window is still there underneath both anchors: recall ranks
	// inside what this returns, so an anchor that replaced the window would
	// answer every unanchored question with silence.
	if len(byAlert) <= 1 {
		t.Fatalf("the anchor replaced the recency window instead of preceding it: %d", len(byAlert))
	}
}

// The visibility rule is the one thing a wider window may not widen. Adding
// two more passes over episode_outcomes added two more chances to forget the
// membership intersection, so each pass is asked the question directly.
func TestAnAnchoredCandidateStillObeysChannelVisibility(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const anchorKey = "alert-link:https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view"
	anchoredOutcome(
		t, st, "CSECRET", "ep-private-oom", anchorKey, `["traefik"]`,
		time.Date(2026, 8, 13, 9, 0, 0, 0, time.UTC),
	)
	if err := st.ReconcileSlackChannelMemberships(ctx, []SlackChannelMembershipObservation{
		{ChannelID: "CSECRET", ChannelName: "security-private", Private: true, Present: true},
		{ChannelID: "COPS", ChannelName: "ops", Private: false, Present: true},
	}, time.Time{}); err != nil {
		t.Fatal(err)
	}

	for _, anchor := range []recall.SimilarEpisodeAnchor{
		{AlertGroupKey: anchorKey},
		{Services: []string{"traefik"}},
	} {
		elsewhere, err := st.Intelligence.ListSimilarEpisodeCandidates(
			ctx, "", "COPS", "other", anchor, recall.SimilarEpisodeCandidates,
		)
		if err != nil {
			t.Fatal(err)
		}
		if candidatesInclude(elsewhere, "ep-private-oom") {
			t.Fatalf("anchor %+v carried a private channel's episode into another room", anchor)
		}
	}
}

func candidatesInclude(candidates []core.EpisodeOutcome, episodeID string) bool {
	for _, candidate := range candidates {
		if candidate.EpisodeID == episodeID {
			return true
		}
	}
	return false
}

// grafanaCard is the Slack message Grafana's integration posts: a headline, a
// few labels, and the stable alert link that is the only part of it that
// survives every re-fire.
func grafanaCard() core.SlackInput {
	return core.SlackInput{
		ID: "slack_grafana", EnvelopeID: "env_grafana", EventID: "event_grafana",
		Kind: "bot_message", TeamID: "T1", ChannelID: "COPS", MessageTS: "1755.1",
		UserID: "B0GRAFANA",
		Text: "[FIRING:1] va1-nomad-oom-risk (traefik)\n" +
			"alertname: va1-nomad-oom-risk\nservice: traefik\n" +
			"<https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view?orgId=1|View alert>",
	}
}

// grafanaCardEpisode runs a real episode whose trigger is that card, so the
// projection under test reads what production reads.
func grafanaCardEpisode(t *testing.T, st *Store, channelID string) (core.SlackInput, string) {
	t.Helper()
	ctx := context.Background()
	input := grafanaCard()
	input.ChannelID = channelID
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: channelID,
		ConversationKey: "operation:" + channelID + ":" + operationalkey.Key(input),
		SourceKind:      "watch", SourceID: input.ID, Prompt: "Investigate " + input.ID,
	})
	if err != nil || !created {
		t.Fatalf("queue alert episode: created=%t err=%v", created, err)
	}
	if _, err := st.AppendWorkEpisodeEvent(ctx, run.ID, core.WorkEpisodeEvent{
		Kind: "completion_submitted", Actor: "agent", IdempotencyKey: "result:complete",
		Payload: []byte(`{"id":"complete","type":"complete_episode","completion":{
		  "alert_assessment":{"cause":"website version 73 rollout churn triggered reload-correlated Traefik memory growth",
		    "immediate_action":"raised the memory cap"}}}`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Resolved", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	return input, episode.ID
}

// Every episode_outcomes row on blitz for a Slack-delivered Grafana alert had
// an empty alert_group_key, because only an escalated webhook incident ever set
// one — the Slack card carries no groupKey. So the strongest signal recall has,
// worth more than every vocabulary match combined, could never fire for exactly
// the alerts that wake people up, and va1-nomad-oom-risk was investigated five
// times as if it had never been seen.
//
// The identity was already being derived on every one of those turns, for burst
// coalescing. This test holds the projection to the same function, because a
// write side that derived it differently from the read side would be
// indistinguishable from having no history at all.
func TestSlackAlertEpisodeOutcomeCarriesTheAlertIdentity(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input, episodeID := grafanaCardEpisode(t, st, "COPS")

	outcome, err := st.Intelligence.GetEpisodeOutcome(ctx, episodeID)
	if err != nil {
		t.Fatal(err)
	}
	want := operationalkey.Key(input)
	if want == "" {
		t.Fatal("the fixture card has no correlation key; it cannot prove anything")
	}
	if outcome.AlertGroupKey == "" {
		t.Fatal("a Slack-delivered Grafana alert left an outcome with no alert identity")
	}
	if outcome.AlertGroupKey != want {
		t.Fatalf("alert identity = %q, want the correlation key %q", outcome.AlertGroupKey, want)
	}
	// The stable alert link is what survives a re-fire; an identity built from
	// the dashboard range would be a new one every time the alert fired.
	if !strings.Contains(outcome.AlertGroupKey, "/alerting/grafana/va1-nomad-oom-risk/view") {
		t.Fatalf("alert identity = %q, want the stable alert link", outcome.AlertGroupKey)
	}
	// And the read side finds it: the same alert, however old, is a candidate.
	candidates, err := st.Intelligence.ListSimilarEpisodeCandidates(
		ctx, "", "COPS", "other",
		recall.SimilarEpisodeAnchor{AlertGroupKey: want}, recall.SimilarEpisodeCandidates,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !candidatesInclude(candidates, episodeID) {
		t.Fatal("the projected alert identity did not match the anchor the read side asks with")
	}
}
