package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/turnreceipt"
)

// turnReceipt answers what the latest finished turn did. The reading of the
// record is turnreceipt's; what is left here is where the answer goes.
//
// The receipt lands in the thread beside the card, because it is about work the
// room watched. The "nothing has finished yet" answer does not: it is a fact
// about the asker's timing rather than about the work, and posting it in a
// shared thread would be noise for everyone who did not ask.
func (s *Service) turnReceipt(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	receipt, ok, err := turnreceipt.Compose(ctx, turnreceipt.Sources{
		Runs: s.store, Activity: s.store.Activity,
		Findings: s.store.Intelligence, Turns: s.coop, Log: s.log,
	}, incident.ID)
	if err != nil {
		return err
	}
	if !ok {
		return s.finishSlashInput(ctx, input, turnreceipt.NoFinishedTurn)
	}
	return s.enqueue(
		ctx, "out_turn_receipt_"+input.ID, incident, "notice",
		incident.ConversationThreadTS(), slackui.TurnReceiptMessage(receipt),
	)
}
