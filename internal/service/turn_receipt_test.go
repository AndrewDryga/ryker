package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
)

// receiptRow reads one label/value row off the receipt's strip.
//
// The rows are the receipt. renderedSlackMessage joins the prose fields and
// never reaches the ledger, so a test that read only that would pass on a
// receipt whose every number had gone missing.
func receiptRow(t *testing.T, message slackui.Message, label string) string {
	t.Helper()
	for _, step := range message.Ledger {
		if step.Label == label {
			return step.When
		}
	}
	t.Fatalf("no %q row on the receipt: %+v", label, message.Ledger)
	return ""
}

// seedFinishedTurn is one agent run that reached Coop, ran for four minutes and
// stopped, with three narrated moments recorded against its turn — one of them
// an edit, so the file count is a count of something rather than of everything.
//
// The queue call is the seam: it is the one public store method that writes a
// run's Coop turn, terminal state and clocks as given, and those four columns
// are exactly what the receipt reads back. The transport state column stays
// "running" because nothing here drives the lease/finalize dance that would
// move it — terminal_state, not state, is what says a turn has stopped.
func seedFinishedTurn(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	incident core.Incident,
) core.AgentRun {
	t.Helper()
	started := time.Now().UTC().Add(-4 * time.Minute)
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "control", SourceID: "receipt-seed",
		Repository: incident.Repository, Prompt: "investigate",
		SessionID: "ses_1", CoopTurnID: "coop_turn_receipt",
		State: core.AgentRunRunning, TerminalState: "completed",
		StartedAt: started, CompletedAt: started.Add(4 * time.Minute),
	})
	if err != nil || !created {
		t.Fatalf("seed a finished run = %+v, %t, %v", run, created, err)
	}
	for index, moment := range []core.AgentActivity{
		{Kind: "tool.started", ToolKind: "read", Title: "internal/service/input.go"},
		{Kind: "tool.started", ToolKind: "execute", Title: "go test ./internal/service"},
		{Kind: "tool.started", ToolKind: "edit", Title: "internal/service/input.go"},
	} {
		moment.EpisodeID = run.EpisodeID
		moment.AgentRunID = run.ID
		moment.SessionID = run.SessionID
		moment.TurnID = run.CoopTurnID
		moment.Sequence = int64(index + 1)
		moment.OccurredAt = started.Add(time.Duration(index+1) * time.Second)
		stored, recordErr := st.Activity.Record(ctx, moment)
		if recordErr != nil || !stored {
			t.Fatalf("record narrated moment %d = %t, %v", index+1, stored, recordErr)
		}
	}
	return run
}

// A receipt describes work that has already stopped, so a room where nothing
// has stopped yet gets told that in words.
//
// The alternative failure is the one worth preventing: a receipt built from an
// unfinished run would show whatever the ledger happened to hold at click time
// and present it as a total, which is a different number wearing this one's
// label — and the operator has no way to tell the two apart.
func TestTurnReceiptSaysSoWhenNoTurnHasFinishedYet(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-receipt-empty", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionTurnReceipt, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("receipt replies = %+v, want the one refusal", slackClient.ephemerals)
	}
	refusal := renderedSlackMessage(slackClient.ephemerals[0].message)
	if !strings.Contains(refusal, "No turn has finished here yet.") {
		t.Fatalf("receipt with nothing to report = %q", refusal)
	}
	// Nothing in the thread: the room did not need to be told that one person
	// clicked a button that had no answer.
	if len(slackClient.posts) != 0 {
		t.Fatalf("a receipt with nothing to report still posted: %+v", slackClient.posts)
	}

	// A turn that reached Coop but has not stopped is not an answer either,
	// and it is the case the terminal-state condition exists for: the run row
	// is there and it knows its turn id, so a receipt that asked only "did this
	// reach Coop" would publish a total that is still moving as if it were
	// final. A separate incident, because this one has now been clicked.
	runningStore, runningService, runningSlack, _, runningIncident := overflowFixture(t, ctx)
	if run, created, err := runningStore.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: runningIncident.ID,
		ChannelID: runningIncident.ChannelID, ThreadTS: runningIncident.RootTS,
		ConversationKey: "incident:" + runningIncident.ID,
		SourceKind:      "control", SourceID: "receipt-still-running",
		Repository: runningIncident.Repository, Prompt: "investigate",
		SessionID: "ses_1", CoopTurnID: "coop_turn_running",
		State: core.AgentRunRunning,
	}); err != nil || !created {
		t.Fatalf("seed a running run = %+v, %t, %v", run, created, err)
	}
	deliverInteraction(
		t, ctx, runningService, runningIncident, "env-receipt-running", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionTurnReceipt, Value: runningIncident.ID,
		})
	if err := runningService.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, runningService)

	if len(runningSlack.ephemerals) != 1 || !strings.Contains(
		renderedSlackMessage(runningSlack.ephemerals[0].message),
		"No turn has finished here yet.",
	) {
		t.Fatalf("receipt for a turn still running = %+v", runningSlack.ephemerals)
	}
	if len(runningSlack.posts) != 0 {
		t.Fatalf("a turn still running was given a receipt: %+v", runningSlack.posts)
	}
}

