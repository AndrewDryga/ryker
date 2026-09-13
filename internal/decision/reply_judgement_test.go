package decision_test

import (
	"testing"

	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
)

// The judge's numbers and the runtime's refusal have to be the same bar.
//
// The corpus records what the host does with each real reply: reject it for
// length, reject it for its closing, or post it. The measurement handed to a
// model judge has to reach the same verdict on all sixteen, or the eval loop
// starts disagreeing with production about which replies are acceptable, and an
// operator gets told two different things about one message.
//
// Length is checked before the closing in the correction, so a reply recorded
// as "length" may also carry a hand-back — the 245-word answer to "hi" does.
// What must never happen is the other direction: a reply the host posts must be
// clean on both axes here.
func TestReplyJudgementAgreesWithTheCorrection(t *testing.T) {
	counts := map[string]int{}
	for _, posted := range postedReplies {
		t.Run(posted.name, func(t *testing.T) {
			judged := decisionpkg.MeasureReply(posted.trigger, posted.lane, posted.reply, "", "")
			counts[posted.expect]++
			switch posted.expect {
			case "length":
				if !judged.OverWordBound {
					t.Fatalf(
						"the host rejects this for length and the judge is told %d words "+
							"against a bound of %d, which is inside it",
						judged.Words, judged.WordBound,
					)
				}
			case "handback":
				if judged.ClosingHandBack == "" {
					t.Fatal("the host rejects this closing and the judge is told nothing about it")
				}
				if judged.OverWordBound {
					t.Fatalf(
						"the judge is told this is over its %d-word bound at %d words, but the "+
							"host posts it at that length and rejects only the closing",
						judged.WordBound, judged.Words,
					)
				}
			default:
				if judged.OverWordBound {
					t.Fatalf(
						"the host posts this and the judge is told it runs %d words over a "+
							"bound of %d",
						judged.Words, judged.WordBound,
					)
				}
				if judged.ClosingHandBack != "" {
					t.Fatalf(
						"the host posts this and the judge is told it closes on %q",
						judged.ClosingHandBack,
					)
				}
			}
			if judged.WrongPlace {
				t.Error("no corpus reply records where it went, so none can be in the wrong place")
			}
		})
	}
	t.Logf(
		"%d posted replies: %d rejected for length, %d for their closing, %d posted as written",
		len(postedReplies), counts["length"], counts["handback"], counts[""],
	)
}

// A reply the operator asked for in a thread and got in the channel is the
// second complaint filed this week, and it was unrepresentable until now.
func TestReplyJudgementReadsWhereTheReplyBelonged(t *testing.T) {
	for _, test := range []struct {
		name       string
		trigger    string
		postedIn   string
		askedFor   string
		wantAsked  string
		wantWrong  bool
		wantPosted string
	}{
		{
			name:       "the trigger asked for a thread and the reply went to the channel",
			trigger:    "can you answer in thread from now on",
			postedIn:   "channel",
			wantAsked:  "thread",
			wantWrong:  true,
			wantPosted: "channel",
		},
		{
			name:       "the trigger asked for a thread and the reply went there",
			trigger:    "reply in this thread please",
			postedIn:   "thread",
			wantAsked:  "thread",
			wantPosted: "thread",
		},
		{
			name:       "an alert says nothing, so the case says it",
			trigger:    "Run notification for SME-Blitz/va1-apps Run Planned - Needs Confirmation",
			postedIn:   "channel",
			askedFor:   "thread",
			wantAsked:  "thread",
			wantWrong:  true,
			wantPosted: "channel",
		},
		{
			name: "an alert nobody routed is not wrong, only unknown",
			trigger: "Run notification for SME-Blitz/va1-apps Run Planned - " +
				"Needs Confirmation",
			postedIn:   "channel",
			wantPosted: "channel",
		},
		{
			name:      "a case that does not model delivery says nothing about it",
			trigger:   "stop posting in the channel",
			wantAsked: "thread",
		},
		{
			name:       "the case overrides an intent the trigger only implies",
			trigger:    "keep this in the channel",
			postedIn:   "channel",
			askedFor:   "thread",
			wantAsked:  "thread",
			wantWrong:  true,
			wantPosted: "channel",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			judged := decisionpkg.MeasureReply(
				test.trigger, "conversation", "A short answer.", test.postedIn, test.askedFor,
			)
			if judged.PostedIn != test.wantPosted {
				t.Errorf("posted in %q, want %q", judged.PostedIn, test.wantPosted)
			}
			if judged.AskedFor != test.wantAsked {
				t.Errorf("asked for %q, want %q", judged.AskedFor, test.wantAsked)
			}
			if judged.WrongPlace != test.wantWrong {
				t.Errorf("wrong place = %t, want %t", judged.WrongPlace, test.wantWrong)
			}
		})
	}
}

// A placement a corpus misspells has to fail loudly. Read as unknown it would
// leave the case still passing while asserting nothing about where the reply
// went, which is the exact blindness this work exists to remove.
func TestValidReplyPlacementRejectsAnythingElse(t *testing.T) {
	for _, valid := range []string{"", "thread", "channel"} {
		if !decisionpkg.ValidReplyPlacement(valid) {
			t.Errorf("%q is a placement a fixture may name", valid)
		}
	}
	for _, invalid := range []string{"threaded", "Thread", "top-level", "dm", " "} {
		if decisionpkg.ValidReplyPlacement(invalid) {
			t.Errorf("%q is not a place a Slack reply can land", invalid)
		}
	}
}

// A trigger that waives the bound has to waive it for the judge too, or the
// rubric caps directness on a reply that was asked to be long.
func TestReplyJudgementReportsAWaivedBound(t *testing.T) {
	long := ""
	for range 300 {
		long += "word "
	}
	judged := decisionpkg.MeasureReply("walk me through it in detail", "conversation", long, "", "")
	switch {
	case !judged.DepthRequested:
		t.Error("the trigger asked for depth and the judge is not told so")
	case judged.WordBound != 0:
		t.Errorf("bound is %d, want none for a trigger that waived it", judged.WordBound)
	case judged.OverWordBound:
		t.Error("a waived bound cannot be exceeded")
	}
}
