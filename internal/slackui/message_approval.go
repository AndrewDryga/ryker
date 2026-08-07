package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func WithEmisarApproval(message Message, approval core.EmisarApproval) Message {
	message.Header = "Approval required in Emisar"
	message.Text = truncateUTF8(
		"Emisar approval required for "+approval.ActionID+
			". Nothing has executed. Review the request in Emisar: "+approval.ApprovalURL,
		4000,
	)
	followup := "I’ll watch this request and update this card automatically. " +
		"You can keep using Slack while it waits."
	message.Sections = append(message.Sections,
		"Emisar paused `"+safeInlineCode(approval.ActionID)+"` before it ran. "+
			"Review the exact target, arguments, evidence, blast radius, and policy decision in Emisar.",
		fmt.Sprintf(
			"*Approval expires:* %s\n*Runner:* `%s`\n*Pack:* `%s`",
			approval.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC"),
			safeInlineCode(approval.RunnerRef),
			safeInlineCode(approval.PackRef),
		),
		followup,
	)
	message.Context = append(
		message.Context,
		"Run `"+safeInlineCode(approval.RunID)+"` is waiting. Approval happens only in Emisar; "+
			"opening the link does not execute it.",
	)
	actions := message.Actions[:0]
	for _, action := range message.Actions {
		if action.ID != ActionApproveProposal && action.ID != ActionRejectProposal {
			actions = append(actions, action)
		}
	}
	message.Actions = append(actions, Action{
		ID:    ActionOpenApproval,
		Label: "Review approval in Emisar",
		Value: approval.RequestID,
		Style: "primary",
		URL:   approval.ApprovalURL,
	})
	return message
}

func EmisarApprovalStateMessage(
	approval core.EmisarApproval,
	continuing bool,
) Message {
	status := safeInlineCode(approval.Status)
	action := safeInlineCode(approval.ActionID)
	runner := safeInlineCode(approval.RunnerRef)
	header := "Emisar is waiting for approval"
	summary := "`" + action + "` is still waiting for an operator decision in Emisar."
	next := "I’ll keep watching this request and update this card automatically."
	switch approval.Status {
	case "pending", "sent", "running", "cancelling":
		header = "Emisar is running the approved action"
		summary = "`" + action + "` is now `" + status + "` on `" + runner + "`."
		next = "I’ll post the result here when Emisar finishes. You can keep using Slack meanwhile."
	case "success":
		header = "Emisar action completed"
		summary = "Emisar reports that `" + action + "` completed successfully on `" + runner + "`."
		next = "The final result is recorded in Emisar."
	case "denied":
		header = "Emisar action was not approved"
		summary = "Emisar reports that `" + action + "` was denied and did not run."
		next = "No operational change was made by this request."
	case "cancelled":
		header = "Emisar action was cancelled"
		summary = "Emisar reports that `" + action + "` was cancelled."
		next = "The run is terminal; check Emisar for its authoritative audit trail."
	case "failed", "error", "validation_failed", "unknown_action", "timed_out", "refused":
		header = "Emisar action did not complete"
		summary = "Emisar reports that `" + action + "` ended as `" + status + "` on `" + runner + "`."
		next = "The run is terminal; check Emisar for its authoritative error and audit trail."
	}
	if continuing {
		next += " I’m checking the terminal result and will post a concise follow-up here."
	}
	sections := []string{summary, next}
	if strings.TrimSpace(approval.LastError) != "" {
		sections = append(sections, "*Reported by Emisar:* "+truncateUTF8(approval.LastError, 800))
	}
	url := approval.RunURL
	label := "Open run in Emisar"
	if url == "" {
		url = approval.ApprovalURL
		label = "Open request in Emisar"
	}
	message := Message{
		Text: truncateUTF8(
			header+": "+approval.ActionID+" is "+approval.Status+". "+url,
			4000,
		),
		Header:   header,
		Sections: sections,
		Context: []string{
			"Run `" + safeInlineCode(approval.RunID) + "` · Emisar remains authoritative for execution, policy, and audit.",
		},
	}
	if url != "" {
		message.Actions = []Action{{
			ID: ActionOpenApproval, Label: label, Value: approval.RequestID,
			Style: "primary", URL: url,
		}}
	}
	return message
}
