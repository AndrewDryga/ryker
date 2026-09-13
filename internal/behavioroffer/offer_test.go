package behavioroffer

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/offerreason"
)

// catalog is the two configuration questions a validator asks, answered from a
// list. The production Catalog is internal/config, and the whole reason this
// package takes an interface is that a refusal has to be reproducible without
// one.
type catalog []string

func (c catalog) Configured(name string) bool {
	for _, configured := range c {
		if configured == name {
			return true
		}
	}
	return false
}

func (c catalog) Names() []string { return c }

func testContext() Context {
	return Context{
		ChannelID: "C1", UserID: "U1", InputID: "in-1", TeamID: "T1",
		Now:          time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC),
		Repositories: catalog{"platform", "coop"},
	}
}

// TestAConfirmationPayloadKeepsTheShapeAlreadyOnButtons pins the wire format of
// the three behaviour confirmations across the extraction that gave them a
// shared Envelope.
//
// These payloads are not ours to change: every button posted in the last day is
// sitting in Slack carrying the old encoding, and the host decodes strictly. A
// reordered or renamed field would turn every live preference, rule and memory
// button into "Ryker could not read this confirmation" — which is the exact
// silence internal/offerreason was written to end. The struct literals below
// are the pre-extraction declarations, kept verbatim so the comparison is
// against what was really on the wire rather than against the new code.
func TestAConfirmationPayloadKeepsTheShapeAlreadyOnButtons(t *testing.T) {
	issuedAt := time.Date(2026, 8, 16, 21, 9, 0, 0, time.UTC)
	issue := Issue{ChannelID: "C1", SourceRef: "Ev1", At: issuedAt}

	type oldPreference struct {
		Version   int                  `json:"version"`
		ChannelID string               `json:"channel_id"`
		SourceRef string               `json:"source_ref"`
		IssuedAt  time.Time            `json:"issued_at"`
		Offer     core.PreferenceOffer `json:"offer"`
	}
	type oldRule struct {
		Version   int            `json:"version"`
		ChannelID string         `json:"channel_id"`
		SourceRef string         `json:"source_ref"`
		IssuedAt  time.Time      `json:"issued_at"`
		Offer     core.RuleOffer `json:"offer"`
	}
	type oldMemory struct {
		Version   int              `json:"version"`
		ChannelID string           `json:"channel_id"`
		SourceRef string           `json:"source_ref"`
		IssuedAt  time.Time        `json:"issued_at"`
		Offer     core.MemoryOffer `json:"offer"`
	}

	preferenceOffer := core.PreferenceOffer{
		Scope: "operator", Name: "response_location",
		Value: "prefer_thread", ExpiresIn: "90d",
	}
	ruleOffer := core.RuleOffer{
		Scope: "channel", Repository: "platform", Trigger: "terraform_plan",
		Action: "review_terraform_plan", SourceKind: "any", ExpiresIn: "90d",
	}
	memoryOffer := core.MemoryOffer{
		Scope: "channel", Subject: "communication_style", Predicate: "guidance",
		Value: "lead with the answer", Visibility: "channel", ExpiresIn: "90d",
	}

	for _, item := range []struct {
		name   string
		got    func() (string, bool)
		wanted any
	}{
		{
			"preference",
			func() (string, bool) { return EncodePreference(issue, preferenceOffer) },
			oldPreference{1, "C1", "Ev1", issuedAt, preferenceOffer},
		},
		{
			"rule",
			func() (string, bool) { return EncodeRule(issue, ruleOffer) },
			oldRule{1, "C1", "Ev1", issuedAt, ruleOffer},
		},
		{
			"memory",
			func() (string, bool) { return EncodeMemory(issue, memoryOffer) },
			oldMemory{1, "C1", "Ev1", issuedAt, memoryOffer},
		},
	} {
		encoded, ok := item.got()
		if !ok {
			t.Fatalf("%s: encoding an ordinary offer reported failure", item.name)
		}
		wanted, err := json.Marshal(item.wanted)
		if err != nil {
			t.Fatal(err)
		}
		if encoded != string(wanted) {
			t.Errorf(
				"%s payload changed shape.\n got: %s\nwant: %s",
				item.name, encoded, wanted,
			)
		}
	}

	// And the buttons already posted still decode, which is the half a shared
	// envelope could break without the encoder ever noticing.
	preference, err := DecodePreference(string(mustMarshal(t, oldPreference{1, "C1", "Ev1", issuedAt, preferenceOffer})))
	if err != nil || preference.Version != 1 || preference.ChannelID != "C1" ||
		preference.SourceRef != "Ev1" || !preference.IssuedAt.Equal(issuedAt) ||
		preference.Offer != preferenceOffer {
		t.Errorf("a preference button already in Slack no longer decodes: %+v, %v", preference, err)
	}
	memoryPayload, err := DecodeMemory(string(mustMarshal(t, oldMemory{1, "C1", "Ev1", issuedAt, memoryOffer})))
	if err != nil || memoryPayload.Version != 1 || memoryPayload.Offer != memoryOffer {
		t.Errorf("a memory button already in Slack no longer decodes: %+v, %v", memoryPayload, err)
	}
}

