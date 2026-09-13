package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	episodepkg "github.com/AndrewDryga/ryker/internal/episode"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// Accepting a request is a promise. The behaviour that makes this feel like a
// teammate rather than a bot is what happens when the promise cannot be kept:
// it says so, once, and then changes state rather than repeating itself.
func TestOverdueCommitmentIsSurfacedOnceThenBlocked(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)

	grace := cfg.Limits.EpisodeOverdueAfter.Duration
	// Not yet overdue: nothing should be said.
	clock.Advance(grace / 2)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 {
		t.Fatalf("surfaced before the grace window elapsed: %+v", slack.posts)
	}

	// Past the window: exactly one notice, naming the state and what to do.
	clock.Advance(grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("expected exactly one overdue notice, got %d: %+v", len(slack.posts), slack.posts)
	}
	notice := slack.posts[0].message
	if !strings.Contains(notice.Text, "not made progress") {
		t.Fatalf("notice does not state the problem: %+v", notice)
	}

	// Running maintenance again inside the same generation must not repeat it.
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("overdue notice repeated within one generation: %+v", slack.posts)
	}

	// Still nothing a full interval later: state changes instead of nagging.
	clock.Advance(2 * grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("a stalled episode kept posting instead of blocking: %+v", slack.posts)
	}
	stalled, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stalled.State != core.EpisodeBlocked {
		t.Fatalf("stalled episode state = %q, want blocked", stalled.State)
	}
}

// A restart must not turn one commitment into two notices.
func TestOverdueSurfacingSurvivesRestart(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)

	clock.Advance(cfg.Limits.EpisodeOverdueAfter.Duration * 2)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	// A fresh service over the same durable state, as after a restart.
	restarted := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	restarted.SetClock(clock.Now)
	restarted.identity = svc.identity
	restarted.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, restarted)

	if len(slack.posts) != 1 {
		t.Fatalf("restart produced a duplicate overdue notice: %+v", slack.posts)
	}
}