// The receipt is the answer that does not depend on the turn being a reliable
// narrator of its own work. A turn that says "still working" twice and makes
// nineteen tool calls has told the room nothing true; every number here is read
// back out of a record that outlives the turn.
//
// Each number is checked against a different source on purpose, because they
// come from three different places and a receipt that quietly took them all
// from one would still look right: the duration is the run row's own clocks,
// the tool and file counts are the activity ledger keyed by Coop's turn id, and
// the tokens are re-read from Coop at click time.
func TestTurnReceiptReportsTheFinishedTurnsRealCountsInThread(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	coopClient, ok := svc.coop.(*fakeCoop)
	if !ok {
		t.Fatalf("fixture Coop = %T", svc.coop)
	}
	run := seedFinishedTurn(t, ctx, st, incident)
	coopClient.turn = coop.Turn{
		ID: run.CoopTurnID, SessionID: run.SessionID, State: "completed",
		Usage: coop.Usage{
			InputTokens: 18204, CachedInputTokens: 4096, OutputTokens: 2140,
			ReasoningTokens: 6300, CostUSD: 0.4213, CostRecorded: true,
		},
	}

	deliverInteraction(t, ctx, svc, incident, "env-receipt", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionTurnReceipt, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("receipt posts = %+v, want the one answer", slackClient.posts)
	}
	posted := slackClient.posts[0]
	// Beside the card that was clicked, not in a private aside: what the last
	// turn cost is the room's business as much as the clicker's.
	if posted.channel != incident.ChannelID ||
		posted.thread != incident.ConversationThreadTS() {
		t.Fatalf("receipt went to %q/%q, want the card's thread %q/%q",
			posted.channel, posted.thread,
			incident.ChannelID, incident.ConversationThreadTS())
	}
	for label, want := range map[string]string{
		"Duration":      "4m",
		"Tool calls":    "3",
		"Files changed": "1",
		"Tokens in":     "18204",
		"Cached in":     "4096",
		"Tokens out":    "2140",
		"Reasoning":     "6300",
		"Cost":          "$0.4213",
	} {
		if value := receiptRow(t, posted.message, label); value != want {
			t.Fatalf("%s = %q, want %q; receipt = %+v",
				label, value, want, posted.message.Ledger)
		}
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("a read-only control was refused: %+v", slackClient.ephemerals)
	}
}

// A receipt is gated exactly as View diff is, because it is the same kind of
// control: read-only, incident-scoped, and quoting a record the room already
// holds. The refusal is compared against ActionChanges' rather than asserted by
// wording, so the two cannot drift into two different answers to the same
// question about who may act.
func TestTurnReceiptRefusesTheSameUsersAsViewDiff(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	// A finished turn exists, so a refusal here is about the person clicking
	// and not about there being nothing to report.
	seedFinishedTurn(t, ctx, st, incident)

	deliverInteraction(t, ctx, svc, incident, "env-changes-denied", "U456DEF",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	deliverInteraction(t, ctx, svc, incident, "env-receipt-denied", "U456DEF",
		&slack.BlockAction{ActionID: slackui.ActionTurnReceipt, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.ephemerals) != 2 {
		t.Fatalf("refusals = %+v", slackClient.ephemerals)
	}
	changesRefusal := renderedSlackMessage(slackClient.ephemerals[0].message)
	receiptRefusal := renderedSlackMessage(slackClient.ephemerals[1].message)
	if receiptRefusal != changesRefusal {
		t.Fatalf("receipt refusal = %q, View diff refusal = %q",
			receiptRefusal, changesRefusal)
	}
	if !strings.Contains(receiptRefusal, "operators") {
		t.Fatalf("refusal does not say who may act: %q", receiptRefusal)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("a refused control still posted the receipt: %+v", slackClient.posts)
	}
}

// The same click, arriving through the ⋯ rather than a row button, reaches the
// same handler — the receipt lives on the task card's menu, so the menu is the
// path most operators will take to it.
func TestTurnReceiptReachesItsHandlerThroughTheOverflowMenu(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	seedFinishedTurn(t, ctx, st, incident)

	deliverInteraction(t, ctx, svc, incident, "env-receipt-menu", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionOverflow,
			SelectedOption: slack.OptionBlockObject{
				Value: slackui.OverflowOptionValue(slackui.Action{
					ID: slackui.ActionTurnReceipt, Value: incident.ID,
				}),
			},
		})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("receipt from the ⋯ = %+v", slackClient.posts)
	}
	if value := receiptRow(t, slackClient.posts[0].message, "Tool calls"); value != "3" {
		t.Fatalf("receipt from the ⋯ counted %q tool calls, want 3", value)
	}
}
