// Package watchpresence owns the visible state machine for watched Slack app
// cards. Standing rules may customize the working reaction, but channel watch
// ownership and terminal handling do not depend on a rule existing.
package watchpresence

import (
	"context"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

const (
	Working = "eyes"
	Handled = "white_check_mark"
)

type reactor interface {
	React(context.Context, string, string, string) error
}

type unreactor interface {
	Unreact(context.Context, string, string, string) error
}

// Acknowledge claims one watched card when Slack reactions are available.
func Acknowledge(
	ctx context.Context,
	candidate any,
	channelID, messageTS, reaction string,
	enabled bool,
) (bool, error) {
	client, ok := candidate.(reactor)
	if !enabled || reaction == "" || messageTS == "" || !ok {
		return false, nil
	}
	if err := client.React(ctx, channelID, messageTS, reaction); err != nil {
		return false, err
	}
	return true, nil
}

// FinishHandled replaces an optional working acknowledgement with the terminal
// handled mark for a lifecycle update that needed no model turn.
func FinishHandled(
	ctx context.Context,
	candidate any,
	channelID, messageTS, acknowledgement string,
) error {
	client, ok := candidate.(interface {
		reactor
		unreactor
	})
	if messageTS == "" || !ok {
		return nil
	}
	if acknowledgement != "" {
		if err := client.Unreact(ctx, channelID, messageTS, acknowledgement); err != nil {
			return err
		}
	}
	return client.React(ctx, channelID, messageTS, Handled)
}

// ClearEvent removes a working acknowledgement and returns the audit fact the
// host should persist. Slack reaction failures are cosmetic and represented in
// that fact rather than returned as work failures.
func ClearEvent(
	ctx context.Context,
	candidate any,
	channelID, messageTS, reaction, objectID string,
) *core.AuditEvent {
	client, ok := candidate.(unreactor)
	if messageTS == "" || !ok {
		return nil
	}
	event := &core.AuditEvent{
		Kind: "standing_rule.acknowledgement_cleared", ActorID: "responder",
		ObjectID: objectID, Outcome: "unreacted", Detail: reaction,
	}
	if err := client.Unreact(ctx, channelID, messageTS, reaction); err != nil {
		event.Kind = "standing_rule.acknowledgement_clear_failed"
		event.Outcome = "failed"
		event.Detail = core.TruncateUTF8(strings.TrimSpace(err.Error()), 500)
	}
	return event
}

// HandledEvent adds the terminal mark and returns its durable audit fact.
func HandledEvent(
	ctx context.Context,
	candidate any,
	channelID, messageTS, objectID string,
) *core.AuditEvent {
	client, ok := candidate.(reactor)
	if messageTS == "" || !ok {
		return nil
	}
	event := &core.AuditEvent{
		Kind: "standing_rule.acknowledgement_answered", ActorID: "responder",
		ObjectID: objectID, Outcome: "reacted", Detail: Handled,
	}
	if err := client.React(ctx, channelID, messageTS, Handled); err != nil {
		event.Kind = "standing_rule.acknowledgement_answer_failed"
		event.Outcome = "failed"
		event.Detail = core.TruncateUTF8(strings.TrimSpace(err.Error()), 500)
	}
	return event
}

// Acknowledgement returns the configured standing-rule reaction or the
// default custody mark for a watched app message.
func Acknowledgement(inputKind, configured string) string {
	if configured != "" {
		return configured
	}
	if inputKind == "bot_message" {
		return Working
	}
	return ""
}

// LeavesHandledMark reports whether finishing the decision should replace the
// working reaction with the host's terminal handled mark.
func LeavesHandledMark(acknowledged, shadow bool, action string) bool {
	return acknowledged && !shadow && action != "react"
}
