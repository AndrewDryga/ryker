package changeledger_test

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
)

func at(minutesAgo int) time.Time {
	return time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC).
		Add(-time.Duration(minutesAgo) * time.Minute)
}

var now = at(0)

func recorded(t *testing.T, event core.ChangeEvent) core.ChangeEvent {
	t.Helper()
	stored, ok := changeledger.Record(event)
	if !ok {
		t.Fatalf("a well-formed %s change was refused", event.Kind)
	}
	return stored
}

// Every one of the three ingest paths is at-least-once. A webhook redelivers,
// the publication poll cursor rewinds on restart recovery, and the approval
// watcher reads the same terminal run again after a lost response — so a
// generated row id would put a duplicate in front of the model for every
// delivery the network repeated, in the one section whose whole job is to say
// how many things changed. The identity is the source's own, and the row id is
// derived from it so that ingestion is idempotent by construction rather than
// by three adapters each remembering to be.
func TestARedeliveredChangeKeepsTheIdentityItsSourceGaveIt(t *testing.T) {
	first := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-1",
		Kind: changeledger.KindDeploy, OccurredAt: at(5),
		Summary: "checkout v41",
	})
	// The same delivery arriving again, normalized differently by the sender:
	// a later received-at, extra whitespace, a summary that gained a word.
	second := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "  evt-1  ",
		Kind: changeledger.KindDeploy, OccurredAt: at(4),
		Summary: "checkout v41 (retry)",
	})
	if first.ID != second.ID {
		t.Fatalf("a redelivery took a new identity: %q then %q", first.ID, second.ID)
	}
	other := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-2",
		Kind: changeledger.KindDeploy, OccurredAt: at(5),
	})
	if other.ID == first.ID {
		t.Fatalf("two distinct deliveries collapsed onto %q", other.ID)
	}
	// A different route is a different ledger source even for the same event
	// id, because two senders have no shared id space to collide in.
	elsewhere := recorded(t, core.ChangeEvent{
		Source: "webhook:flags", SourceIdentity: "evt-1",
		Kind: changeledger.KindFlag, OccurredAt: at(5),
	})
	if elsewhere.ID == first.ID {
		t.Fatalf("two routes collided on identity %q", first.ID)
	}
}

// The kind vocabulary is closed because the prompt explains each member, and a
// kind the prompt cannot explain is a word the model interprets for itself. A
// mapping typo must fail at ingest, where an operator can still see it, rather
// than reach a prompt as an unexplained noun.
func TestAChangeOutsideTheKindVocabularyIsNeverRecorded(t *testing.T) {
	for _, kind := range []string{"", "rollback", "Deploy", "deployment"} {
		if _, ok := changeledger.Record(core.ChangeEvent{
			Source: "webhook:deploys", SourceIdentity: "evt-1",
			Kind: kind, OccurredAt: at(5),
		}); ok {
			t.Errorf("kind %q was accepted into the ledger", kind)
		}
	}
	// The identity halves are equally load-bearing: without both, the row id is
	// not a function of anything the source can repeat.
	for _, event := range []core.ChangeEvent{
		{Source: "", SourceIdentity: "evt-1", Kind: changeledger.KindDeploy, OccurredAt: at(5)},
		{Source: "webhook:deploys", SourceIdentity: "", Kind: changeledger.KindDeploy, OccurredAt: at(5)},
		{Source: "webhook:deploys", SourceIdentity: "evt-1", Kind: changeledger.KindDeploy},
	} {
		if _, ok := changeledger.Record(event); ok {
			t.Errorf("an unidentifiable change was accepted: %+v", event)
		}
	}
}

// A change event is a hint inside a prompt, and the budget assembler drops the
// whole layer as one unit. An unbounded summary from a webhook body would
// therefore evict the live evidence beside it rather than being trimmed, so the
// bound is applied where the row is created rather than where it is rendered.
func TestAnUnboundedChangeBodyCannotEvictTheLayersBesideIt(t *testing.T) {
	stored := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-1",
		Kind: changeledger.KindDeploy, OccurredAt: at(5),
		Summary:  strings.Repeat("a", 5000),
		Actor:    strings.Repeat("b", 5000),
		Services: []string{strings.Repeat("c", 5000)},
	})
	if len(stored.Summary) > changeledger.MaxSummary {
		t.Errorf("summary kept %d bytes, over the %d bound", len(stored.Summary), changeledger.MaxSummary)
	}
	if len(stored.Actor) > changeledger.MaxActor {
		t.Errorf("actor kept %d bytes, over the %d bound", len(stored.Actor), changeledger.MaxActor)
	}
	if len(stored.Services[0]) > changeledger.MaxScopeRef {
		t.Errorf("service ref kept %d bytes, over the %d bound", len(stored.Services[0]), changeledger.MaxScopeRef)
	}
}

