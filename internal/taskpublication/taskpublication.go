// Package taskpublication serializes the durable handoff from a completed
// engineering feedback turn to its existing pull request.
package taskpublication

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const LegacyDirtyWorkspaceReviewError = "review requires a clean committed task workspace"

type ChangesReader interface {
	Changes(context.Context, string) (coop.Changes, error)
}

type RecoveryPolicy struct {
	TeamID    string
	InputKind string
	Now       func() time.Time
	Warn      func(string, string, error)
}

// RecoverLegacyDirtyFailures bridges publication attempts that failed before
// clean-commit completion was enforced. A clean newer task commit belongs to
// the existing PR, so the host queues the update without another button press.
func RecoverLegacyDirtyFailures(
	ctx context.Context,
	st *store.Store,
	reader ChangesReader,
	policy RecoveryPolicy,
) error {
	const pageSize = 100
	for offset := 0; ; offset += pageSize {
		incidents, total, err := st.ListIncidentPage(ctx, true, pageSize, offset)
		if err != nil {
			return err
		}
		for _, incident := range incidents {
			if !incident.IsEngineeringTask() || incident.CoopSessionID == "" ||
				incident.ActiveTurnID != "" {
				continue
			}
			publication, err := st.GetPublication(ctx, incident.ID)
			if err != nil || publication.State != core.PublicationFailed ||
				!publication.HasPR() ||
				!strings.Contains(publication.LastError, LegacyDirtyWorkspaceReviewError) {
				continue
			}
			changes, err := reader.Changes(ctx, incident.CoopSessionID)
			if err != nil {
				warn(policy, "inspect legacy failed publication workspace", incident.ID, err)
				continue
			}
			if len(changes.Staged) > 0 || len(changes.Unstaged) > 0 ||
				len(changes.Untracked) > 0 || len(changes.Conflicts) > 0 ||
				len(changes.Committed) == 0 || changes.ForkHead == "" ||
				changes.ForkHead == publication.RemoteSHA {
				continue
			}
			changed, err := st.MarkPublicationStale(
				ctx, incident.ID,
				"The committed task changes are ready for automatic PR review.",
			)
			if err != nil || !changed {
				if err != nil {
					warn(policy, "rearm legacy failed publication", incident.ID, err)
				}
				continue
			}
			publication, err = st.GetPublication(ctx, incident.ID)
			if err != nil {
				return err
			}
			if !publication.NeedsUpdate() {
				continue
			}
			input := core.SlackInput{
				ID:         "auto_recover_publish_" + incident.ID + "_" + fmt.Sprint(publication.Generation),
				EnvelopeID: "publication_recovery:" + incident.ID,
				EventID:    incident.LatestUpdateRunID, Kind: policy.InputKind,
				TeamID: policy.TeamID, ChannelID: incident.ChannelID,
				ThreadTS: incident.ConversationThreadTS(),
				ActionID: slackui.ActionPublishPR, ActionValue: incident.ID,
				ReceivedAt: policy.Now().UTC(),
			}
			if _, err := st.AdmitSlackInput(ctx, input); err != nil {
				return err
			}
		}
		if offset+len(incidents) >= total {
			return nil
		}
	}
}

func warn(policy RecoveryPolicy, message, incidentID string, err error) {
	if policy.Warn != nil {
		policy.Warn(message, incidentID, err)
	}
}

type Policy struct {
	Now         func() time.Time
	RetryAt     func(int) time.Time
	Terminal    func(core.SlackInput, error, int) bool
	SafeError   func(error) string
	ControlKind string
	Publish     func(context.Context, core.SlackInput, core.Incident) error
}

type Result struct {
	TerminalFailure bool
	Detail          string
}

func Process(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	policy Policy,
) (Result, error) {
	incident, err := st.GetIncident(ctx, input.ActionValue)
	if errors.Is(err, store.ErrNotFound) {
		return Result{}, st.FinishSlackInput(ctx, input.ID)
	}
	if err != nil {
		return retry(ctx, st, input, policy, err)
	}
	if incident.LatestUpdateRunID != input.EventID {
		return Result{}, st.FinishSlackInput(ctx, input.ID)
	}
	if incident.ActiveTurnID != "" {
		return Result{}, st.RetrySlackInput(ctx, input.ID,
			"waiting for the current engineering turn", policy.Now().Add(2*time.Second), false)
	}
	control := input
	control.Kind = policy.ControlKind
	if err := policy.Publish(ctx, control, incident); err != nil {
		return retry(ctx, st, input, policy, err)
	}
	return Result{}, st.FinishSlackInput(ctx, input.ID)
}

func retry(
	ctx context.Context,
	st *store.Store,
	input core.SlackInput,
	policy Policy,
	cause error,
) (Result, error) {
	attempt := input.Failures + 1
	terminal := policy.Terminal(input, cause, attempt)
	detail := policy.SafeError(cause)
	err := st.RetrySlackInputFailure(ctx, input.ID, detail, policy.RetryAt(attempt), terminal)
	return Result{TerminalFailure: terminal, Detail: detail}, err
}
