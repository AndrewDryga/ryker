// Package knowledgeoffer decides what a verified remediation may become.
//
// Two artefacts, one rule. An episode that ran an Emisar action and then
// checked that it worked may be offered as a runbook draft or as a knowledge
// card; an episode that did neither may not. Everything here is a pure function
// of values — the offer the model wrote, and what the host already recorded
// about the episode — for the same reason internal/remediation is: a decision
// that needs a database, a Slack client and a model turn to exercise is a
// decision nobody tests exhaustively, and this one ends in a document somebody
// will later trust enough to run.
//
// The package deliberately cannot reach a store, an HTTP client or Slack. It is
// imported by internal/investigation, which validates the operation, and by the
// service, which performs the confirmed offer; both ask the same functions the
// same questions, so a proposal accepted at result time cannot be a proposal
// refused at confirmation time for a reason the model was never told.
package knowledgeoffer

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
)

// The two kinds, as they appear in a confirmation payload and an audit row.
const (
	KindRunbook = "runbook_draft"
	KindCard    = "kb_card"
)

// ConfirmationMaxAge is how long a knowledge card stays clickable — the same
// twenty-four hours the behaviour offers and the promotion card use.
//
// The reason is the same and one more. Confirming creates something outside
// Responder: a draft in Emisar, or an engineering task that will open a pull
// request. A button pressed a week later would be acting on an episode whose
// verification has long since stopped being the newest thing known about the
// system it describes.
const ConfirmationMaxAge = 24 * time.Hour

var (
	// ErrStaleConfirmation is a confirmation payload that may not be acted on.
	ErrStaleConfirmation = errors.New("knowledge confirmation is invalid or stale")
	// ErrNotVerified is an episode that concluded without checking its own fix.
	ErrNotVerified = errors.New("the episode did not record a verified remediation")
	// ErrUnrecordedAction is the refusal that matters most here: an offer naming
	// an Emisar identity the host has no successful run for.
	ErrUnrecordedAction = errors.New("the offer names an action this episode did not run")
)