// The scoping query, which is the whole feature: a change reaches a prompt only
// because something named it. Recalling by window alone would put every deploy
// in the estate in front of every incident, and the section that is supposed to
// shorten time-to-cause would be the section that lengthens it.
func TestAChangeIsRecalledOnlyByAScopeThatNamesIt(t *testing.T) {
	checkout := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-checkout",
		Kind: changeledger.KindDeploy, OccurredAt: at(20),
		Services: []string{"checkout"}, Summary: "checkout v41",
	})
	billing := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-billing",
		Kind: changeledger.KindDeploy, OccurredAt: at(10),
		Services: []string{"billing"}, Summary: "billing v9",
	})
	byRepository := recorded(t, core.ChangeEvent{
		Source: changeledger.SourcePublication, SourceIdentity: "lifecycle-1",
		Kind: changeledger.KindMerge, OccurredAt: at(30),
		Repositories: []string{"acme/api"}, Summary: "merged #14",
	})
	candidates := []core.ChangeEvent{checkout, billing, byRepository}

	scope := changeledger.ScopeFrom("acme/api", nil, []string{"checkout"})
	selected := changeledger.Select(candidates, scope, now, 6*time.Hour, 10)
	if len(selected) != 2 {
		t.Fatalf("selected %d changes, want the checkout deploy and the repository merge: %+v",
			len(selected), selected)
	}
	if selected[0].ChangeID != checkout.ID || selected[1].ChangeID != byRepository.ID {
		t.Fatalf("selection was not newest-first over the matching changes: %+v", selected)
	}
	// Billing was in the window and was not recalled, because nothing about
	// this incident named it.
	for _, entry := range selected {
		if entry.ChangeID == billing.ID {
			t.Fatal("a change no scope named was recalled anyway")
		}
	}
	// And the model is told which scope did the selecting, because "the
	// repository every service shares" and "the service you just probed" are
	// very different reasons to look at a change.
	if len(selected[0].MatchedOn) == 0 || !strings.Contains(selected[0].MatchedOn[0], "checkout") {
		t.Fatalf("the recalled change does not say why it was selected: %+v", selected[0].MatchedOn)
	}
}

// A turn that implicates nothing must recall nothing. Treating an empty scope
// as "match everything" is the failure that turns this layer into noise: the
// conversational lane resolves no repository at all, and the whole estate's
// deploys would land in a prompt answering "what does this flag do".
func TestATurnThatImplicatesNothingRecallsNoChanges(t *testing.T) {
	candidates := []core.ChangeEvent{recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "evt-1",
		Kind: changeledger.KindDeploy, OccurredAt: at(5),
		Services: []string{"checkout"},
	})}
	empty := changeledger.ScopeFrom("", nil, nil)
	if !empty.Empty() {
		t.Fatalf("a scope built from nothing is not empty: %+v", empty)
	}
	if selected := changeledger.Select(candidates, empty, now, 6*time.Hour, 10); len(selected) != 0 {
		t.Fatalf("an unscoped turn recalled %d changes", len(selected))
	}
}

// The window is the difference between "what changed before this broke" and a
// list of everything that ever shipped. A change from yesterday correlates with
// nothing and costs the budget a live evidence record.
func TestAChangeOlderThanTheWindowIsNotRecalled(t *testing.T) {
	inside := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "fresh",
		Kind: changeledger.KindDeploy, OccurredAt: at(359),
		Services: []string{"checkout"},
	})
	stale := recorded(t, core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: "stale",
		Kind: changeledger.KindDeploy, OccurredAt: at(361),
		Services: []string{"checkout"},
	})
	scope := changeledger.ScopeFrom("", nil, []string{"checkout"})
	selected := changeledger.Select(
		[]core.ChangeEvent{inside, stale}, scope, now, 6*time.Hour, 10,
	)
	if len(selected) != 1 || selected[0].ChangeID != inside.ID {
		t.Fatalf("the window did not hold: %+v", selected)
	}
	if selected[0].Age != "5h59m ago" {
		t.Fatalf("age reads %q, which is not how an operator would say it", selected[0].Age)
	}
}

// The cap keeps the newest, because a busy deploy hour is exactly when the
// section matters and exactly when it would otherwise take the whole budget.
func TestTheCapKeepsTheNewestChangesRatherThanTheFirstFound(t *testing.T) {
	var candidates []core.ChangeEvent
	for minute := 1; minute <= 20; minute++ {
		candidates = append(candidates, recorded(t, core.ChangeEvent{
			Source: "webhook:deploys", SourceIdentity: "evt-" + strings.Repeat("x", minute),
			Kind: changeledger.KindDeploy, OccurredAt: at(minute),
			Services: []string{"checkout"},
		}))
	}
	scope := changeledger.ScopeFrom("", nil, []string{"checkout"})
	selected := changeledger.Select(candidates, scope, now, 6*time.Hour, 3)
	if len(selected) != 3 {
		t.Fatalf("the cap let %d changes through", len(selected))
	}
	if selected[0].Age != "1m ago" || selected[2].Age != "3m ago" {
		t.Fatalf("the cap kept the wrong three: %q, %q, %q",
			selected[0].Age, selected[1].Age, selected[2].Age)
	}
}

// Scope resolution has to work at both ends of an investigation. A turn starts
// knowing only which repository the channel is bound to; by the time the model
// has probed two services the evidence names them, and the same query has to
// return the changes that are actually about this incident rather than
// everything the repository ever shipped.
func TestEvidenceTargetsNarrowTheScopeAnIncidentStartedWith(t *testing.T) {
	scope := changeledger.ScopeFrom(
		"Acme/API",
		[]core.Signal{{Labels: map[string]string{"service": "Checkout", "cluster": "prod-eu"}}},
		[]string{"payments"},
	)
	if !contains(scope.Repositories, "acme/api") {
		t.Errorf("the channel's repository binding did not reach the scope: %+v", scope.Repositories)
	}
	if !contains(scope.Services, "checkout") {
		t.Errorf("the alert's service label did not reach the scope: %+v", scope.Services)
	}
	if !contains(scope.Services, "payments") {
		t.Errorf("an evidence target did not reach the scope: %+v", scope.Services)
	}
	// cluster and namespace name a place, not a thing that gets deployed.
	// Matching on them would recall every change in the estate.
	if contains(scope.Services, "prod-eu") {
		t.Errorf("a location label was treated as a service: %+v", scope.Services)
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
