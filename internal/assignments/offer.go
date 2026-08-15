package assignments

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The bounds an offer is measured against.
//
// They are stated here rather than at the two call sites because this package
// is the one place that knows what a standing assignment means, and because a
// bound written twice is a bound that can be enforced twice differently: an
// offer accepted at result time and refused at confirmation time is a broken
// promise to an operator who already pressed the button. ValidateOffer is the
// operation validator AND the first half of the confirmation check, exactly as
// knowledgeoffer.ValidateRunbookOffer is.
//
// maxDailyBudget and maxPathGlobs match standingassignmentstore's own refusals,
// which are the last line and stay the last line. Repeating them earlier is not
// redundant: the store's refusal reaches a Go caller, and this one reaches the
// model, which is the only party that can write a different number.
const (
	maxDailyBudget     = 20
	defaultDailyBudget = 1
	maxExpiryDays      = 90
	defaultExpiryDays  = 14
	maxPathGlobs       = 10
	maxSignalBytes     = 200
)

// maxExpiry is the longest grant this package will write.
//
// Ninety days is already long for authority nobody re-confirms; the point of an
// expiry is that a forgotten assignment decays rather than running forever, and
// an expiry beyond the horizon anybody plans on is an expiry in name only.
const maxExpiry = maxExpiryDays * 24 * time.Hour

// ConfirmationMaxAge is how long an assignment offer stays clickable — the same
// twenty-four hours the memory, knowledge and promotion cards use.
//
// The reason here is the strongest of the four. Confirming grants Responder
// scoped authority over a repository for weeks, and the sentence that justified
// it was said in a channel that has moved on. A button pressed a day later is a
// grant made against a conversation nobody in the room still remembers.
const ConfirmationMaxAge = 24 * time.Hour

var (
	// ErrStaleConfirmation is a confirmation payload that may not be acted on.
	ErrStaleConfirmation = errors.New("assignment confirmation is invalid or stale")
	// ErrNotOffered is a confirmation naming an offer the episode never made.
	ErrNotOffered = errors.New("the episode recorded no such assignment offer")
)

// ValidateOffer checks that a proposal names bounds the host can actually
// grant.
//
// Everything it refuses is something the model could have written correctly, and
// the refusal says which value and what the set or range is — a rejection that
// only said "invalid assignment" would send the next turn guessing at six fields
// at once. What it deliberately does NOT check is whether the repository exists
// or the channel wants one; those need the record, and a shape complaint and a
// record complaint are different messages.
func ValidateOffer(operationID string, offer *core.StandingAssignmentOffer) error {
	if offer == nil {
		return fmt.Errorf("result operation %q requires a standing assignment offer", operationID)
	}
	if strings.TrimSpace(offer.Repository) == "" {
		return fmt.Errorf(
			"result operation %q requires a repository; a standing assignment is authority "+
				"over exactly one repository and never over whichever one is default",
			operationID,
		)
	}
	if signal := normalizedSignal(offer.SignalPattern); signal == "" {
		return fmt.Errorf(
			"result operation %q requires signal_pattern naming what this assignment watches "+
				"for; without it the grant covers every message in the channel", operationID,
		)
	}
	if class := NormalizeChangeClass(offer.ChangeClass); !slices.Contains(
		core.StandingAssignmentChangeClasses, class,
	) {
		return fmt.Errorf(
			"result operation %q proposes change class %q, which is not one of: %s. "+
				"The set is closed because free text means Responder may change anything",
			operationID, offer.ChangeClass,
			strings.Join(core.StandingAssignmentChangeClasses, ", "),
		)
	}
	if offer.DailyBudget < 0 || offer.DailyBudget > maxDailyBudget {
		return fmt.Errorf(
			"result operation %q asks for %d pull requests a day; the range is 1 to %d, and "+
				"omitting it means %d", operationID, offer.DailyBudget, maxDailyBudget,
			defaultDailyBudget,
		)
	}
	if offer.ExpiryDays < 0 || offer.ExpiryDays > maxExpiryDays {
		return fmt.Errorf(
			"result operation %q asks for %d days; a standing assignment lasts at most %d, "+
				"and omitting it means %d — authority nobody re-confirms is authority nobody "+
				"is deciding about", operationID, offer.ExpiryDays, maxExpiryDays,
			defaultExpiryDays,
		)
	}
	if globs := normalizedGlobs(offer.PathGlobs); len(globs) > maxPathGlobs {
		return fmt.Errorf(
			"result operation %q lists %d path patterns; an assignment covers at most %d, "+
				"and more than that is a repository-wide grant written the long way",
			operationID, len(globs), maxPathGlobs,
		)
	}
	for _, glob := range offer.PathGlobs {
		if strings.Contains(glob, "..") {
			return fmt.Errorf(
				"result operation %q has path pattern %q, which traverses upward out of the "+
					"repository it is scoped to", operationID, glob,
			)
		}
	}
	return nil
}