func mustMarshal(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

// TestAnOversizedOfferIsNeverPostedAsAButton keeps the size refusal on the
// encoder. A payload over Slack's action-value limit that got posted anyway
// would be a button that fails only when somebody presses it.
func TestAnOversizedOfferIsNeverPostedAsAButton(t *testing.T) {
	issue := Issue{ChannelID: "C1", SourceRef: "Ev1", At: time.Now().UTC()}
	if _, ok := EncodeMemory(issue, core.MemoryOffer{
		Scope: "channel", Subject: "s", Predicate: "guidance",
		Value: strings.Repeat("x", maxPayloadBytes), Visibility: "channel",
	}); ok {
		t.Fatal("an offer past the action-value limit was encoded into a button")
	}
}

// TestARefusedRepositoryListsTheOnesThatExist covers the 2026-08-16 finding
// that a "not configured" refusal the model could only answer by guessing was
// answered by guessing — blitz-infra, on every schedule blitz was asked for by
// its own name.
func TestARefusedRepositoryListsTheOnesThatExist(t *testing.T) {
	_, _, err := Preference(core.PreferenceOffer{
		Scope: "repository", Repository: "blitz-infra",
		Name: "response_detail", Value: "concise", ExpiresIn: "90d",
	}, testContext())
	var refused *offerreason.FieldError
	if !errors.As(err, &refused) {
		t.Fatalf("an unconfigured repository was not refused by field: %v", err)
	}
	if refused.Field != "repository" || refused.Value != "blitz-infra" ||
		!strings.Contains(refused.Expected, "platform") ||
		!strings.Contains(refused.Expected, "coop") {
		t.Errorf("the refusal does not name the repositories that exist: %+v", refused)
	}
}

// TestAnOfferValidatorAnswersFromItsArgumentsAlone is the reason this package
// exists: every refusal below is reproducible from an offer and a list of
// repository names, with no store, no clock and no configuration behind it.
func TestAnOfferValidatorAnswersFromItsArgumentsAlone(t *testing.T) {
	context := testContext()
	for _, item := range []struct {
		name  string
		run   func() error
		field string
	}{
		{"preference scope", func() error {
			_, _, err := Preference(core.PreferenceOffer{
				Scope: "galaxy", Name: "response_detail", Value: "concise", ExpiresIn: "90d",
			}, context)
			return err
		}, "scope"},
		{"preference name", func() error {
			_, _, err := Preference(core.PreferenceOffer{
				Scope: "operator", Name: "favourite_colour", Value: "blue", ExpiresIn: "90d",
			}, context)
			return err
		}, "name"},
		{"rule source kind", func() error {
			_, _, err := Rule(core.RuleOffer{
				Scope: "channel", Repository: "platform", Trigger: "terraform_plan",
				Action: "review_terraform_plan", SourceKind: "robot", ExpiresIn: "90d",
			}, context)
			return err
		}, "source_kind"},
		{"memory visibility", func() error {
			_, _, err := Entry(core.MemoryOffer{
				Scope: "channel", Subject: "topic", Predicate: "guidance",
				Value: "be brief", Visibility: "galaxy", ExpiresIn: "90d",
			}, context)
			return err
		}, "visibility"},
	} {
		err := item.run()
		var refused *offerreason.FieldError
		if !errors.As(err, &refused) {
			t.Errorf("%s: refused with %v, which names no field", item.name, err)
			continue
		}
		if refused.Field != item.field {
			t.Errorf("%s: refused field %q, want %q", item.name, refused.Field, item.field)
		}
	}
}

// TestAChannelScopedOfferOutsideAChannelIsRefusedNotStored keeps the App Home
// case, where ChannelID is empty and a channel-keyed scope would otherwise
// store a row keyed on nothing.
func TestAChannelScopedOfferOutsideAChannelIsRefusedNotStored(t *testing.T) {
	context := testContext()
	context.ChannelID = ""
	if _, _, err := Preference(core.PreferenceOffer{
		Scope: "channel", Name: "response_detail", Value: "concise", ExpiresIn: "90d",
	}, context); err == nil {
		t.Error("a channel preference was accepted with no channel to key it on")
	}
	if _, _, err := Rule(core.RuleOffer{
		Scope: "channel", Repository: "platform", Trigger: "terraform_plan",
		Action: "review_terraform_plan", ExpiresIn: "90d",
	}, context); err == nil {
		t.Error("a standing rule was accepted with no channel to watch")
	}
	if _, _, err := Entry(core.MemoryOffer{
		Scope: "channel", Subject: "topic", Predicate: "guidance",
		Value: "be brief", Visibility: "channel", ExpiresIn: "90d",
	}, context); err == nil {
		t.Error("a memory entry was accepted with no channel context")
	}
}

// TestAStalePressSaysWhichCauseStoppedIt checks the envelope reaches
// offerreason with every field it weighs, which is what a shared Envelope
// could quietly drop.
func TestAStalePressSaysWhichCauseStoppedIt(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	fresh := Envelope{Version: 1, ChannelID: "C1", SourceRef: "Ev1", IssuedAt: now.Add(-time.Hour)}
	for _, item := range []struct {
		name      string
		envelope  Envelope
		decodeErr error
		channel   string
		wanted    offerreason.Cause
		stale     bool
	}{
		{"fresh", fresh, nil, "C1", "", false},
		{"unreadable", fresh, errors.New("bad json"), "C1", offerreason.Unreadable, true},
		{"old host", Envelope{Version: 0, ChannelID: "C1", SourceRef: "Ev1", IssuedAt: now}, nil, "C1", offerreason.Unreadable, true},
		{"other channel", fresh, nil, "C2", offerreason.OtherChannel, true},
		{"expired", Envelope{Version: 1, ChannelID: "C1", SourceRef: "Ev1", IssuedAt: now.Add(-MaxAge - time.Minute)}, nil, "C1", offerreason.Expired, true},
		{"undated", Envelope{Version: 1, ChannelID: "C1", SourceRef: "Ev1"}, nil, "C1", offerreason.Undated, true},
	} {
		cause, stale := item.envelope.Click(item.decodeErr, item.channel, now).Cause()
		if stale != item.stale || cause != item.wanted {
			t.Errorf(
				"%s: cause %q stale=%v, want %q stale=%v",
				item.name, cause, stale, item.wanted, item.stale,
			)
		}
	}
}

// The last refusal that still named no field, found while extracting this
// package and left for its own change.
//
// A memory whose predicate is repository_for_channel is how an operator binds a
// channel to a repository — "for this channel, use blitz-infra" — and it is the
// one place a model must name a repository from a set it cannot see in the
// conversation. It got "repository \"blitz-infra\" is not configured": no field,
// no list, nothing to correct toward, three lines from the UnknownRepository
// helper every sibling already used. That is the same defect the standing-rule
// and schedule offers were fixed for, in the one branch nobody checked.
func TestABoundRepositoryRefusalNamesTheOnesThatExist(t *testing.T) {
	_, _, err := Entry(core.MemoryOffer{
		Scope: "channel", Subject: "channel:C1", Predicate: "repository_for_channel",
		Value: "blitz-infra", Visibility: "channel", ExpiresIn: "90d",
	}, testContext())
	var refused *offerreason.FieldError
	if !errors.As(err, &refused) {
		t.Fatalf("an unconfigured bound repository was not refused by field: %v", err)
	}
	if refused.Value != "blitz-infra" ||
		!strings.Contains(refused.Expected, "platform") ||
		!strings.Contains(refused.Expected, "coop") {
		t.Errorf("the refusal does not name the repositories that exist: %+v", refused)
	}
}

// The last refusal in the offer family that named nothing.
//
// A standing rule is offered as a trigger/action pair, and the accepted pairs
// are four cases in one switch in internal/core that the model cannot see. An
// invented pair came back as `standing rule pair "deploy"/"watch_it" is
// invalid`: no field, no value, and above all no list — while every sibling
// refusal names the field, what was sent, and what would have been accepted.
//
// The naming has to happen here rather than in core, because internal/core
// cannot import internal/offerreason: offerreason already imports core, so the
// dependency would be a cycle. core exports the pairs, this package turns the
// refusal into words.
func TestAnInvalidStandingRulePairNamesThePairsThatExist(t *testing.T) {
	_, _, err := Rule(core.RuleOffer{
		Scope: "channel", Repository: "platform",
		Trigger: "deploy", Action: "watch_it", ExpiresIn: "90d",
	}, testContext())
	var refused *offerreason.FieldError
	if !errors.As(err, &refused) {
		t.Fatalf("an invented trigger/action pair was not refused by field: %v", err)
	}
	if !strings.Contains(refused.Value, "deploy") ||
		!strings.Contains(refused.Value, "watch_it") {
		t.Errorf("the refusal does not name what was sent: %+v", refused)
	}
	// Every pair the host actually accepts, so the model can pick one instead of
	// guessing a second time.
	for _, pair := range core.StandingRulePairs() {
		if !strings.Contains(refused.Expected, pair) {
			t.Errorf("the refusal omits the accepted pair %q: %q", pair, refused.Expected)
		}
	}
	if len(core.StandingRulePairs()) < 4 {
		t.Errorf("the accepted pairs are not enumerated: %v", core.StandingRulePairs())
	}
}