// Emisar's own runbook-definition grammar, copied here so a draft is refused
// before it is sent rather than rejected after.
//
// Refused rather than repaired, deliberately. A pack id that does not match is
// not a spelling Responder may guess at: it means the recorded pack ref is not
// shaped the way this builder assumes, and the honest answer is to say so and
// create nothing. A runbook that quietly points at a slightly different pack is
// the exact failure this whole path exists to prevent.
var (
	slugPattern    = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,79}$`)
	packIDPattern  = regexp.MustCompile(`^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)*$`)
	actionIDattern = regexp.MustCompile(`^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+$`)
)

// Emisar's bounds, and ours. MaxCardBody is the only one this package chose:
// a knowledge card is a card, and a body that needs more than four kilobytes is
// a document that belongs in the repository through an ordinary change.
const (
	MaxTitle        = 80
	MaxSummary      = 4096
	MaxContext      = 16384
	MaxRunnerRef    = 113
	MaxCardBody     = 4096
	maxRootCause    = 600
	maxVerification = 400
)

// Episode is everything the host knows about the finished episode an offer is
// made against. The model supplies none of it.
//
// Verified is episode_outcomes.verified and nothing else — the field the
// graduated-autonomy ladder counts on and this package does not redefine: a
// closing assessment that named how the fix was checked, on an episode that
// then completed.
//
// Actions is the set of exact Emisar identities this episode ran successfully,
// read from the approval rows. An offer may only name one of these.
type Episode struct {
	EpisodeID    string
	Verified     bool
	RootCause    string
	Verification string
	Actions      []remediation.ActionRef
}

// ValidateRunbookOffer checks the shape of a runbook proposal.
//
// It is the operation validator and it is also the first half of the
// confirmation check, so a model reading a rejection is reading the same rule
// the operator's click will be measured against. It says nothing about whether
// the action was actually run — that needs the record, and lives in
// EvaluateRunbookDraft — because a shape complaint and an evidence complaint
// are different messages and a model can only act on the first.
func ValidateRunbookOffer(operationID string, offer *core.RunbookDraftOffer) error {
	if offer == nil {
		return fmt.Errorf("result operation %q requires a runbook draft offer", operationID)
	}
	if err := checkTitle(operationID, offer.Title); err != nil {
		return err
	}
	if err := checkSlug(operationID, offer.Slug); err != nil {
		return err
	}
	if strings.TrimSpace(offer.Summary) == "" {
		return fmt.Errorf(
			"result operation %q requires a summary; the draft's description is what tells a "+
				"reviewer when to run it", operationID,
		)
	}
	if len(offer.Summary) > MaxSummary {
		return fmt.Errorf(
			"result operation %q has a %d-byte summary; Emisar bounds a runbook description at %d",
			operationID, len(offer.Summary), MaxSummary,
		)
	}
	for _, part := range []struct{ name, value string }{
		{"action_id", offer.ActionID},
		{"pack_ref", offer.PackRef},
		{"runner_ref", offer.RunnerRef},
	} {
		if strings.TrimSpace(part.value) == "" {
			return fmt.Errorf(
				"result operation %q requires %s; a runbook step names one exact Emisar action "+
					"identity — action id, pack ref and runner ref together — and the host builds "+
					"the draft only from an identity it recorded running", operationID, part.name,
			)
		}
	}
	return nil
}

// ValidateCardOffer checks the shape of a knowledge-card proposal.
func ValidateCardOffer(operationID string, offer *core.KnowledgeCardOffer) error {
	if offer == nil {
		return fmt.Errorf("result operation %q requires a knowledge card offer", operationID)
	}
	if err := checkTitle(operationID, offer.Title); err != nil {
		return err
	}
	if err := checkSlug(operationID, offer.Slug); err != nil {
		return err
	}
	body := strings.TrimSpace(offer.Body)
	if body == "" {
		return fmt.Errorf("result operation %q requires a card body", operationID)
	}
	if len(body) > MaxCardBody {
		return fmt.Errorf(
			"result operation %q has a %d-byte card body; a knowledge card is a card and is "+
				"bounded at %d bytes — anything longer belongs in an ordinary repository change",
			operationID, len(body), MaxCardBody,
		)
	}
	if strings.Contains(body, "```") && strings.Count(body, "```")%2 != 0 {
		return fmt.Errorf(
			"result operation %q has an unclosed code fence in its card body", operationID,
		)
	}
	return nil
}

func checkTitle(operationID, title string) error {
	trimmed := strings.TrimSpace(title)
	if trimmed == "" {
		return fmt.Errorf("result operation %q requires a title", operationID)
	}
	if len(trimmed) > MaxTitle {
		return fmt.Errorf(
			"result operation %q has a %d-byte title; the bound is %d",
			operationID, len(trimmed), MaxTitle,
		)
	}
	return nil
}

// checkSlug is strict and says why. The slug becomes a file path or an Emisar
// identifier, and both refuse anything else; a rejection naming the alphabet is
// a rejection the next turn can satisfy.
func checkSlug(operationID, slug string) error {
	trimmed := strings.TrimSpace(slug)
	if !slugPattern.MatchString(trimmed) {
		return fmt.Errorf(
			"result operation %q has slug %q; a slug starts with a lowercase letter and holds "+
				"only lowercase letters, digits, hyphens and underscores, at most 80 characters",
			operationID, slug,
		)
	}
	return nil
}

// RunbookDraft is one validated, evidence-backed draft, ready to send.
//
// Action is NOT what the offer said. It is the recorded identity the offer
// matched, copied out of the approval row, so nothing downstream can be reading
// a model's spelling of a pack digest.
type RunbookDraft struct {
	Title        string
	Slug         string
	Summary      string
	Action       remediation.ActionRef
	EpisodeID    string
	RootCause    string
	Verification string
}

// EvaluateRunbookDraft grades a runbook proposal against the record.
//
// Two refusals, and both are the point of the feature. An episode that never
// verified its fix has nothing to promote into a procedure — a runbook is a
// claim that this works, and "we restarted it and stopped looking" is not that
// claim. And an offer naming an action the host has no successful approval for
// is refused outright rather than corrected: the whole value of a draft
// assembled by a machine is that its steps are the steps that actually ran, and
// an action id a model produced from memory looks exactly like one it read.
func EvaluateRunbookDraft(
	offer core.RunbookDraftOffer,
	episode Episode,
) (RunbookDraft, error) {
	if err := ValidateRunbookOffer("offer", &offer); err != nil {
		return RunbookDraft{}, err
	}
	if !episode.Verified {
		return RunbookDraft{}, ErrNotVerified
	}
	claimed := remediation.ActionRef{
		ActionID: strings.TrimSpace(offer.ActionID),
		PackRef:  strings.TrimSpace(offer.PackRef), RunnerRef: strings.TrimSpace(offer.RunnerRef),
	}
	recorded, ok := matchRecorded(claimed, episode.Actions)
	if !ok {
		return RunbookDraft{}, fmt.Errorf(
			"%w: %s on %s is not among the %d Emisar runs this episode completed successfully",
			ErrUnrecordedAction, claimed.ActionID, claimed.RunnerRef, len(episode.Actions),
		)
	}
	if _, err := packID(recorded.PackRef); err != nil {
		return RunbookDraft{}, err
	}
	if !actionIDattern.MatchString(recorded.ActionID) {
		return RunbookDraft{}, fmt.Errorf(
			"recorded action id %q is not shaped like an Emisar action reference",
			recorded.ActionID,
		)
	}
	if len(recorded.RunnerRef) > MaxRunnerRef {
		return RunbookDraft{}, fmt.Errorf(
			"recorded runner ref is %d bytes; an Emisar target ref is bounded at %d",
			len(recorded.RunnerRef), MaxRunnerRef,
		)
	}
	return RunbookDraft{
		Title: strings.TrimSpace(offer.Title), Slug: strings.TrimSpace(offer.Slug),
		Summary: core.BoundedText(strings.TrimSpace(offer.Summary), MaxSummary),
		Action:  recorded, EpisodeID: episode.EpisodeID,
		RootCause:    core.BoundedText(strings.TrimSpace(episode.RootCause), maxRootCause),
		Verification: core.BoundedText(strings.TrimSpace(episode.Verification), maxVerification),
	}, nil
}

// matchRecorded returns the RECORDED ref, never the claimed one.
//
// Returning the record rather than the claim is the entire mechanism: even an
// exact match is discarded in favour of the row it matched, so there is no path
// by which a byte a model typed reaches Emisar.
func matchRecorded(
	claimed remediation.ActionRef,
	recorded []remediation.ActionRef,
) (remediation.ActionRef, bool) {
	for _, candidate := range recorded {
		if candidate.Equal(claimed) {
			return candidate, true
		}
	}
	return remediation.ActionRef{}, false
}

// packID takes the pack identifier out of an immutable pack ref.
//
// A pack ref is `nomad@1.4.0+sha256:1111` — an id, a version and a digest — and
// the runbook grammar's `pack.id` holds only the first part. Splitting is the
// one derivation in this file, and it is a split on a literal character rather
// than a guess. The full ref goes into the draft's context verbatim, so the
// reviewer reads the digest the fix was verified against even though the step
// cannot carry it.
func packID(packRef string) (string, error) {
	id, _, _ := strings.Cut(strings.TrimSpace(packRef), "@")
	if !packIDPattern.MatchString(id) {
		return "", fmt.Errorf(
			"recorded pack ref %q does not begin with an Emisar pack id; refusing to guess one",
			packRef,
		)
	}
	return id, nil
}

// RunbookArguments builds the exact create_runbook_draft call.
//
// Every value is either the operator-confirmed text or a recorded ref. There is
// no `args` map and no success condition: this is a DRAFT, Emisar owns
// publishing it, and a step whose arguments were invented would be worse than a
// step a human has to fill in. The empty collections are present because the
// tool's schema requires the keys.
func RunbookArguments(draft RunbookDraft) (map[string]any, error) {
	pack, err := packID(draft.Action.PackRef)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"title":       core.BoundedText(draft.Title, MaxTitle),
		"slug":        draft.Slug,
		"description": core.BoundedText(draft.Summary, MaxSummary),
		"definition": map[string]any{
			"schema_version":   1,
			"context_markdown": core.BoundedText(draftContext(draft), MaxContext),
			"inputs":           []any{},
			"stages": []any{map[string]any{
				"id":    "remediate",
				"title": core.BoundedText("Run the verified remediation", MaxTitle),
				"mode":  "sequential",
				"steps": []any{map[string]any{
					"id":     "verified_action",
					"pack":   map[string]any{"id": pack},
					"action": draft.Action.ActionID,
					"targets": map[string]any{
						"selection": "all",
						"refs":      []any{"runner:" + draft.Action.RunnerRef},
					},
					"args":    map[string]any{},
					"outputs": []any{},
					"success": []any{},
					"wait":    nil,
				}},
			}},
		},
	}, nil
}

// draftContext is what a human reads before publishing the draft.
//
// The three refs are printed in full because the step above can only carry two
// of them: the pack digest the remediation was verified against does not fit in
// `pack.id`, and a reviewer approving a procedure is entitled to see the exact
// version it was proven on. The episode id makes the claim checkable — every
// sentence in this block came from one investigation, and it is named.
func draftContext(draft RunbookDraft) string {
	var body strings.Builder
	body.WriteString("Drafted by Emisar Responder from a verified remediation. Nothing here has ")
	body.WriteString("been published; review every step before releasing this runbook.\n\n")
	body.WriteString("- Source episode: `" + draft.EpisodeID + "`\n")
	body.WriteString("- Action id: `" + draft.Action.ActionID + "`\n")
	body.WriteString("- Pack ref: `" + draft.Action.PackRef + "`\n")
	body.WriteString("- Runner ref: `" + draft.Action.RunnerRef + "`\n")
	if draft.RootCause != "" {
		body.WriteString("\n## Root cause\n\n" + draft.RootCause + "\n")
	}
	if draft.Verification != "" {
		body.WriteString("\n## How the fix was checked\n\n" + draft.Verification + "\n")
	}
	body.WriteString("\n## Summary\n\n" + draft.Summary + "\n")
	body.WriteString("\nThe step below carries no arguments. The recorded run's arguments are not ")
	body.WriteString("part of the remediation record, so a reviewer supplies them rather than ")
	body.WriteString("Responder guessing them.\n")
	return body.String()
}

// Card is one validated knowledge card.
type Card struct {
	Slug         string
	Title        string
	Body         string
	EpisodeID    string
	RootCause    string
	Verification string
}

// EvaluateCard grades a knowledge-card proposal.
//
// It carries the same verified gate as the runbook, for a smaller reason that
// still holds: a card is a durable claim about how the system behaves, and an
// episode that guessed at a cause and then stopped is not the place to write
// one from. Unlike the runbook it needs no Emisar identity, because a card
// describes rather than acts.
func EvaluateCard(offer core.KnowledgeCardOffer, episode Episode) (Card, error) {
	if err := ValidateCardOffer("offer", &offer); err != nil {
		return Card{}, err
	}
	if !episode.Verified {
		return Card{}, ErrNotVerified
	}
	return Card{
		Slug: strings.TrimSpace(offer.Slug), Title: strings.TrimSpace(offer.Title),
		Body:      core.BoundedText(strings.TrimSpace(offer.Body), MaxCardBody),
		EpisodeID: episode.EpisodeID,
		RootCause: core.BoundedText(strings.TrimSpace(episode.RootCause), maxRootCause),
		Verification: core.BoundedText(
			strings.TrimSpace(episode.Verification), maxVerification,
		),
	}, nil
}

// Path is where the card lands. Committed knowledge lives in `.agent/kb/`;
// docs/architecture-next.md §18.1 is the decision this encodes.
func (c Card) Path() string { return ".agent/kb/" + c.Slug + ".md" }

// Document is the card's full Markdown.
//
// The heading and the provenance block are the host's, not the model's. A
// reader checking a card against the investigation that produced it should not
// be reading a citation the same turn wrote — and the model's body is prose
// about content that arrived from Slack and an alert, which is exactly the
// material that must never be able to author its own attribution.
func (c Card) Document(recorded time.Time) string {
	var body strings.Builder
	body.WriteString("# " + c.Title + "\n\n")
	body.WriteString(c.Body)
	if !strings.HasSuffix(c.Body, "\n") {
		body.WriteString("\n")
	}
	body.WriteString("\n## Provenance\n\n")
	body.WriteString("Recorded by Emisar Responder from episode `" + c.EpisodeID + "` on " +
		recorded.UTC().Format("2006-01-02") + ".\n")
	if c.RootCause != "" {
		body.WriteString("\n- Root cause: " + c.RootCause + "\n")
	}
	if c.Verification != "" {
		body.WriteString("- Verified by: " + c.Verification + "\n")
	}
	return body.String()
}

// TaskTitle and TaskPrompt express the card as the engineering task that will
// write it.
//
// This is the whole of "the propose-to-PR path" and it deliberately adds
// nothing to it. The publisher only ever commits a tree Coop reviewed and
// hashed, so there is no host-side affordance for "here is a file, commit it"
// and inventing one would mean a second way to reach the default branch. The
// existing route — engineering task, Coop fork, review, operator-gated publish,
// draft pull request — already ends where this needs to end, and Responder
// still never merges anything.
func (c Card) TaskTitle() string {
	return core.BoundedText("Add knowledge card: "+c.Title, 200)
}

func (c Card) TaskPrompt(recorded time.Time) string {
	return "Create the file `" + c.Path() + "` containing exactly the Markdown between the " +
		"markers below, and change nothing else in the repository. Do not reformat it, do not " +
		"add sections, and do not edit any other file.\n\n" +
		"--- BEGIN CARD ---\n" + c.Document(recorded) + "--- END CARD ---\n"
}

// Artifact is one graded offer: which kind it is, and the validated thing that
// would be created.
//
// One type for both so the two callers — the turn that posts the card and the
// click that acts on it — walk one code path. They must agree exactly: an offer
// the host was willing to show and then refuses on confirmation is a broken
// promise to the operator, and an offer it shows but would not have made is
// worse. A shared Evaluate is the cheapest way to make disagreement unwritable.
type Artifact struct {
	Kind      string
	Draft     RunbookDraft
	Card      Card
	Rationale string
}

// Evaluate grades whichever offer is present against the episode's record.
//
// The kind is the caller's, not the payload's: at confirmation time it comes
// from the button, and a payload whose typed offer does not match the kind that
// was offered is refused rather than reinterpreted.
func Evaluate(
	kind string,
	runbook *core.RunbookDraftOffer,
	card *core.KnowledgeCardOffer,
	episode Episode,
) (Artifact, error) {
	switch {
	case kind == KindRunbook && runbook != nil:
		draft, err := EvaluateRunbookDraft(*runbook, episode)
		if err != nil {
			return Artifact{}, err
		}
		return Artifact{Kind: kind, Draft: draft, Rationale: runbook.Rationale}, nil
	case kind == KindCard && card != nil:
		evaluated, err := EvaluateCard(*card, episode)
		if err != nil {
			return Artifact{}, err
		}
		return Artifact{Kind: kind, Card: evaluated, Rationale: card.Rationale}, nil
	}
	return Artifact{}, fmt.Errorf("%w: it carries no %s payload", ErrStaleConfirmation, kind)
}

// Kind names the artefact an operation type proposes, and reports whether the
// operation is one of them at all.
func Kind(operationType string) (string, bool) {
	switch operationType {
	case "offer_runbook_draft":
		return KindRunbook, true
	case "offer_kb_card":
		return KindCard, true
	}
	return "", false
}

// Confirmation is the blob a knowledge card's button carries.
//
// It names WHICH offer and nothing else. The title, the body, the refs and the
// evidence are all read back from the episode at confirm time, because a button
// value is a round trip through a Slack client and a card body would not fit in
// one anyway. What it is trusted for is identity, and even that is checked
// against the channel the click arrived from.
type Confirmation struct {
	Version     int       `json:"version"`
	ChannelID   string    `json:"channel_id"`
	IssuedAt    time.Time `json:"issued_at"`
	Kind        string    `json:"kind"`
	EpisodeID   string    `json:"episode_id"`
	OperationID string    `json:"operation_id"`
}

// NewConfirmation builds the payload for one offered artefact.
func NewConfirmation(
	kind string,
	episodeID string,
	operationID string,
	channelID string,
	issuedAt time.Time,
) Confirmation {
	return Confirmation{
		Version: 1, ChannelID: channelID, IssuedAt: issuedAt.UTC(),
		Kind: kind, EpisodeID: episodeID, OperationID: operationID,
	}
}

// Resolve refuses anything a click may not be acted on for.
//
// `channelID` is where the click actually came from, not where the payload says
// it came from — a card replayed by a client in another room must not be able to
// create anything. The five-minute future-clock allowance matches the behaviour
// offers and the promotion card: a host whose clock stepped backwards should not
// invalidate every card it just posted, but a payload issued tomorrow is not a
// clock problem.
func (c Confirmation) Resolve(channelID string, now time.Time) error {
	switch {
	case c.Version != 1:
		return fmt.Errorf("%w: unsupported version %d", ErrStaleConfirmation, c.Version)
	case c.Kind != KindRunbook && c.Kind != KindCard:
		return fmt.Errorf("%w: it names unsupported kind %q", ErrStaleConfirmation, c.Kind)
	case strings.TrimSpace(channelID) == "" || c.ChannelID != channelID:
		return fmt.Errorf(
			"%w: it was issued for channel %q and clicked in %q",
			ErrStaleConfirmation, c.ChannelID, channelID,
		)
	case strings.TrimSpace(c.EpisodeID) == "" || strings.TrimSpace(c.OperationID) == "":
		return fmt.Errorf("%w: it does not name one recorded offer", ErrStaleConfirmation)
	case c.IssuedAt.IsZero():
		return fmt.Errorf("%w: it carries no issue time", ErrStaleConfirmation)
	case c.IssuedAt.After(now.UTC().Add(5 * time.Minute)):
		return fmt.Errorf("%w: it was issued in the future", ErrStaleConfirmation)
	case now.UTC().Sub(c.IssuedAt) > ConfirmationMaxAge:
		return fmt.Errorf("%w: it is older than %s", ErrStaleConfirmation, ConfirmationMaxAge)
	}
	return nil
}
