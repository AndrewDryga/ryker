package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
)

func promotionGrant() remediation.Grant {
	return remediation.Grant{
		ID: "grant-1",
		Trigger: remediation.TriggerClass{
			AlertGroupKey: "grafana:api-5xx:production",
			ChannelID:     "C0INCIDENT",
			Repository:    "api",
		},
		Action: remediation.ActionRef{
			ActionID:  "nomad.job.restart",
			PackRef:   "nomad@1.4.0+sha256:1111",
			RunnerRef: "runner:prod-us-east",
		},
		Rung:      remediation.RungPropose,
		GrantedBy: "U0OPERATOR",
		ExpiresAt: time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC),
	}
}

// TestAPromotionCardOffersExactlyOneConfirmationAndNoApproval is the shape rule
// for the most authority-sensitive card in the product.
//
// One control, and it confirms a GRANT. The card must not acquire an approve
// button, a decline button, or anything that could be read as a decision about
// a run — Slack-side approval of an Emisar decision was deliberately deleted
// from this codebase and this is the card most likely to grow it back, because
// it is the one card that is genuinely about authority.
func TestAPromotionCardOffersExactlyOneConfirmationAndNoApproval(t *testing.T) {
	message := WithGrantPromotionOffer(
		Message{Sections: []string{"I restarted the API job and the error rate returned to baseline."}},
		promotionGrant(), 3, `{"version":1}`, "30 days", "",
	)
	actions := allActions(message)
	if len(actions) != 1 {
		t.Fatalf("%d controls on a promotion card, want exactly one confirmation: %+v", len(actions), actions)
	}
	if actions[0].ID != ActionConfirmGrantPromotion {
		t.Fatalf("control is %q, want %q", actions[0].ID, ActionConfirmGrantPromotion)
	}
	if actions[0].Value != `{"version":1}` {
		t.Fatalf("control carries %q, want the confirmation payload", actions[0].Value)
	}
	if actions[0].Confirm == "" {
		t.Fatal("a grant of authority is confirmed without a confirmation dialog")
	}
	if !strings.Contains(actions[0].Confirm, "Emisar still approves every run") {
		t.Fatalf("the confirm dialog %q does not say Emisar still approves", actions[0].Confirm)
	}
}

// TestAPromotionCardShowsTheHostsOwnCountAndTheFullActionIdentity keeps the
// operator's decision resting on the things it must rest on.
//
// The count is the entire argument for the promotion, and it is the host's
// recomputed number rather than the model's claim. The identity is rendered in
// all three parts because that — not the action's friendly name — is what
// authority is being granted over.
func TestAPromotionCardShowsTheHostsOwnCountAndTheFullActionIdentity(t *testing.T) {
	grant := promotionGrant()
	message := WithGrantPromotionOffer(Message{}, grant, 4, "payload", "30 days", "")
	rendered := strings.Join(append(allRowText(message), message.Context...), "\n")
	for _, want := range []string{
		grant.Action.ActionID, grant.Action.PackRef, grant.Action.RunnerRef,
		grant.Trigger.AlertGroupKey, "4 verified successes",
	} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("the promotion card never says %q:\n%s", want, rendered)
		}
	}
	if !strings.Contains(rendered, "Nothing is granted yet") {
		t.Fatalf("the card does not say nothing is granted yet:\n%s", rendered)
	}
	if !strings.Contains(rendered, "never approves a run") {
		t.Fatalf("the card does not disclaim approving runs:\n%s", rendered)
	}
}

// TestTheEmisarApprovalCardStillHasNoApproveButton is a regression guard, not a
// new rule.
//
// The Slack-side approve and reject buttons were deliberately DELETED — Emisar
// owns approval, policy and audit, and a Slack button that approved an Emisar
// decision would put the authoritative decision in the least authoritative
// place. The trust ladder is exactly the feature that would tempt someone to
// bring them back ("the operator already trusts this action, why make them
// leave Slack"), so the assertion lives here, next to the ladder's own card.
//
// Both approval surfaces are checked: the card that asks for approval, and every
// state card that reports on one.
func TestTheEmisarApprovalCardStillHasNoApproveButton(t *testing.T) {
	approval := core.EmisarApproval{
		RequestID: "req-1", ActionID: "nomad.job.restart", RunnerRef: "runner:prod",
		PackRef: "nomad@1.4.0", RunID: "run-1", ApprovalURL: "https://emisar.example/approvals/1",
		ExpiresAt: time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC),
	}
	surfaces := map[string][]Action{
		"approval request": allActions(WithEmisarApproval(Message{}, approval)),
	}
	for _, status := range []string{
		"pending", "pending_approval", "sent", "running", "cancelling", "success",
		"failed", "error", "validation_failed", "unknown_action", "cancelled",
		"timed_out", "refused", "denied",
	} {
		stated := approval
		stated.Status = status
		surfaces["state:"+status] = allActions(EmisarApprovalStateMessage(stated, false))
	}
	for surface, actions := range surfaces {
		for _, action := range actions {
			if action.ID != ActionOpenApproval {
				t.Fatalf(
					"%s carries control %q; the only control an Emisar approval surface may "+
						"have is a link to Emisar (%q). Slack-side approve/reject was deleted "+
						"deliberately and must not come back",
					surface, action.ID, ActionOpenApproval,
				)
			}
			if action.URL == "" {
				t.Fatalf("%s control %q has no Emisar URL; it is not a link out", surface, action.ID)
			}
			for _, banned := range []string{"approve", "reject", "deny", "run now", "execute"} {
				if strings.Contains(strings.ToLower(action.Label), banned) {
					t.Fatalf("%s control is labelled %q, which reads as a decision Slack does not get to make", surface, action.Label)
				}
			}
		}
	}
}

// TestADemotionNoticeNamesItsReason keeps the automatic side legible. An
// operator who confirmed a promotion is entitled to learn it was taken back
// without them, and which of the four reasons it was.
func TestADemotionNoticeNamesItsReason(t *testing.T) {
	for _, tc := range []struct {
		reason remediation.DemotionReason
		says   string
	}{
		{remediation.VerificationFailed, "did not hold"},
		{remediation.ContractChanged, "no longer resolves"},
		{remediation.Expired, "reached its expiry"},
		{remediation.OperatorCommand, "took this grant back"},
	} {
		t.Run(string(tc.reason), func(t *testing.T) {
			grant := promotionGrant()
			grant.Rung = remediation.RungObserve
			message := GrantDemotedMessage(grant, tc.reason)
			rendered := strings.Join(append(message.Sections, message.Context...), "\n")
			if !strings.Contains(rendered, tc.says) {
				t.Fatalf("a %s demotion never says %q:\n%s", tc.reason, tc.says, rendered)
			}
			if len(message.Actions) != 0 {
				t.Fatalf("a demotion notice offered %d controls; demotion is not a decision", len(message.Actions))
			}
		})
	}
}

// allActions gathers every control on a card, wherever it sits: offers attach
// theirs to a row rather than the bottom pile, and a test that only read
// message.Actions would pass while the card carried an approve button.
func allActions(message Message) []Action {
	actions := append([]Action{}, message.Actions...)
	for _, row := range message.Rows {
		actions = append(actions, row.Actions...)
	}
	return actions
}

func allRowText(message Message) []string {
	text := append([]string{}, message.Sections...)
	for _, row := range message.Rows {
		text = append(text, row.Text)
	}
	return text
}
