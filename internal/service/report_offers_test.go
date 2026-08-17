package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The wiring, which is the actual defect: the helpers above can be perfect and
// change nothing if the conversation lane's correction chain never calls them.
//
// That is exactly how this bug got here. The watch lane grew
// offerRejectionCorrection on 2026-08-16 and the incident-conversation lane,
// which runs the same offers through the same validators, was left alone — so
// the test that would have caught it is one that drives a real conversational
// turn and reads what came back, not one that calls the helper directly.
func TestTheConversationLaneCorrectsARejectedOffer(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_offer", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-offer-conversation", EnvelopeID: "envelope-offer-conversation",
		EventID: "event-offer-conversation", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, MessageTS: "1700.700",
		UserID: cfg.Slack.Operators[0], Text: "From now on always keep your answers short.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit conversation = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	// An invented preference name on an otherwise fine answer — the shape the
	// 2026-08-16 audit found, and the one the host silently threw away here.
	answer := `{"operations":[` +
		`{"id":"pref","type":"offer_preference","preference_offer":` +
		`{"scope":"operator","name":"verbosity","value":"short","expires_in":"90d"}},` +
		`{"id":"complete","type":"complete_episode","completion":{` +
		`"message":"Noted — I will keep answers short.",` +
		`"completion":{"status":"decision_ready",` +
		`"summary":"Recorded the requested answer-length preference."}}}]}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	// An incident-bound run is polled through its incident, not through the
	// agent-run poller; driving it the other way finishes nothing and the lane
	// under test never runs.
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(answer)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}

	corrections := auditOutcomes(t, cfg, "result.correction", "")
	joined := strings.Join(corrections, "\n")
	for _, want := range []string{"preference", "verbosity", "response_detail"} {
		if !strings.Contains(joined, want) {
			t.Fatalf(
				"the conversation lane never told the model %q was wrong; corrections: %v",
				want, corrections,
			)
		}
	}
}

// The conversation lane never told the model its offer was refused.
//
// The watch lane got this on 2026-08-16: a malformed offer becomes a correction
// naming the field, its value and the accepted set. The incident-conversation
// lane was left as it was, and it is the lane a person actually talks to — a
// teammate says "remember that staging redeploys nightly", the model attaches a
// memory offer the host will not store, `prepareMemoryOfferAction` returns
// false, and the reply posts with no button and no correction. The user is told
// nothing was saved by the absence of a button they never knew to expect, and
// the model, never told which field failed, proposes the same thing next time.
//
// Both lanes read the same traversal, so this asserts the conversation lane's
// view of a report produces the correction the watch lane's view of a decision
// already produces from the same offer.
func TestAConversationOfferRejectionTellsTheModelWhichFieldWasWrong(t *testing.T) {
	s, _ := discardLog(t)
	input := core.SlackInput{
		ID: "slack_conv_offer", EventID: "EvConvOffer",
		TeamID: s.cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: s.cfg.Slack.Operators[0],
		Text:   "From now on always keep your answers short.",
	}
	offer := &core.PreferenceOffer{
		Scope: "operator", Name: "verbosity", Value: "short", ExpiresIn: "90d",
	}
	report := decisionpkg.AgentReport{
		Message:         "Noted — I will keep answers short.",
		PreferenceOffer: offer,
	}

	correction := s.reportOfferRejectionCorrection(context.Background(), input, report)
	for _, want := range []string{"preference", "name", "verbosity", "response_detail"} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the conversation correction never named %q: %q", want, correction)
		}
	}
}

// A refused offer must not eat the answer it was attached to.
//
// The watch lane learned this: blocking on a rejected offer replaces a good
// reply with "I couldn't finish this check safely yet", which is untrue and
// throws away work the user is waiting on over a malformed button. The
// conversation lane's exhaustion path blocked on every correction class except
// shape, so wiring the offer correction in without this would have made the
// lane worse than the silence it replaced — a correct answer, lost, because a
// memory offer had the wrong scope.
//
// So when the retries are spent the offer is dropped and the answer posts,
// which is what the lane already did silently. What changes is that the model
// got told first, and the operator gets a record of what was dropped.
func TestSpentOfferCorrectionsDropTheOfferAndKeepTheAnswer(t *testing.T) {
	s, logs := discardLog(t)
	input := core.SlackInput{
		ID: "slack_conv_drop", EventID: "EvConvDrop",
		TeamID: s.cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: s.cfg.Slack.Operators[0],
		Text:   "From now on always keep your answers short.",
	}
	report := decisionpkg.AgentReport{
		Message: "Noted — I will keep answers short.",
		PreferenceOffer: &core.PreferenceOffer{
			Scope: "operator", Name: "verbosity", Value: "short", ExpiresIn: "90d",
		},
		MemoryOffer: &core.MemoryOffer{
			Scope: "channel", Subject: "staging", Predicate: "guidance",
			Value: "redeploys nightly", ExpiresIn: "30d", Visibility: "channel",
		},
	}

	s.dropRejectedReportOffers(
		context.Background(), input, &report, core.AgentRun{ID: "run_conv_drop"},
	)
	if report.PreferenceOffer != nil {
		t.Errorf("the refused preference offer survived: %+v", report.PreferenceOffer)
	}
	// A turn can carry a good memory and a bad preference, and dropping both
	// would lose something the user asked for.
	if report.MemoryOffer == nil {
		t.Error("a valid memory offer was dropped alongside the refused preference")
	}
	if report.Message != "Noted — I will keep answers short." {
		t.Errorf("the answer was rewritten: %q", report.Message)
	}
	if !strings.Contains(logs.String(), "preference") {
		t.Errorf("the operator was not told what was dropped: %q", logs.String())
	}
}
