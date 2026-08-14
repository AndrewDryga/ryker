package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/socketmode"
)

// overflowFixture is an incident with a delivered card, and a service wired to
// a socket so interactions can arrive the way Slack delivers them.
func overflowFixture(t *testing.T, ctx context.Context) (
	*store.Store, *Service, *fakeSlack, *fakeSocket, core.Incident,
) {
	t.Helper()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident := createBoundIncident(t, ctx, st)
	// The isolated working copy exists, so a queued control run is leasable and
	// the read-only controls are not refused for a reason unrelated to routing.
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-read-only", 1,
	); err != nil {
		t.Fatal(err)
	}
	if incident, err = st.GetIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	return st, svc, slackClient, socket, incident
}

// deliverInteraction hands the service one block_actions payload the way the
// socket consumer receives it, then runs the control lane over whatever it
// admitted.
func deliverInteraction(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	incident core.Incident,
	envelope, userID string,
	action *slack.BlockAction,
) {
	t.Helper()
	svc.admitInteraction(ctx, socketmode.Event{
		Type: socketmode.EventTypeInteractive,
		Data: slack.InteractionCallback{
			Type: slack.InteractionTypeBlockActions,
			Team: slack.Team{ID: "T123ABC"},
			User: slack.User{ID: userID},
			Container: slack.Container{
				ChannelID: incident.ChannelID, MessageTs: incident.RootTS,
			},
			ActionCallback: slack.ActionCallbacks{
				BlockActions: []*slack.BlockAction{action},
			},
		},
		Request: &socketmode.Request{EnvelopeID: envelope},
	})
}

// A ⋯ choice has to reach the same place the same control reaches as a button,
// and reach it the same way: one authorization gate, one staleness check, one
// control switch. The two paths are run side by side and their effect compared,
// because a second dispatch that merely looks equivalent is the failure mode
// this is guarding — the routing is only shared if it is literally shared.
//
// Every option on every card was inert before this. Slack puts an overflow
// choice in `selected_option.value` and the socket read `value`, which is empty
// for a menu, so the click arrived carrying nothing to route.
// The two paths run against separate incidents because the first Ask for an
// update leaves a turn running on its own, which the second would then be
// answering rather than duplicating.
func TestOverflowSelectionRoutesLikeTheEquivalentButton(t *testing.T) {
	ctx := context.Background()

	// The button. Ask for an update queues an agent run against the incident.
	buttonStore, buttonService, _, buttonSocket, buttonIncident := overflowFixture(t, ctx)
	deliverInteraction(t, ctx, buttonService, buttonIncident, "env-button", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionUpdate, Value: buttonIncident.ID,
		})
	if err := buttonService.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	fromButton, err := buttonStore.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatalf("the button queued no run: %v", err)
	}

	// The same control chosen from the ⋯ instead. Value is empty exactly as
	// Slack sends it, and the choice travels in the selected option.
	menuStore, menuService, _, menuSocket, menuIncident := overflowFixture(t, ctx)
	deliverInteraction(t, ctx, menuService, menuIncident, "env-overflow", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionOverflow,
			SelectedOption: slack.OptionBlockObject{
				Value: slackui.OverflowOptionValue(slackui.Action{
					ID: slackui.ActionUpdate, Value: menuIncident.ID,
				}),
			},
		})
	if err := menuService.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	fromOverflow, err := menuStore.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatalf("the ⋯ choice queued no run: %v", err)
	}

	if fromOverflow.IncidentID != menuIncident.ID ||
		fromOverflow.SourceKind != fromButton.SourceKind ||
		fromOverflow.UserID != fromButton.UserID ||
		fromOverflow.Prompt != fromButton.Prompt {
		t.Fatalf("⋯ run = %+v, button run = %+v", fromOverflow, fromButton)
	}
	if buttonSocket.acks != 1 || menuSocket.acks != 1 {
		t.Fatalf("acks = %d/%d, want both interactions acknowledged",
			buttonSocket.acks, menuSocket.acks)
	}
}

// A card with two menus suffixes the second action_id, and the suffix is
// stripped before the overflow is recognised — otherwise every ⋯ after the
// first on a surface would be inert again.
func TestSecondOverflowMenuOnASurfaceStillRoutes(t *testing.T) {
	ctx := context.Background()
	st, svc, _, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-second-menu", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionOverflow + slackui.ActionInstanceSeparator + "2",
			SelectedOption: slack.OptionBlockObject{
				Value: slackui.OverflowOptionValue(slackui.Action{
					ID: slackui.ActionUpdate, Value: incident.ID,
				}),
			},
		})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatalf("the second ⋯ on the surface queued no run: %v", err)
	}
}

