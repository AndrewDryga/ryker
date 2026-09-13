package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/turndelta"
)

// correctedRetryPrompts drives one episode through a rejected turn and its
// corrected retry in the same Coop session, and returns both submitted prompts
// with the store.
//
// betweenTurns runs after the first turn has reached its terminal and before the
// retry is prepared, which is the only window where a mid-episode change can
// make the standing briefing stale. It is where the fallback cases spoil the one
// fact they are about, and it is handed the run in exactly the shape the lease
// path will find it so a case can also ask what the decision would be.
func correctedRetryPrompts(
	t *testing.T,
	betweenTurns func(*fakeCoop, *Service, *store.Store, core.AgentRun),
) (*fakeCoop, *Service, *store.Store, string) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	cfg.Slack.SummonChannels = []string{"CFOLLOW"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	const evidence = `{"claim":"checkout latency cause",` +
		`"observation":"p99 write latency is 40ms on va1-cass-3","relation":"supports",` +
		`"health_effect":"risk","source_type":"monitoring","source_name":"grafana",` +
		`"confidence":"high","freshness":"live query",` +
		`"dimensions":{"service":"checkout","environment":"production"}}`
	envelope := func(evidenceJSON string) string {
		return `{"action":"reply",
			"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":2},
			"reason":"direct question with evidence",
			"operations":[
				{"id":"ev-1","type":"record_evidence","evidence":` + evidenceJSON + `},
				{"id":"complete","type":"complete_episode","completion":{"message":"Checkout is slow because va1-cass-3 writes at 40ms p99.","completion":{"status":"decision_ready","summary":"cause identified"}}}]}`
	}
	coopClient := newFakeCoop()
	coopClient.session.Policy = "watch"
	coopClient.completeQueue = []string{
		envelope(evidence),
		envelope(`{"claim_id":"application.functional_behavior",` + evidence[1:]),
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack-delta-turn", EnvelopeID: "env-delta-turn",
		EventID: "event-delta-turn", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CFOLLOW", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@U999BOT> why is checkout slow?",
	}); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	// A correction is proved by the correction text the host recorded, not by
	// failure_count: correction rounds stopped spending failures on 2026-08-14,
	// so the counter that used to be the proxy now says nothing about whether
	// this turn was sent back.
	run, err := st.GetAgentRunBySource(ctx, "watch", "slack-delta-turn")
	if err != nil || run.State != core.AgentRunPending ||
		!strings.Contains(run.LastError, "the structured Slack response is invalid") {
		t.Fatalf("the first turn was not corrected, so this test no longer "+
			"exercises a follow-up into a live session: state = %s, last error = %q, %v",
			run.State, run.LastError, err)
	}
	if betweenTurns != nil {
		betweenTurns(coopClient, svc, st, run)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.submitPrompts) != 2 {
		t.Fatalf("expected a rejected turn and its retry, got %d prompts",
			len(coopClient.submitPrompts))
	}
	return coopClient, svc, st, run.EpisodeID
}

// A follow-up attempt into a session that already holds the previous briefing
// must send the new material, not the briefing again.
//
// Measured on blitz over 2026-08-14 and the first five hours of 2026-08-15: 201
// follow-up attempts resubmitted 30,258,462 bytes into sessions that already
// held the previous briefing, and 99.22% of those bytes were byte-identical to
// the message immediately before them. Prefix caching cannot dedupe repeated
// text inside a NEW message, so every one of those bytes was billed and
// prefilled again — roughly 9.0 million uncached input tokens and four hours of
// provider time a day, to restate what the conversation already contained.
func TestAFollowUpIntoALiveSessionSendsADeltaNotAnotherBriefing(t *testing.T) {
	coopClient, _, st, episodeID := correctedRetryPrompts(t, nil)
	briefing, followUp := coopClient.submitPrompts[0], coopClient.submitPrompts[1]

	if !strings.Contains(followUp, "<host-standing-briefing>") {
		t.Fatalf("the follow-up restated the whole briefing instead of leaning "+
			"on the one in the session:\n%.2000s", followUp)
	}
	// The static instruction block is what this change exists to stop resending.
	// The tool-transport rules are part of it and ride every full prompt, so
	// their absence is the cheapest proof the block was not repeated.
	if strings.Contains(followUp, "<host-tool-transport>") {
		t.Fatal("the delta turn still carries the static instruction block")
	}
	if !strings.Contains(followUp, "<host-structured-correction>") {
		t.Fatalf("the delta dropped the correction, which is the only reason "+
			"this turn exists:\n%s", followUp)
	}
	// The fixture's briefing is a fraction of a production one — 59 KB against a
	// measured 146 KB — because the harness has no channel history, memory or
	// repository map to carry. The bound is a ratio for that reason: what must
	// hold is that the follow-up stopped being a briefing, not that it hits a
	// byte count this harness cannot produce.
	if len(followUp)*3 >= len(briefing) {
		t.Fatalf("the delta is %d bytes against a %d byte briefing; it is not a "+
			"message, it is another briefing", len(followUp), len(briefing))
	}

	// The delta must still freeze a manifest, and that manifest has to name the
	// briefing it leans on. Without the link the recorded prompt reads as a turn
	// that was told almost nothing, and a fixture harvested from it would replay
	// a delta with no conversation behind it.
	latest, err := st.GetLatestContextManifest(context.Background(), episodeID)
	if err != nil {
		t.Fatalf("load the episode's latest context manifest: %v", err)
	}
	if latest.Version != 2 || latest.SubmittedPrompt != followUp {
		t.Fatalf("the delta turn did not record the prompt it sent: version = %d",
			latest.Version)
	}
	if latest.ParentManifestID == "" {
		t.Fatal("the delta manifest names no parent")
	}
	want := "delta_of:" + latest.ParentManifestID
	found := false
	for _, reference := range latest.References {
		if reference.SourceRef == want {
			found = true
			if reference.Visibility != "omitted" || reference.OmittedReason == "" {
				t.Fatalf("the delta record does not read as an omission: %+v", reference)
			}
		}
	}
	if !found {
		t.Fatalf("no reference records %q, so nothing on disk says this prompt "+
			"was a delta of an earlier briefing", want)
	}
	if !strings.Contains(strings.Join(latest.Omissions, "\n"), turndelta.ReasonStandingBriefingHeld) {
		t.Fatalf("the manifest does not say why the briefing was left out: %v",
			latest.Omissions)
	}
}

