// Package changeledger owns what counts as a change, how an ingested one is
// made safe to store, and which recorded changes a turn is shown.
//
// It is a package rather than a corner of the service because none of that
// needs a database, a Slack client or a Coop session, and because three
// unrelated adapters — a webhook route, the publication follower, and the
// Emisar approval watcher — have to agree on the answer. A second copy of "is
// this kind valid" is a second place for one of them to start recording
// something the prompt has no words for.
package changeledger

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The bounded kind vocabulary. It is closed on purpose: the prompt explains
// what each of these means, and a kind the prompt cannot explain is a word the
// model will interpret for itself.
const (
	KindDeploy     = "deploy"
	KindMerge      = "merge"
	KindInfraApply = "infra_apply"
	KindFlag       = "flag"
	KindConfig     = "config"
)

// The adapter names that may appear in ChangeEvent.Source. A webhook source is
// "webhook:<route>" so an operator reading the ledger can tell which of several
// configured routes produced a row.
const (
	SourcePublication  = "publication"
	SourceEmisar       = "emisar"
	SourceWebhoookRoot = "webhook:"
)

// Bounds on what one row may carry. A change event is a hint in a prompt, so
// every free-text field is capped where it is created rather than where it is
// rendered: an unbounded summary from a webhook body would otherwise reach the
// budget assembler as one indivisible section and evict the layers beside it.
const (
	MaxSummary   = 400
	MaxActor     = 120
	MaxSourceRef = 500
	MaxRevision  = 120
	MaxScopeRefs = 12
	MaxScopeRef  = 120
)

func ValidKind(value string) bool {
	switch value {
	case KindDeploy, KindMerge, KindInfraApply, KindFlag, KindConfig:
		return true
	default:
		return false
	}
}

// Record normalizes an ingested change and reports whether it may be stored.
//
// Every adapter goes through here, and the identity discipline is the reason.
// The row's primary key is derived from source and source identity rather than
// generated, so an at-least-once webhook redelivery, a poll cursor rewound by
// restart recovery, and an approval watcher that reads the same terminal run
// twice all address the same row instead of writing a second one. Ingestion
// that is idempotent by construction needs no adapter to remember to be.
//
// A change with no scope at all is still recorded. The ledger is a record
// before it is an index, and a row nothing can recall is better than a silent
// drop an operator would have to read the code to discover — but it is also
// why Select can honestly return nothing for a busy hour.
func Record(event core.ChangeEvent) (core.ChangeEvent, bool) {
	event.Source = strings.TrimSpace(event.Source)
	event.SourceIdentity = strings.TrimSpace(event.SourceIdentity)
	event.Kind = strings.TrimSpace(event.Kind)
	if event.Source == "" || event.SourceIdentity == "" ||
		!ValidKind(event.Kind) || event.OccurredAt.IsZero() {
		return core.ChangeEvent{}, false
	}
	event.ID = EventID(event.Source, event.SourceIdentity)
	event.OccurredAt = event.OccurredAt.UTC()
	event.Services = normalizeRefs(event.Services)
	event.Repositories = normalizeRefs(event.Repositories)
	event.Actor = core.TruncateUTF8(strings.TrimSpace(event.Actor), MaxActor)
	event.Summary = core.TruncateUTF8(collapseSpace(event.Summary), MaxSummary)
	event.SourceRef = core.TruncateUTF8(strings.TrimSpace(event.SourceRef), MaxSourceRef)
	event.Revision = core.TruncateUTF8(strings.TrimSpace(event.Revision), MaxRevision)
	return event, true
}

// EventID is the row's identity, and it is a function of the source's own
// identity rather than a fresh identifier. See Record.
func EventID(source, identity string) string {
	sum := sha256.Sum256([]byte(source + "\x00" + identity))
	return "chg_" + hex.EncodeToString(sum[:])[:32]
}

