package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/liveturn"
	"github.com/AndrewDryga/responder/internal/localstate"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// liveTurnFixture drives one engineering task to the point where a turn is
// running against Coop and the poll loop is what advances it.
//
// A task rather than an incident because the ledger is where a finished turn's
// totals end up, and only a task card has one.
func liveTurnFixture(t *testing.T) (
	context.Context, *store.Store, *Service, *fakeCoop, core.Incident, core.AgentRun,
) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-live-turn", "Prevent the reload-driven OOM", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_1", "fork-live-turn", 1); err != nil {
		t.Fatal(err)
	}
	if task, err = st.GetIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	run, created, err := svc.queueIncidentAgentRun(
		ctx, task, "initial", task.ID, "", "Make the focused change.",
	)
	if err != nil || !created {
		t.Fatalf("queue task run = %+v, %t, %v", run, created, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	running, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task, err = st.GetIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if task.ActiveTurnID == "" {
		t.Fatal("the fixture did not leave a turn running, so there is no window to test")
	}
	return ctx, st, svc, coopClient, task, running
}

// A three-line reasoning summary, a pack ref with the digest that makes it
// unreadable, and one moment of every kind the window must not show.
func seedNarratedTurn(
	t *testing.T,
	runCtx context.Context,
	svc *Service,
	coopClient *fakeCoop,
	run core.AgentRun,
) {
	t.Helper()
	coopClient.events = append(coopClient.events,
		activityEvent(1, run.CoopTurnID, "model.plan",
			`{"entries":[{"content":"Read the Traefik job"}]}`),
		activityEvent(2, run.CoopTurnID, "tool.started",
			`{"tool_call_id":"t1","title":"Read traefik.nomad.hcl","kind":"read"}`),
		activityEvent(3, run.CoopTurnID, "tool.completed",
			`{"tool_call_id":"t1","title":"Read traefik.nomad.hcl","kind":"read","status":"completed"}`),
		activityEvent(4, run.CoopTurnID, "model.thought",
			`{"text":"Planning PromQL queries for request rates.\nFirst the rate window.\nThen the reload counter."}`),
		activityEvent(5, run.CoopTurnID, "tool.started",
			`{"tool_call_id":"t2","title":"Emisar vm.query_range","kind":"execute",`+
				`"input":{"server":"emisar","tool":"run_action","arguments":`+
				`{"action_id":"vm.query_range","pack_ref":"victoriametrics@0.1.7/sha256:`+
				strings.Repeat("2c", 32)+`"}}}`),
		activityEvent(6, run.CoopTurnID, "permission.decided",
			`{"outcome":"allowed","option_id":"once"}`),
		activityEvent(7, run.CoopTurnID, "tool.started",
			`{"tool_call_id":"t3","title":"Edit traefik.nomad.hcl","kind":"edit"}`),
	)
	svc.pollAgentRuns(runCtx)
}

// The card is a window onto what the turn actually did.
//
// This is the whole of the grounding failure: a real 57-minute turn made 119
// tool calls and told the operator "Still working" twice, byte for byte,
// because the only account on the card was the model's summary of itself. The
// stream underneath it was specific, truthful, and already on disk. So the
// window shows the last few moments, the chips show what they add up to, and
// the recorded evidence claim states the one finding so far — none of it
// generated for the card, all of it recorded when it happened.
func TestRunningCardShowsTheRecordedTurnRatherThanItsSelfReport(t *testing.T) {
	ctx, st, svc, coopClient, task, run := liveTurnFixture(t)
	seedNarratedTurn(t, ctx, svc, coopClient, run)
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: task.ID, ChannelID: "COPS", SourceInput: run.ID,
		Claim: "Traefik reloads correlate with the RSS step", Observation: "vm.query_range",
		SourceType: "emisar", SourceName: "victoriametrics", Target: "traefik",
	}}); err != nil {
		t.Fatal(err)
	}
	task, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}

	// Three lines, newest first. The fourth would make the card taller every
	// turn, and the card is rewritten rather than extended.
	if len(card.Activity) != 3 {
		t.Fatalf("window = %d lines, want the newest three: %+v", len(card.Activity), card.Activity)
	}
	if card.Activity[0].Title != "Edit traefik.nomad.hcl" ||
		card.Activity[0].Kind != slackui.ActivityEdit {
		t.Fatalf("newest line is not the edit that just happened: %+v", card.Activity[0])
	}
	// The action, named from the payload rather than from the runtime's own
	// title. "mcp.emisar.run_action" told the operator which transport was
	// used and nothing about what was run.
	if card.Activity[1].Title != "emisar vm.query_range" ||
		card.Activity[1].Kind != slackui.ActivityTool {
		t.Fatalf("second line is not the tool call: %+v", card.Activity[1])
	}
	// And no pack ref. It used to be the target, on the reasoning that it was
	// the one durable identifier in the payload — but it identifies the pack
	// the action came from, which is the same for every call in a run and is
	// never the thing the operator is trying to read. This call passes no
	// arguments, so there is nothing more specific to say, and the line says
	// nothing rather than filling the column with the least useful fact in it.
	if card.Activity[1].Target != "" {
		t.Fatalf("the call named its pack instead of its arguments: %+v", card.Activity[1])
	}
	// Reasoning is a summary title and one line of it. The store holds up to
	// four kilobytes of thought and none of it is chain-of-thought for Slack.
	if card.Activity[2].Kind != slackui.ActivityThinking {
		t.Fatalf("the thought did not render as thinking: %+v", card.Activity[2])
	}
	if card.Activity[2].Title != "Planning PromQL queries for request rates." {
		t.Fatalf("the thought was not reduced to its first line: %q", card.Activity[2].Title)
	}
	// A completion repeats its own start; a plan revision and a permission
	// decision are about the run rather than about the work. These are the
	// exact labels coop.Activity.Label gives those kinds, so an excluded kind
	// that slipped through would be recognisable by name.
	for _, line := range card.Activity {
		switch line.Title {
		case "Plan updated", "Permission decided", "Activity not recorded":
			t.Fatalf("a non-displayable moment reached the window: %+v", line)
		}
	}

	// The counters describe the whole engineering task, not one turn that
	// resets whenever feedback starts another attempt. They live on the active
	// progress step instead of in detached per-turn chips.
	var active slackui.LedgerStep
	for _, step := range card.Ledger {
		if step.Current {
			active = step
			break
		}
	}
	if !strings.Contains(active.Detail, "3 tool calls") ||
		!strings.Contains(active.Detail, "last activity") {
		t.Fatalf("active progress does not carry cumulative activity: %+v", active)
	}
	if len(card.Chips) != 0 {
		t.Fatalf("engineering task still renders resetting per-turn chips: %+v", card.Chips)
	}
	if !hasSection(card, "Found so far") ||
		!hasSection(card, "Traefik reloads correlate with the RSS step") {
		t.Fatalf("the recorded claim never reached the card: %+v", card.Sections)
	}
	// Rule 3: the fallback carries state, not detail. A notification says what
	// the work is doing, not that the agent read a file.
	if strings.Contains(card.Text, "traefik.nomad.hcl") {
		t.Fatalf("activity leaked into the notification text: %q", card.Text)
	}
}