// The fallback is the feature's whole safety argument: any doubt sends the full
// briefing, and the full briefing is exactly what the host sent before this
// existed.
//
// A mid-episode policy change is the doubt the session itself cannot show. Coop
// reports an open session at the right cursor and nothing about it looks stale;
// the only thing that moved is what the host would now say. Left unchecked the
// model keeps answering to instructions that have been retired, and the host has
// no way to notice because the conversation looks healthy.
func TestAPolicyChangeMidEpisodeRestatesTheWholeBriefing(t *testing.T) {
	coopClient, _, st, episodeID := correctedRetryPrompts(t, func(
		client *fakeCoop, _ *Service, _ *store.Store, _ core.AgentRun,
	) {
		client.session.Policy = "watch-operator"
	})
	briefing, followUp := coopClient.submitPrompts[0], coopClient.submitPrompts[1]
	if strings.Contains(followUp, "<host-standing-briefing>") {
		t.Fatalf("a turn leaned on a briefing written under a policy that has "+
			"since been replaced:\n%.2000s", followUp)
	}
	if !strings.Contains(followUp, "<host-tool-transport>") {
		t.Fatal("the fallback dropped the static instruction block")
	}
	if len(followUp) < len(briefing)/2 {
		t.Fatalf("the fallback is %d bytes against a %d byte first briefing; it "+
			"is no longer the self-contained prompt the fallback promises",
			len(followUp), len(briefing))
	}
	latest, err := st.GetLatestContextManifest(context.Background(), episodeID)
	if err != nil {
		t.Fatal(err)
	}
	for _, reference := range latest.References {
		if strings.HasPrefix(reference.SourceRef, "delta_of:") {
			t.Fatalf("a full briefing recorded itself as a delta: %+v", reference)
		}
	}
}

// A retry that moved up the model ladder is briefed again.
//
// A repeated correction escalates the retry to a higher rung of the session
// policy's target ladder, and a rung is a DIFFERENT model — on blitz on
// 2026-08-16, gpt-5.6-terra to Claude Opus. The session still held the standing
// briefing and the delta turn therefore told the new model that a briefing it
// had never read "still applies in full". Its first two answers were `unknown
// field "completion_contract"` and `unknown field "record_evidence"`: two
// envelope rounds, about $0.85 and four minutes, spent learning a result
// schema the host had on hand and could have restated. It answered correctly
// only once a fresh attempt handed it the full 136 KB briefing.
//
// The control matters as much as the case. The same run, one line earlier, is
// delta-eligible on every other clause, so what this proves is the rung and not
// some other doubt tripping first.
func TestRungEscalationRebriefsTheContract(t *testing.T) {
	ctx := context.Background()
	var beforeEscalation, afterEscalation turndelta.Decision
	coopClient, _, st, episodeID := correctedRetryPrompts(t, func(
		client *fakeCoop, svc *Service, st *store.Store, run core.AgentRun,
	) {
		decide := func(run core.AgentRun) turndelta.Decision {
			t.Helper()
			state, err := decodeWatchRunContext(run)
			if err != nil {
				t.Fatal(err)
			}
			// The projection sits where this run left it, which is what makes
			// the run delta-eligible in the first place.
			return svc.standingBriefing(
				ctx, run, client.session,
				run.SessionGeneration, run.CoopEventSequence, state,
			)
		}
		beforeEscalation = decide(run)
		if err := st.SetAgentRunTargetFloor(ctx, run.ID, 1, 0); err != nil {
			t.Fatal(err)
		}
		escalated, err := st.GetAgentRun(ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		afterEscalation = decide(escalated)
	})

	if !beforeEscalation.Delta {
		t.Fatalf("the control turn was not delta-eligible, so this test proves "+
			"nothing about the rung: %s", beforeEscalation.Reason)
	}
	if afterEscalation.Delta {
		t.Fatalf("a retry escalated above its briefing's rung leaned on that "+
			"briefing: %s", afterEscalation.Reason)
	}
	if afterEscalation.Reason != turndelta.ReasonRungEscalated {
		t.Fatalf("reason = %q, want %q", afterEscalation.Reason,
			turndelta.ReasonRungEscalated)
	}

	// And the turn that actually went out carries it. The static instruction
	// block rides every full briefing and no delta, so its presence is the
	// cheapest proof the new model was taught the contract again.
	followUp := coopClient.submitPrompts[1]
	if strings.Contains(followUp, "<host-standing-briefing>") ||
		!strings.Contains(followUp, "<host-tool-transport>") {
		t.Fatalf("the escalated retry went out as a delta:\n%.2000s", followUp)
	}
	latest, err := st.GetLatestContextManifest(ctx, episodeID)
	if err != nil {
		t.Fatal(err)
	}
	// The rung has to reach the manifest, or the NEXT retry compares itself
	// against a briefing that claims it went out on the ordinary rung and
	// re-briefs a model that has just been briefed.
	if latest.TargetFloor != 1 {
		t.Fatalf("the escalated briefing recorded rung %d, so the next turn "+
			"cannot tell it was delivered on a higher one", latest.TargetFloor)
	}
}
