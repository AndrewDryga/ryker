package service

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// ControlPlaneAct runs one incident-scoped operator action for the local web
// control plane, through the identical handler the Slack button calls.
//
// The dashboard cannot be given these paths any other way: publishing reviews
// the fork through the Coop client, discarding plans and executes a verified
// workspace deletion, and closing schedules cleanup — all against clients only
// this service holds. Reimplementing any of them against the store would be a
// second implementation of the safety rules, which is how a surface ends up
// with a button that skips the dirty-tree check.
//
// The Slack admission gate is mirrored, not skipped: Slack refuses every
// control except inspection and discard once the work is closed, so this
// entrance refuses the same ones rather than becoming the one door without
// the rule. The synthetic input carries the dashboard actor so the audit
// trail says where the action came from, and a fresh id so the outcome
// notices it enqueues are delivered rather than deduplicated away.
func (s *Service) ControlPlaneAct(ctx context.Context, action, incidentID, actor string) error {
	incident, err := s.store.GetIncident(ctx, incidentID)
	if err != nil {
		return fmt.Errorf("load the work record: %w", err)
	}
	inputID, err := core.NewID("cp")
	if err != nil {
		return err
	}
	input := core.SlackInput{ID: inputID, UserID: actor}
	closed := incident.Status == core.IncidentClosed
	switch action {
	case "publish":
		if closed {
			return errors.New("this work is closed, and Slack refuses publish on closed work too; discard is the remaining exit")
		}
		return s.publishDraftPR(ctx, input, incident)
	case "discard":
		return s.discardRetainedWork(ctx, input, incident)
	case "close":
		if closed {
			return errors.New("this work is already closed")
		}
		return s.closeIncident(ctx, input, incident)
	default:
		return fmt.Errorf("unsupported control plane action %q", action)
	}
}

// ControlPlaneChannelSetting writes a participation override the way the
// /responder slash command writes it: the same store call, the same three
// values, and "inherit" deleting the row rather than storing the word — an
// override that stored "inherit" would shadow the workspace default it is
// meant to defer to.
//
// Only the two overrides are offered. The channel-setup flow that writes
// channel_configurations is a guided Slack conversation with a repository
// catalogue behind it, and reproducing its choices in a form would be a second
// implementation of that flow rather than a view onto it.
func (s *Service) ControlPlaneChannelSetting(
	ctx context.Context,
	channelID, name, value, actor string,
) error {
	if name != proactiveSettingName && name != shadowSettingName {
		return fmt.Errorf("unsupported channel setting %q", name)
	}
	if value != "on" && value != "off" && value != "inherit" {
		return fmt.Errorf("channel setting %q must be on, off or inherit", name)
	}
	if strings.TrimSpace(channelID) == "" {
		return errors.New("a channel is required")
	}
	if value == "inherit" {
		if err := s.store.DeleteSlackSetting(ctx, "channel", channelID, name); err != nil &&
			!errors.Is(err, store.ErrNotFound) {
			return err
		}
		return nil
	}
	return s.store.SetSlackSetting(ctx, "channel", channelID, name, value, actor)
}
