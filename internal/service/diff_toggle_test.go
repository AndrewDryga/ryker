package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/slack-go/slack"
)

// forkWithChanges gives the fixture a fork that actually holds a change, which
// is what puts the diff control on the card at all — and a patch small enough
// to arrive in one page, which is what lets the stat be computed honestly.
const forkPatch = `diff --git a/traefik.nomad.hcl b/traefik.nomad.hcl
--- a/traefik.nomad.hcl
+++ b/traefik.nomad.hcl
@@ -1,3 +1,3 @@
-  memory = 4096
+  memory = 8192
 }
`

func forkWithChanges(t *testing.T, svc *Service) {
	t.Helper()
	fake, ok := svc.coop.(*fakeCoop)
	if !ok {
		t.Fatalf("the fixture's Coop is %T", svc.coop)
	}
	fake.changes = coop.Changes{
		BaseCommit: "aaaa111", ForkHead: "bbbb222",
		Committed:  []coop.Change{{Path: "traefik.nomad.hcl", Status: "M"}},
		Patch:      []byte(forkPatch),
		PatchBytes: int64(len(forkPatch)),
	}
}

// diffButton reads the label the card is offering for its diff control, which
// is the whole visible half of this feature.
func diffButton(t *testing.T, message slackui.Message) slackui.Action {
	t.Helper()
	for _, action := range message.Actions {
		if action.ID == slackui.ActionChanges {
			return action
		}
	}
	t.Fatalf("the card has no diff control: %+v", message.Actions)
	return slackui.Action{}
}

// View diff opens one and becomes Hide diff; pressing it again puts it away.
//
// It used to be one-way. Every press posted another copy of the diff into the
// thread and nothing took one down, so a task checked four times carried four
// diffs of the same fork, three of them describing a fork that had moved on.
func TestViewDiffOpensADiffAndThenHidesIt(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)
	forkWithChanges(t, svc)

	// Nothing open yet, so the card offers to open one.
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if label := diffButton(t, card).Label; label != "View diff" {
		t.Fatalf("a task with no diff open offers %q", label)
	}

	deliverInteraction(t, ctx, svc, task, "env-view-diff", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("View diff posted %d messages: %+v", len(slackClient.posts), slackClient.posts)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	diffTS := task.ChangesMessageTS
	if diffTS == "" {
		t.Fatal("the delivered diff was not tracked, so the button can never flip")
	}
	// The card now offers the way back, on the same control.
	card, err = svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	hide := diffButton(t, card)
	if hide.Label != "Hide diff" || hide.Value != task.ID {
		t.Fatalf("an open diff leaves the card offering %+v", hide)
	}

	// The same button again. It deletes rather than posting.
	deliverInteraction(t, ctx, svc, task, "env-hide-diff", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.deletes) != 1 || slackClient.deletes[0].timestamp != diffTS {
		t.Fatalf("Hide diff deleted %+v, want the diff at %q", slackClient.deletes, diffTS)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("Hide diff posted another diff: %+v", slackClient.posts)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ChangesMessageTS != "" {
		t.Fatalf("the closed diff is still tracked as %q", task.ChangesMessageTS)
	}
	if label := diffButton(t, mustCard(t, ctx, svc, task)).Label; label != "View diff" {
		t.Fatalf("after hiding, the card offers %q", label)
	}
}

// Close diff, on the diff message itself, is the same act as Hide diff on the
// card — and it deletes the message it is sitting on.
func TestCloseDiffOnTheDiffMessageClearsTheCard(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)
	forkWithChanges(t, svc)

	deliverInteraction(t, ctx, svc, task, "env-open-for-close", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	opened, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	diffTS := opened.ChangesMessageTS
	if diffTS == "" {
		t.Fatal("the fixture never opened a diff")
	}

	// The press arrives from the diff message, which is where the button is.
	deliverInteractionAt(t, ctx, svc, task, diffTS, "env-close-diff", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionCloseDiff, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.deletes) != 1 || slackClient.deletes[0].timestamp != diffTS {
		t.Fatalf("Close diff deleted %+v, want the diff at %q", slackClient.deletes, diffTS)
	}
	closed, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if closed.ChangesMessageTS != "" {
		t.Fatalf("Close diff left the diff tracked as %q", closed.ChangesMessageTS)
	}
}

// A delete that fails still clears the tracking.
//
// The alternative strands the card: it goes on saying "Hide diff" about a
// message that is not there, and its only control retries the same failing
// delete forever. Forgetting a message that may still exist costs one stale
// diff in a thread, which the operator can remove themselves; the other way
// round costs them the button.
func TestAFailedDeleteStillForgetsTheDiff(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)
	forkWithChanges(t, svc)

	deliverInteraction(t, ctx, svc, task, "env-open-for-failure", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	task, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ChangesMessageTS == "" {
		t.Fatal("the fixture never opened a diff")
	}

	slackClient.deleteErr = errors.New("cant_delete_message")
	deliverInteraction(t, ctx, svc, task, "env-hide-fails", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("a failed delete failed the whole press: %v", err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.deletes) != 1 {
		t.Fatalf("the delete was not attempted: %+v", slackClient.deletes)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ChangesMessageTS != "" {
		t.Fatalf("a failed delete left the diff tracked as %q; the card is stuck",
			task.ChangesMessageTS)
	}
	if label := diffButton(t, mustCard(t, ctx, svc, task)).Label; label != "View diff" {
		t.Fatalf("after a failed delete the card offers %q", label)
	}
}

// The stat is on the card, from the same fetch the diff came from, so the
// operator can see how big the change is without opening it.
func TestTheCardStatesWhatTheChangeAmountsTo(t *testing.T) {
	ctx := context.Background()
	st, svc, _, task := taskOverflowFixture(t, ctx, longAsk)
	forkWithChanges(t, svc)

	deliverInteraction(t, ctx, svc, task, "env-diff-stat", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	task, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.ChangesStat == "" {
		t.Fatal("a whole patch was fetched and nothing was counted")
	}
	if !strings.Contains(task.ChangesStat, "file") || !strings.Contains(task.ChangesStat, "+") {
		t.Fatalf("stat = %q, want files and lines", task.ChangesStat)
	}
	card := mustCard(t, ctx, svc, task)
	for _, step := range card.Ledger {
		if strings.Contains(step.Detail, task.ChangesStat) {
			return
		}
	}
	t.Fatalf("the stat reached the incident but not the ledger: %+v", card.Ledger)
}

func mustCard(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	incident core.Incident,
) slackui.Message {
	t.Helper()
	card, err := svc.incidentCard(ctx, incident)
	if err != nil {
		t.Fatal(err)
	}
	return card
}
