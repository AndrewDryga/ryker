// This file is an EXTERNAL test package on purpose.
//
// internal/investigation imports internal/assignments so that offer_assignment
// is validated by the same function the confirmation click is measured against.
// internal/store reaches internal/investigation through the service's fanout,
// so an in-package test that opened a real database would be an import cycle.
// The external package is Go's own answer to exactly this, and the tests keep
// their real store rather than being rewritten against a fake — the invariants
// here are about what survives a round trip through SQLite.
package assignments_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/assignments"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/standingassignmentstore"
)

func openRepository(t *testing.T) *standingassignmentstore.Repository {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return st.StandingAssignments
}

func run(t *testing.T, repository assignments.Repository, command string) (
	assignments.Result, error,
) {
	t.Helper()
	return assignments.Run(
		context.Background(), repository, strings.Fields(command),
		core.SlackInput{ChannelID: "CALERTS", UserID: "UOPERATOR"},
	)
}

// seed writes a grant the way the confirmation click does, so the management
// verbs are tested against a row nothing in this package created.
func seed(t *testing.T, repository assignments.Repository) core.StandingAssignment {
	t.Helper()
	assignment, err := assignments.Normalize(core.StandingAssignmentOffer{
		Repository: "payments-api", ChangeClass: "observability",
		SignalPattern: "sentry timeout", PathGlobs: []string{"src/payments/**"},
		DailyBudget: 2, ExpiryDays: 30,
	}, "CALERTS", time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	assignment.ActorID = "UOPERATOR"
	saved, err := repository.Create(context.Background(), assignment)
	if err != nil {
		t.Fatal(err)
	}
	return saved
}

// The retired create verb answers with the conversation that replaced it.
//
// `/responder assignments create repo=... class=... signal=...` was the ONLY
// way to grant a standing assignment for the day and a half that feature
// existed, so it is the one verb in this family an operator has muscle memory
// for. "Unknown subcommand" would tell somebody who typed a command that worked
// last week that they typed it wrong, which is both false and useless: the
// capability still exists, it is just no longer a command. The pointer carries
// a worked example because the replacement is a sentence, and the operator who
// learned six key=value bounds has no reason to guess that plain English
// reaches further than the grammar did.
func TestTheRetiredCreateVerbPointsAtTheConversation(t *testing.T) {
	repository := openRepository(t)
	for _, verb := range []string{"create", "add", "new"} {
		t.Run(verb, func(t *testing.T) {
			_, err := run(t, repository, verb+" repo=payments-api class=observability signal=x")
			if err == nil {
				t.Fatal("the retired create verb still granted a standing assignment")
			}
			for _, required := range []string{"is gone", "Ask for it in the channel", "confirmation card"} {
				if !strings.Contains(err.Error(), required) {
					t.Errorf("the refusal does not say %q:\n%s", required, err)
				}
			}
		})
	}
	// And it granted nothing on the way past. A refusal that had already
	// written the row would be the worst of both surfaces.
	stored, err := repository.ListForChannel(context.Background(), "CALERTS", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(stored) != 0 {
		t.Fatalf("the retired verb created %d assignments", len(stored))
	}
}

// Pause, resume and delete reach exactly one assignment, in this channel.
//
// An id is guessable enough that a command typed in the wrong room must not
// revoke or resume authority granted in another one, and the refusal says
// nothing about whether that id exists elsewhere.
func TestManagingAnAssignmentStaysInsideItsOwnChannel(t *testing.T) {
	ctx := context.Background()
	repository := openRepository(t)
	id := seed(t, repository).ID

	if _, err := assignments.Run(ctx, repository, []string{"pause", id},
		core.SlackInput{ChannelID: "CELSEWHERE", UserID: "UOPERATOR"}); err == nil {
		t.Fatal("a command in another channel paused this channel's assignment")
	}
	if _, err := run(t, repository, "pause "+id); err != nil {
		t.Fatalf("pause: %v", err)
	}
	paused, err := repository.Get(ctx, id)
	if err != nil || paused.Enabled {
		t.Fatalf("pause left the assignment enabled: %+v %v", paused, err)
	}
	if _, err := run(t, repository, "resume "+id); err != nil {
		t.Fatalf("resume: %v", err)
	}
	resumed, err := repository.Get(ctx, id)
	if err != nil || !resumed.Enabled {
		t.Fatalf("resume left the assignment paused: %+v %v", resumed, err)
	}
	// Resuming must not also grant. Pausing is how an operator stops an
	// assignment they are unsure of, and a resume that quietly cleared the
	// shadow flag would turn the safest control into the most dangerous one.
	if !resumed.Shadow {
		t.Fatal("resuming an assignment granted it the authority it was created without")
	}
	if _, err := run(t, repository, "delete "+id); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := repository.Get(ctx, id); err == nil {
		t.Fatal("delete left the assignment behind")
	}
}

// The list answers with the tally, and says so when there is nothing to judge.
func TestTheListingCarriesTheTallyThatDecidesTheGrant(t *testing.T) {
	ctx := context.Background()
	repository := openRepository(t)
	saved := seed(t, repository)

	empty, err := run(t, repository, "")
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := json.Marshal(
		slackui.AssignmentDirectoryMessage(empty.Directory, empty.Tallies),
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "nothing to judge it on") {
		t.Fatalf("a listing with no evaluations invented a verdict:\n%s", rendered)
	}

	for index := 0; index < 3; index++ {
		if _, err := repository.RecordEvaluation(ctx, core.StandingAssignmentEvaluation{
			AssignmentID: saved.ID, InputID: "in", Signal: "sentry timeout", Shadow: true,
			Verdict: "declined", Reason: "this has not happened often enough to be a pattern yet",
		}); err != nil {
			t.Fatal(err)
		}
	}
	listed, err := run(t, repository, "list")
	if err != nil {
		t.Fatal(err)
	}
	rendered, err = json.Marshal(
		slackui.AssignmentDirectoryMessage(listed.Directory, listed.Tallies),
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"Evaluated 3", "would have opened 0", "refused 3",
		"granting it would change nothing yet",
	} {
		if !strings.Contains(string(rendered), required) {
			t.Errorf("the listing does not say %q:\n%s", required, rendered)
		}
	}
}
