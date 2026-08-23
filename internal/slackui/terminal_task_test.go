package slackui

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

// renderedActionLabels reads the buttons a surface actually ships, because the
// duplicate way out was added during rendering rather than by the caller.
func renderedActionLabels(t *testing.T, message Message) []string {
	t.Helper()
	labels := []string{}
	for _, block := range message.Blocks() {
		actions, ok := block.(*slack.ActionBlock)
		if !ok {
			continue
		}
		for _, element := range actions.Elements.ElementSet {
			if button, ok := element.(*slack.ButtonBlockElement); ok && button.Text != nil {
				labels = append(labels, button.Text.Text)
			}
		}
	}
	return labels
}

func mergedTask() core.Incident {
	return core.Incident{
		ID: "inc_1234567890abcdef", Route: "manual", SourceIncidentID: "task:EvTask",
		WorkKind: core.WorkKindEngineeringTask, WorkScope: core.WorkScopeThread,
		OriginChannelID: "COPS", OriginThreadTS: "1700.0",
		Title: "Audit infrastructure packs", Status: core.IncidentActive,
		Workflow: core.WorkflowParked, RootTS: "1700.1", CoopSessionID: "ses_1",
		CoopForkName: "remote-task", CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
}

func mergedFollowup() core.PublicationFollowup {
	return core.PublicationFollowup{PRState: "merged", MergeSHA: "ecfc5413886b"}
}

func mergedPublication() core.Publication {
	return core.Publication{
		State: core.PublicationPublished, PRNumber: 6,
		PRURL: "https://github.test/o/r/pull/6",
	}
}

// A merged card offered "Open PR" beside "Close task", which reads as
// unfinished business: the button an eye lands on said nothing about the fact
// that this work had already landed.
func TestMergedTaskCardSaysThePullRequestIsMerged(t *testing.T) {
	card := IncidentCardWithPublication(
		mergedTask(), "Emisar", nil, true, true, mergedPublication(),
		mergedFollowup(), core.PublicationLifecycleEvent{},
	)

	index := slices.IndexFunc(card.Actions, func(action Action) bool {
		return action.ID == ActionViewPR
	})
	if index < 0 {
		t.Fatalf("merged task card has no PR control: %+v", card.Actions)
	}
	if card.Actions[index].Label != "View merged PR" {
		t.Errorf("PR control says %q on a merged task", card.Actions[index].Label)
	}
}

func TestClosedWithoutMergeSaysSoOnItsOwnButton(t *testing.T) {
	card := IncidentCardWithPublication(
		mergedTask(), "Emisar", nil, true, true, mergedPublication(),
		core.PublicationFollowup{PRState: "closed"}, core.PublicationLifecycleEvent{},
	)

	index := slices.IndexFunc(card.Actions, func(action Action) bool {
		return action.ID == ActionViewPR
	})
	if index < 0 || card.Actions[index].Label != "View closed PR" {
		t.Errorf("closed task card PR control: %+v", card.Actions)
	}
}

// Closing a merged task looked like it had done nothing worth doing, because
// the only thing it said was that leftovers had been archived for recovery.
// What it actually did was release the isolated fork.
func TestClosingAMergedTaskReportsDeliveryNotSalvage(t *testing.T) {
	notice := ClosedNotice(true, mergedPublication(), mergedFollowup())

	if strings.Contains(notice, "archived for manual inspection") {
		t.Errorf("delivered work reported as salvage: %q", notice)
	}
	if !strings.Contains(notice, "PR #6") {
		t.Errorf("close notice does not name the PR that carried the work: %q", notice)
	}
}

// The floor: an abandoned task still says its changes were kept, because for
// that task the sentence is true and it is the only pointer to the fork.
func TestClosingAnUndeliveredTaskStillReportsTheArchive(t *testing.T) {
	notice := ClosedNotice(true, core.Publication{}, core.PublicationFollowup{})

	if !strings.Contains(notice, "archived for manual inspection") {
		t.Errorf("undelivered task lost its recovery pointer: %q", notice)
	}
}

// Close diff already deletes the message. The generic Dismiss appended beside
// it gave the diff two buttons that read as the same offer, so a reader picking
// one had to wonder what the other would have done.
func TestDiffViewOffersOneWayOut(t *testing.T) {
	message := Message{
		Temporary: true,
		Actions: []Action{
			{ID: ActionChangesRefresh, Label: "Refresh diff", Value: "inc_1"},
			{ID: ActionCloseDiff, Label: "Close diff", Value: "inc_1"},
		},
	}

	rendered := renderedActionLabels(t, message)

	if slices.Contains(rendered, "Dismiss") {
		t.Errorf("diff view carries both Close diff and Dismiss: %v", rendered)
	}
	if !slices.Contains(rendered, "Close diff") {
		t.Errorf("diff view lost its way out: %v", rendered)
	}
}

// A temporary message with no way out of its own still gets one.
func TestTemporaryMessageWithoutADismissStillGetsOne(t *testing.T) {
	message := Message{
		Temporary: true,
		Actions:   []Action{{ID: ActionViewPR, Label: "Open PR", Value: "inc_1"}},
	}

	if !slices.Contains(renderedActionLabels(t, message), "Dismiss") {
		t.Error("a temporary message was left with no way to put it away")
	}
}
