package slackui

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The delivery notification is coloured by what happened to the PR.
//
// The kinds and states in this table are the ones `publicationTransition` in
// internal/publication actually emits — it is the only caller — plus the two
// kinds the header switch names that nothing has ever emitted. Those two are
// mapped by state rather than left to a default, so the day something does
// emit one it inherits the same rule as everything else.
//
// Nothing here is amber. These report something that already happened on
// GitHub; Responder is not working on any of it, and amber would claim a
// custody nobody holds.
func TestPublicationLifecycleColoursFollowTheOutcome(t *testing.T) {
	for _, testCase := range []struct {
		name, kind, state   string
		checks              string
		stripe, glyph, word string
	}{
		{name: "merged", kind: "merged", state: "succeeded",
			stripe: StripeDone, glyph: "✅", word: "Merged"},
		{name: "closed unmerged", kind: "closed", state: "stopped",
			stripe: StripeIdle, glyph: "⏸", word: "Closed"},
		{name: "checks passed", kind: "checks", state: "succeeded",
			stripe: StripeDone, glyph: "✅", word: "Checks passed"},
		{name: "checks failed", kind: "checks", state: "failed",
			stripe: StripeFailed, glyph: "🛑", word: "Checks failed"},
		// A manual refresh is coloured by the PR's state, not by the fact that
		// somebody asked for it.
		{name: "refresh open", kind: "status", state: "open",
			stripe: StripeIdle, glyph: "🔀", word: "PR open"},
		{name: "refresh merged", kind: "status", state: "merged",
			stripe: StripeDone, glyph: "✅", word: "Merged"},
		{name: "refresh closed", kind: "status", state: "closed",
			stripe: StripeIdle, glyph: "⏸", word: "Closed"},
		// The one case where a readout is bad news, and it reads as bad news.
		{name: "refresh failing checks", kind: "status", state: "open", checks: "failing",
			stripe: StripeFailed, glyph: "🛑", word: "Failed"},
		{name: "terraform applied", kind: "terraform", state: "succeeded",
			stripe: StripeDone, glyph: "✅", word: "Done"},
		{name: "terraform errored", kind: "terraform", state: "errored",
			stripe: StripeFailed, glyph: "🛑", word: "Failed"},
		{name: "deployment failed", kind: "deployment", state: "failed",
			stripe: StripeFailed, glyph: "🛑", word: "Failed"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			message := PublicationLifecycleMessage(
				core.Publication{
					IncidentID: "inc_1", PRNumber: 42,
					PRURL: "https://github.example/pull/42",
				},
				"Update runtime packs",
				testCase.kind,
				testCase.state,
				"GitHub reported the change.",
				core.PublicationLifecycleStatus{
					ChecksState: testCase.checks, MergeSHA: strings.Repeat("a", 40),
				},
			)
			if message.Stripe != testCase.stripe {
				t.Errorf("stripe = %q, want %q", message.Stripe, testCase.stripe)
			}
			if !strings.HasPrefix(message.Header, testCase.glyph+" ") {
				t.Errorf("header = %q, want the %q glyph", message.Header, testCase.glyph)
			}
			if !strings.HasPrefix(message.Text, testCase.word+" — ") {
				t.Errorf("fallback = %q, want it to lead with %q", message.Text, testCase.word)
			}
			// The summary is composed by publicationTransition from typed
			// GitHub status. It is the one sentence this card exists to carry
			// and it arrives unedited.
			if len(message.Sections) != 1 ||
				message.Sections[0] != "GitHub reported the change." {
				t.Errorf("sections = %+v", message.Sections)
			}
			context := strings.Join(message.Context, "\n")
			if !strings.Contains(context, "Update runtime packs") ||
				!strings.Contains(context, "aaaaaaaaaaaa") {
				t.Errorf("context lost the task title or the merge commit: %q", context)
			}
			for _, action := range cardActions(message) {
				if !routedActionIDs[action.ID] {
					t.Errorf("lifecycle card offers %q, which no handler answers", action.ID)
				}
			}
		})
	}
}

