package taskpublication

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// creationFixture builds a task whose creator is exactly who the caller says,
// because that provenance is the whole input to the operator_tasks decision.
func creationFixture(t *testing.T, mode, creator string) (config.Config, *store.Store, core.Incident) {
	t.Helper()
	cfg := config.Config{StateDir: t.TempDir()}
	cfg.Slack.Operators = []string{"UOPERATOR"}
	cfg.GitHub.AutomaticDraftPRCreation = mode
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident, created, err := st.CreateMemberEngineeringTask(
		context.Background(), "repo", "src-1", "Task", "summary", creator,
		"COPS", "1700.001", 100, 2, 30*time.Second,
	)
	if err != nil || !created {
		t.Fatalf("task not created: %+v err=%v", incident, err)
	}
	return cfg, st, incident
}

func due(t *testing.T, mode, creator string, publication core.Publication) bool {
	t.Helper()
	cfg, st, incident := creationFixture(t, mode, creator)
	result, err := CreationDue(context.Background(), cfg, st, incident, publication)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

// The first draft PR is the moment work reaches GitHub, and it used to cost an
// operator a button press on every task. operator_tasks removes the press from
// the path an operator started without moving the boundary that a teammate's
// contributor task still needs an operator.
func TestOperatorStartedTaskOpensItsFirstDraftPRWithoutAPress(t *testing.T) {
	if !due(t, config.AutomaticDraftPROperatorTasks, "UOPERATOR", core.Publication{}) {
		t.Error("an operator's own task still waits for an operator to press a button")
	}
}

func TestContributorTaskStillNeedsAnOperatorForItsFirstDraftPR(t *testing.T) {
	if due(t, config.AutomaticDraftPROperatorTasks, "UTEAMMATE", core.Publication{}) {
		t.Error("a teammate's task opened a PR on the real repository with no operator involved")
	}
}

func TestAllTasksModeOpensAContributorTaskFirstDraftPR(t *testing.T) {
	if !due(t, config.AutomaticDraftPRAllTasks, "UTEAMMATE", core.Publication{}) {
		t.Error("all_tasks left a contributor task waiting for a press")
	}
}

func TestOffKeepsTheOperatorPressForEveryFirstDraftPR(t *testing.T) {
	if due(t, config.AutomaticDraftPROff, "UOPERATOR", core.Publication{}) {
		t.Error("off opened a PR anyway")
	}
}

// Updating a PR that already exists predates this setting and must not start
// depending on it: a review loop that asks for a press per iteration is the
// thing the automatic handoff was written to remove.
func TestExistingPullRequestKeepsUpdatingItselfEvenWhenCreationIsOff(t *testing.T) {
	stale := core.Publication{
		State: core.PublicationStale, PRNumber: 41,
		PRURL: "https://github.test/o/r/pull/41",
	}
	if !due(t, config.AutomaticDraftPROff, "UTEAMMATE", stale) {
		t.Error("an open PR stopped updating itself because creation was disabled")
	}
}

// A publication already reviewing or publishing must not be queued a second
// time by the turn that is finishing while it runs.
func TestPublicationInFlightIsNotQueuedTwice(t *testing.T) {
	for _, state := range []core.PublicationState{
		core.PublicationReviewing, core.PublicationPublishing, core.PublicationRetrying,
	} {
		if due(t, config.AutomaticDraftPRAllTasks, "UOPERATOR", core.Publication{State: state}) {
			t.Errorf("queued a second publication while one was %s", state)
		}
	}
}

// The caller gets an input it can queue, or nil, and never a boolean it has to
// remember to pair with the right shape.
func TestAutomaticPublicationQueuesTheHandoffItDecidedOn(t *testing.T) {
	cfg, st, incident := creationFixture(t, config.AutomaticDraftPROperatorTasks, "UOPERATOR")
	cfg.Slack.TeamID = "T123ABC"
	now := time.Date(2026, 8, 22, 12, 0, 0, 0, time.UTC)

	input, err := AutomaticPublication(
		context.Background(), cfg, st, incident, core.Publication{},
		"task_publication", "run_9", "UOPERATOR", now,
	)
	if err != nil {
		t.Fatal(err)
	}
	if input == nil {
		t.Fatal("an operator's task produced no handoff")
	}
	if input.ActionValue != incident.ID || input.EventID != "run_9" ||
		input.Kind != "task_publication" || input.TeamID != "T123ABC" {
		t.Fatalf("handoff does not address this task and run: %+v", input)
	}
}

func TestAutomaticPublicationReturnsNothingWhenTheTaskWantsTheButton(t *testing.T) {
	cfg, st, incident := creationFixture(t, config.AutomaticDraftPROperatorTasks, "UTEAMMATE")

	input, err := AutomaticPublication(
		context.Background(), cfg, st, incident, core.Publication{},
		"task_publication", "run_9", "UTEAMMATE", time.Now().UTC(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if input != nil {
		t.Fatalf("a contributor task queued a publication anyway: %+v", input)
	}
}

// A merged PR left its task open holding a Coop fork until a person pressed
// Close task. Nothing closed it: the follower marks the followup merged, parks
// its next check in the year 9999, and stops looking. On 2026-08-23 three tasks
// across two deployments had been sitting that way for eight to twelve days.
func TestMergedTaskIsClosedWithoutAnyonePressingAnything(t *testing.T) {
	_, st, incident := creationFixture(t, config.AutomaticDraftPROff, "UOPERATOR")
	ctx := context.Background()
	seedPublishedPR(t, st, incident.ID)
	markMerged(t, st, incident.ID)

	closed := []string{}
	if err := CloseMergedTasks(ctx, st, func(_ context.Context, c core.Incident) error {
		closed = append(closed, c.ID)
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if !slices.Contains(closed, incident.ID) {
		t.Errorf("a task whose PR merged was left open: closed %v", closed)
	}
}

// The floor: a task whose PR is still open is still being worked on.
func TestUnmergedTaskIsLeftAlone(t *testing.T) {
	_, st, incident := creationFixture(t, config.AutomaticDraftPROff, "UOPERATOR")
	ctx := context.Background()
	seedPublishedPR(t, st, incident.ID)

	closed := []string{}
	if err := CloseMergedTasks(ctx, st, func(_ context.Context, c core.Incident) error {
		closed = append(closed, c.ID)
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if len(closed) != 0 {
		t.Errorf("an unmerged task was closed: %v", closed)
	}
}

// One task that refuses to close must not strand the rest, because the
// conditions that refuse — a turn still running, a cleanup conflict — are
// per-task and the sweep converges on the next tick.
func TestOneRefusalDoesNotStrandTheOtherMergedTasks(t *testing.T) {
	_, st, first := creationFixture(t, config.AutomaticDraftPROff, "UOPERATOR")
	ctx := context.Background()
	second, _, err := st.CreateMemberEngineeringTask(
		ctx, "repo", "src-2", "Second", "summary", "UOPERATOR",
		"COPS", "1700.002", 100, 2, 0,
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{first.ID, second.ID} {
		seedPublishedPR(t, st, id)
		markMerged(t, st, id)
	}

	seen := []string{}
	sweepErr := CloseMergedTasks(ctx, st, func(_ context.Context, c core.Incident) error {
		seen = append(seen, c.ID)
		if c.ID == first.ID {
			return errors.New("a turn is still running")
		}
		return nil
	})

	if len(seen) != 2 {
		t.Errorf("the sweep stopped at the first refusal: reached %v", seen)
	}
	if sweepErr == nil {
		t.Error("the refusal was swallowed rather than reported")
	}
}

// markMerged puts the followup in the state the GitHub follower leaves behind
// when it sees a merge, which is the state nothing acted on.
func markMerged(t *testing.T, st *store.Store, incidentID string) {
	t.Helper()
	followup, err := st.PublicationFollowups.Get(context.Background(), incidentID)
	if err != nil {
		t.Fatal(err)
	}
	expected := followup
	followup.PRState = "merged"
	followup.MergeSHA = "ecfc5413886b"
	if _, err := st.PublicationFollowups.SaveTransition(
		context.Background(), expected, followup, nil,
	); err != nil {
		t.Fatal(err)
	}
}

// seedPublishedPR gives a task the published publication a followup row hangs
// off, which is the state a merge arrives into.
func seedPublishedPR(t *testing.T, st *store.Store, incidentID string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: incidentID, Repository: "owner/repo", BaseBranch: "main",
		HeadBranch: "responder/change", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 6,
		PRURL: "https://github.test/owner/repo/pull/6",
		State: "published", PublishedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, incidentID, now); err != nil {
		t.Fatal(err)
	}
}
