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
// room watched. The "nothing has finished yet" answer stays private to the
// asker: it is a fact about their timing rather than about the work, and a
// shared thread post would be noise for everyone who did not ask.
//
// Private, but in the same thread. An ephemeral with no thread_ts lands at
// channel level whichever message was clicked, so on a thread-scoped task this
// answer was being delivered outside the thread the operator was reading — the
// receipt button looked broken while Slack was faithfully showing the reply
// somewhere else.
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
		return s.finishSlashInput(
			ctx, input, turnreceipt.NoFinishedTurn, controlReplyThread(input, incident),
		)
	}
	return s.enqueue(
		ctx, "out_turn_receipt_"+input.ID, incident, "notice",
		incident.ConversationThreadTS(), slackui.TurnReceiptMessage(receipt),
	)
}
