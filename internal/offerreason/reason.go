// Package offerreason owns the words the host owes when it refuses something.
//
// Two audiences, one vocabulary. When a model attaches a malformed offer to a
// reply, the model has to be told which field carried the problem, what value
// it sent, and what that field accepts — anything less and it proposes the same
// thing next time, which is exactly what happened until 2026-08-16. When an
// operator clicks a confirmation button the host will not honour, the operator
// has to be told which control it was and why, because "invalid or stale" is
// four different situations wearing one sentence and each has a different next
// step.
//
// It is a package rather than a corner of the service because it is only text:
// every function here is pure, the whole vocabulary can be read in one sitting
// and kept consistent, and nothing about it needs a store, a clock, or Slack.
package offerreason

import (
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// FieldError is a refusal that knows which field it refused.
//
// The three parts stay separate so every consumer renders the same facts: the
// model reads them as a sentence in its correction, and the discard record logs
// them as structured fields an operator can filter on.
type FieldError struct {
	Field string
	// Value is model-supplied text and is bounded when rendered.
	Value string
	// Expected completes the sentence "<field> is <value>; <expected>", so it
	// reads as a clause: "expected one of quick, standard, or deep".
	Expected string
}

func (e *FieldError) Error() string {
	value := core.BoundedText(strings.TrimSpace(e.Value), 120)
	if value == "" {
		return e.Field + " is empty; " + e.Expected
	}
	return e.Field + " is " + strconv.Quote(value) + "; " + e.Expected
}

// Field refuses one field of an offer, naming the value it carried and what
// that field accepts.
func Field(field, value, expected string) error {
	return &FieldError{Field: field, Value: value, Expected: expected}
}

// maximumNamedValues bounds how many accepted values one refusal reads back.
// Eight is the cap the evidence corrections already use: past that a list stops
// being a menu and starts being a wall.
const maximumNamedValues = 8

// List renders the values a field accepts. Each is bounded individually because
// some of these lists are configuration rather than a fixed vocabulary, and
// what the cap dropped is counted rather than silently lost.
func List(values []string) string {
	shown := make([]string, 0, maximumNamedValues)
	kept := 0
	for _, value := range values {
		if value = core.BoundedText(strings.TrimSpace(value), 120); value == "" {
			continue
		}
		kept++
		if len(shown) < maximumNamedValues {
			shown = append(shown, value)
		}
	}
	if kept == 0 {
		return "none"
	}
	list := strings.Join(shown, ", ")
	if kept > len(shown) {
		list += " and " + strconv.Itoa(kept-len(shown)) + " more"
	}
	return list
}

// Control is a thing an operator clicks. The value is how the notice names it,
// so it reads as the operator saw it rather than as the handler is spelled.
type Control string

const (
	PreferenceConfirmation Control = "preference confirmation"
	RuleConfirmation       Control = "standing-rule confirmation"
	MemoryConfirmation     Control = "memory confirmation"
	ScheduleConfirmation   Control = "schedule confirmation"
	PreferenceSwitch       Control = "preference switch"
	ScheduleSwitch         Control = "schedule switch"
)

// Cause is why the host will not honour a click. The host always knows which
// of these it is; until 2026-08-16 it never said.
type Cause string

const (
	// Unreadable covers a payload that will not decode and one from an older
	// version of the host. Both mean the same thing to the person clicking:
	// this button is not one this Responder can act on.
	Unreadable Cause = "unreadable"
	// OtherChannel is a button whose payload names a different conversation.
	OtherChannel Cause = "other_channel"
	// Expired is a button past its lifetime.
	Expired Cause = "expired"
	// Undated is a payload whose issue time is missing or in the future, so
	// the host cannot tell whether it is expired.
	Undated Cause = "undated"
	// Gone is a button whose subject is no longer waiting: the proposal behind
	// it has been accepted, replaced, or has lapsed.
	Gone Cause = "gone"
)

// Click is a decoded confirmation payload and what the host knows about the
// click that carried it.
//
// The classification lives beside the wording on purpose: a cause with no
// sentence, or a sentence no cause can reach, is then impossible to write.
type Click struct {
	// DecodeErr is whatever reading the payload returned.
	DecodeErr error
	// Version is the payload's version; the host issues and honours one.
	Version int
	// PayloadChannel is the channel the offer was made in, InputChannel the
	// one the click came from. They differ when a button is shared or when a
	// message is read in two places.
	PayloadChannel string
	InputChannel   string
	SourceRef      string
	IssuedAt       time.Time
	Now            time.Time
	MaxAge         time.Duration
}

// Cause says which check on the payload failed, and nothing about the person
// who clicked it.
//
// This was one boolean OR across five different situations, and every one of
// them reached the operator as "invalid or stale". They are not the same
// problem and they do not have the same fix: a payload from an older host needs
// the offer made again, a payload from another channel needs the click to
// happen where the offer was made, and a day-old button needs nothing but a
// fresh one. The host has always known which; it just never said.
//
// The clock allowance stays. Slack round-trips a click through the operator's
// browser, and a payload stamped a moment in the future is a clock, not a
// forgery.
func (c Click) Cause() (Cause, bool) {
	switch {
	case c.DecodeErr != nil || c.Version != 1 || c.SourceRef == "":
		return Unreadable, true
	case c.PayloadChannel == "" || c.PayloadChannel != c.InputChannel:
		return OtherChannel, true
	case c.IssuedAt.IsZero() || c.IssuedAt.After(c.Now.Add(5*time.Minute)):
		return Undated, true
	case c.Now.Sub(c.IssuedAt) > c.MaxAge:
		return Expired, true
	}
	return "", false
}

// control carries the words that vary per control: who to ask, what did not
// happen, and what to do instead.
type control struct{ actor, effect, repair string }

var controls = map[Control]control{
	PreferenceConfirmation: {
		"Responder", "Nothing was saved",
		"ask Responder to apply the preference again and use the new button",
	},
	RuleConfirmation: {
		"Responder", "Nothing was saved",
		"ask Responder to set the rule up again and use the new button",
	},
	MemoryConfirmation: {
		"Responder", "Nothing was saved",
		"ask Responder to propose it again and use the new button",
	},
	ScheduleConfirmation: {
		"Emisar", "Nothing was saved",
		"ask Emisar to schedule it again and use the new button",
	},
	PreferenceSwitch: {
		"Responder", "Nothing changed",
		"open the preference list again and use the switch there",
	},
	ScheduleSwitch: {
		"Emisar", "Nothing changed",
		"open the schedule list again and use the switch there",
	},
}

// Stale is the operator-facing notice for a click the host will not honour.
//
// Plain, short, and never the person's fault: they clicked a button the host
// put in front of them, and the only useful thing to say is which button it
// was, what happened to it, and what to do now.
func Stale(name Control, cause Cause) string {
	words, known := controls[name]
	if !known {
		words = control{"Responder", "Nothing changed", "try again from the current message"}
	}
	headline := "This " + string(name) + " is no longer usable."
	switch cause {
	case Unreadable:
		headline = words.actor + " could not read this " + string(name) + "."
	case OtherChannel:
		headline = "This " + string(name) + " belongs to another channel."
	case Expired:
		headline = "This " + string(name) + " expired after a day."
	case Undated:
		headline = words.actor + " could not tell when this " + string(name) + " was made."
	case Gone:
		headline = "This " + string(name) + " expired or was already used."
	}
	return "*" + headline + "* " + words.effect + " — " + words.repair + "."
}
