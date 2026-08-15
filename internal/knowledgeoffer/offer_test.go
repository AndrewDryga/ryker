package knowledgeoffer

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
)

var recordedAction = remediation.ActionRef{
	ActionID:  "nomad.job.restart",
	PackRef:   "nomad@1.4.0+sha256:1111",
	RunnerRef: "prod~7f3c",
}

func verifiedEpisode() Episode {
	return Episode{
		EpisodeID:    "episode_1",
		Verified:     true,
		RootCause:    "The allocation lost its Consul registration after the node drained.",
		Verification: "Error rate returned to baseline for twenty minutes after the restart.",
		Actions:      []remediation.ActionRef{recordedAction},
	}
}

func runbookOffer() core.RunbookDraftOffer {
	return core.RunbookDraftOffer{
		Title:     "Restart a job that lost its Consul registration",
		Slug:      "nomad-lost-registration",
		Summary:   "Run when allocations are healthy but the service is not routable.",
		ActionID:  recordedAction.ActionID,
		PackRef:   recordedAction.PackRef,
		RunnerRef: recordedAction.RunnerRef,
	}
}

// A runbook is a document somebody will later trust enough to run, and the only
// thing that makes a machine-assembled one worth trusting is that its steps are
// the steps that actually ran. An action id a model produced from memory looks
// exactly like one it read out of an approval row, so the host may never let a
// claimed identity through — it matches against its record and uses the record.
//
// The cost of not having this: a plausible runbook naming an action nobody has
// ever run, published by an operator who reasonably assumed Responder only
// drafts what it did.
func TestARunbookDraftRefusesAnActionTheEpisodeNeverRan(t *testing.T) {
	for _, invented := range []struct {
		name  string
		apply func(*core.RunbookDraftOffer)
	}{
		{"action id", func(o *core.RunbookDraftOffer) { o.ActionID = "nomad.job.stop" }},
		{"pack ref", func(o *core.RunbookDraftOffer) { o.PackRef = "nomad@1.5.0+sha256:2222" }},
		{"runner ref", func(o *core.RunbookDraftOffer) { o.RunnerRef = "staging~7f3c" }},
	} {
		t.Run(invented.name, func(t *testing.T) {
			offer := runbookOffer()
			invented.apply(&offer)
			_, err := EvaluateRunbookDraft(offer, verifiedEpisode())
			if !errors.Is(err, ErrUnrecordedAction) {
				t.Fatalf("an invented %s was accepted: %v", invented.name, err)
			}
		})
	}
}

// The draft must carry the RECORDED identity, not the offered one, even when
// the two differ only in whitespace. Returning the claim after matching it
// would leave a path by which a byte a model typed reaches Emisar, and the
// whole discipline rests on there being no such path.
func TestARunbookDraftCarriesTheRecordedRefsRatherThanTheOfferedOnes(t *testing.T) {
	offer := runbookOffer()
	offer.PackRef = "  " + recordedAction.PackRef + "  "
	draft, err := EvaluateRunbookDraft(offer, verifiedEpisode())
	if err != nil {
		t.Fatalf("a padded but matching ref was refused: %v", err)
	}
	if draft.Action != recordedAction {
		t.Fatalf("draft carries %+v, want the recorded %+v", draft.Action, recordedAction)
	}
}

// An episode that never checked its own fix has nothing to promote. "We
// restarted it and stopped looking" is not the claim a runbook makes, and a
// knowledge card written from a guess is worse than no card: it is a guess with
// a commit SHA on it.
//
// Verified is episode_outcomes.verified, the same field the promotion ladder
// counts. This test pins that a false there refuses BOTH artefacts.
func TestAnUnverifiedEpisodeOffersNothingToKeep(t *testing.T) {
	episode := verifiedEpisode()
	episode.Verified = false
	if _, err := EvaluateRunbookDraft(runbookOffer(), episode); !errors.Is(err, ErrNotVerified) {
		t.Fatalf("an unverified episode drafted a runbook: %v", err)
	}
	card := core.KnowledgeCardOffer{Slug: "pool-exhaustion", Title: "Pool exhaustion", Body: "x"}
	if _, err := EvaluateCard(card, episode); !errors.Is(err, ErrNotVerified) {
		t.Fatalf("an unverified episode wrote a knowledge card: %v", err)
	}
}

// The step Emisar receives must name the pack id it will resolve and the runner
// the fix was proven on, and the full immutable pack ref — digest included —
// has to survive somewhere a reviewer reads, because `pack.id` cannot hold it.
//
// This is the assertion that would have caught a builder that shipped the whole
// `nomad@1.4.0+sha256:1111` string as a pack id, which Emisar's own pattern
// rejects, or one that dropped the digest entirely and left a reviewer approving
// a procedure against an unknown pack version.
func TestARunbookPayloadNamesTheRecordedPackRunnerAndDigest(t *testing.T) {
	draft, err := EvaluateRunbookDraft(runbookOffer(), verifiedEpisode())
	if err != nil {
		t.Fatal(err)
	}
	arguments, err := RunbookArguments(draft)
	if err != nil {
		t.Fatal(err)
	}
	definition := arguments["definition"].(map[string]any)
	stage := definition["stages"].([]any)[0].(map[string]any)
	step := stage["steps"].([]any)[0].(map[string]any)
	if got := step["pack"].(map[string]any)["id"]; got != "nomad" {
		t.Fatalf("pack id is %q, want the id alone", got)
	}
	if got := step["action"]; got != recordedAction.ActionID {
		t.Fatalf("action is %q, want the recorded %q", got, recordedAction.ActionID)
	}
	refs := step["targets"].(map[string]any)["refs"].([]any)
	if len(refs) != 1 || refs[0] != "runner:"+recordedAction.RunnerRef {
		t.Fatalf("targets are %v, want exactly the recorded runner", refs)
	}
	context := definition["context_markdown"].(string)
	for _, want := range []string{
		recordedAction.PackRef, recordedAction.RunnerRef, recordedAction.ActionID, "episode_1",
	} {
		if !strings.Contains(context, want) {
			t.Fatalf("the draft context omits %q, so a reviewer cannot check it", want)
		}
	}
	// The whole payload must survive a round trip: a map holding a non-encodable
	// value would fail at the HTTP boundary, where the failure is a transport
	// error rather than a refusal anyone can read.
	if _, err := json.Marshal(arguments); err != nil {
		t.Fatalf("the Emisar payload does not encode: %v", err)
	}
}

