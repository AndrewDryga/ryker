package service

import (
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// A malformed offer must come back to the model as a repair instruction rather
// than vanish. The three offers here are each rejected for a different reason,
// and each rejection has to name the offer that failed — a correction that
// says only "invalid" sends the model back to guess which of its offers was
// the problem.
func TestRejectedOfferIsReturnedToTheModelAsACorrection(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	operator := core.SlackInput{
		ID: "slack_reject", EventID: "EvReject",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "When you see a new Terraform plan here, always review it.",
	}

	for _, tc := range []struct {
		name     string
		decision decisionpkg.WatchDecision
		want     string
	}{
		{
			name: "a rule with an action the host does not have",
			decision: decisionpkg.WatchDecision{RuleOffer: &core.RuleOffer{
				Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
				Action: "summon_a_second_opinion", SourceKind: "app",
				ExpiresIn: "30d",
			}},
			want: "standing rule",
		},
		{
			name: "a preference whose lifetime cannot be read",
			decision: decisionpkg.WatchDecision{PreferenceOffer: &core.PreferenceOffer{
				Scope: "operator", Name: "health_check_depth",
				Value: "deep", ExpiresIn: "for a while",
			}},
			want: "preference",
		},
		{
			name: "a memory with no subject",
			decision: decisionpkg.WatchDecision{MemoryOffer: &core.MemoryOffer{
				Scope: "channel", Subject: "", Predicate: "means",
				Value: "payments-api", ExpiresIn: "30d",
			}},
			want: "memory",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			correction := s.offerRejectionCorrection(
				context.Background(), operator, tc.decision,
			)
			if correction == "" {
				t.Fatal("a rejected offer produced no correction; " +
					"it would be dropped silently and the reply sent anyway")
			}
			if !strings.Contains(correction, tc.want) {
				t.Fatalf("correction does not name the offer that failed: %q",
					correction)
			}
			// The model must be told it may drop the offer. Without this it
			// rewrites a malformed offer until it passes rather than asking
			// whether the offer belonged in the reply at all.
			if !strings.Contains(correction, "without") {
				t.Fatalf("correction does not offer the drop path: %q", correction)
			}
		})
	}
}

// The correction must fire only for what the model can fix. An offer is also
// refused when the requester is not an operator or never asked for one, and
// neither is the model's doing: correcting those would send it back to rewrite
// an offer that was already correct, and it would fail the same way forever.
func TestOfferRefusedForContextIsNotCorrected(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	valid := decisionpkg.WatchDecision{RuleOffer: &core.RuleOffer{
		Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
		Action: "review_terraform_plan", SourceKind: "app", ExpiresIn: "30d",
	}}

	// A stranger asking, and an operator who asked for one thing once. The
	// host declines to store a rule in both cases; the model built it fine.
	for _, input := range []core.SlackInput{
		{
			ID: "slack_stranger", EventID: "EvStranger",
			TeamID: cfg.Slack.TeamID, ChannelID: "COPS", UserID: "UNOTANOPERATOR",
			Text: "When you see a new Terraform plan here, always review it.",
		},
		{
			ID: "slack_onetime", EventID: "EvOnetime",
			TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
			UserID: cfg.Slack.Operators[0],
			Text:   "Review this Terraform plan once.",
		},
	} {
		if _, _, _, ok := s.prepareRuleOfferAction(input, valid.RuleOffer); ok {
			t.Fatalf("this input was supposed to be refused for context: %q",
				input.Text)
		}
		if correction := s.offerRejectionCorrection(
			context.Background(), input, valid,
		); correction != "" {
			t.Fatalf("corrected the model for something it did not do: %q",
				correction)
		}
	}
}

