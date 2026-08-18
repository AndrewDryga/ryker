package slackui

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

// operatorAsk is a real request's shape: long, and carrying the commit the work
// starts from. The card that prompted this round quoted one of these whole.
const operatorAsk = "Fix the reload-driven OOM introduced by " +
	"deadbeefcafebabefeedfacedeadbeefcafebabe and confirm against " +
	"0123456789abcdef0123456789abcdef01234567 before the rollout, then raise " +
	"Traefik memory from 4096 to 8192 MiB, keep five replicas, add RSS and swap " +
	"and reload-rate alerts, and document the rollout checks in the runbook."

func askCard(t *testing.T, ask string) Message {
	t.Helper()
	return IncidentCardWithPublication(
		taskFixture(), "Tenant Infrastructure",
		[]core.Signal{{Status: core.SignalFiring, Summary: ask}},
		false, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
}

func requestTail(t *testing.T, card Message) string {
	t.Helper()
	for _, section := range card.Tail {
		if strings.HasPrefix(section, "*The request*") {
			return section
		}
	}
	t.Fatalf("the card has no request in its tail: %+v", card)
	return ""
}

// The request is on the card whole. It used to be a 160-rune lede with a button
// that swapped it for the rest, which spent a control, a round trip and a Slack
// edit on a job Slack does for itself: a long message folds behind "Show more".
func TestTheCardCarriesTheWholeRequestWithNoToggle(t *testing.T) {
	card := askCard(t, operatorAsk)
	tail := requestTail(t, card)

	if !strings.Contains(tail, "document the rollout checks in the runbook") {
		t.Fatalf("the card stops short of the whole request: %q", tail)
	}
	if strings.Contains(tail, "…") {
		t.Fatalf("the request was trimmed: %q", tail)
	}
	// Reference material keeps every id whole. The lede shortened them because
	// one 40-character token reserved a whole line on a block that had to stay
	// two lines tall, and that block is gone.
	for _, whole := range []string{
		"deadbeefcafebabefeedfacedeadbeefcafebabe",
		"0123456789abcdef0123456789abcdef01234567",
	} {
		if !strings.Contains(tail, whole) {
			t.Fatalf("the request shortened a commit id: %q", tail)
		}
	}
	// No control anywhere on the card offers to expand or collapse it.
	for _, action := range append(append([]Action{}, card.Actions...), card.Overflow...) {
		if action.ID == ActionFullRequest {
			t.Fatalf("the retired expand toggle is still rendered: %+v", action)
		}
	}
	for _, row := range card.Rows {
		for _, action := range append(append([]Action{}, row.Actions...), row.Overflow...) {
			if action.ID == ActionFullRequest {
				t.Fatalf("a row still offers the retired expand toggle: %+v", action)
			}
		}
	}
	// Every line stays inside the quote, or a request with structure in it
	// reads half as the card talking.
	multi := requestTail(t, askCard(t, "Do this:\nfirst step\nsecond step"))
	for _, line := range strings.Split(strings.TrimPrefix(multi, "*The request*\n"), "\n") {
		if !strings.HasPrefix(line, "> ") {
			t.Fatalf("a line of the request left the quote: %q", multi)
		}
	}
}

// The fold is the whole design: Slack hides what is at the bottom, so what is
// at the bottom has to be the one block nobody needs to see to act. Buttons
// above it, request below it, and nothing between the request and the end.
func TestTheRequestIsTheLastBlockAndTheButtonsComeFirst(t *testing.T) {
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
	if len(card.Actions) == 0 {
		t.Fatalf("the fixture stopped carrying controls: %+v", card)
	}

	blocks := card.Blocks()
	action, last := -1, len(blocks)-1
	for index, block := range blocks {
		if _, ok := block.(*slack.ActionBlock); ok && action < 0 {
			action = index
		}
	}
	if action < 0 {
		t.Fatalf("the card rendered no action block: %+v", blocks)
	}
	// header, state line, action needed, latest, delivery update, divider, then
	// the buttons. Asserted as a position rather than a pixel height: what the
	// fold can reach is decided by order, and order is the thing this file owns.
	const budget = 7
	if action > budget {
		t.Fatalf("the first action block is at position %d of %d, past the %d "+
			"that keeps it above the fold", action, len(blocks), budget)
	}
	// Everything the card states about the run — the ledger, the counters, the
	// footer — sits between the buttons and the request.
	section, ok := blocks[last].(*slack.SectionBlock)
	if !ok || section.Text == nil || !strings.HasPrefix(section.Text.Text, "*The request*") {
		t.Fatalf("the last block is not the request: %#v", blocks[last])
	}
	if _, ok := blocks[last-1].(*slack.ContextBlock); !ok {
		t.Fatalf("the block above the request is not the footer: %#v", blocks[last-1])
	}
}

// A two-hour production task card put its ledger and fork identity behind an
// outer attachment-level "Show more", then showed a second ⋯ beside the first.
// The request is the only reference material allowed to fold: the work state,
// ledger, fork and one consolidated overflow menu must be visible immediately.
func TestTheTaskCardLeavesOnlyTheRequestBehindShowMore(t *testing.T) {
	card := askCard(t, operatorAsk)

	if !card.TopLevelBlocks {
		t.Fatal("task card still requests collapsible attachment delivery")
	}
	if len(card.Rows) != 0 {
		t.Fatalf("task card still renders a second record control row: %+v", card.Rows)
	}
	menus := renderedOverflowMenus(t, card)
	if len(menus) != 1 {
		t.Fatalf("task card renders %d overflow menus, want one: %+v", len(menus), menus)
	}
	if len(card.Overflow) == 0 || card.Overflow[0].Label != "Work record" {
		t.Fatalf("the consolidated menu does not lead with the work record: %+v", card.Overflow)
	}
	blocks := card.Blocks()
	last := blocks[len(blocks)-1]
	section, ok := last.(*slack.SectionBlock)
	if !ok || section.Text == nil || !strings.HasPrefix(section.Text.Text, "*The request*") {
		t.Fatalf("the request is not the one last foldable block: %#v", last)
	}
}

// Bounded, because the card renders the request whole and a request can be a
// pasted twenty-kilobyte log. This is not a display opinion about how much is
// worth reading — it is the point past which Slack rejects the section and the
// whole delivery fails after the work is done.
func TestTheRequestIsBounded(t *testing.T) {
	huge := strings.Repeat("reload the allocation and watch the resident set grow ", 400)
	tail := requestTail(t, askCard(t, huge))

	if len(tail) > requestQuoteBytes+len("*The request*\n") {
		t.Fatalf("the request runs %d bytes, over the %d it is allowed",
			len(tail), requestQuoteBytes)
	}
	// Still under what the sanitizer would cut, so the bound is this file's
	// decision rather than a silent trim somewhere downstream.
	if sanitized := NewSanitizer(12000).Message(askCard(t, huge)); len(
		requestTail(t, sanitized),
	) != len(tail) {
		t.Fatal("the sanitizer had to cut the request, so the bound is not honest")
	}
}