// A pack ref this builder cannot take an id out of is refused rather than
// guessed at. Guessing produces a runbook pointing at a pack nobody named,
// which is the failure the whole path exists to prevent.
func TestAnUnparseablePackRefDraftsNothing(t *testing.T) {
	episode := verifiedEpisode()
	episode.Actions[0].PackRef = "Nomad Ops Pack v1"
	offer := runbookOffer()
	offer.PackRef = "Nomad Ops Pack v1"
	if _, err := EvaluateRunbookDraft(offer, episode); err == nil {
		t.Fatal("a pack ref with no extractable id produced a draft")
	}
}

// A confirmation is trusted for one thing — which offer the operator meant —
// and it is checked even for that. A card posted in an incident channel and
// replayed by a client in another room must not create anything, and a payload
// older than the day it was issued is confirming a sentence about evidence that
// has since moved.
func TestAKnowledgeConfirmationIsRefusedOutsideItsChannelAndItsDay(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)
	fresh := NewConfirmation(KindRunbook, "episode_1", "rb-1", "C123", now)
	if err := fresh.Resolve("C123", now); err != nil {
		t.Fatalf("a fresh confirmation was refused: %v", err)
	}
	for _, refusal := range []struct {
		name    string
		payload Confirmation
		channel string
		now     time.Time
	}{
		{"another channel", fresh, "C999", now},
		{"a day later", fresh, "C123", now.Add(ConfirmationMaxAge + time.Minute)},
		{"issued in the future", NewConfirmation(
			KindRunbook, "episode_1", "rb-1", "C123", now.Add(time.Hour),
		), "C123", now},
		{"no episode", NewConfirmation(KindRunbook, "", "rb-1", "C123", now), "C123", now},
		{"unknown kind", NewConfirmation("publish", "episode_1", "rb-1", "C123", now), "C123", now},
	} {
		t.Run(refusal.name, func(t *testing.T) {
			if err := refusal.payload.Resolve(refusal.channel, refusal.now); !errors.Is(
				err, ErrStaleConfirmation,
			) {
				t.Fatalf("accepted a confirmation from %s: %v", refusal.name, err)
			}
		})
	}
}

// Evaluate is what both the offering turn and the confirming click call, so a
// kind that does not match the payload present must refuse rather than fall
// through to whichever offer happens to be there. Otherwise a confirmation
// button saying "draft this runbook" could be answered by a card payload.
func TestAConfirmedKindMustMatchTheRecordedPayload(t *testing.T) {
	offer := runbookOffer()
	if _, err := Evaluate(KindCard, &offer, nil, verifiedEpisode()); err == nil {
		t.Fatal("a card confirmation was answered by a runbook payload")
	}
	if _, err := Evaluate(KindRunbook, &offer, nil, verifiedEpisode()); err != nil {
		t.Fatalf("a matching kind was refused: %v", err)
	}
}

// The card's heading and provenance are the host's, and the path is derived
// from the slug rather than accepted from the model. A card that could author
// its own citation is a card whose citation proves nothing.
func TestAKnowledgeCardCarriesHostWrittenProvenance(t *testing.T) {
	card, err := EvaluateCard(core.KnowledgeCardOffer{
		Slug:  "pool-exhaustion",
		Title: "Connection pool exhausts during overlapping jobs",
		Body:  "The migration and the nightly export both open 40 connections.",
	}, verifiedEpisode())
	if err != nil {
		t.Fatal(err)
	}
	if card.Path() != ".agent/kb/pool-exhaustion.md" {
		t.Fatalf("card path is %q", card.Path())
	}
	document := card.Document(time.Date(2026, 8, 15, 0, 0, 0, 0, time.UTC))
	for _, want := range []string{
		"# Connection pool exhausts during overlapping jobs",
		"episode `episode_1`", "2026-08-15", "Root cause:", "Verified by:",
	} {
		if !strings.Contains(document, want) {
			t.Fatalf("the card document omits %q:\n%s", want, document)
		}
	}
	if !strings.Contains(card.TaskPrompt(time.Now()), ".agent/kb/pool-exhaustion.md") {
		t.Fatal("the engineering task prompt does not name the file it must write")
	}
}

// The slug becomes a file path and an Emisar identifier, so it is checked
// against one alphabet rather than sanitized into one. A traversal that got as
// far as the engineering task prompt would be asking Coop to write outside the
// knowledge directory.
func TestASlugThatCouldEscapeTheKnowledgeDirectoryIsRejected(t *testing.T) {
	for _, slug := range []string{
		"../../etc/passwd", "Pool Exhaustion", "pool/exhaustion", "", "-leading-hyphen",
	} {
		offer := core.KnowledgeCardOffer{Slug: slug, Title: "Title", Body: "Body"}
		if err := ValidateCardOffer("kb-1", &offer); err == nil {
			t.Fatalf("slug %q was accepted", slug)
		}
	}
}
