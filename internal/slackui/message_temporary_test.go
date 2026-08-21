package slackui

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
)

// Temporary surfaces are the reproducible views and receipts around durable
// work, not the work itself. This inventory keeps the distinction explicit:
// adding a new constructor cannot be justified by calling every bot message
// temporary, and a new empty-directory branch cannot quietly lose Dismiss.
func TestEveryTemporaryCardFamilyIsMarkedDismissible(t *testing.T) {
	incident := taskFixture()
	record := core.RemediationRecord{Incident: incident}
	cards := map[string]Message{
		"plain notice":                    Notice("Queued."),
		"repository preparation":          RepositoryPreparationBlocked("repo"),
		"read-only preparation":           ReadOnlyWorkspaceBlocked("repo", time.Time{}),
		"workspace preparation":           WorkspacePreparationBlocked("repo", time.Time{}),
		"help":                            HelpMessage(incident),
		"status":                          IncidentStatusMessage(incident),
		"diff":                            ChangesMessage(incident, "One file changed.", nil, ChangesNavigation{}),
		"turn receipt":                    TurnReceiptMessage(TurnReceipt{}),
		"record directory":                RecordDirectoryMessage(core.RemediationRecord{Incident: incident}),
		"evidence directory":              EvidenceDirectoryMessage(incident, nil, nil),
		"assignment directory empty":      AssignmentDirectoryMessage(nil, nil),
		"schedule directory empty":        ScheduleDirectoryMessage(nil),
		"preference directory empty":      PreferenceDirectoryMessage(nil),
		"rule directory empty":            RuleDirectoryMessage(nil),
		"memory directory empty":          MemoryDirectoryMessage(nil),
		"commitment directory empty":      CommitmentDirectoryMessage(nil),
		"receipt shape":                   receiptCard("Saved.", "Saved.", "Value", nil),
		"state-change shape":              stateChangeCard("Paused.", "Paused.", ""),
		"directory shape":                 directoryCard(Message{Text: "Directory"}, nil, ""),
		"timeline":                        TimelineMessage(record),
		"handoff":                         HandoffMessage(record),
		"postmortem view":                 PostmortemDraft(record),
		"canvas pointer":                  ReportCanvasCard(Report{Title: "Report", Headline: "Ready"}, "https://example.slack.com/canvas"),
		"manual handoff":                  ManualHandoff("CROOM"),
		"scheduled-start acknowledgement": ScheduledRunStartedMessage(core.ScheduledTask{Title: "Health check"}, time.Now()),
		"nothing-scheduled receipt":       SchedulesSavedMessage(nil),
		"setup moved receipt":             ChannelSetupMoved(true),
		"setup cancelled receipt":         ChannelSetupCancelled(),
		"publication receipt":             PublicationMessage(core.Publication{PRNumber: 42}, false),
		"publication lifecycle receipt": PublicationLifecycleMessage(
			core.Publication{PRNumber: 42}, "Fix health check", "checks", "succeeded",
			"Checks passed.", core.PublicationLifecycleStatus{},
		),
		"grant demotion receipt": GrantDemotedMessage(
			remediation.Grant{}, remediation.DemotionReason("test"),
		),
	}
	for name, card := range cards {
		if !card.Temporary {
			t.Errorf("%s is not marked temporary", name)
		}
	}
}

func TestDurableAndUnresolvedCardsCannotBeDismissed(t *testing.T) {
	incident := taskFixture()
	cards := map[string]Message{
		"final response":  ConversationResponse("Investigation finished.", NewSanitizer(12000)),
		"review decision": ReviewMessage(incident, "Ready for review.", true),
		"approval state": EmisarApprovalStateMessage(core.EmisarApproval{
			ActionID: "service.restart", Status: "pending", RunnerRef: "runner-1",
		}, false),
		"run result": RunCheckVerdictMessage(RunCheckVerdict{
			Subject: "Terraform apply", Outcome: RunCheckClean,
		}),
	}
	for name, card := range cards {
		if card.Temporary {
			t.Errorf("%s was marked temporary", name)
		}
	}
}
