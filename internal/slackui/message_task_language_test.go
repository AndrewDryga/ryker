package slackui

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// An engineering task is not an outage, and a surface that forgets it tells a
// teammate their rename is an incident.
//
// The 2026-08-14 live-feedback audit found seven surfaces presuming one at
// once: a failed turn on a rename said "Investigation could not finish", the
// App Home flew every task under the red firing glyph and "Creating incident
// room", `/responder help` in an engineering room offered to continue "the
// same incident conversation", and the four record reports described an outage
// that never happened. None of it was wrong about the state — all of it was
// wrong about what the work was, which is the kind of copy that trains a
// reader to stop believing the rest of the card.
//
// Each table below pins one surface's split. They are deliberately paired: the
// incident half is asserted beside the task half so that a future edit which
// "fixes" a task surface by flattening both into one neutral noun fails here
// too.

func taskLanguageRoomTask() core.Incident {
	return core.Incident{
		ID:        "inc_task_room",
		Title:     "Rename the retry helper",
		WorkKind:  core.WorkKindEngineeringTask,
		WorkScope: core.WorkScopeRoom,
	}
}

func taskLanguageThreadTask() core.Incident {
	return core.Incident{
		ID:        "inc_task_thread",
		Title:     "Rename the retry helper",
		WorkKind:  core.WorkKindEngineeringTask,
		WorkScope: core.WorkScopeThread,
	}
}

func taskLanguageIncident() core.Incident {
	return core.Incident{
		ID:        "inc_alert",
		Title:     "Checkout latency above budget",
		WorkScope: core.WorkScopeRoom,
	}
}

// wordingCase is one rendered surface plus what it must and must not claim.
type wordingCase struct {
	name   string
	text   string
	says   []string
	denies []string
}

func checkWording(t *testing.T, cases []wordingCase) {
	t.Helper()
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			for _, want := range testCase.says {
				if !strings.Contains(testCase.text, want) {
					t.Errorf("missing %q in:\n%s", want, testCase.text)
				}
			}
			for _, reject := range testCase.denies {
				if strings.Contains(testCase.text, reject) {
					t.Errorf("still claims %q in:\n%s", reject, testCase.text)
				}
			}
		})
	}
}

func TestAFailedTurnNamesTheWorkItThenStopped(t *testing.T) {
	checkWording(t, []wordingCase{
		{
			name: "task",
			text: cardText(TurnFailureMessage(
				taskLanguageRoomTask(), "failed", "the Coop session went away",
			)),
			says:   []string{"Task could not finish", "the changes made so far are preserved"},
			denies: []string{"Investigation", "evidence"},
		},
		{
			name: "incident",
			text: cardText(TurnFailureMessage(
				taskLanguageIncident(), "failed", "the Coop session went away",
			)),
			says: []string{
				"Investigation could not finish",
				"the evidence collected so far are preserved",
			},
		},
		{
			// Cancelling is the system obeying the operator, and it reads the
			// same either way — the split must not grow a third voice here.
			name: "cancelled task",
			text: cardText(TurnFailureMessage(
				taskLanguageRoomTask(), "cancelled", "operator stopped the turn",
			)),
			says:   []string{"Stopped — you asked me to."},
			denies: []string{"Investigation"},
		},
	})
}

func TestAnUnreadableResultNamesTheWorkThatProducedIt(t *testing.T) {
	checkWording(t, []wordingCase{
		{
			name: "task",
			text: cardText(AgentReportFailureMessage(taskLanguageRoomTask())),
			says: []string{
				"The engineering task ran",
				"The isolated changes are preserved",
			},
			denies: []string{"investigation", "findings"},
		},
		{
			name: "incident",
			text: cardText(AgentReportFailureMessage(taskLanguageIncident())),
			says: []string{"The investigation ran", "The findings and workspace are preserved"},
		},
	})
}

// The App Home strip is the one place a reader sees every open work item side
// by side, so an engineering task wearing 🔴 Firing there is the audit's most
// visible false claim: it puts a refactor and a paging outage in the same
// column with the same colour.
func TestTheInFlightStripFliesTasksUnderTheirOwnGlyph(t *testing.T) {
	home := func(incident core.Incident) string {
		return homeContent(OperationsHome(
			1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			[]core.Incident{incident}, nil, nil, nil, nil, nil,
		))
	}
	provisioning := taskLanguageRoomTask()
	provisioning.Workflow = core.WorkflowProvisioningChannel
	firing := taskLanguageIncident()
	firing.Workflow = core.WorkflowProvisioningChannel
	firing.FiringCount, firing.SignalCount = 1, 1
	working := taskLanguageRoomTask()
	working.Workflow = core.WorkflowInvestigating

	checkWording(t, []wordingCase{
		{
			name:   "task being provisioned",
			text:   home(provisioning),
			says:   []string{"⚙️", "Creating working room"},
			denies: []string{"🔴", "Creating incident room"},
		},
		{
			name: "incident being provisioned",
			text: home(firing),
			says: []string{"🔴", "Creating incident room"},
		},
		{
			name:   "task with a turn running",
			text:   home(working),
			says:   []string{"Working"},
			denies: []string{"Investigating", "🔴"},
		},
	})
}

