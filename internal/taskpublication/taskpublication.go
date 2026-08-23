// Package taskpublication serializes the durable handoff from a completed
// engineering feedback turn to its existing pull request.
package taskpublication

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskaccess"
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

// CreationDue decides whether a finished task's committed changes reach GitHub
// without anyone pressing a button.
//
// Updating a PR that already exists has been automatic since this handoff was
// written and stays that way: the decision that this work belongs on GitHub was
// made when the PR was opened, and re-asking for it every turn is how a review
// loop acquires one button press per iteration. Opening the first PR is that
// decision, and github.automatic_draft_pr_creation is who may make it.
//
// A task whose provenance the host cannot read counts as a contributor's,
// matching UsesContributorAuthority: missing provenance must never imply
// operator authority, and the control is still on the card either way.
func CreationDue(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	publication core.Publication,
) (bool, error) {
	if publication.InProgress() {
		return false, nil
	}
	if publication.NeedsUpdate() {
		return true, nil
	}
	if publication.HasPR() {
		return false, nil
	}
	switch cfg.GitHub.AutomaticDraftPRCreation {
	case config.AutomaticDraftPRAllTasks:
		return true, nil
	case config.AutomaticDraftPROperatorTasks:
		contributor, err := taskaccess.UsesContributorAuthority(ctx, cfg, st, incident)
		if err != nil {
			return false, err
		}
		return !contributor, nil
	default:
		return false, nil
	}
}

// AutomaticPublication is the handoff a finished task should queue to reach its
// PR without a press, or nil when this task still wants the button.
//
// One entry point rather than a predicate and a constructor: whether to publish
// and what publishing looks like are the same question asked once per finished
// turn, and splitting them left the caller holding a boolean it had to remember
// to pair with the right input shape.
//
// An unreadable creator returns the error and no input. The caller logs it; the
// task keeps its control, which is the same outcome as a contributor task.
func AutomaticPublication(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	publication core.Publication,
	kind, runID, userID string,
	now time.Time,
) (*core.SlackInput, error) {
	due, err := CreationDue(ctx, cfg, st, incident, publication)
	if err != nil || !due {
		return nil, err
	}
	input := AutomaticInput(kind, cfg.Slack.TeamID, runID, userID, incident, now)
	return &input, nil
}

// AutomaticInput is the queued handoff a finished task uses to reach its PR
// without a press. It lives here beside RecoverLegacyDirtyFailures, which
// queues the same shape for the same reason, so the two cannot drift into
// disagreeing about what an automatic publication looks like.
func AutomaticInput(
	kind, teamID, runID, userID string,
	incident core.Incident,
	now time.Time,
) core.SlackInput {
	return core.SlackInput{
		ID: "auto_publish_" + runID, EnvelopeID: "agent_run:" + runID,
		EventID: runID, Kind: kind, TeamID: teamID,
		ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
		UserID:      userID,
		ActionID:    slackui.ActionPublishPR,
		ActionValue: incident.ID,
		ReceivedAt:  now,
	}
}
