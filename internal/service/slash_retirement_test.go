package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A removed verb stays removed, and says where its capability went.
//
// `/responder` was more than twenty subcommands, which is what a command
// surface becomes when everything the product does is required to have one.
// The pressure that produced them has not gone anywhere: the cheapest way to
// expose any new capability is still a new case in this switch, and the second
// cheapest is to restore one that used to be here. A re-added case would fail
// nothing without this test — it would simply work, and the kit would grow back
// one convenient verb at a time.
//
// One exemplar per family, because the families are the argument. Each removed
// verb has somewhere else to be, and the answer has to name it: an operator who
// typed a verb that worked last week did not typo, and "Unknown subcommand"
// tells them they did.
func TestARetiredSubcommandAnswersWithWhereItWent(t *testing.T) {
	for _, probe := range []struct {
		verb    string
		pointer string
	}{
		// Directories: the App Home and the web control plane list them.
		{verb: "incidents", pointer: "App Home"},
		// Durable behavior: same surfaces, and creation stays conversational.
		{verb: "schedules", pointer: "App Home"},
		// Product feedback: the model records it from what was said.
		{verb: "feedback", pointer: "Just say it here"},
		// The four durable records: the pinned card's Record row.
		{verb: "handoff", pointer: "pinned card"},
		// Lifecycle: the pinned card's buttons.
		{verb: "publish", pointer: "pinned card"},
		// The turn ceiling: a deployment value, and never an operator estimate.
		{verb: "turn-limit", pointer: "responder.yaml"},
	} {
		t.Run(probe.verb, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			slackClient := &fakeSlack{}
			svc := New(
				cfg, st, newFakeCoop(), slackClient, nil,
				slackui.NewSanitizer(12000), nil,
			)
			input := core.SlackInput{
				ID: "slash-" + probe.verb, EnvelopeID: "env-slash-" + probe.verb,
				EventID: "event-slash-" + probe.verb, Kind: "slash",
				TeamID: cfg.Slack.TeamID, ChannelID: "CRETIRED",
				UserID: cfg.Slack.Operators[0], Text: probe.verb,
				ActionID: "/responder",
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit %q = %v, %v", probe.verb, created, err)
			}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			if len(slackClient.ephemerals) != 1 {
				t.Fatalf("`/responder %s` answers = %+v", probe.verb, slackClient.ephemerals)
			}
			answer := renderedSlackMessage(slackClient.ephemerals[0].message)
			if !strings.Contains(answer, "is gone") {
				t.Fatalf("`/responder %s` did not say it was removed: %s", probe.verb, answer)
			}
			if !strings.Contains(answer, probe.pointer) {
				t.Fatalf(
					"`/responder %s` did not point at %q: %s",
					probe.verb, probe.pointer, answer,
				)
			}
			// Whatever they typed, the answer states the whole of what is left,
			// `assignments` included: a pointer that names four of five verbs
			// sends an operator looking for the fifth somewhere it is not.
			for _, kept := range keptSlashKit {
				if !strings.Contains(answer, kept) {
					t.Fatalf(
						"`/responder %s` did not name the kept verb %q: %s",
						probe.verb, kept, answer,
					)
				}
			}
		})
	}
}

// keptSlashKit is every verb `/responder` still routes.
//
// Four of them are the emergency kit — they reach no model, need no Coop
// session, and answer privately, so they work when the conversational path is
// the thing that is broken. `assignments` is the fifth and belongs to that
// argument for half of what it does: reading a channel's standing grants and
// taking one back are exactly the things an operator needs when the model is
// the thing misbehaving.
//
// Its CREATION verb was here too, for a day and a half, and for a different
// reason: standing assignments landed with no `offer_assignment` result
// operation behind them, so slash was the only surface that could grant one and
// retiring the spelling on schedule would have retired the feature with it. That
// operation landed on 2026-08-15, so `create`, `add` and `new` now answer with
// the conversation instead — see TestTheRetiredAssignmentCreateVerbAnswersWith
// TheConversation. The family stays in this list because the reading half of it
// is still routed; a future move of list/pause/resume/delete to the App Home is
// what would take this entry out.
var keptSlashKit = []string{"status", "proactive", "shadow", "assignments", "help"}

// Every alias spelling of a removed verb is removed too.
//
// An operator who learned `preference` is no better served by silence than one
// who learned `preferences`, and an alias left in the switch is a whole
// subcommand still reachable — which is how a deletion becomes a rename.
func TestEveryAliasOfARetiredSubcommandIsRetired(t *testing.T) {
	kept := map[string]bool{
		"status": true, "settings": true, "config": true,
		"proactive": true, "watch": true, "shadow": true, "help": true,
		"assignments": true, "assignment": true,
	}
	for _, verb := range keptSlashKit {
		if !kept[verb] {
			t.Fatalf("%q is named as kept and is not in the routed set", verb)
		}
	}
	for _, verb := range []string{
		"incidents", "work", "commitments", "feedback",
		"memory", "preferences", "preference", "rules", "rule",
		"schedules", "schedule", "reminders", "turn-limit", "turns",
		"timeline", "evidence", "handoff", "postmortem",
		"update", "changes", "review", "publish", "stop", "extend", "close",
	} {
		if kept[verb] {
			t.Fatalf("%q is in both the kept kit and the retired list", verb)
		}
		if _, ok := retiredSlashSubcommands[verb]; !ok {
			t.Errorf(
				"`/responder %s` is not in retiredSlashSubcommands, so it answers "+
					"\"unknown subcommand\" instead of naming where it went",
				verb,
			)
		}
	}
	for verb := range retiredSlashSubcommands {
		if kept[verb] {
			t.Errorf("%q is retired and still routed; one of the two is wrong", verb)
		}
	}
}