// The publication receipt is one line and two controls.
//
// It used to spend a header, a linked line, a paragraph about lease protection
// and a boundary line listing four things Responder had not done — most of a
// screen to report that a PR now exists.
func TestPublicationReceiptStatesOneFactAndKeepsItsControls(t *testing.T) {
	message := PublicationMessage(core.Publication{
		IncidentID: "inc_1", PRNumber: 91,
		PRURL: "https://github.example/pull/91",
	}, false)
	if message.Header != "" || len(message.Sections) != 1 || message.Stripe != StripeDone {
		t.Fatalf("publication receipt = %+v", message)
	}
	if !strings.Contains(message.Sections[0], "<https://github.example/pull/91|Draft PR #91>") ||
		!strings.Contains(message.Sections[0], "is open") {
		t.Fatalf("receipt does not link the PR it is about: %q", message.Sections[0])
	}
	// And it states no boundary at all. "Lease-protected publication: …did not
	// merge, deploy, sign, or change review state" was the third statement of
	// the same fact in one flow — the publish control confirms with it, the PR
	// body carries it on GitHub, and this receipt said it again to somebody who
	// had just read both. It stays where it can still change a decision.
	if len(message.Context) != 0 {
		t.Fatalf("the receipt repeats a boundary the operator has already read twice: %+v",
			message.Context)
	}
	// Check delivery stays a button. It would belong in the ⋯ menu if overflow
	// options routed; they do not, so moving it there would retire a working
	// control. See routedActionIDs.
	ids := cardActionIDs(message)
	if len(ids) != 2 || ids[0] != ActionViewPR || ids[1] != ActionCheckDelivery {
		t.Fatalf("receipt controls = %+v", ids)
	}
	for _, action := range cardActions(message) {
		if !routedActionIDs[action.ID] {
			t.Fatalf("receipt offers %q, which no handler answers", action.ID)
		}
	}
	updated := PublicationMessage(core.Publication{PRNumber: 91, PRURL: "https://github.example/pull/91"}, true)
	if !strings.Contains(updated.Sections[0], "is updated") ||
		!strings.HasPrefix(updated.Text, "Done — Responder updated") {
		t.Fatalf("updated receipt = %+v", updated)
	}
}

// The readiness verdict is coloured, and it still refuses to invent a checklist.
//
// A green verdict reached by running every gate and a green verdict reached by
// skipping most of them are different claims, and this card cannot yet tell
// them apart — the per-check results are not carried to this constructor. The
// assertion is that it does not pretend otherwise: one section, the summary as
// it arrived, and no fabricated check names.
func TestReviewVerdictColoursCustodyAndInventsNoChecklist(t *testing.T) {
	incident := core.Incident{ID: "task_1", WorkKind: core.WorkKindEngineeringTask}
	ready := ReviewMessage(incident, "Repository gate passed. Rebase is clean.", true)
	if ready.Stripe != StripeDone || ready.Header != "✅ Ready for external review" {
		t.Fatalf("ready review = %+v", ready)
	}
	if len(ready.Sections) != 1 ||
		ready.Sections[0] != "Repository gate passed. Rebase is clean." {
		t.Fatalf("review rewrote or decomposed the summary: %+v", ready.Sections)
	}
	if !strings.Contains(strings.Join(ready.Context, "\n"), "Candidate tree pinned") {
		t.Fatalf("ready review lost its useful receipt: %+v", ready.Context)
	}
	notReady := ReviewMessage(incident, "The repository gate failed.", false)
	if notReady.Stripe != StripeNeedsYou || notReady.Header != "✋ Not ready for review" {
		t.Fatalf("not-ready review = %+v", notReady)
	}
	// The fallback leads with the state, not with a glyph.
	if !strings.HasPrefix(notReady.Text, "Not ready for review") {
		t.Fatalf("review fallback = %q", notReady.Text)
	}
}

