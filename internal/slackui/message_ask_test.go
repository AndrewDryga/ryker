package slackui

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
)

// operatorAsk is a real request's shape: long, and carrying the commit the work
// starts from. The card that prompted this round quoted one of these whole.
const operatorAsk = "Fix the reload-driven OOM introduced by " +
	"deadbeefcafebabefeedfacedeadbeefcafebabe and confirm against " +
	"0123456789abcdef0123456789abcdef01234567 before the rollout, then raise " +
	"Traefik memory from 4096 to 8192 MiB, keep five replicas, add RSS and swap " +
	"and reload-rate alerts, and document the rollout checks in the runbook."

func askCard(t *testing.T, ask string, expanded bool) Message {
	t.Helper()
	compose := IncidentCardWithPublication
	if expanded {
		compose = IncidentCardWithAskExpanded
	}
	return compose(
		taskFixture(), "Tenant Infrastructure",
		[]core.Signal{{Status: core.SignalFiring, Summary: ask}},
		false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
}

func askRow(t *testing.T, card Message) Row {
	t.Helper()
	for _, row := range card.Rows {
		for _, action := range row.Actions {
			if action.ID == ActionFullRequest {
				return row
			}
		}
	}
	t.Fatalf("the card has no ask row: %+v", card)
	return Row{}
}

// The lede is cut on a word and says that it cut.
//
// It used to be truncateUTF8(..., 180): a byte bound with no ellipsis and no
// word boundary, so a trimmed request ended mid-token and read as corrupted
// rather than as shortened, and 180 bytes was never the "two lines" the design
// beside it claimed.
func TestTheAskLedeIsCutOnAWordAndSaysSo(t *testing.T) {
	row := askRow(t, askCard(t, operatorAsk, false))

	if !strings.HasPrefix(row.Text, "> ") {
		t.Fatalf("the ask is not quoted: %q", row.Text)
	}
	lede := strings.TrimPrefix(row.Text, "> ")
	if !strings.HasSuffix(lede, "…") {
		t.Fatalf("a cut ask does not say it was cut: %q", lede)
	}
	if runes := utf8.RuneCountInString(lede); runes > askLedeRunes {
		t.Fatalf("the lede runs %d runes, over the %d it is allowed", runes, askLedeRunes)
	}
	// Cut on a word: the last thing before the ellipsis is a whole token.
	if strings.HasSuffix(strings.TrimSuffix(lede, "…"), " ") {
		t.Fatalf("the cut left a trailing space: %q", lede)
	}
	body := strings.TrimSuffix(lede, "…")
	if !strings.Contains(operatorAsk, body[strings.LastIndex(body, " ")+1:]) {
		t.Fatalf("the lede ends mid-token: %q", lede)
	}
	// Short asks are quoted whole, with nothing claiming they were trimmed.
	short := askRow(t, askCard(t, "Bump the memory limit.", false))
	if short.Text != "> Bump the memory limit." {
		t.Fatalf("a short ask was altered: %q", short.Text)
	}
}

// A full git object id is one unbreakable token. Slack cannot wrap inside it,
// so it reserves a whole line's width and drags the quote down with it — which
// is how a 180-character lede rendered as five lines and pushed the card's
// buttons under "Show more". Shortened on the card, whole everywhere else.
func TestTheAskLedeShortensCommitSHAsAndTheExpandedAskDoesNot(t *testing.T) {
	lede := askRow(t, askCard(t, operatorAsk, false)).Text

	for _, whole := range []string{
		"deadbeefcafebabefeedfacedeadbeefcafebabe",
		"0123456789abcdef0123456789abcdef01234567",
	} {
		if strings.Contains(lede, whole) {
			t.Fatalf("the lede carries a whole SHA: %q", lede)
		}
		if !strings.Contains(lede, whole[:12]) {
			t.Fatalf("the lede dropped the SHA instead of shortening it: %q", lede)
		}
	}
	// Nothing left in the lede is long enough to force a wrap on its own.
	for _, token := range strings.Fields(strings.TrimPrefix(lede, "> ")) {
		if utf8.RuneCountInString(token) > 20 {
			t.Fatalf("the lede carries an unbreakable %d-rune token %q",
				utf8.RuneCountInString(token), token)
		}
	}

	// The expanded view is reference material, and a shortened revision is not a
	// revision. It keeps every id whole.
	expanded := askRow(t, askCard(t, operatorAsk, true)).Text
	if !strings.Contains(expanded, "deadbeefcafebabefeedfacedeadbeefcafebabe") {
		t.Fatalf("the expanded ask shortened a SHA: %q", expanded)
	}
}

// The toggle swaps the row's text and the button under it, together. A view
// that changed one without the other would offer "Collapse" over a lede.
func TestTheAskRowTogglesTextAndButtonTogether(t *testing.T) {
	collapsed := askRow(t, askCard(t, operatorAsk, false))
	expanded := askRow(t, askCard(t, operatorAsk, true))

	if collapsed.Actions[0].Label != "Full request" ||
		collapsed.Actions[0].Value != FullRequestActionValue(taskFixture().ID, true) {
		t.Fatalf("collapsed control = %+v", collapsed.Actions[0])
	}
	if expanded.Actions[0].Label != "Collapse" ||
		expanded.Actions[0].Value != FullRequestActionValue(taskFixture().ID, false) {
		t.Fatalf("expanded control = %+v", expanded.Actions[0])
	}
	if !strings.Contains(expanded.Text, "document the rollout checks in the runbook") {
		t.Fatalf("the expanded ask is not the whole request: %q", expanded.Text)
	}
	if strings.Contains(collapsed.Text, "document the rollout checks in the runbook") {
		t.Fatalf("the collapsed ask is not a lede: %q", collapsed.Text)
	}
	// Every line of the expanded ask stays inside the quote, or a request with
	// structure in it reads half as the card talking.
	multi := askRow(t, askCard(t, "Do this:\nfirst step\nsecond step", true))
	for _, line := range strings.Split(multi.Text, "\n") {
		if !strings.HasPrefix(line, "> ") {
			t.Fatalf("a line of the expanded ask left the quote: %q", multi.Text)
		}
	}
}

// The card's buttons have to sit above Slack's "Show more" fold, and the only
// thing that decides that is how much text is above them. The block-count
// budget beside this cannot see it: a card can stay at eleven blocks and still
// be twice as tall.
//
// The number: this fixture is the busiest state a task can legally reach — a
// failed publication, a failing check, a delivery failure, a blocker, a latest
// update and the ask — and it measures 467 bytes of section and row text. The
// same fixture measured 492 before the ask lede was capped on a word and its
// commit SHAs shortened, and it was that version, wrapping the quote to five
// lines, that the operator screenshotted with the action row folded away. 500
// is the measured busiest plus one short sentence of headroom; a new
// unconditional section, or an ask that stops being bounded at the composition
// site, breaks it immediately.
func TestTheBusiestTaskCardKeepsItsButtonsAboveTheFold(t *testing.T) {
	const budget = 500

	task := taskFixture()
	task.LastError = "The readiness gate needs a repository validation command."
	task.LatestUpdate = "Raised the allocation memory and added the two alert rules."
	card := IncidentCardWithPublication(
		task, "Tenant Infrastructure",
		[]core.Signal{{Status: core.SignalFiring, Summary: operatorAsk}},
		true, true,
		core.Publication{
			State: core.PublicationFailed, PRNumber: 482,
			PRURL:     "https://github.example/owner/repository/pull/482",
			LastError: "GitHub rejected the branch update.",
		},
		core.PublicationFollowup{ChecksState: "failing"},
		core.PublicationLifecycleEvent{
			ID: "delivery-1", Kind: "terraform", State: "failed",
			Summary: "Terraform apply failed for the next staged hostname.",
		},
	)

	total := 0
	for _, section := range card.Sections {
		total += len(section)
	}
	for _, row := range card.Rows {
		total += len(row.Text)
	}
	if total > budget {
		t.Fatalf("the busiest task card renders %d bytes of text, over the %d "+
			"that keeps its buttons above the fold", total, budget)
	}
	// The guard is only meaningful while the card still carries its controls.
	if len(card.Actions) == 0 || len(card.Rows) != 1 {
		t.Fatalf("the fixture stopped being the busiest card: %+v", card)
	}
}

// Expansion is bounded too. The whole ask is reference material, not licence to
// post twenty kilobytes of pasted log into a channel as one block.
func TestTheExpandedAskIsBounded(t *testing.T) {
	huge := strings.Repeat("reload the allocation and watch the resident set grow ", 400)
	row := askRow(t, askCard(t, huge, true))

	if len(row.Text) > askExpandedBytes {
		t.Fatalf("the expanded ask runs %d bytes, over the %d it is allowed",
			len(row.Text), askExpandedBytes)
	}
	// Still under what the sanitizer would cut, so the bound is this file's
	// decision rather than a silent trim somewhere downstream.
	if sanitized := NewSanitizer(12000).Message(askCard(t, huge, true)); len(
		askRow(t, sanitized).Text,
	) != len(row.Text) {
		t.Fatal("the sanitizer had to cut the expanded ask, so the bound is not honest")
	}
}
