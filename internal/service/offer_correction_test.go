package service

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
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

func TestRuleCorrectionFillsHostOwnedChannelAndRepository(t *testing.T) {
	cfg := serviceConfig(t)
	s := &Service{cfg: cfg}
	input := core.SlackInput{
		ID: "slack_contextual_rule", EventID: "EvContextualRule",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text: "Look at the Terraform events in this channel and comment in a thread " +
			"with red flags, check health after apply, and tag me if apply failed.",
	}
	decision := decisionpkg.WatchDecision{RuleOffer: &core.RuleOffer{
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "app", ExpiresIn: "30d",
	}}
	if correction := s.offerRejectionCorrection(
		context.Background(), input, decision,
	); correction != "" {
		t.Fatalf("host-owned context caused a model retry: %q", correction)
	}
	decision.RuleOffer = decisionpkg.NormalizeStandingRule(input, "repo", decision.RuleOffer)
	if decision.RuleOffer.Scope != "channel" || decision.RuleOffer.Repository != "repo" ||
		decision.RuleOffer.Trigger != "terraform_lifecycle" ||
		decision.RuleOffer.Action != "monitor_terraform_lifecycle" {
		t.Fatalf("normalized contextual rule = %+v", decision.RuleOffer)
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

// Three wrong occurrences survived the model-facing correction boundary in
// two private replays on 2026-08-11. The operator asked for two checks; the
// result supplied three valid-looking timestamps, so the proposal writer
// stored a batch it could not prove belonged to the request. Proposal writing
// is the last authority boundary and must repeat the semantic check itself.
//
// Covers: TestScheduleOfferBatchRejectsMismatchWithExplicitRelativeRequest
// Covers: TestSeveralScheduleOffersMustMatchExplicitOccurrences
func TestScheduleProposalsMatchEveryExplicitRelativeOccurrence(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 8, 11, 20, 0, 23, 0, time.UTC)
	svc := New(
		cfg, st, newFakeCoop(),
		&fakeSlack{channel: slackui.Channel{ID: "COPS", Name: "operations", Member: true}},
		nil, slackui.NewSanitizer(12000), nil,
	)
	svc.SetClock(func() time.Time { return now })
	st.SetClock(func() time.Time { return now })
	input := core.SlackInput{
		ID: "slack_exact_relative_batch", EnvelopeID: "env_exact_relative_batch",
		EventID: "EvExactRelativeBatch", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "1700.100",
		MessageTS: "1786478423.000000", UserID: cfg.Slack.Operators[0],
		Text:       "Check tomorrow and in 3 days that Zot authentication failures are gone.",
		ReceivedAt: now,
	}
	offerAt := func(offset time.Duration) *core.ScheduleOffer {
		return &core.ScheduleOffer{
			Title: "Verify Zot authentication", Prompt: "Check Zot logs and report here.",
			Repository: "repo", Recurrence: "once",
			StartAt:  now.Add(offset).Format(time.RFC3339),
			Timezone: "UTC", CatchUp: "latest", ExpiresIn: "7d",
		}
	}

	if _, _, _, ok := svc.prepareScheduleOffersAction(ctx, input, []*core.ScheduleOffer{
		offerAt(24 * time.Hour), offerAt(48 * time.Hour), offerAt(96 * time.Hour),
	}); ok {
		t.Fatal("a three-occurrence batch was proposed for a two-occurrence request")
	}
	if proposal, err := st.Schedules.GetPendingForConversation(
		ctx, input.TeamID, input.ChannelID, input.ThreadTS, input.UserID,
	); !errors.Is(err, schedulestore.ErrNotFound) {
		t.Fatalf("mismatched batch left a pending proposal: proposal=%+v err=%v", proposal, err)
	}

	if _, tasks, _, ok := svc.prepareScheduleOffersAction(ctx, input, []*core.ScheduleOffer{
		offerAt(24 * time.Hour), offerAt(72 * time.Hour),
	}); !ok || len(tasks) != 2 {
		t.Fatalf("the exact requested occurrences were refused: ok=%t tasks=%+v", ok, tasks)
	}
}

// One real confirmation card on 2026-08-11 shifted "same time tomorrow" by
// eleven minutes because the model's RFC3339 value was only checked for shape.
// The terse selection still belongs to the preceding operator request: the
// host must preserve its timestamp, normalize it to a minute, and refuse a
// different model-authored clock before any proposal exists.
// Covers finding: 20260811T200655Z-run_5cc27f35e9374bda6b2ae289ad29556d
func TestSameTimeScheduleSelectionKeepsTheOperatorsPriorLocalMinute(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	reference := time.Date(2026, 8, 11, 20, 1, 32, 0, time.UTC)
	now := reference.Add(90 * time.Second)
	svc := New(
		cfg, st, newFakeCoop(),
		&fakeSlack{channel: slackui.Channel{ID: "COPS", Name: "operations", Member: true}},
		nil, slackui.NewSanitizer(12000), nil,
	)
	svc.SetClock(func() time.Time { return now })
	st.SetClock(func() time.Time { return now })
	prior := core.SlackInput{
		ID: "slack_same_time_request", EnvelopeID: "env_same_time_request",
		EventID: "EvSameTimeRequest", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: "1700.100",
		MessageTS: "1786478492.660349", UserID: cfg.Slack.Operators[0],
		Text:       "Same time tomorrow and after tomorrow, my local timezone.",
		ReceivedAt: reference,
	}
	selection := core.SlackInput{
		ID: "slack_same_time_selection", EnvelopeID: "env_same_time_selection",
		EventID: "EvSameTimeSelection", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", ThreadTS: prior.ThreadTS,
		MessageTS: "1786478582.660349", UserID: cfg.Slack.Operators[0],
		Text: "Tomorrow.", ReceivedAt: now,
	}
	for _, input := range []core.SlackInput{prior, selection} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s: created=%t err=%v", input.ID, created, err)
		}
	}
	offerAt := func(start string) *core.ScheduleOffer {
		return &core.ScheduleOffer{
			Title:      "Verify Zot authentication tomorrow",
			Prompt:     "Check Zot logs for recurring authentication failures and report here.",
			Repository: "repo", Recurrence: "once", StartAt: start,
			Timezone: "America/Merida", CatchUp: "latest", ExpiresIn: "7d",
		}
	}

	if _, _, _, ok := svc.prepareScheduleOfferAction(
		ctx, selection, offerAt("2026-08-12T19:50:00Z"),
	); ok {
		t.Fatal("the model-authored 13:50 local proposal replaced the requested 14:01 local time")
	}
	if proposal, err := st.Schedules.GetPendingForConversation(
		ctx, selection.TeamID, selection.ChannelID, selection.ThreadTS, selection.UserID,
	); !errors.Is(err, schedulestore.ErrNotFound) {
		t.Fatalf("wrong-time offer left a pending proposal: proposal=%+v err=%v", proposal, err)
	}

	want := time.Date(2026, 8, 12, 20, 1, 0, 0, time.UTC)
	_, task, _, ok := svc.prepareScheduleOfferAction(
		ctx, selection, offerAt(want.Format(time.RFC3339)),
	)
	if !ok || !task.NextRunAt.Equal(want) {
		t.Fatalf("same-time proposal = ok=%t start=%s, want %s", ok, task.NextRunAt, want)
	}
}