// Normalize turns a validated proposal into the exact grant that would be
// written.
//
// This is what the confirmation card renders, and rendering the NORMALIZED
// bounds rather than the proposal is the whole discipline: an operator agreeing
// once to work that happens without them can only check what they agreed to at
// this moment, so the card has to show the repository as it will be stored, the
// class as the allowlist spells it, the budget and expiry the host filled in,
// and the paths after the empty ones were dropped. A card showing the model's
// words and a row holding something else is the failure this replaces.
//
// ActorID is deliberately not set and not a parameter. A standing assignment
// records who CONFIRMED it, and at the moment this runs nobody has; the click
// fills it in, and the store's own validate refuses a row without one. The
// expiry is likewise measured from the caller's clock rather than the offer's,
// so a grant lasts its agreed days from when it was granted — which is why the
// card states the days rather than a date it would then miss by up to the
// twenty-four hours a confirmation stays clickable.
//
// Shadow is set here and is not a parameter either. The store refuses a live
// creation outright — see standingassignmentstore.ErrGrantWithheld — and this
// is the only constructor of the value it refuses, so the two agree by
// construction rather than by a caller remembering.
func Normalize(
	offer core.StandingAssignmentOffer,
	channelID string,
	now time.Time,
) (core.StandingAssignment, error) {
	if err := ValidateOffer("offer", &offer); err != nil {
		return core.StandingAssignment{}, err
	}
	if strings.TrimSpace(channelID) == "" {
		return core.StandingAssignment{}, errors.New(
			"a standing assignment records the channel it watches",
		)
	}
	budget := offer.DailyBudget
	if budget < 1 {
		budget = defaultDailyBudget
	}
	return core.StandingAssignment{
		ChannelID:     channelID,
		Repository:    strings.TrimSpace(offer.Repository),
		ChangeClass:   NormalizeChangeClass(offer.ChangeClass),
		SignalPattern: normalizedSignal(offer.SignalPattern),
		PathGlobs:     normalizedGlobs(offer.PathGlobs),
		DailyBudget:   budget,
		Enabled:       true,
		Shadow:        true,
		ExpiresAt:     now.UTC().Add(time.Duration(ExpiryDays(offer)) * 24 * time.Hour),
	}, nil
}

// ExpiryDays is the bound the card states in words.
//
// It is a function rather than a field on the normalized assignment because the
// stored row holds an instant and the operator agreed to a duration. Those are
// the same fact only at the moment of granting, and the offer card is posted
// before it.
func ExpiryDays(offer core.StandingAssignmentOffer) int {
	switch {
	case offer.ExpiryDays < 1:
		return defaultExpiryDays
	case offer.ExpiryDays > maxExpiryDays:
		return maxExpiryDays
	default:
		return offer.ExpiryDays
	}
}

// NormalizeChangeClass reads the allowlist entry out of what an operator said.
//
// "dependency upgrade", "Dependency Upgrade" and "dependency_upgrade" are the
// same class, and only the last one is storable. Refusing the first two would
// be refusing a model for transcribing a human sentence accurately, which is
// the opposite of what the closed set is for: the set exists to stop Responder
// being granted a class nobody named, not to test spelling.
func NormalizeChangeClass(class string) string {
	folded := strings.ToLower(strings.TrimSpace(class))
	folded = strings.ReplaceAll(folded, "-", "_")
	return strings.Join(strings.Fields(folded), "_")
}

// normalizedSignal collapses the words an assignment watches for.
//
// Bounded, because the signal is matched against message text and a signal the
// length of a paragraph matches nothing; collapsed, because a pattern that
// differs from another only by a line break is a second assignment nobody meant
// to create.
func normalizedSignal(signal string) string {
	return core.BoundedText(strings.Join(strings.Fields(signal), " "), maxSignalBytes)
}

// normalizedGlobs drops the empties and the duplicates.
//
// An empty entry is the shape a trailing comma leaves behind, and stored as-is
// it is a path pattern matching nothing while counting against the ten. A
// duplicate is the same. Neither is worth a refusal — they change no bound —
// but both belong out of the row the operator is reading.
func normalizedGlobs(globs []string) []string {
	if len(globs) == 0 {
		return nil
	}
	normalized := make([]string, 0, len(globs))
	for _, glob := range globs {
		trimmed := strings.TrimSpace(glob)
		if trimmed == "" || slices.Contains(normalized, trimmed) {
			continue
		}
		normalized = append(normalized, trimmed)
	}
	if len(normalized) == 0 {
		return nil
	}
	return normalized
}

// Confirmation is the blob an assignment offer's button carries.
//
// It names WHICH offer and nothing else — the same shape the knowledge cards
// use, and for the stronger reason. The bounds are read back from the episode's
// own event stream at confirm time, so the grant that is created is the one the
// host recorded the model proposing, not the one that came back through an
// operator's browser. A payload edited in transit can change which offer is
// confirmed at most, and never what it grants.
type Confirmation struct {
	Version     int       `json:"version"`
	ChannelID   string    `json:"channel_id"`
	IssuedAt    time.Time `json:"issued_at"`
	EpisodeID   string    `json:"episode_id"`
	OperationID string    `json:"operation_id"`
}

// NewConfirmation builds the payload for one offered assignment.
func NewConfirmation(
	episodeID string,
	operationID string,
	channelID string,
	issuedAt time.Time,
) Confirmation {
	return Confirmation{
		Version: 1, ChannelID: channelID, IssuedAt: issuedAt.UTC(),
		EpisodeID: episodeID, OperationID: operationID,
	}
}

// Resolve refuses anything a click may not be acted on for.
//
// `channelID` is where the click actually came from, not where the payload says
// it came from: a card replayed by a client in another room must not be able to
// grant authority over that room's repository. The five-minute future-clock
// allowance matches the other confirmation payloads — a host whose clock
// stepped backwards should not invalidate every card it just posted, and a
// payload issued tomorrow is not a clock problem.
func (c Confirmation) Resolve(channelID string, now time.Time) error {
	switch {
	case c.Version != 1:
		return fmt.Errorf("%w: unsupported version %d", ErrStaleConfirmation, c.Version)
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
