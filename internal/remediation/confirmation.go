package remediation

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// ConfirmationMaxAge is how long a promotion card stays clickable.
//
// The same twenty-four hours the behaviour offers use, for the same reason and
// one more. An offer names a count the host recomputed at the moment it was
// composed; a click a week later would be confirming a sentence about evidence
// that has since changed. The handler recomputes anyway — this bound is what
// stops the operator being shown one number and granted against another.
const ConfirmationMaxAge = 24 * time.Hour

// ErrStaleConfirmation is a confirmation payload that may not be acted on.
var ErrStaleConfirmation = errors.New("promotion confirmation is invalid or stale")

// Confirmation is the blob a promotion card's button carries.
//
// It holds an identity and nothing else — no count, no expiry, no operator. All
// three are recomputed or supplied at confirm time, because a button value is a
// round trip through a Slack client and the one thing it must never be is the
// source of the numbers the decision rests on. What it IS trusted for is which
// grant the operator meant, and even that is checked against the channel the
// click arrived from.
type Confirmation struct {
	Version       int       `json:"version"`
	ChannelID     string    `json:"channel_id"`
	IssuedAt      time.Time `json:"issued_at"`
	AlertGroupKey string    `json:"alert_group_key"`
	Repository    string    `json:"repository,omitempty"`
	ActionID      string    `json:"action_id"`
	PackRef       string    `json:"pack_ref"`
	RunnerRef     string    `json:"runner_ref"`
	Rung          string    `json:"rung"`
}

// NewConfirmation builds the payload for one evaluated promotion.
func NewConfirmation(grant Grant, issuedAt time.Time) Confirmation {
	return Confirmation{
		Version: 1, ChannelID: grant.Trigger.ChannelID, IssuedAt: issuedAt.UTC(),
		AlertGroupKey: grant.Trigger.AlertGroupKey, Repository: grant.Trigger.Repository,
		ActionID: grant.Action.ActionID, PackRef: grant.Action.PackRef,
		RunnerRef: grant.Action.RunnerRef, Rung: string(grant.Rung),
	}
}

// Resolve turns a confirmation back into the identity it names, refusing
// anything a click may not be acted on for.
//
// `channelID` is where the click actually came from, not where the payload says
// it came from. A promotion card posted in an incident channel and replayed by a
// client in another one would otherwise grant authority scoped to a room the
// operator was not looking at.
//
// The future-clock allowance is five minutes, matching the behaviour offers: a
// host whose clock stepped backwards should not invalidate every card it just
// posted, but a payload claiming to be issued tomorrow is not a clock problem.
func (c Confirmation) Resolve(
	channelID string,
	now time.Time,
) (TriggerClass, ActionRef, Rung, error) {
	class := TriggerClass{
		AlertGroupKey: c.AlertGroupKey, ChannelID: c.ChannelID, Repository: c.Repository,
	}
	action := ActionRef{ActionID: c.ActionID, PackRef: c.PackRef, RunnerRef: c.RunnerRef}
	rung := Rung(strings.TrimSpace(c.Rung))
	switch {
	case c.Version != 1:
		return class, action, rung, fmt.Errorf("%w: unsupported version %d", ErrStaleConfirmation, c.Version)
	case strings.TrimSpace(channelID) == "" || c.ChannelID != channelID:
		return class, action, rung, fmt.Errorf(
			"%w: it was issued for channel %q and clicked in %q",
			ErrStaleConfirmation, c.ChannelID, channelID,
		)
	case c.IssuedAt.IsZero():
		return class, action, rung, fmt.Errorf("%w: it carries no issue time", ErrStaleConfirmation)
	case c.IssuedAt.After(now.UTC().Add(5 * time.Minute)):
		return class, action, rung, fmt.Errorf("%w: it was issued in the future", ErrStaleConfirmation)
	case now.UTC().Sub(c.IssuedAt) > ConfirmationMaxAge:
		return class, action, rung, fmt.Errorf(
			"%w: it is older than %s", ErrStaleConfirmation, ConfirmationMaxAge,
		)
	case !class.Complete() || !action.Complete():
		return class, action, rung, fmt.Errorf(
			"%w: it does not name a complete grant identity", ErrStaleConfirmation,
		)
	case !rung.Valid():
		return class, action, rung, fmt.Errorf(
			"%w: it names unsupported rung %q", ErrStaleConfirmation, c.Rung,
		)
	}
	return class, action, rung, nil
}
