// Slack shows a status line beside a thread and rotates a list of "loading
// messages" underneath it while work runs. The status says what is happening
// now; these say what the work consists of, and Slack cycles them on its own
// without another API call.
//
// They live here rather than beside the code that sets a status because they
// are presentation vocabulary and nothing else — no store, no clock, no
// decision — and the package that owns every other string a card shows is the
// right place for the ones a status shows.
package slackui

import "strings"

// ProgressMilestones are the steps Slack rotates beneath a status.
func ProgressMilestones(status string) []string {
	switch {
	case strings.Contains(status, "explaining"):
		return []string{
			"Reading the earlier answer",
			"Writing a simpler explanation",
		}
	case strings.Contains(status, "scheduling"):
		return []string{
			"Checking the requested timing",
			"Preparing the follow-up for confirmation",
		}
	case strings.Contains(status, "approved action"):
		return []string{
			"Checking that the information is still current",
			"Checking exactly what will change",
			"Requesting policy authorization from Emisar",
			"Waiting for verification",
		}
	case strings.Contains(status, "review"):
		return []string{
			"Reading the code changes",
			"Checking whether the branch is current",
			"Running the project's checks",
			"Writing the review",
		}
	default:
		return []string{
			"Checking the repository setup",
			"Checking live systems",
			"Comparing expected and current state",
			"Checking what remains unknown",
			"Checking whether the result is complete",
		}
	}
}

// WatchProgressSteps are the steps for a watched conversation turn, whose
// first act is reading the conversation it was mentioned in.
func WatchProgressSteps() []string {
	return []string{
		"Reading the conversation",
		"Checking the repository setup",
		"Checking live systems",
		"Comparing expected and current state",
		"Checking whether the result is complete",
	}
}