func TestHelpOffersToContinueTheWorkTheChannelActuallyHolds(t *testing.T) {
	checkWording(t, []wordingCase{
		{
			name:   "room-scoped task",
			text:   cardText(HelpMessage(taskLanguageRoomTask())),
			says:   []string{"continues the same isolated session"},
			denies: []string{"incident conversation"},
		},
		{
			name: "incident room",
			text: cardText(HelpMessage(taskLanguageIncident())),
			says: []string{"continues the same incident conversation"},
		},
		{
			// A thread-scoped task already had its own sentence, and it is the
			// one this fix must not disturb.
			name:   "thread-scoped task",
			text:   cardText(HelpMessage(taskLanguageThreadTask())),
			says:   []string{"continues the same isolated session"},
			denies: []string{"incident"},
		},
	})
}

func TestAProvisioningRoomIsDescribedAsTheRoomItWillBe(t *testing.T) {
	roomTask := taskLanguageRoomTask()
	roomTask.Workflow = core.WorkflowProvisioningChannel
	incident := taskLanguageIncident()
	incident.Workflow = core.WorkflowProvisioningChannel
	threadTask := taskLanguageThreadTask()
	threadTask.Workflow = core.WorkflowProvisioningChannel

	checkWording(t, []wordingCase{
		{
			name:   "room-scoped task",
			text:   workflowStateDescription(roomTask),
			says:   []string{"dedicated engineering room"},
			denies: []string{"incident room"},
		},
		{
			name: "incident",
			text: workflowStateDescription(incident),
			says: []string{"dedicated incident room"},
		},
		{
			name: "thread-scoped task",
			text: workflowStateDescription(threadTask),
			says: []string{"task card", "isolated work session"},
		},
	})
}

// The incident twin of the blocked-with-no-reason fix taskAsk already carries:
// *Action needed* is rendered only when the work item recorded an error, so
// pointing a reader at it otherwise sends them hunting for a section that is
// not on the card.
func TestABlockedStatusPointsAtASectionOnlyWhenThereIsOne(t *testing.T) {
	blockedTask := taskLanguageRoomTask()
	blockedTask.Workflow = core.WorkflowBlocked
	blockedIncident := taskLanguageIncident()
	blockedIncident.Workflow = core.WorkflowBlocked
	explained := taskLanguageIncident()
	explained.Workflow = core.WorkflowBlocked
	explained.LastError = "The repository lease is held by another session."

	checkWording(t, []wordingCase{
		{
			name:   "task blocked with no recorded reason",
			text:   cardText(IncidentStatusMessage(blockedTask)),
			says:   []string{"close the engineering task"},
			denies: []string{"Action needed"},
		},
		{
			name:   "incident blocked with no recorded reason",
			text:   cardText(IncidentStatusMessage(blockedIncident)),
			says:   []string{"close the incident"},
			denies: []string{"Action needed"},
		},
		{
			name: "incident blocked with a recorded reason",
			text: cardText(IncidentStatusMessage(explained)),
			says: []string{"Read *Action needed*"},
		},
	})
}

// The timeline, evidence, handoff and postmortem reports all resolve through
// the work item they were asked for, and an engineering room holds an
// engineering task — so all four were reporting on an outage that never
// happened.
func TestTheRecordReportsNameTheWorkTheyWereBuiltFrom(t *testing.T) {
	taskRecord := core.RemediationRecord{Incident: taskLanguageRoomTask()}
	incidentRecord := core.RemediationRecord{Incident: taskLanguageIncident()}

	checkWording(t, []wordingCase{
		{
			name:   "timeline for a task",
			text:   cardText(TimelineMessage(taskRecord)),
			says:   []string{"Engineering task timeline", "No engineering task activity"},
			denies: []string{"Incident", "incident"},
		},
		{
			name: "timeline for an incident",
			text: cardText(TimelineMessage(incidentRecord)),
			says: []string{"Remediation timeline", "No incident activity"},
		},
		{
			name:   "timeline report headline for a task",
			text:   TimelineReport(taskRecord).Headline,
			says:   []string{"No engineering task activity"},
			denies: []string{"incident"},
		},
		{
			name:   "evidence for a task",
			text:   cardText(EvidenceDirectoryMessage(taskLanguageRoomTask(), nil, nil)),
			says:   []string{"Evidence for engineering task"},
			denies: []string{"for incident"},
		},
		{
			name: "evidence for an incident",
			text: cardText(EvidenceDirectoryMessage(taskLanguageIncident(), nil, nil)),
			says: []string{"Evidence for incident"},
		},
		{
			name:   "evidence report headline for a task",
			text:   EvidenceReport(taskLanguageRoomTask(), nil, nil).Headline,
			says:   []string{"for this engineering task yet"},
			denies: []string{"incident"},
		},
		{
			name:   "handoff for a task",
			text:   cardText(HandoffMessage(taskRecord)),
			says:   []string{"Shift handoff", "Rename the retry helper"},
			denies: []string{"Signals:", "Severity:"},
		},
		{
			name: "handoff for an incident",
			text: cardText(HandoffMessage(incidentRecord)),
			says: []string{"**Signals:**", "**Severity:**", "Checkout latency"},
		},
		{
			name:   "handoff report headline for a task",
			text:   HandoffReport(taskRecord).Headline,
			denies: []string{"signals firing", "severity"},
		},
		{
			name: "handoff report headline for an incident",
			text: HandoffReport(incidentRecord).Headline,
			says: []string{"0 of 0 signals firing", "severity unclassified"},
		},
		{
			name:   "postmortem draft for a task",
			text:   cardText(PostmortemDraft(taskRecord)),
			says:   []string{"Engineering task review draft", "**Engineering task:**"},
			denies: []string{"Post-incident", "**Incident:**"},
		},
		{
			name: "postmortem draft for an incident",
			text: cardText(PostmortemDraft(incidentRecord)),
			says: []string{"Post-incident draft", "**Incident:**"},
		},
	})
}