// When the turn stops, the window comes down and the ledger keeps the number.
//
// The work does not stop being true when the turn ends; it stops being news. A
// window left up would make a stopped card the most reassuring one on the
// screen, and the totals are the only place a reader later finds out that
// "Investigate" meant three tool calls rather than none.
func TestFinishedTurnMovesItsTotalsFromTheWindowToTheLedger(t *testing.T) {
	ctx, st, svc, coopClient, task, run := liveTurnFixture(t)
	seedNarratedTurn(t, ctx, svc, coopClient, run)
	coopClient.events = append(coopClient.events,
		activityEvent(8, run.CoopTurnID, "turn.completed", `{"stop_reason":"end_turn"}`),
	)
	svc.pollAgentRuns(ctx)

	task, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ActiveTurnID != "" {
		t.Fatalf("the fixture never finished the turn: %q", task.ActiveTurnID)
	}
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if len(card.Activity) != 0 {
		t.Fatalf("a stopped turn is still claiming to be working: %+v", card.Activity)
	}
	if len(card.Chips) != 0 {
		t.Fatalf("the live counters outlived the turn they counted: %+v", card.Chips)
	}
	var receipt string
	for _, step := range card.Ledger {
		if strings.Contains(step.Detail, "calls") {
			receipt = step.Detail
		}
	}
	if !strings.Contains(receipt, "3 calls") {
		t.Fatalf("the ledger did not absorb the turn's totals: %+v", card.Ledger)
	}
}

