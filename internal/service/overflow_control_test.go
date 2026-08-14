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
	deliverInteractionAt(t, ctx, svc, incident, incident.RootTS, envelope, userID, action)
}

// deliverInteractionAt is a press on a message other than the pinned card.
//
// Not every control lives on the card. Close diff sits on the diff message it
// closes, and a press recorded against the root ts would be answered by the
// card's own staleness check rather than by the diff's.
func deliverInteractionAt(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	incident core.Incident,
	messageTS string,
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
				ChannelID: incident.ChannelID, MessageTs: messageTS,
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

// theAsk is the ask row's rendered text and the label of the button under it.
// renderedSlackMessage deliberately joins only the prose blocks, and the ask
// lives in a Row with its own control, so these two facts have to be read
// together or a test can watch the text change without noticing that the button
// stopped agreeing with it.
func theAsk(t *testing.T, message slackui.Message) string {
	t.Helper()
	for _, section := range message.Tail {
		if strings.HasPrefix(section, "*The request*") {
			return section
		}
	}
	t.Fatalf("the card has no request in its tail: %+v", message)
	return ""
}

// legacyFullRequestValue is the retired toggle's encoding, frozen.
//
// It is written out here rather than imported because nothing composes it any
// more: the only values that still carry it are sitting in Slack on cards
// posted before the request moved into the card's tail, and this is a test
// about those cards specifically.
func legacyFullRequestValue(incidentID string) string {
	return incidentID + "~expanded"
}

// taskOverflowFixture is an engineering task with a delivered card and an ask
// long enough to be worth collapsing. Only a task card carries the ask row.
func taskOverflowFixture(t *testing.T, ctx context.Context, ask string) (
	*store.Store, *Service, *fakeSlack, core.Incident,
) {
	t.Helper()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-ask-toggle", "Prevent the reload-driven OOM", ask,
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
	if err := st.SetCoopSession(ctx, task.ID, "ses_1", "fork-ask-toggle", 1); err != nil {
		t.Fatal(err)
	}
	if task, err = st.GetIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, &fakeSocket{}, slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	return st, svc, slackClient, task
}

// deliverStoredCard records message as sent at messageTS, which is what the
// staleness gate reads when a control is pressed somewhere other than the
// pinned root card.
func deliverStoredCard(
	t *testing.T,
	ctx context.Context,
	svc *Service,
	incident core.Incident,
	messageTS string,
	message slackui.Message,
) {
	t.Helper()
	body, err := slackui.Encode(svc.sanitizeMessage(message))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_card_at_" + messageTS, IncidentID: incident.ID, Kind: "card",
		ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
		Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := svc.store.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.store.FinishSlackDelivery(ctx, delivery.ID, messageTS, "sending"); err != nil {
		t.Fatal(err)
	}
}

// The whole ask, and the sentence at the end of it that a lede cannot reach.
const longAsk = "The reload path allocates a fresh cache per request and never " +
	"releases it, so a busy hour walks the pod into the OOM killer. Reproduce it " +
	"against the staging fixture first, then fix the allocation, then prove the " +
	"steady state with a soak. Start from commit deadbeefcafebabefeedfacedeadbeefcafebabe " +
	"which is where the regression landed."

// A press on the retired Full request button re-renders the card.
//
// The control is gone: the card carries the whole request in its tail, where
// Slack's own fold handles the height, so there is no view to toggle. But cards
// posted before that are still in channels with the button on them, and the
// honest answer to that press is the current card — which shows the request the
// operator wanted and replaces the button with a layout that needs none.
func TestARetiredFullRequestPressRerendersTheCard(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	deliverInteraction(t, ctx, svc, task, "env-legacy-full-request", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionFullRequest,
			Value:    legacyFullRequestValue(task.ID),
		})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.updates) != 1 {
		t.Fatalf("the press rewrote %d messages, want the card itself", len(slackClient.updates))
	}
	rendered := slackClient.updates[0]
	if rendered.channel != task.ChannelID || rendered.ts != task.RootTS {
		t.Fatalf("rewrote %q/%q, want the clicked card %q/%q",
			rendered.channel, rendered.ts, task.ChannelID, task.RootTS)
	}
	if ask := theAsk(t, rendered.message); !strings.Contains(
		ask, "prove the steady state with a soak",
	) {
		t.Fatalf("the re-rendered card stops short of the request: %q", ask)
	}
	// And the button does not come back.
	for _, action := range append(
		append([]slackui.Action{}, rendered.message.Actions...),
		rendered.message.Overflow...,
	) {
		if action.ID == slackui.ActionFullRequest {
			t.Fatalf("the re-rendered card still offers the retired control: %+v", action)
		}
	}

	// Nothing was said in the thread and nothing was refused: it is a re-render,
	// and it costs exactly one Slack edit.
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("the press posted in the thread: %+v", slackClient.posts)
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("a read-only control was answered privately: %+v", slackClient.ephemerals)
	}
}