// "No progress" is what a stall looks like from outside, and it is not always
// what happened.
//
// A run can be wedged on a failure it has already written down. Reporting only
// that nothing moved sends an operator to look for a slow agent when the agent
// finished long ago — which is exactly how a completed engineering task came to
// sit behind an "Investigating" card for seventy-nine minutes. If the run knows
// why it is stuck, the person waiting on it should be told.
func TestAStalledEpisodeNamesWhatActuallyFailed(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)
	const cause = `result operation "goal-completed-traefik-oom": not found`
	if err := st.HoldOffAgentRunPoll(
		ctx, episode.AgentRunID, cause, clock.Now().Add(time.Second),
	); err != nil {
		t.Fatal(err)
	}

	grace := cfg.Limits.EpisodeOverdueAfter.Duration
	clock.Advance(2 * grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 1 {
		t.Fatalf("expected one overdue notice, got %d: %+v", len(slack.posts), slack.posts)
	}
	notice := slack.posts[0].message
	spoken := notice.Text + "\n" + strings.Join(notice.Sections, "\n")
	if !strings.Contains(spoken, "goal-completed-traefik-oom") {
		t.Fatalf("the notice never names why the run is stuck: %s", spoken)
	}

	// And the state an operator lands on afterwards carries it too, so the
	// answer survives the message scrolling away.
	clock.Advance(2 * grace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	stalled, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stalled.State != core.EpisodeBlocked {
		t.Fatalf("stalled episode state = %q, want blocked", stalled.State)
	}
	if !strings.Contains(stalled.NextAction, "goal-completed-traefik-oom") {
		t.Fatalf("blocked episode next action = %q, want it to name the cause", stalled.NextAction)
	}
}

// A run that is simply quiet must not be dressed up as a failure. Inventing a
// cause is its own kind of lying.
func TestAQuietRunIsNotGivenAFabricatedCause(t *testing.T) {
	if got := stalledEpisodeNextAction("Retry or close this work", ""); got != "Retry or close this work" {
		t.Fatalf("next action = %q, want it unchanged when the run recorded nothing", got)
	}
}

// The 19:57 shape, reproduced from the blitz instance on 2026-08-13.
//
// Episode episode_run_d9dc2097… ("VA1: prevent reload-driven Traefik OOM
// recurrence") reported progress at 19:22:44 and again at 19:24:44 — byte for
// byte, "Still working; implementing and validating the focused change" — and
// then said nothing else in prose. Underneath, the turn made 119 tool calls and
// 59 reasoning summaries through 20:06. commitment_overdue fired at 19:57:24,
// at an agent that was mid-investigation, because the watchdog read only the
// model's opinion of itself.
//
// Progress prose is written when the model chooses to write it. The activity
// stream is what it did. When they disagree the stream wins, and the alarm
// waits.
func TestOverdueDoesNotFireWhileTheTurnIsStillNarrating(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)
	grace := cfg.Limits.EpisodeOverdueAfter.Duration

	// Long past the progress deadline, and the turn is still working: one more
	// tool call lands at the moment the sweep runs.
	clock.Advance(2 * grace)
	narrateMoment(t, ctx, st, episode, 1, clock.Now())
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 0 {
		t.Fatalf("accused a turn that was still narrating: %+v", slack.posts)
	}
	if count := overdueEventCount(t, ctx, st, episode.AgentRunID); count != 0 {
		t.Fatalf("commitment_overdue events = %d, want none while the stream is live", count)
	}

	// Deferring is all that happened. The deadline is untouched, so the next
	// pass asks the same question rather than the episode being written off.
	deferred, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !deferred.ProgressDueAt.Equal(episode.ProgressDueAt) {
		t.Fatalf(
			"progress deadline moved from %s to %s; deferral must not rewrite lifecycle state",
			episode.ProgressDueAt, deferred.ProgressDueAt,
		)
	}
	if deferred.State != core.EpisodeWorking {
		t.Fatalf("episode state = %q, want it left working", deferred.State)
	}

	// The check is still armed. Silence the stream and the same episode is
	// surfaced, now saying how long the silence has been.
	clock.Advance(2 * overdueActivityGrace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 1 {
		t.Fatalf("expected one notice once the stream went quiet, got %+v", slack.posts)
	}
	spoken := spokenNotice(slack.posts[0].message)
	if !strings.Contains(spoken, "10 minutes") {
		t.Fatalf("the notice never says how long the turn has been quiet: %s", spoken)
	}
}

// Both clocks stopped, and the notice says so with its evidence.
//
// The confident word is earned here: nothing has been recorded since before the
// progress note was even due, so "stalled" is a description rather than a
// guess. The age of the last recorded action is stated because it is the fact
// that distinguishes this from the case above.
func TestOverdueFiresWhenTheActivityStreamStoppedToo(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)
	narrateMoment(t, ctx, st, episode, 1, clock.Now())

	clock.Advance(2 * cfg.Limits.EpisodeOverdueAfter.Duration)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 1 {
		t.Fatalf("expected one overdue notice, got %d: %+v", len(slack.posts), slack.posts)
	}
	spoken := spokenNotice(slack.posts[0].message)
	if !strings.Contains(spoken, "Stalled") {
		t.Fatalf("a genuinely stalled turn was not called one: %s", spoken)
	}
	if !strings.Contains(spoken, "nothing recorded for an hour") {
		t.Fatalf("the notice does not cite the age of the last recorded action: %s", spoken)
	}
	if count := overdueEventCount(t, ctx, st, episode.AgentRunID); count != 1 {
		t.Fatalf("commitment_overdue events = %d, want exactly one", count)
	}
}

// A turn that narrated nothing keeps the rule it had before there was a stream
// to read.
//
// Rows written before the column existed carry no activity, and so do turns
// that produce no narration. Missing evidence is not evidence of work, so the
// progress deadline decides alone and the notice says only what it knows —
// no invented "last activity" for an episode that never had one.
func TestOverdueStillFiresForATurnThatNarratedNothing(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)

	clock.Advance(2 * cfg.Limits.EpisodeOverdueAfter.Duration)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 1 {
		t.Fatalf("expected one overdue notice, got %d: %+v", len(slack.posts), slack.posts)
	}
	spoken := spokenNotice(slack.posts[0].message)
	if !strings.Contains(spoken, "No progress for") {
		t.Fatalf("the prose-only notice changed shape: %s", spoken)
	}
	for _, invented := range []string{"last activity", "nothing recorded", "Stalled"} {
		if strings.Contains(spoken, invented) {
			t.Fatalf("the notice claims %q about a turn that recorded nothing: %s", invented, spoken)
		}
	}
	if count := overdueEventCount(t, ctx, st, episode.AgentRunID); count != 1 {
		t.Fatalf("commitment_overdue events = %d, want exactly one", count)
	}
}

