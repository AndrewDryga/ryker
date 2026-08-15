package assignments

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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

func run(t *testing.T, repository Repository, command string) (Result, error) {
	t.Helper()
	return Run(
		context.Background(), repository, strings.Fields(command),
		core.SlackInput{ChannelID: "CALERTS", UserID: "UOPERATOR"},
		time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC),
	)
}

// The creation path exists, and what it creates cannot act.
//
// The consumption half of standing assignments has been complete and gated
// since migration 43 and has never once run, because nothing could create one:
// CreateStandingAssignment had no caller outside tests and both deployments
// held zero rows. This is the missing half, and the whole point of landing it
// this way is that it does not also grant the authority — the row it writes is
// shadowed, and the flag survives the round trip so the gate reads it back.
func TestCreatingAnAssignmentPersistsItWithTheGrantWithheld(t *testing.T) {
	ctx := context.Background()
	repository := openRepository(t)

	result, err := run(t, repository,
		"create repo=payments-api class=observability budget=2 days=30 "+
			"paths=src/payments/** signal=sentry payments timeout")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if result.Audit.Kind != "proactive.assignment" || result.Audit.Outcome != "created" ||
		result.Audit.ActorID != "UOPERATOR" {
		t.Fatalf("creation was not audited as an operator's grant: %+v", result.Audit)
	}
	if !strings.Contains(result.Audit.Detail, "shadow") {
		t.Fatalf("the audit line does not say the grant was withheld: %q", result.Audit.Detail)
	}

	saved, err := repository.ListForChannel(ctx, "CALERTS", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 1 {
		t.Fatalf("stored %d assignments, want one", len(saved))
	}
	if !saved[0].Shadow {
		t.Fatal("the created assignment may act unattended; shadow must be the default")
	}
	if saved[0].Repository != "payments-api" || saved[0].DailyBudget != 2 ||
		saved[0].SignalPattern != "sentry payments timeout" {
		t.Fatalf("the stored grant is not the one that was typed: %+v", saved[0])
	}
	// The receipt restates the scope, because agreeing once to unattended work
	// means this is the only moment anybody checks what was agreed to.
	receipt, err := json.Marshal(result.Message)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"shadow", "payments-api", "src/payments/**"} {
		if !strings.Contains(string(receipt), required) {
			t.Errorf("the creation receipt does not restate %q", required)
		}
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
	if _, err := run(t, repository,
		"create repo=payments-api class=observability signal=sentry timeout"); err != nil {
		t.Fatal(err)
	}
	saved, err := repository.ListForChannel(ctx, "CALERTS", 20)
	if err != nil || len(saved) != 1 {
		t.Fatalf("setup: %v %d", err, len(saved))
	}
	id := saved[0].ID

	if _, err := Run(ctx, repository, []string{"pause", id},
		core.SlackInput{ChannelID: "CELSEWHERE", UserID: "UOPERATOR"}, time.Now().UTC()); err == nil {
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
	if _, err := run(t, repository,
		"create repo=payments-api class=observability signal=sentry timeout"); err != nil {
		t.Fatal(err)
	}
	saved, err := repository.ListForChannel(ctx, "CALERTS", 20)
	if err != nil || len(saved) != 1 {
		t.Fatalf("setup: %v %d", err, len(saved))
	}

	empty, err := run(t, repository, "")
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := json.Marshal(empty.Message)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "nothing to judge it on") {
		t.Fatalf("a listing with no evaluations invented a verdict:\n%s", rendered)
	}

	for index := 0; index < 3; index++ {
		if _, err := repository.RecordEvaluation(ctx, core.StandingAssignmentEvaluation{
			AssignmentID: saved[0].ID, InputID: "in", Signal: "sentry timeout", Shadow: true,
			Verdict: "declined", Reason: "this has not happened often enough to be a pattern yet",
		}); err != nil {
			t.Fatal(err)
		}
	}
	listed, err := run(t, repository, "list")
	if err != nil {
		t.Fatal(err)
	}
	rendered, err = json.Marshal(listed.Message)
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