// An option value this renderer did not write has no action in it, so there is
// nothing to route and nothing to guess. It is dropped at admission rather than
// admitted and refused later: an input with no action id would otherwise travel
// the whole control lane to arrive at "unknown Responder control".
func TestUndecodableOverflowSelectionIsAcknowledgedAndDropped(t *testing.T) {
	ctx := context.Background()
	st, svc, _, socket, incident := overflowFixture(t, ctx)

	for name, value := range map[string]string{
		// The pre-fix encoding: the bare target, with the action discarded.
		"bare target": incident.ID,
		"empty":       "",
		"no action":   "~opt~" + incident.ID,
	} {
		deliverInteraction(t, ctx, svc, incident, "env-bad-"+name, "U123ABC",
			&slack.BlockAction{
				ActionID:       slackui.ActionOverflow,
				SelectedOption: slack.OptionBlockObject{Value: value},
			})
		if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("%s: admitted an unroutable overflow selection: %v", name, err)
		}
	}
	// Dropped is not ignored. Slack retries an unacknowledged interaction and
	// shows the operator a failure on a menu that has already been answered.
	if socket.acks != 3 {
		t.Fatalf("acks = %d, want every dropped selection acknowledged", socket.acks)
	}
}

// Full request answers the card's two-line quote with the whole ask, in the
// thread beside the card. The card holds a lede because it is an instrument;
// this is where the rest of the text stayed reachable, and until now the button
// that promised it had no handler at all.
func TestFullRequestControlPostsTheWholeAskInThread(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-full-request", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionFullRequest, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("full request posts = %+v", slackClient.posts)
	}
	posted := slackClient.posts[0]
	if posted.channel != incident.ChannelID ||
		posted.thread != incident.ConversationThreadTS() {
		t.Fatalf("full request went to %q/%q, want the card's thread %q/%q",
			posted.channel, posted.thread,
			incident.ChannelID, incident.ConversationThreadTS())
	}
	// The recorded signal, not a restatement of it.
	if !strings.Contains(
		renderedSlackMessage(posted.message), "API requests are timing out.",
	) {
		t.Fatalf("full request reply = %+v", posted.message)
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("a read-only control was refused: %+v", slackClient.ephemerals)
	}
}

// Full request is gated exactly as View diff is, because it is the same kind of
// control: read-only, incident-scoped, and quoting something the room already
// holds. The refusal is compared against ActionChanges' rather than asserted by
// wording, so the two cannot drift into two different answers.
func TestFullRequestControlRefusesTheSameUsersAsViewDiff(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-changes-denied", "U456DEF",
		&slack.BlockAction{ActionID: slackui.ActionChanges, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	deliverInteraction(t, ctx, svc, incident, "env-full-request-denied", "U456DEF",
		&slack.BlockAction{ActionID: slackui.ActionFullRequest, Value: incident.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.ephemerals) != 2 {
		t.Fatalf("refusals = %+v", slackClient.ephemerals)
	}
	changesRefusal := renderedSlackMessage(slackClient.ephemerals[0].message)
	fullRequestRefusal := renderedSlackMessage(slackClient.ephemerals[1].message)
	if fullRequestRefusal != changesRefusal {
		t.Fatalf("full request refusal = %q, View diff refusal = %q",
			fullRequestRefusal, changesRefusal)
	}
	if !strings.Contains(fullRequestRefusal, "operators") {
		t.Fatalf("refusal does not say who may act: %q", fullRequestRefusal)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("a refused control still posted the request: %+v", slackClient.posts)
	}
}

// The same click, arriving through the ⋯ rather than the row button, reaches
// the same handler — this is the control the Full request row and the task
// card's menu both carry.
func TestFullRequestReachesItsHandlerThroughTheOverflowMenu(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _, incident := overflowFixture(t, ctx)

	deliverInteraction(t, ctx, svc, incident, "env-full-request-menu", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionOverflow,
			SelectedOption: slack.OptionBlockObject{
				Value: slackui.OverflowOptionValue(slackui.Action{
					ID: slackui.ActionFullRequest, Value: incident.ID,
				}),
			},
		})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 || !strings.Contains(
		renderedSlackMessage(slackClient.posts[0].message),
		"API requests are timing out.",
	) {
		t.Fatalf("full request from the ⋯ = %+v", slackClient.posts)
	}
}