// Every render carries the whole request, so there is no view state left for a
// worker pass to heal or to leak. The card an operator opens is the card
// everyone else sees.
func TestEveryCardRenderCarriesTheWholeRequest(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, _ := taskOverflowFixture(t, ctx, longAsk)

	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.updates) == 0 {
		t.Fatal("the worker pass rendered no card")
	}
	rendered := slackClient.updates[len(slackClient.updates)-1]
	if ask := theAsk(t, rendered.message); !strings.Contains(
		ask, "prove the steady state with a soak",
	) {
		t.Fatalf("a worker render stops short of the request: %q", ask)
	}
}

// A retired button has to survive the staleness gate, and the gate reads the
// *delivered* body. A card expanded in place before the toggle was retired
// carries a value the stored body never recorded, so an exact-value match would
// refuse the one press that would have replaced that card with a current one.
func TestARetiredFullRequestButtonPassesTheStalenessCheck(t *testing.T) {
	ctx := context.Background()
	_, svc, _, task := taskOverflowFixture(t, ctx, longAsk)

	// The body as an older build delivered it, at a ts other than the pinned
	// root so the check reads the stored body instead of short-circuiting.
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	card.Overflow = append(card.Overflow, slackui.Action{
		ID:    slackui.ActionFullRequest,
		Label: "Open the full request",
		Value: legacyFullRequestValue(task.ID),
	})
	deliverStoredCard(t, ctx, svc, task, "1700.400", card)

	for name, value := range map[string]string{
		"asking to expand":   legacyFullRequestValue(task.ID),
		"asking to collapse": task.ID,
	} {
		t.Run(name, func(t *testing.T) {
			input := core.SlackInput{
				ChannelID: task.ChannelID, MessageTS: "1700.400", UserID: "U123ABC",
				ActionID: slackui.ActionFullRequest, ActionValue: value,
			}
			matches, err := svc.incidentControlMatchesMessage(ctx, input, task)
			if err != nil {
				t.Fatal(err)
			}
			if !matches {
				t.Fatalf("the card refused a button it is still carrying: %q", value)
			}
		})
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

// The same press arriving through the ⋯ rather than as a button re-renders the
// same card — and the retired value survives being wrapped in the overflow
// codec, which is the part that could silently stop decoding.
func TestARetiredFullRequestChoiceReachesItsHandlerThroughTheOverflowMenu(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	deliverInteraction(t, ctx, svc, task, "env-full-request-menu", "U123ABC",
		&slack.BlockAction{
			ActionID: slackui.ActionOverflow,
			SelectedOption: slack.OptionBlockObject{
				Value: slackui.OverflowOptionValue(slackui.Action{
					ID:    slackui.ActionFullRequest,
					Value: legacyFullRequestValue(task.ID),
				}),
			},
		})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.updates) != 1 {
		t.Fatalf("the ⋯ choice rewrote %d messages", len(slackClient.updates))
	}
	if ask := theAsk(t, slackClient.updates[0].message); !strings.Contains(
		ask, "prove the steady state with a soak",
	) {
		t.Fatalf("full request from the ⋯ = %q", ask)
	}
}

// Ask for an update queues an agent run and says nothing else. The reply lands
// minutes later, so with no acknowledgement the press was indistinguishable
// from a dead button — which is exactly what the operator reported after
// clicking it on a deployed card and watching the thread stay empty.
func TestAskForAnUpdateAcknowledgesThePressInTheTaskThread(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	deliverInteraction(t, ctx, svc, task, "env-update-ack", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionUpdate, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	// The work was really admitted; the acknowledgement is not a substitute for
	// it, and an ack for a run that was never queued would be the worse bug.
	if _, err := st.LeaseAgentRun(ctx); err != nil {
		t.Fatalf("the press queued no run: %v", err)
	}

	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("acknowledgements = %+v", slackClient.ephemerals)
	}
	ack := slackClient.ephemerals[0]
	if ack.channel != task.ChannelID || ack.thread != task.ConversationThreadTS() {
		t.Fatalf("the acknowledgement went to %q/%q, want the task's thread %q/%q",
			ack.channel, ack.thread, task.ChannelID, task.ConversationThreadTS())
	}
	if ack.user != "U123ABC" {
		t.Fatalf("the acknowledgement was addressed to %q", ack.user)
	}
	if !strings.Contains(ack.message.Text, "On it") {
		t.Fatalf("acknowledgement = %q", ack.message.Text)
	}
	// One line. A press receipt that carries blocks is a second card competing
	// with the one the operator is already reading.
	if len(ack.message.Sections) != 1 || len(ack.message.Actions) != 0 ||
		strings.Contains(ack.message.Text, "\n") {
		t.Fatalf("the acknowledgement is not one line: %+v", ack.message)
	}
}

// A control that already answers for itself is not acknowledged twice. The
// receipt's own reply is the receipt — an "On it" in front of it would be one
// more line saying nothing, on the surface this whole round is trying to quiet.
//
// It also has to arrive in the task's thread. This is the reported symptom:
// every ephemeral was posted with no thread_ts, so a thread-scoped task's
// private answers landed at channel level and the operator, watching the
// thread, saw the click do nothing at all.
func TestTheTurnReceiptAnswersInTheThreadAndIsNotAcknowledgedTwice(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	deliverInteraction(t, ctx, svc, task, "env-receipt", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionTurnReceipt, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("the receipt answered %d times: %+v",
			len(slackClient.ephemerals), slackClient.ephemerals)
	}
	answer := slackClient.ephemerals[0]
	if answer.thread != task.ConversationThreadTS() {
		t.Fatalf("the receipt answered in %q, not the task's thread %q",
			answer.thread, task.ConversationThreadTS())
	}
	rendered := renderedSlackMessage(answer.message)
	if !strings.Contains(rendered, "No turn has finished here yet") {
		t.Fatalf("the receipt said %q", rendered)
	}
	if strings.Contains(rendered, "On it") {
		t.Fatal("a control that answers for itself was acknowledged as well")
	}
}

// A refusal is about the task, so it goes where the task's other answers go.
// Mirroring the click instead would put it at channel level whenever the card
// being pressed is a thread's parent.
func TestAControlRefusalLandsInTheTaskThread(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	// Review refuses while a turn is running, so leave one running.
	if _, _, err := svc.queueIncidentAgentRun(
		ctx, task, "initial", task.ID, "", "Make the focused change.",
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	refreshed, err := svc.store.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.ActiveTurnID == "" {
		t.Fatal("the fixture left no turn running, so review would not refuse")
	}
	deliverInteraction(t, ctx, svc, refreshed, "env-review-refused", "U123ABC",
		&slack.BlockAction{ActionID: slackui.ActionReview, Value: task.ID})
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("refusals = %+v", slackClient.ephemerals)
	}
	refusal := slackClient.ephemerals[0]
	if refusal.thread != refreshed.ConversationThreadTS() {
		t.Fatalf("the refusal landed in %q, not the task's thread %q",
			refusal.thread, refreshed.ConversationThreadTS())
	}
	if !strings.Contains(renderedSlackMessage(refusal.message), "still running") {
		t.Fatalf("refusal = %q", renderedSlackMessage(refusal.message))
	}
	// Refused work is not acknowledged as started.
	if strings.Contains(renderedSlackMessage(refusal.message), "On it") {
		t.Fatal("a refused control was acknowledged as started")
	}
}

// A press is acknowledged once, not once per attempt. The controls worth
// acknowledging are the slow ones, and those are exactly the ones whose
// handlers fail and get retried — up to twelve times — so an acknowledgement
// that did not check would answer one press with twelve identical lines.
func TestAControlPressIsAcknowledgedOncePerPressNotPerAttempt(t *testing.T) {
	ctx := context.Background()
	_, svc, slackClient, task := taskOverflowFixture(t, ctx, longAsk)

	first := core.SlackInput{
		ID: "in_1", Kind: "action", ChannelID: task.ChannelID, UserID: "U123ABC",
		// LeaseSlackInput counts the lease it hands out, so a first press
		// arrives at the handler with Attempts already at 1.
		ActionID: slackui.ActionReview, ActionValue: task.ID, Attempts: 1,
	}
	svc.ackControl(ctx, first, task, "On it — re-running the readiness check.")
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("the first attempt acknowledged %d times", len(slackClient.ephemerals))
	}

	retried := first
	retried.Attempts = 2
	svc.ackControl(ctx, retried, task, "On it — re-running the readiness check.")
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("a retried attempt acknowledged again: %+v", slackClient.ephemerals)
	}

	// The dashboard renders its own refusals and progress, so a control-plane
	// press is not answered with a Slack ephemeral at all.
	fromDashboard := first
	fromDashboard.Kind = controlPlaneInput
	svc.ackControl(ctx, fromDashboard, task, "On it.")
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("a control-plane press posted to Slack: %+v", slackClient.ephemerals)
	}
}