// The run-check verdict is host-typed all the way through.
//
// Every string on this card is composed here from a typed field. That is the
// point of it: the most frequent operator-visible message Responder sends is a
// run check, and it ships today as a paragraph the model wrote about a
// notification it read.
func TestRunCheckVerdictStatesOutcomeBasisAndBoundary(t *testing.T) {
	for _, testCase := range []struct {
		outcome, stripe, glyph, word string
		wantsButton                  bool
	}{
		{RunCheckClean, StripeDone, "✅", "Clean", true},
		{RunCheckReview, StripeNeedsYou, "✋", "Needs you", true},
		{RunCheckFailed, StripeFailed, "🛑", "Failed", true},
		{RunCheckRunning, StripeWorking, "⚙️", "Running", true},
		{RunCheckStopped, StripeIdle, "⏸", "Stopped", true},
	} {
		t.Run(testCase.outcome, func(t *testing.T) {
			message := RunCheckVerdictMessage(RunCheckVerdict{
				Subject: "Terraform plan", Outcome: testCase.outcome,
				RunRef: "run-ABC123", RunURL: "https://app.terraform.io/runs/run-ABC123",
				Basis: []string{"tfc.run_details", "tfc.plan_summary"},
			})
			if message.Stripe != testCase.stripe {
				t.Errorf("stripe = %q, want %q", message.Stripe, testCase.stripe)
			}
			if !strings.HasPrefix(message.Header, testCase.glyph+" Checked Terraform plan") {
				t.Errorf("header = %q", message.Header)
			}
			if !strings.HasPrefix(message.Text, testCase.word+" — ") {
				t.Errorf("fallback = %q, want it to lead with %q", message.Text, testCase.word)
			}
			// The basis is the card's licence to be believed, and "read-only"
			// is why it was safe to run at all.
			context := strings.Join(message.Context, "\n")
			if !strings.Contains(context, "tfc.run_details · tfc.plan_summary") ||
				!strings.Contains(context, "read-only") ||
				!strings.Contains(context, "run `run-ABC123`") {
				t.Errorf("context = %q", context)
			}
			actions := cardActions(message)
			if len(actions) != 1 {
				t.Fatalf("verdict controls = %+v", actions)
			}
			if !routedActionIDs[actions[0].ID] {
				t.Errorf("verdict offers %q, which no handler answers", actions[0].ID)
			}
			if actions[0].URL == "" {
				t.Errorf("the verdict's only control must be a link: %+v", actions[0])
			}
			// One primary, earned: only the plan that is waiting on a person.
			if (actions[0].Style == "primary") != (testCase.outcome == RunCheckReview) {
				t.Errorf("primary style on %q: %+v", testCase.outcome, actions[0])
			}
		})
	}
	// A clean check states the boundary that makes it worth reading: the plan
	// finished and nothing entered apply.
	clean := RunCheckVerdictMessage(RunCheckVerdict{
		Subject: "Terraform plan", Outcome: RunCheckClean,
		Basis: []string{"tfc.run_details"},
	})
	if !strings.Contains(clean.Sections[0], "no material changes") ||
		!strings.Contains(clean.Sections[0], "Nothing entered apply") {
		t.Fatalf("clean verdict = %+v", clean.Sections)
	}
	// With no run link there is no control at all, rather than a button that
	// goes nowhere.
	if len(cardActions(clean)) != 0 {
		t.Fatalf("verdict invented a control without a link: %+v", cardActions(clean))
	}
	// A hostile subject cannot take the card with it.
	hostile := RunCheckVerdictMessage(RunCheckVerdict{
		Subject: "plan\nxoxb-0123456789abcdefghij", Outcome: RunCheckFailed,
	})
	if strings.Contains(cardText(hostile), "xoxb-") ||
		strings.Contains(hostile.Header, "\n") {
		t.Fatalf("verdict carried a credential or a line break: %+v", hostile)
	}
}
