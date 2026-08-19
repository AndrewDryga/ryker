package slackdismiss

import (
	"context"
	"errors"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/preparationnotice"
	"github.com/AndrewDryga/responder/internal/store"
)

type Membership interface {
	UserAllowed(context.Context, string, string) (bool, error)
}

type Deleter interface {
	Delete(context.Context, string, string) error
}

type Request struct {
	UserID, ChannelID, MessageTS, TeamID string
	Operator                             bool
}

type Result struct {
	Denial, AuditDetail string
}

func (r Result) Audit(input core.SlackInput) core.AuditEvent {
	return core.AuditEvent{
		Kind: "slack.message.dismissed", ActorID: input.UserID,
		ObjectID: input.ChannelID + ":" + input.MessageTS,
		Outcome:  "succeeded", Detail: r.AuditDetail,
	}
}

// Handle removes only the clicked Slack surface. Mutable preparation notices
// first retire their durable delivery epoch so a later retry cannot update the
// timestamp that the operator removed.
func Handle(
	ctx context.Context,
	st *store.Store,
	membership Membership,
	deleter Deleter,
	request Request,
) (Result, error) {
	if !request.Operator {
		return Result{Denial: "Only a configured operator can dismiss shared Responder messages. Nothing was removed."}, nil
	}
	allowed, err := membership.UserAllowed(ctx, request.UserID, request.TeamID)
	if err != nil {
		return Result{}, err
	}
	if !allowed {
		return Result{Denial: "Only active full workspace members can dismiss shared Responder messages. Nothing was removed."}, nil
	}
	if request.ChannelID == "" || request.MessageTS == "" {
		return Result{}, errors.New("dismiss message interaction has no Slack target")
	}
	delivery, err := st.GetSentSlackMessageDelivery(ctx, request.ChannelID, request.MessageTS)
	if err == nil && strings.HasPrefix(delivery.CoalesceKey, preparationnotice.CoalescePrefix) {
		if _, err := st.PreparationNotices.Retire(ctx, delivery.CoalesceKey); err != nil {
			return Result{}, err
		}
		return Result{AuditDetail: "temporary preparation notice retired"}, nil
	}
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return Result{}, err
	}
	if deleter == nil {
		return Result{}, errors.New("Slack client does not support deleting a message")
	}
	if err := deleter.Delete(ctx, request.ChannelID, request.MessageTS); err != nil &&
		!strings.Contains(strings.ToLower(strings.TrimSpace(err.Error())), "message_not_found") {
		return Result{}, err
	}
	return Result{AuditDetail: "temporary Responder message removed"}, nil
}