// An offer the host accepts must not be corrected, or every well-formed turn
// pays for a second pass.
func TestAcceptedOfferProducesNoCorrection(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	input := core.SlackInput{
		ID: "slack_ok", EventID: "EvOK",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "When you see a new Terraform plan here, always review it.",
	}
	decision := decisionpkg.WatchDecision{RuleOffer: &core.RuleOffer{
		Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
		Action: "review_terraform_plan", SourceKind: "app", ExpiresIn: "30d",
	}}
	if correction := s.offerRejectionCorrection(
		context.Background(), input, decision,
	); correction != "" {
		t.Fatalf("a valid offer was corrected: %q", correction)
	}
	// And a turn with no offer at all is the common case.
	if correction := s.offerRejectionCorrection(
		context.Background(), input, decisionpkg.WatchDecision{},
	); correction != "" {
		t.Fatalf("a turn with no offers was corrected: %q", correction)
	}
}

// The reporting command must count every class the service can emit. These
// drifted apart once already: a hand-written list in the reader meant a class
// was emitted, counted by nobody, and the totals quietly understated.
func TestEveryCorrectionClassIsReportable(t *testing.T) {
	reported := map[string]bool{}
	for _, class := range CorrectionClasses() {
		reported[class] = true
	}
	for _, class := range []correctionClass{
		correctionUnreadable, correctionIncomplete, correctionRejected,
	} {
		if !reported[string(class)] {
			t.Fatalf("class %q is emitted but not reported", class)
		}
	}
}

// When the model has had its retries and still cannot state an offer, the
// answer must still go out. Blocking the whole turn over a malformed offer
// replaces a correct reply with a generic failure the user cannot act on, and
// loses the work they were waiting for.
//
// Only the failing offer is dropped: a turn can carry a good memory and a bad
// rule, and dropping both would lose something the user asked for.
func TestExhaustedOfferCorrectionKeepsTheAnswerAndDropsOnlyTheBadOffer(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg, log: slog.New(slog.DiscardHandler)}
	input := core.SlackInput{
		ID: "slack_drop", EventID: "EvDrop",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "When you see a new Terraform plan here, always review it.",
	}
	decision := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The plan adds two subnets and changes no security groups.",
		RuleOffer: &core.RuleOffer{
			Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
			Action: "summon_a_second_opinion", SourceKind: "app", ExpiresIn: "30d",
		},
		PreferenceOffer: &core.PreferenceOffer{
			Scope: "operator", Name: "health_check_depth",
			Value: "deep", ExpiresIn: "90d",
		},
	}
	answer := decision.Message

	s.dropRejectedOffers(context.Background(), input, &decision, core.AgentRun{ID: "run_drop"})

	if decision.RuleOffer != nil {
		t.Fatal("the offer the host rejects survived; it would fail silently again")
	}
	if decision.PreferenceOffer == nil {
		t.Fatal("a valid offer was dropped along with the invalid one")
	}
	if decision.Message != answer || decision.Action != "reply" {
		t.Fatalf("the answer was altered: action=%q message=%q",
			decision.Action, decision.Message)
	}
}

// A schedule_offer also rides along with an activation of an established
// schedule, where the host never validates it as a new schedule at all. The
// correction path must use the same gate the persistence path uses, or it
// corrects the model for an offer it was never asked to build — and the turn
// requeues forever instead of replying.
//
// This is a regression test for exactly that: the correction path originally
// re-derived the gate and got this case wrong.
func TestOfferOutsideTheHostsScopeIsNotCorrected(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	activation := core.SlackInput{
		ID: "slack_activate", EventID: "EvActivate", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: cfg.Slack.Operators[0],
		Text:   "activate it",
	}
	// Deliberately missing the fields a new schedule needs. The host does not
	// read it as a new schedule, so its shape is not the model's problem.
	decision := decisionpkg.WatchDecision{ScheduleOffer: &core.ScheduleOffer{
		Prompt:     "Execute whole-platform-health-review-v5@5 with fresh evidence.",
		Repository: "repo", Recurrence: "daily", LocalTime: "09:00",
		CatchUp: "latest",
	}}
	if s.scheduleOfferInScope(activation) {
		t.Fatal("an activation was read as an explicit request for a new schedule")
	}
	if correction := s.offerRejectionCorrection(
		context.Background(), activation, decision,
	); correction != "" {
		t.Fatalf("corrected an offer the host never validates: %q", correction)
	}
}
