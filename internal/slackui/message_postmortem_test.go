package slackui

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

// The follow-up section used to end with "- [ ] Assign remaining corrective
// actions and owners", which is a document asking its reader to do the tracking
// by hand. Every episode this incident ran already produced a commitment with a
// title, a lifecycle state and a thread; a postmortem that lists checkboxes
// instead is throwing away tracking it already has.
//
// The three assertions are the three things an action item needs to stop being
// prose: what it is, where it stands, and how to reach the work. A ticked box
// for finished work is deliberate — a section that showed only what is
// outstanding would answer "what is left" and lose "what we did", and the second
// is most of what a reader opens a postmortem for.
func TestAPostmortemListsTrackedCommitmentsWithTheirThread(t *testing.T) {
	record := core.RemediationRecord{
		Incident: core.Incident{
			ID: "inc_1", Title: "Checkout latency", Severity: "sev1", ChannelID: "C123",
		},
		Commitments: []core.Commitment{
			{
				ID: "commitment_episode_1", Title: "Restart the stuck export job",
				State: core.CommitmentDone, ChannelID: "C123", ThreadTS: "1700.001",
			},
			{
				ID: "commitment_episode_2", Title: "Raise the pool ceiling before Monday",
				State: core.CommitmentBlocked, ChannelID: "C123", ThreadTS: "1700.500",
			},
		},
	}
	markdown := PostmortemDraft(record).Markdown
	for _, want := range []string{
		"- [x] Restart the stuck export job",
		"- [ ] Raise the pool ceiling before Monday",
		"`blocked`",
		"https://slack.com/app_redirect?channel=C123&message_ts=1700.500",
	} {
		if !strings.Contains(markdown, want) {
			t.Fatalf("the follow-up section omits %q:\n%s", want, markdown)
		}
	}
	if strings.Contains(markdown, "Assign remaining corrective actions") {
		t.Fatalf("tracked commitments did not replace the prose checklist:\n%s", markdown)
	}
}

// An incident that tracked nothing still needs somebody to say whether anything
// is owed. A silent section reads as "nothing is owed", which is a claim this
// document has no basis for.
func TestAPostmortemWithNoTrackedWorkStillAsksForOwners(t *testing.T) {
	markdown := PostmortemDraft(core.RemediationRecord{
		Incident: core.Incident{ID: "inc_1", Title: "Checkout latency", ChannelID: "C123"},
	}).Markdown
	if !strings.Contains(markdown, "Assign remaining corrective actions and owners") {
		t.Fatalf("an untracked incident lost its follow-up prompt:\n%s", markdown)
	}
}

// A commitment with no channel gets no link rather than a broken one. A
// postmortem full of dead links is a postmortem people stop clicking.
func TestACommitmentWithNoChannelIsListedWithoutALink(t *testing.T) {
	markdown := PostmortemDraft(core.RemediationRecord{
		Incident:    core.Incident{ID: "inc_1", Title: "Checkout latency"},
		Commitments: []core.Commitment{{Title: "Check the export job", State: core.CommitmentQueued}},
	}).Markdown
	if !strings.Contains(markdown, "Check the export job") {
		t.Fatalf("the commitment is missing:\n%s", markdown)
	}
	if strings.Contains(markdown, "app_redirect") {
		t.Fatalf("a channel-less commitment rendered a link:\n%s", markdown)
	}
}
