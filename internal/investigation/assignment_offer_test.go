package investigation

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func assignmentOffer() *core.StandingAssignmentOffer {
	return &core.StandingAssignmentOffer{
		Repository: "AndrewDryga/responder", ChangeClass: "observability",
		SignalPattern: "terraform drift", PathGlobs: []string{"infra/**"},
		DailyBudget: 2, ExpiryDays: 30,
	}
}

// An assignment offer is validated by the same function the confirmation click
// is measured against, and a bound the host cannot grant is refused here.
//
// Here is where it has to happen. This is the only refusal a model can act on:
// a correction turn reads it, and the next result either names a real change
// class or does not. A bound that passed here and failed at the operator's
// click would be a card offering authority the host was never going to grant —
// which is worse than a rejected result, because somebody already agreed to it.
func TestAnAssignmentOfferIsRefusedForABoundTheHostCannotGrant(t *testing.T) {
	if err := (ResultOperation{
		ID: "assign-1", Type: "offer_assignment", AssignmentOffer: assignmentOffer(),
	}).Validate(); err != nil {
		t.Fatalf("a complete assignment offer was rejected: %v", err)
	}
	for _, refusal := range []struct {
		name   string
		break_ func(*core.StandingAssignmentOffer)
		says   string
	}{
		{"an invented change class", func(o *core.StandingAssignmentOffer) {
			o.ChangeClass = "refactor"
		}, "dependency_upgrade"},
		{"an unbounded expiry", func(o *core.StandingAssignmentOffer) {
			o.ExpiryDays = 3650
		}, "at most 90"},
		{"a budget no reviewer reads", func(o *core.StandingAssignmentOffer) {
			o.DailyBudget = 100
		}, "range is 1 to 20"},
		{"no signal, which is every message in the channel", func(o *core.StandingAssignmentOffer) {
			o.SignalPattern = "  "
		}, "signal_pattern"},
	} {
		t.Run(refusal.name, func(t *testing.T) {
			offer := assignmentOffer()
			refusal.break_(offer)
			err := (ResultOperation{
				ID: "assign-1", Type: "offer_assignment", AssignmentOffer: offer,
			}).Validate()
			if err == nil {
				t.Fatal("an offer the host cannot grant was accepted")
			}
			if !strings.Contains(err.Error(), refusal.says) {
				t.Fatalf("the rejection does not say what to write instead: %v", err)
			}
		})
	}
}

// The offer carries the bounds and it cannot carry shadow.
//
// A standing assignment is created in shadow with no exception, and the flag is
// cleared later against a row that already has an audit to argue with. If the
// payload could say `"shadow": false`, the one refusal this whole feature was
// landed behind would be a field a model can set. The strict decoder is what
// enforces it, so this asserts the decoder rather than a comment.
func TestAnAssignmentOfferCannotAskForLiveAuthority(t *testing.T) {
	var operation ResultOperation
	err := json.Unmarshal([]byte(`{
		"id":"assign-1","type":"offer_assignment",
		"assignment":{"repository":"r","change_class":"observability",
		  "signal_pattern":"drift","shadow":false}
	}`), &operation)
	if err == nil {
		t.Fatal("an offer asking for a live grant was decoded")
	}
	if !strings.Contains(err.Error(), "shadow") {
		t.Fatalf("the decoder refused for some other reason: %v", err)
	}
}

// The short spellings two months of documentation taught still reach the field
// they name.
//
// `repo=`, `class=`, `signal=`, `paths=`, `budget=` and `days=` were the whole
// grammar of `/responder assignments create`. A model that read that history —
// in the channel, in the help card, in an operator's own sentence quoting it —
// and wrote `repo` would otherwise have its entire response rejected over a key.
func TestAnAssignmentOfferAcceptsTheSpellingsTheRetiredCommandTaught(t *testing.T) {
	var operation ResultOperation
	if err := json.Unmarshal([]byte(`{
		"id":"assign-1","type":"offer_assignment",
		"assignment":{"repo":"AndrewDryga/responder","class":"observability",
		  "signal":"terraform drift","paths":["infra/**"],"budget":2,"days":30}
	}`), &operation); err != nil {
		t.Fatalf("the retired command's own field names were rejected: %v", err)
	}
	if err := operation.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	got := operation.AssignmentOffer
	if got.Repository != "AndrewDryga/responder" || got.ChangeClass != "observability" ||
		got.SignalPattern != "terraform drift" || got.DailyBudget != 2 || got.ExpiryDays != 30 ||
		len(got.PathGlobs) != 1 {
		t.Fatalf("an aliased offer lost a bound: %+v", got)
	}
}

// The operations prompt has to name the operation, its payload key, and the
// pairing rule.
//
// The pairing sentence is not decoration. request_record's first live gate run
// failed both of its cases because "emit it and say nothing else" sat two lines
// above "exactly one complete_episode operation is required", and the model
// obeyed the nearer sentence — sending the operation alone, or a completion
// with no message. offer_assignment is emitted in exactly the same shape, from
// an operator's request, so it says the pairing outright rather than repeating
// that first-gate failure.
func TestTheOperationsPromptPairsTheAssignmentOfferWithACompletion(t *testing.T) {
	prompt := ResultOperationsPrompt()
	for _, want := range []string{
		"offer_assignment", `"assignment"`,
		"BESIDE your one complete_episode",
		"an operator confirms",
		"always created shadowed",
		// The closed set, in the prompt rather than only in the refusal. A
		// model told to pick from a list it cannot see is the exact shape of
		// the worst recorded correction loop — 6.6 repeats on one episode,
		// choosing from an empty list of verdicts.
		"dependency_upgrade|alert_threshold",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("the operations prompt omits %q", want)
		}
	}
	if _, ok := resultOperationValidators["offer_assignment"]; !ok {
		t.Fatal("offer_assignment is in the prompt with no validator behind it")
	}
}
