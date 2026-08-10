package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A setup session owns one card, and every step edits it.
//
// The wizard used to post a message per step, so an operator watching
// #frontend-ops-alerts got "1 of 4 - When should I participate?", then "2 of 4 -
// What code should I use for this channel?", then two more, then a confirmation,
// then a receipt: six messages to answer four questions, in a channel whose other
// readers wanted alerts. Their words were "can it be one message that we update?
// So that we don't spam".
func TestAFullSetupRunUpdatesOneCardInsteadOfPostingOnePerStep(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		channel: slackui.Channel{
			ID: "CFRONT", Name: "frontend-ops-alerts", Member: true,
		},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	join := core.SlackInput{
		ID: "card-join", EnvelopeID: "card-join-env", EventID: "card-join-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID,
		ChannelID: "CFRONT", UserID: "U123ABC",
	}
	if _, err := st.AdmitSlackInput(ctx, join); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	session, err := st.GetActiveConfigurationSession(ctx, "CFRONT")
	if err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Markdown, "1 of 4") {
		t.Fatalf("opening card = %+v", slackClient.posts)
	}
	card := slackClient.posts[0]

	for index, answer := range []string{
		"be proactive",
		"default",
		"offer an incident button",
		"no additional invitees",
	} {
		reply := core.SlackInput{
			ID:         "card-answer-" + string(rune('a'+index)),
			EnvelopeID: "card-answer-env-" + string(rune('a'+index)),
			EventID:    "card-answer-event-" + string(rune('a'+index)),
			Kind:       "message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CFRONT", ThreadTS: session.ThreadTS,
			MessageTS: "1800.0" + string(rune('1'+index)),
			UserID:    "U123ABC", Text: answer,
		}
		if _, err := st.AdmitSlackInput(ctx, reply); err != nil {
			t.Fatal(err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process answer %q: %v", answer, err)
		}
	}
	session, err = st.GetActiveConfigurationSession(ctx, "CFRONT")
	if err != nil {
		t.Fatal(err)
	}
	if session.Step != "confirm" || session.Status != "confirming" {
		t.Fatalf("session after four answers = %+v", session)
	}

	save := core.SlackInput{
		ID: "card-save", EnvelopeID: "card-save-env", EventID: "card-save-event",
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "CFRONT",
		MessageTS: card.thread, UserID: "U123ABC",
		ActionID: slackui.ActionSaveChannelConfig, ActionValue: session.ID,
	}
	if _, err := st.AdmitSlackInput(ctx, save); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.posts) != 1 {
		t.Fatalf(
			"a four-step setup posted %d cards, want exactly 1: %+v",
			len(slackClient.posts), slackClient.posts,
		)
	}
	if len(slackClient.updates) != 5 {
		t.Fatalf(
			"a four-step setup made %d edits, want 5 (four answers and the save): %+v",
			len(slackClient.updates), slackClient.updates,
		)
	}
	for index, update := range slackClient.updates {
		if update.channel != "CFRONT" || update.ts != "1700.001" {
			t.Fatalf("edit %d addressed %s/%s, not the one card", index, update.channel, update.ts)
		}
	}
	final := slackClient.updates[len(slackClient.updates)-1].message
	if final.Header != "Channel behavior saved" || len(final.Actions) != 0 {
		t.Fatalf("the card did not end as a readable record: %+v", final)
	}
	if len(slackClient.ephemerals) != 0 {
		t.Fatalf("the wizard question stopped being public: %+v", slackClient.ephemerals)
	}
}

// A card cannot move between a channel and a thread by editing it, so the one
// that is left behind has to stop being a live question.
//
// The operator asked to continue in a thread. The setup follows them, which means
// a second message exists whatever we do; the choice is whether the first one
// keeps its buttons. It must not: two cards for one session both accepting clicks
// is the state where an operator answers question three on the card that is still
// showing question two.
func TestASetupThatMovesToAThreadRetiresTheCardItLeavesBehind(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		channel:     slackui.Channel{ID: "CMOVE", Name: "infra", Member: true},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	join := core.SlackInput{
		ID: "move-join", EnvelopeID: "move-join-env", EventID: "move-join-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID,
		ChannelID: "CMOVE", UserID: "U123ABC",
	}
	if _, err := st.AdmitSlackInput(ctx, join); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("opening card = %+v", slackClient.posts)
	}
	abandoned := "1700.001"

	move := core.SlackInput{
		ID: "move-to-thread", EnvelopeID: "move-to-thread-env",
		EventID: "move-to-thread-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CMOVE", MessageTS: "1800.500", UserID: "U123ABC",
		Text: "be proactive, and let's switch to a thread not to pollute the channel",
	}
	if _, err := st.AdmitSlackInput(ctx, move); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.posts) != 2 || slackClient.posts[1].thread != "1800.500" {
		t.Fatalf("the setup did not follow the operator into the thread: %+v", slackClient.posts)
	}
	retired := slackUpdate{}
	for _, update := range slackClient.updates {
		if update.ts == abandoned {
			retired = update
		}
	}
	if retired.ts != abandoned {
		t.Fatalf("the card left in the channel was never retired: %+v", slackClient.updates)
	}
	if len(retired.message.Actions) != 0 {
		t.Fatalf("the retired card still accepts clicks: %+v", retired.message)
	}
	if !strings.Contains(strings.ToLower(retired.message.Markdown), "thread") {
		t.Fatalf("the retired card does not say where the setup went: %+v", retired.message)
	}

	answer := core.SlackInput{
		ID: "move-answer", EnvelopeID: "move-answer-env", EventID: "move-answer-event",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CMOVE",
		ThreadTS: "1800.500", MessageTS: "1800.501", UserID: "U123ABC",
		Text: "default",
	}
	if _, err := st.AdmitSlackInput(ctx, answer); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 2 {
		t.Fatalf("answering in the new thread posted another card: %+v", slackClient.posts)
	}
	last := slackClient.updates[len(slackClient.updates)-1]
	if last.ts != "1700.002" {
		t.Fatalf("the next question did not edit the card in the thread: %+v", slackClient.updates)
	}
}