// FromEmisarApproval is the change a finished Emisar run amounts to.
//
// Only a successful run, because a validation failure or an unknown action
// changed nothing and listing it under "what changed" is worse than silence.
// Every row in emisar_approvals is a governed mutation by construction —
// read-only inspection never reaches the approval gate — so reaching a terminal
// success here is exactly the definition of something having been changed.
//
// Immutable references only, per the Emisar client discipline: the run,
// operation, action, pack and runner are identifiers Emisar issued and will
// still resolve later, and the run URL is the same-origin permalink an operator
// opens to check the claim. Nothing here is re-derived from run output, which
// is untrusted data.
//
// The scope is the channel's repository, because that is what Responder
// actually knows. A run's action names an operation, not a service, and
// inventing a service name from it would put a confident wrong scope into the
// one query this feature is built around.
func FromEmisarApproval(
	approval core.EmisarApproval,
	repository string,
	at time.Time,
) (core.ChangeEvent, bool) {
	if approval.Status != "success" || approval.RunID == "" {
		return core.ChangeEvent{}, false
	}
	occurredAt := approval.TerminalAt
	if occurredAt.IsZero() {
		occurredAt = at
	}
	return Record(core.ChangeEvent{
		Source:         SourceEmisar,
		SourceIdentity: approval.RunID,
		// An approved Emisar action is a configuration change to something
		// running. It is deliberately not deploy: a deploy is a new revision of
		// code, and conflating the two would let a restart answer "what shipped
		// before this broke" with something that shipped nothing.
		Kind:         KindConfig,
		OccurredAt:   occurredAt,
		Repositories: []string{repository},
		Actor:        approval.RequestedBy,
		Summary:      "Emisar action " + approval.ActionID + " completed on runner " + approval.RunnerRef,
		SourceRef:    approval.RunURL,
		Revision:     approval.OperationID,
	})
}

// Scope is what a turn is about, in the terms a change event names itself in.
//
// Services and Repositories are separate because they match different columns
// and because the operator reading matched_on needs to know which one selected
// a change: a repository shared by every service in a one-repository
// deployment is a much weaker reason than a named service.
type Scope struct {
	Services     []string
	Repositories []string
}

func (s Scope) Empty() bool { return len(s.Services) == 0 && len(s.Repositories) == 0 }

// serviceLabels are the alert-label keys that name a service. A closed list,
// because "cluster" and "namespace" name a place rather than a thing that gets
// deployed, and matching on those would recall every change in the estate.
var serviceLabels = []string{"service", "app", "application", "job", "deployment"}

// ScopeFrom resolves what an incident implicates from the three things the host
// already knows: the channel's repository binding, the firing alert's labels,
// and the target identities of the evidence gathered so far.
//
// Evidence targets arrive last and matter most. A turn starts knowing only
// which repository the channel is bound to, which in a one-repository
// deployment selects everything; by the time the model has probed two services
// the scope names them, and the same query returns the changes that are
// actually about this incident.
func ScopeFrom(repository string, signals []core.Signal, evidenceTargets []string) Scope {
	scope := Scope{Repositories: []string{repository}}
	for _, signal := range signals {
		for _, key := range serviceLabels {
			scope.Services = append(scope.Services, signal.Labels[key])
		}
		scope.Repositories = append(scope.Repositories, signal.Repository)
	}
	// A target identity is free text an operation chose, so it is offered to
	// both sides rather than guessed at: "acme/api" should match a repository
	// and "checkout" a service, and nothing here knows which one it holds.
	scope.Services = append(scope.Services, evidenceTargets...)
	scope.Repositories = append(scope.Repositories, evidenceTargets...)
	scope.Services = normalizeRefs(scope.Services)
	scope.Repositories = normalizeRefs(scope.Repositories)
	return scope
}

