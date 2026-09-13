package service

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store"
)

// pastGrafanaAlert runs an episode whose trigger is the Slack card Grafana
// posts, to completion, so the recall row is the one the production
// transaction writes.
func pastGrafanaAlert(t *testing.T, st *store.Store, channelID string) string {
	t.Helper()
	ctx := context.Background()
	input := core.SlackInput{
		ID: "slack_alert_past", EnvelopeID: "env_alert_past", EventID: "event_alert_past",
		Kind: "bot_message", TeamID: "T123ABC", ChannelID: channelID, MessageTS: "1700.5",
		UserID: "B0GRAFANA",
		Text: "[FIRING:1] va1-nomad-oom-risk (traefik)\nalertname: va1-nomad-oom-risk\n" +
			"<https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view?orgId=1&from=now-6h|View alert>",
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: channelID,
		ConversationKey: watchConversationKey(input),
		SourceKind:      "watch", SourceID: input.ID, Prompt: "Investigate " + input.ID,
	})
	if err != nil || !created {
		t.Fatalf("queue past alert: created=%t err=%v", created, err)
	}
	if _, err := st.AppendWorkEpisodeEvent(ctx, run.ID, core.WorkEpisodeEvent{
		Kind: "completion_submitted", Actor: "agent", IdempotencyKey: "result:complete",
		Payload: []byte(`{"id":"complete","type":"complete_episode","completion":{
		  "alert_assessment":{"cause":"website version 73 rollout churn triggered reload-correlated Traefik memory growth",
		    "immediate_action":"raised the allocation memory cap",
		    "verification":"RSS held below the cap for an hour after the rollout settled"}}}`),
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
	return episode.ID
}

// The whole point of the twelve-point alert-group signal is that it does not
// depend on wording, and for every Slack-delivered alert it did nothing at all:
// Grafana's Slack card carries no groupKey, so both sides of the comparison
// were empty strings and the match could only ever be made on vocabulary.
//
// On 2026-08-16 that is what happened to va1-nomad-oom-risk on blitz. It had
// been investigated on 2026-08-04 and three times on 2026-08-13 in the same
// channel; the turn that answered it recalled a host-OOM episode and two
// disk-IO episodes instead, on shared words, and lost the mechanism its own
// earlier investigation had found.
//
// The identity is the correlation key the host already derives for these
// messages, on both sides. This test holds them together: the projection writes
// it and recall asks with it, and the reason the episode is selected has to be
// the identity rather than the words.
func TestTheSameSlackAlertIsRecalledByItsIdentityNotItsWording(t *testing.T) {
	svc, st, ctx := recalledEpisodeService(t)
	past := pastGrafanaAlert(t, st, "COPS")
	// The same alert firing again days later: a different counter, a different
	// dashboard range on the link, a resolution notice in between. Only the
	// stable /alerting/<uid>/view link is the same.
	input := core.SlackInput{
		ID: "slack_alert_now", TeamID: svc.cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1800.5", Kind: "bot_message", UserID: "B0GRAFANA",
		Text: "[FIRING:2] va1-nomad-oom-risk (traefik)\nalertname: va1-nomad-oom-risk\n" +
			"<https://grafana.example/alerting/grafana/va1-nomad-oom-risk/view?orgId=1&from=now-24h|View alert>",
	}

	assembled, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: "COPS", Repository: "blitz-infra", TargetInput: &input,
		Effort: core.EffortOperationalAssessment,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(assembled.SimilarPastEpisodes) != 1 ||
		assembled.SimilarPastEpisodes[0].EpisodeID != past {
		t.Fatalf("recalled %+v, want the earlier firing of the same alert",
			assembled.SimilarPastEpisodes)
	}
	recalled := assembled.SimilarPastEpisodes[0]
	if !slices.Contains(recalled.MatchedOn, "same alert group key") {
		t.Fatalf(
			"matched on %v, want the alert's own identity rather than its wording",
			recalled.MatchedOn,
		)
	}
	// And the mechanism survives, which is what five re-derivations of "raise
	// the cap" threw away.
	if recalled.RootCause == "" || !recalled.Verified {
		t.Fatalf("recalled entry lost the earlier finding: %+v", recalled)
	}
}