// A card whose timestamp was lost is still in the channel, so the next step
// adopts it rather than posting a second one.
//
// Post and the write that records where it landed are two operations, and only
// the second can be rolled back. When the process dies between them the session
// has no card timestamp and Slack has a card, and the wizard used to answer that
// by posting another one — the duplicate the operator would then be able to click.
func TestASetupCardLostToAFailedStoreWriteIsAdoptedNotReposted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		channel:     slackui.Channel{ID: "CLOST", Name: "infra", Member: true},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	session, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CLOST", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CLOST", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	// The post that landed. The write that would have recorded it did not, so the
	// session still has no card of its own.
	if _, err := slackClient.Post(
		ctx, "channel_setup_card_"+session.ID, "CLOST", "",
		slackui.ChannelSetupQuestion("infra", session, svc.setupRepositoryChoices()),
	); err != nil {
		t.Fatal(err)
	}

	answer := core.SlackInput{
		ID: "lost-answer", EnvelopeID: "lost-answer-env", EventID: "lost-answer-event",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CLOST",
		MessageTS: "1800.700", UserID: "U123ABC", Text: "be proactive",
	}
	if _, err := st.AdmitSlackInput(ctx, answer); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.posts) != 1 {
		t.Fatalf(
			"the lost card was replaced rather than adopted: %d posts %+v",
			len(slackClient.posts), slackClient.posts,
		)
	}
	if len(slackClient.updates) != 1 || slackClient.updates[0].ts != "1700.001" {
		t.Fatalf("the recovered card was not edited: %+v", slackClient.updates)
	}
	advanced, err := st.GetActiveConfigurationSession(ctx, "CLOST")
	if err != nil {
		t.Fatal(err)
	}
	if advanced.Step != "repository" {
		t.Fatalf("the answer was not applied: %+v", advanced)
	}

	next := core.SlackInput{
		ID: "lost-answer-two", EnvelopeID: "lost-answer-two-env",
		EventID: "lost-answer-two-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CLOST", MessageTS: "1800.701", UserID: "U123ABC", Text: "default",
	}
	if _, err := st.AdmitSlackInput(ctx, next); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 || len(slackClient.updates) != 2 {
		t.Fatalf(
			"the adopted card was not kept: posts=%+v updates=%+v",
			slackClient.posts, slackClient.updates,
		)
	}
}

// The opening card has the same two-step window, and the retry that follows it
// used to cancel the session and post a second card.
//
// startChannelConfiguration replaces any live session, which is right when an
// operator asks to reconfigure a channel and wrong when the previous attempt
// simply failed to record the card it had already posted. A session with no card
// was never shown to anyone, so there is nothing to replace: it is an unfinished
// start, and finishing it adopts the card that is already in the channel.
func TestAnOpeningCardLostBeforeItWasBoundIsAdoptedNotReposted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		channel:     slackui.Channel{ID: "CBIND", Name: "infra", Member: true},
		dedupePosts: true,
	}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	session, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CBIND", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CBIND", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := slackClient.Post(
		ctx, "channel_setup_card_"+session.ID, "CBIND", "",
		slackui.ChannelSetupQuestion("infra", session, svc.setupRepositoryChoices()),
	); err != nil {
		t.Fatal(err)
	}

	retry := core.SlackInput{
		ID: "bind-retry", EnvelopeID: "bind-retry-env", EventID: "bind-retry-event",
		Kind: "channel_joined", TeamID: cfg.Slack.TeamID,
		ChannelID: "CBIND", UserID: "U123ABC",
	}
	if _, err := st.AdmitSlackInput(ctx, retry); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	if len(slackClient.posts) != 1 {
		t.Fatalf(
			"the unbound opening card was replaced: %d posts %+v",
			len(slackClient.posts), slackClient.posts,
		)
	}
	resumed, err := st.GetActiveConfigurationSession(ctx, "CBIND")
	if err != nil {
		t.Fatal(err)
	}
	if resumed.ID != session.ID {
		t.Fatalf("the unfinished start was replaced by %s, not resumed", resumed.ID)
	}
	if resumed.ThreadTS != "1700.001" {
		t.Fatalf("the adopted card was not bound as the setup conversation: %+v", resumed)
	}
}
