package offerreason

import (
	"errors"
	"strings"
	"testing"
	"time"
)

// A refusal is read by a model that has to repair one field, so the field, the
// value it sent, and the accepted set all have to survive into the sentence.
// The value is model text, so it is bounded — a refusal that quotes a runaway
// value back in full is a correction the model cannot read.
func TestAFieldRefusalNamesTheValueItRejectedAndBoundsIt(t *testing.T) {
	refusal := Field("name", "verbosity", "expected health_check_depth or response_detail")
	for _, want := range []string{"name", "verbosity", "health_check_depth"} {
		if !strings.Contains(refusal.Error(), want) {
			t.Fatalf("the refusal never named %q: %q", want, refusal.Error())
		}
	}
	if empty := Field("subject", "  ", "name what the memory is about").Error(); //
	!strings.Contains(empty, "empty") {
		t.Fatalf("a blank field was not reported as empty: %q", empty)
	}
	long := Field("value", strings.Repeat("x", 4000), "expected a setting").Error()
	if len(long) > 400 {
		t.Fatalf("an unbounded value became the whole refusal: %d bytes", len(long))
	}

	var named *FieldError
	if !errors.As(refusal, &named) || named.Field != "name" {
		t.Fatalf("the refusal cannot be read back as fields: %+v", named)
	}
}

// The accepted set is sometimes configuration rather than a fixed vocabulary —
// a deployment's repositories, for instance — and a list past eight stops being
// a menu the model can choose from. What the cap drops is counted, never
// silently lost.
func TestAnAcceptedSetIsCappedAndWhatItDroppedIsCounted(t *testing.T) {
	values := make([]string, 0, 12)
	for index := range 12 {
		values = append(values, string(rune('a'+index)))
	}
	list := List(values)
	if strings.Count(list, ",") != 7 || !strings.Contains(list, "4 more") {
		t.Fatalf("the accepted set was not capped at eight: %q", list)
	}
	if got := List([]string{"  ", ""}); got != "none" {
		t.Fatalf("an empty accepted set = %q, want none", got)
	}
}

// Every cause has to reach a different sentence, or the operator is back to one
// message for four situations. The control has to be named too: a person with
// two confirmation cards on screen cannot act on "this button".
func TestEveryStaleCauseSaysSomethingDifferentAndNamesTheControl(t *testing.T) {
	seen := map[string]bool{}
	for _, cause := range []Cause{Unreadable, OtherChannel, Expired, Undated, Gone} {
		notice := Stale(PreferenceConfirmation, cause)
		if seen[notice] {
			t.Fatalf("cause %q repeats another cause's notice: %q", cause, notice)
		}
		seen[notice] = true
		if !strings.Contains(notice, "preference confirmation") {
			t.Fatalf("cause %q does not name the control: %q", cause, notice)
		}
		if !strings.Contains(notice, "Nothing was saved") {
			t.Fatalf("cause %q does not say what did not happen: %q", cause, notice)
		}
	}
	// A switch changed nothing rather than saved nothing, and an unknown
	// control must still produce a sentence rather than a bare asterisk.
	if notice := Stale(ScheduleSwitch, Unreadable); !strings.Contains(notice, "Nothing changed") {
		t.Fatalf("a switch reported a save: %q", notice)
	}
	if notice := Stale(Control("mystery control"), Expired); !strings.Contains(
		notice, "mystery control",
	) {
		t.Fatalf("an unnamed control lost its notice: %q", notice)
	}
}

// The five situations a confirmation payload can be in are told apart here and
// nowhere else, so each one is checked against the envelope that produces it.
func TestAClickIsClassifiedByWhatActuallyFailed(t *testing.T) {
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)
	fresh := Click{
		Version: 1, PayloadChannel: "COPS", InputChannel: "COPS",
		SourceRef: "Ev1", IssuedAt: now.Add(-time.Hour), Now: now,
		MaxAge: 24 * time.Hour,
	}
	if cause, stale := fresh.Cause(); stale {
		t.Fatalf("a good click was refused as %q", cause)
	}
	for _, tc := range []struct {
		name  string
		click Click
		want  Cause
	}{
		{"a payload that will not decode", func() Click {
			c := fresh
			c.DecodeErr = errors.New("unknown field")
			return c
		}(), Unreadable},
		{"a payload from an older host", func() Click {
			c := fresh
			c.Version = 0
			return c
		}(), Unreadable},
		{"a click from another channel", func() Click {
			c := fresh
			c.InputChannel = "CELSEWHERE"
			return c
		}(), OtherChannel},
		{"a payload stamped in the future", func() Click {
			c := fresh
			c.IssuedAt = now.Add(time.Hour)
			return c
		}(), Undated},
		{"a button past its lifetime", func() Click {
			c := fresh
			c.IssuedAt = now.Add(-30 * time.Hour)
			return c
		}(), Expired},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cause, stale := tc.click.Cause()
			if !stale || cause != tc.want {
				t.Fatalf("cause = %q, %t; want %q", cause, stale, tc.want)
			}
		})
	}
}
