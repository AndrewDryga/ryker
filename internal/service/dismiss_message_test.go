package service

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/socketmode"
)

// A transient card used to need Slack's multi-step message menu to remove it,
// so preparation notices and read-only pop-outs accumulated in busy threads.
// The button must delete the delivered message itself while leaving the work
// and its durable history exactly as they were.
func TestDismissRemovesOnlyTheDeliveredTemporaryCard(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	messageTS, action := deliveredTemporaryCard(t, ctx, st, svc, slackClient, incident)
	before, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}

	deliverInteractionAt(
		t, ctx, svc, incident, messageTS, "env-dismiss", "U123ABC", action,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.deletes) != 1 ||
		slackClient.deletes[0].channel != incident.ChannelID ||
		slackClient.deletes[0].timestamp != messageTS {
		t.Fatalf("dismiss deleted %+v, want %s:%s",
			slackClient.deletes, incident.ChannelID, messageTS)
	}
	after, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("dismiss changed durable work:\nbefore=%+v\nafter=%+v", before, after)
	}
	input, err := st.SlackInputs.GetByEventID(ctx, "interaction:env-dismiss")
	if err != nil || input.State != "done" {
		t.Fatalf("dismiss input = %+v, %v", input, err)
	}
}

func TestDismissRefusesSomeoneWhoCannotRemoveSharedCards(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	messageTS, action := deliveredTemporaryCard(t, ctx, st, svc, slackClient, incident)

	deliverInteractionAt(
		t, ctx, svc, incident, messageTS, "env-dismiss-denied", "U-NOT-OPERATOR", action,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.deletes) != 0 {
		t.Fatalf("non-operator deleted %+v", slackClient.deletes)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(renderedSlackMessage(slackClient.ephemerals[0].message),
			"configured operator") {
		t.Fatalf("denial response = %+v", slackClient.ephemerals)
	}
	if !slackClient.ephemerals[0].message.Temporary {
		t.Fatal("the private refusal lost the Dismiss button its response URL can remove")
	}
	input, err := st.SlackInputs.GetByEventID(ctx, "interaction:env-dismiss-denied")
	if err != nil || input.State != "done" {
		t.Fatalf("denied dismiss input = %+v, %v", input, err)
	}
}

// The record directory and all four record views are private Slack messages.
// They were the exact temporary cards an operator wanted to clear, but the
// pacer stripped their marker because chat.delete cannot delete ephemerals.
// Slack gives a clicked ephemeral its own response URL; that is the deletion
// capability this path must use, without admitting a durable control action.
func TestDismissRemovesAPrivateRecordCardThroughItsInteractionResponse(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, socket, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-record-directory", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionRecordDirectory, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("record directory replies = %+v", slackClient.ephemerals)
	}
	message := slackClient.ephemerals[0].message
	if !message.Temporary {
		t.Fatal("private record directory lost its temporary marker")
	}
	action := dismissAction(t, message)

	svc.admitInteraction(ctx, socketmode.Event{
		Type: socketmode.EventTypeInteractive,
		Data: slack.InteractionCallback{
			Type:        slack.InteractionTypeBlockActions,
			Team:        slack.Team{ID: svc.cfg.Slack.TeamID},
			User:        slack.User{ID: "U123ABC"},
			ResponseURL: "https://hooks.slack.test/response/private-record",
			Container: slack.Container{
				ChannelID: incident.ChannelID, MessageTs: "1700.ephemeral", IsEphemeral: true,
			},
			ActionCallback: slack.ActionCallbacks{BlockActions: []*slack.BlockAction{action}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-dismiss-private-record"},
	})

	if !reflect.DeepEqual(slackClient.responseDeletes, []string{
		"https://hooks.slack.test/response/private-record",
	}) {
		t.Fatalf("private dismiss response deletes = %v", slackClient.responseDeletes)
	}
	if len(slackClient.deletes) != 0 {
		t.Fatalf("private dismiss incorrectly used chat.delete: %+v", slackClient.deletes)
	}
	if socket.acks != 2 {
		t.Fatalf("socket acknowledgements = %d, want directory and dismiss", socket.acks)
	}
	if _, err := st.SlackInputs.GetByEventID(ctx, "interaction:env-dismiss-private-record"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("private presentation-only dismiss was admitted as work: %v", err)
	}
}

func TestPrivateDismissStillAcknowledgesWhenSlackCannotRemoveTheCard(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, socket, incident := overflowFixture(t, ctx)
	slackClient.responseDeleteErr = errors.New("expired_response_url")

	svc.admitInteraction(ctx, socketmode.Event{
		Type: socketmode.EventTypeInteractive,
		Data: slack.InteractionCallback{
			Type: slack.InteractionTypeBlockActions,
			Team: slack.Team{ID: svc.cfg.Slack.TeamID},
			User: slack.User{ID: "U123ABC"}, ResponseURL: "https://hooks.slack.test/expired",
			Container: slack.Container{
				ChannelID: incident.ChannelID, MessageTs: "1700.ephemeral", IsEphemeral: true,
			},
			ActionCallback: slack.ActionCallbacks{BlockActions: []*slack.BlockAction{{
				ActionID: slackui.ActionDismissMessage,
			}}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-dismiss-private-expired"},
	})

	if socket.acks != 1 {
		t.Fatalf("failed private dismiss acknowledgements = %d, want 1", socket.acks)
	}
	if len(slackClient.responseDeletes) != 1 {
		t.Fatalf("failed private dismiss attempts = %v", slackClient.responseDeletes)
	}
}

func TestHelpIsPrivateToTheOperatorWhoAskedForIt(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-private-help", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionHelp, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 0 {
		t.Fatalf("Help was posted to everyone: %+v", slackClient.posts)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("private Help replies = %+v", slackClient.ephemerals)
	}
	help := slackClient.ephemerals[0]
	if help.user != "U123ABC" || help.thread != incident.ConversationThreadTS() ||
		!help.message.Temporary {
		t.Fatalf("private Help destination/message = %+v", help)
	}
	dismissAction(t, help.message)
}

func TestDismissRefusesAnInactiveConfiguredOperator(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	messageTS, action := deliveredTemporaryCard(t, ctx, st, svc, slackClient, incident)
	slackClient.deniedUsers = map[string]bool{"U123ABC": true}

	deliverInteractionAt(
		t, ctx, svc, incident, messageTS,
		"env-dismiss-inactive", "U123ABC", action,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.deletes) != 0 {
		t.Fatalf("inactive operator deleted %+v", slackClient.deletes)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(renderedSlackMessage(slackClient.ephemerals[0].message),
			"active full workspace") {
		t.Fatalf("inactive-operator response = %+v", slackClient.ephemerals)
	}
}

func TestDismissAcceptsAMessageThatSlackAlreadyRemoved(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	messageTS, action := deliveredTemporaryCard(t, ctx, st, svc, slackClient, incident)
	slackClient.deleteErr = errors.New("message_not_found")

	deliverInteractionAt(
		t, ctx, svc, incident, messageTS, "env-dismiss-gone", "U123ABC", action,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	input, err := st.SlackInputs.GetByEventID(ctx, "interaction:env-dismiss-gone")
	if err != nil || input.State != "done" || input.Failures != 0 {
		t.Fatalf("already-gone dismiss input = %+v, %v", input, err)
	}
}

// Preparation blockers are mutable: retries update one Slack message and
// recovery retires its delivery epoch. Deleting Slack without closing that
// epoch leaves the store pointing at a timestamp that no longer exists, so the
// next blocker tries to update a ghost and becomes invisible.
func TestDismissClosesAMutablePreparationNoticeEpoch(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, _, incident := overflowFixture(t, ctx)
	const prefix = "watch_preparation_blocked_episode_1_"
	body, err := slackui.Encode(slackui.RepositoryPreparationBlocked("repo"))
	if err != nil {
		t.Fatal(err)
	}
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:         "watch_preparation_blocked_episode_1_epoch_001",
		IncidentID: incident.ID, Operation: "post", Kind: "notice",
		ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
		Body: body, CoalesceKey: prefix,
	}); err != nil || !created {
		t.Fatalf("enqueue preparation notice = %t, %v", created, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	delivery, err := st.GetSlackDelivery(ctx, "watch_preparation_blocked_episode_1_epoch_001")
	if err != nil || delivery.MessageTS == "" {
		t.Fatalf("preparation delivery = %+v, %v", delivery, err)
	}
	action := dismissAction(t, slackClient.posts[0].message)

	deliverInteractionAt(
		t, ctx, svc, incident, delivery.MessageTS,
		"env-dismiss-preparation", "U123ABC", action,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	deliveries, err := st.ListSlackDeliveriesByPrefix(ctx, prefix)
	if err != nil {
		t.Fatal(err)
	}
	foundRetirement := false
	for _, candidate := range deliveries {
		if candidate.Operation == "delete" && candidate.State == "sent" {
			foundRetirement = true
		}
	}
	if !foundRetirement {
		t.Fatalf("dismiss left the mutable preparation epoch open: %+v", deliveries)
	}
	if len(slackClient.deletes) != 1 || slackClient.deletes[0].timestamp != delivery.MessageTS {
		t.Fatalf("preparation dismiss deleted %+v", slackClient.deletes)
	}
}

func deliveredTemporaryCard(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	svc *Service,
	slackClient *fakeSlack,
	incident core.Incident,
) (string, *slack.BlockAction) {
	t.Helper()
	const deliveryID = "out_temporary_card"
	if err := svc.enqueue(
		ctx, deliveryID, incident, "notice", incident.ConversationThreadTS(),
		slackui.Message{
			Text: "Workspace preparation is blocked.", Sections: []string{
				"Workspace preparation is blocked.",
			}, Temporary: true,
		},
	); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("temporary card deliveries = %+v", slackClient.posts)
	}
	delivery, err := st.GetSlackDelivery(ctx, deliveryID)
	if err != nil || delivery.MessageTS == "" {
		t.Fatalf("delivered temporary card = %+v, %v", delivery, err)
	}
	return delivery.MessageTS, dismissAction(t, slackClient.posts[0].message)
}

func dismissAction(t *testing.T, message slackui.Message) *slack.BlockAction {
	t.Helper()
	for _, block := range message.Blocks() {
		actions, ok := block.(*slack.ActionBlock)
		if !ok {
			continue
		}
		for _, element := range actions.Elements.ElementSet {
			button, ok := element.(*slack.ButtonBlockElement)
			if ok && slackui.BaseActionID(button.ActionID) == slackui.ActionDismissMessage {
				return &slack.BlockAction{
					ActionID: button.ActionID, Value: button.Value,
				}
			}
		}
	}
	t.Fatal("delivered temporary card has no Dismiss button")
	return nil
}