// The activity clock never accuses on its own.
//
// Between turns an episode records no activity at all, and a wait that is
// behaving exactly as promised would look stale to the stream while its
// progress deadline is still hours away. The progress deadline governs; the
// activity clock can only hold the alarm back.
func TestOverdueWaitsForTheProgressDeadlineWhileTheStreamIsQuiet(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)
	narrateMoment(t, ctx, st, episode, 1, clock.Now())
	if err := st.SetWorkEpisodePhase(
		ctx, episode.AgentRunID, core.EpisodeWaitingExternal, "waiting", "Waiting",
		"Waiting on the external run", clock.Now().Add(2*time.Hour),
	); err != nil {
		t.Fatal(err)
	}

	// Far past the activity grace, nowhere near the promised deadline.
	clock.Advance(time.Hour)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)

	if len(slack.posts) != 0 {
		t.Fatalf("a quiet stream accused work that is still inside its deadline: %+v", slack.posts)
	}
	if count := overdueEventCount(t, ctx, st, episode.AgentRunID); count != 0 {
		t.Fatalf("commitment_overdue events = %d, want none before the deadline", count)
	}

	// And the deadline still means what it always did.
	clock.Advance(2*time.Hour + cfg.Limits.EpisodeOverdueAfter.Duration)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("the progress deadline stopped firing entirely: %+v", slack.posts)
	}
}

// The deferral has no cap, and that is the design rather than an oversight.
//
// A turn that narrates for hours without writing prose is a working turn, and
// this watchdog exists to detect silence, not to enforce prose discipline. What
// stops an overlong turn is its own budget and timeout, which end it and say
// why. Making the alarm fire "eventually anyway" would reinstate the false
// accusation one interval later and teach operators to ignore it.
func TestOverdueKeepsDeferringWhileTheTurnKeepsNarrating(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	episode := acceptedEpisodeAwaitingProgress(t, ctx, svc, st, clock)
	clock.Advance(2 * cfg.Limits.EpisodeOverdueAfter.Duration)

	// An hour of tool calls after the last progress note, checked all the way
	// through: never surfaced, never blocked, never nagged.
	for moment := range 15 {
		clock.Advance(4 * time.Minute)
		narrateMoment(t, ctx, st, episode, int64(moment+1), clock.Now())
		svc.surfaceOverdueEpisodes(ctx, clock.Now())
		drainSlackDeliveries(t, ctx, svc)
		if len(slack.posts) != 0 {
			t.Fatalf("pass %d accused a turn that is still working: %+v", moment+1, slack.posts)
		}
	}
	working, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if working.State != core.EpisodeWorking {
		t.Fatalf("episode state = %q, want it still working", working.State)
	}

	// The moment the work actually stops, so does the deferral.
	clock.Advance(2 * overdueActivityGrace)
	svc.surfaceOverdueEpisodes(ctx, clock.Now())
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 {
		t.Fatalf("silence after a long turn was not surfaced: %+v", slack.posts)
	}
}

// narrateMoment records one narrated moment the way the Coop poll does, through
// the same store API — so a change that stops stamping the episode's freshness,
// or stops loading it back, fails the tests above rather than passing quietly.
func narrateMoment(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	episode core.WorkEpisode,
	sequence int64,
	at time.Time,
) {
	t.Helper()
	stored, err := st.Activity.Record(ctx, core.AgentActivity{
		EpisodeID: episode.ID, AgentRunID: episode.AgentRunID,
		Sequence: sequence, Kind: "tool.started", ToolKind: "execute",
		Title: "vm.query_range", OccurredAt: at,
	})
	if err != nil {
		t.Fatalf("record narrated moment %d: %v", sequence, err)
	}
	if !stored {
		t.Fatalf("narrated moment %d was not stored", sequence)
	}
}

func overdueEventCount(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	runID string,
) int {
	t.Helper()
	events, err := st.ListWorkEpisodeEvents(ctx, runID, 200)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, event := range events {
		if event.Kind == episodepkg.EventCommitmentOverdue {
			count++
		}
	}
	return count
}

// spokenNotice is everything the operator actually reads on one notice.
func spokenNotice(message slackui.Message) string {
	return message.Text + "\n" + strings.Join(message.Sections, "\n") + "\n" +
		strings.Join(message.Context, "\n")
}

func acceptedEpisodeAwaitingProgress(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	st *store.Store,
	clock *testClock,
) core.WorkEpisode {
	t.Helper()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_overdue", Mode: core.AgentRunTriage, ChannelID: "C123ABC",
		ThreadTS: "1700.001", ConversationKey: "channel:C123ABC",
		SourceKind: "watch", SourceID: "slack_overdue", UserID: "U123ABC",
		State: core.AgentRunRunning,
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeWorking, "working", "Working",
		"Investigating", clock.Now().Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	refreshed, err := st.GetWorkEpisode(ctx, episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	return refreshed
}