// Select picks the changes a turn is shown, newest first.
//
// Filtering happens here rather than in SQL because scope is assembled from
// three sources of different freshness and a capped SQL query would have to cap
// before it could match — returning the ten newest changes in the estate and
// then discovering none of them are about this incident. The candidate window
// is small enough that reading it whole is cheaper than the join would be.
func Select(
	candidates []core.ChangeEvent,
	scope Scope,
	now time.Time,
	window time.Duration,
	limit int,
) []core.RecentChange {
	if limit <= 0 || window <= 0 || scope.Empty() {
		return nil
	}
	services := refSet(scope.Services)
	repositories := refSet(scope.Repositories)
	horizon := now.Add(-window)
	selected := make([]core.ChangeEvent, 0, len(candidates))
	reasons := make(map[string][]string, len(candidates))
	for _, candidate := range candidates {
		if !candidate.OccurredAt.After(horizon) {
			continue
		}
		matched := matchedOn(candidate, services, repositories)
		if len(matched) == 0 {
			continue
		}
		selected = append(selected, candidate)
		reasons[candidate.ID] = matched
	}
	sort.SliceStable(selected, func(left, right int) bool {
		if selected[left].OccurredAt.Equal(selected[right].OccurredAt) {
			return selected[left].ID < selected[right].ID
		}
		return selected[left].OccurredAt.After(selected[right].OccurredAt)
	})
	if len(selected) > limit {
		selected = selected[:limit]
	}
	entries := make([]core.RecentChange, 0, len(selected))
	for _, event := range selected {
		entries = append(entries, core.RecentChange{
			ChangeID:     event.ID,
			Kind:         event.Kind,
			Source:       event.Source,
			OccurredAt:   event.OccurredAt.UTC().Format(time.RFC3339),
			Age:          Age(now.Sub(event.OccurredAt)),
			MatchedOn:    reasons[event.ID],
			Services:     event.Services,
			Repositories: event.Repositories,
			Actor:        event.Actor,
			Summary:      event.Summary,
			Revision:     event.Revision,
			SourceRef:    event.SourceRef,
		})
	}
	return entries
}

// matchedOn says why a change was selected, naming the exact scope ref that did
// it. "matched the repository" and "matched service checkout" are different
// strengths of claim and the model is told which it has.
func matchedOn(event core.ChangeEvent, services, repositories map[string]bool) []string {
	var matched []string
	for _, service := range event.Services {
		if services[service] {
			matched = append(matched, "implicated service "+service)
		}
	}
	for _, repository := range event.Repositories {
		if repositories[repository] {
			matched = append(matched, "implicated repository "+repository)
		}
	}
	return matched
}

// Age is how long ago a change landed, in the words an operator would use.
//
// A change stamped in the future is a sender with a bad clock, not a prediction,
// and it reads as "just now" rather than as a negative duration — the prompt
// also carries the absolute timestamp, so nothing is hidden by saying it
// plainly.
func Age(since time.Duration) string {
	switch minutes := int(since.Round(time.Minute) / time.Minute); {
	case minutes <= 0:
		return "just now"
	case minutes < 60:
		return strconv.Itoa(minutes) + "m ago"
	case minutes < 60*24:
		return strconv.Itoa(minutes/60) + "h" + strconv.Itoa(minutes%60) + "m ago"
	default:
		return strconv.Itoa(minutes/(60*24)) + "d ago"
	}
}

func normalizeRefs(values []string) []string {
	seen := make(map[string]bool, len(values))
	normalized := make([]string, 0, len(values))
	for _, value := range values {
		ref := core.TruncateUTF8(strings.ToLower(collapseSpace(value)), MaxScopeRef)
		if ref == "" || seen[ref] {
			continue
		}
		seen[ref] = true
		normalized = append(normalized, ref)
		if len(normalized) == MaxScopeRefs {
			break
		}
	}
	sort.Strings(normalized)
	return normalized
}

func refSet(values []string) map[string]bool {
	set := make(map[string]bool, len(values))
	for _, value := range values {
		set[value] = true
	}
	return set
}

func collapseSpace(value string) string {
	return strings.Join(strings.Fields(value), " ")
}