// A card with no agent behind it asks the activity store nothing.
//
// The window is the reason the card became expensive: it turned a card that
// was rewritten on state changes into one that is rewritten every fifteen
// seconds. That cost belongs only to work that has an agent. An incident that
// never opened a Coop session has no narrated interior, and neither the
// projection nor the bump may spend a query discovering that again.
func TestCardAsksNothingOfWorkWithNoTurnBehindIt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	card, err := svc.incidentCard(ctx, incident)
	if err != nil {
		t.Fatal(err)
	}
	if len(card.Activity) != 0 || len(card.Chips) != 0 {
		t.Fatalf("an idle card grew a live window: %+v / %+v", card.Activity, card.Chips)
	}
	turn, err := liveturn.Fetch(ctx, st.Activity, st.Intelligence, st.Goals, incident)
	if err != nil {
		t.Fatal(err)
	}
	if turn.Recorded() || turn.Active {
		t.Fatalf("the projection queried a card with no session: %+v", turn)
	}

	// And nothing narrated against a turn that is not running may mark the
	// card stale. The guard is in the statement rather than in the caller,
	// because a turn can end between reading the row and writing it — so the
	// store is asked directly, and it reports that it refused.
	bumped, err := st.TaskCards.BumpActiveTurn(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if bumped {
		t.Fatal("a card with no active turn accepted an activity refresh")
	}
	before := incident.CardVersion
	svc.refreshCardForActivity(ctx, core.AgentRun{ID: "run_x", IncidentID: incident.ID})
	after, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if after.CardVersion != before {
		t.Fatalf("a card with no active turn was refreshed: %d -> %d", before, after.CardVersion)
	}
}

// Narration is faster than Slack will accept edits, so it is throttled.
//
// Slack tolerates roughly one chat.update per second per channel and a turn
// narrates in bursts tighter than that. The throttle is what keeps a busy card
// from spending the channel's whole write budget — including the budget the
// replies queued behind it need — on a three-line strip nobody is watching
// change.
func TestActivityRefreshesTheCardAtMostOncePerThrottleWindow(t *testing.T) {
	ctx, st, svc, _, task, run := liveTurnFixture(t)
	// The throttle has recorded nothing yet, so the first refresh is allowed
	// whatever the clock says; everything after it is measured against this
	// one.
	clock := useTestClock(svc, st)

	version := func() int64 {
		t.Helper()
		current, err := st.GetIncident(ctx, task.ID)
		if err != nil {
			t.Fatal(err)
		}
		return current.CardVersion
	}
	start := version()
	svc.refreshCardForActivity(ctx, run)
	first := version()
	if first != start+1 {
		t.Fatalf("the first narrated moment did not refresh the card: %d -> %d", start, first)
	}

	// A second moment one second later. Real turns narrate this fast and
	// faster; the card has nothing new to say that a reader could use.
	clock.Advance(time.Second)
	svc.refreshCardForActivity(ctx, run)
	if held := version(); held != first {
		t.Fatalf("a moment inside the window refreshed the card again: %d -> %d", first, held)
	}

	// Once the window has passed the card is allowed to move again, because
	// by then the counters and the freshness chip have news in them.
	clock.Advance(localstate.CardActivityInterval)
	svc.refreshCardForActivity(ctx, run)
	if reopened := version(); reopened != first+1 {
		t.Fatalf("the card never reopened after the window: %d -> %d", first, reopened)
	}
}

func hasSection(message slackui.Message, needle string) bool {
	for _, section := range message.Sections {
		if strings.Contains(section, needle) {
			return true
		}
	}
	return false
}
