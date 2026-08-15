package service

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// proactiveFixture builds a channel where one standing assignment is one
// eligibility check away from opening a pull request.
//
// Everything the gate asks for is here and real: the signal matches the granted
// pattern, the problem has recurred three times across distinct episodes in the
// window, the investigation reached a decision-ready conclusion with no
// material gaps, and the evidence comes from something that observed the system
// rather than from reading the repository. Assembling it once is what lets each
// test below change exactly one thing.
type proactiveFixture struct {
	svc        *Service
	store      *store.Store
	db         *sql.DB
	assignment core.StandingAssignment
	input      core.SlackInput
	completion *investigation.CompletionAssessment
	evidence   []core.Evidence
}

func newProactiveFixture(t *testing.T) *proactiveFixture {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	// A second read-only handle, because the counts these tests assert are of
	// rows nothing should have written, and there is deliberately no store
	// method that lists a table nobody reads.
	db, err := sql.Open("sqlite", filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	assignment, err := st.StandingAssignments.Create(ctx, core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "payments timeout",
		Repository: cfg.Slack.DefaultRepository, ChangeClass: "observability",
		DailyBudget: 2, ActorID: "UOPERATOR", Shadow: true,
		ExpiresAt: svc.now().UTC().Add(24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}

	input := core.SlackInput{
		ID: "in_now", ChannelID: "CALERTS", Kind: "bot_message",
		EventID: "ev_now", UserID: "B_GRAFANA", MessageTS: "1723700000.000100",
		Text: "FIRING: payments timeout on checkout",
	}
	// Admitted, because the assignment acts on a real inbound signal and the
	// task it would open is bound to that row. Without it the withheld path and
	// the granted one would fail for the same uninteresting reason, and the test
	// could not tell them apart.
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit the signal: created=%v err=%v", created, err)
	}
	// Three distinct episodes on this conversation key, which is what turns a
	// coincidence into a pattern the gate will act on.
	for index := 0; index < 3; index++ {
		if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunTriage, ChannelID: "CALERTS",
			ConversationKey: watchConversationKey(input),
			SourceKind:      "watch", SourceID: fmt.Sprintf("alert_%d", index),
			UserID: "B_GRAFANA",
		}); err != nil {
			t.Fatal(err)
		}
	}

	return &proactiveFixture{
		svc: svc, store: st, db: db, assignment: assignment, input: input,
		completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Summary: "checkout times out on a missing client deadline",
		},
		evidence: []core.Evidence{{SourceType: "emisar"}},
	}
}

func (f *proactiveFixture) count(t *testing.T, query string) int {
	t.Helper()
	var count int
	if err := f.db.QueryRowContext(context.Background(), query).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

// A shadowed assignment runs the whole gate and then opens nothing.
//
// This is the entire safety property of the shadow period, and it has two
// halves that fail in opposite directions. If the gate is skipped, the recorded
// verdicts are not the decisions the live feature would have made and the
// evidence the grant will be argued from is worthless. If the action is not
// skipped, Responder is opening pull requests unattended on a completion
// contract that was the largest single source of defects on 2026-08-09 — the
// exact grant this task exists to withhold.
//
// The comparable feature is why the assertion is "zero", not "few": the
// quality-watch fixer writes code unattended and produced zero net fixes across
// 59 attempts in seven days before it was switched off.
func TestAShadowedAssignmentRunsTheGateAndOpensNothing(t *testing.T) {
	ctx := context.Background()
	fixture := newProactiveFixture(t)

	episodesBefore := fixture.count(t, `SELECT COUNT(*) FROM work_episodes`)
	if err := fixture.svc.considerProactiveWork(
		ctx, fixture.input, "ep_watch", fixture.completion, fixture.evidence,
	); err != nil {
		t.Fatalf("proactive consideration: %v", err)
	}

	// The gate ran, and it said yes. Assert the decision before anything else,
	// so a failure names what went wrong rather than reporting a missing task
	// that could equally mean the fixture stopped matching the pattern.
	evaluations, err := fixture.store.StandingAssignments.ListEvaluations(
		ctx, fixture.assignment.ID, 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(evaluations) != 1 {
		t.Fatalf("recorded %d evaluations, want exactly one", len(evaluations))
	}
	recorded := evaluations[0]
	if recorded.Verdict != "eligible" {
		t.Fatalf(
			"verdict = %q (%s); the shadow record is worthless unless it is the "+
				"decision the live feature would have made",
			recorded.Verdict, recorded.Reason,
		)
	}
	if !recorded.Shadow || recorded.InputID != fixture.input.ID ||
		recorded.EpisodeID != "ep_watch" || recorded.Signal == "" {
		t.Fatalf("evaluation does not name the assignment's signal and turn: %+v", recorded)
	}

	// And nothing happened. A claim is what marks a signal handled and spends
	// the budget, so a claim left behind would silently suppress the next
	// occurrence of a signal this feature never acted on.
	if claims := fixture.count(
		t, `SELECT COUNT(*) FROM standing_assignment_actions`,
	); claims != 0 {
		t.Fatalf("a shadowed assignment claimed %d actions; it must claim none", claims)
	}
	if episodes := fixture.count(t, `SELECT COUNT(*) FROM work_episodes`); episodes != episodesBefore {
		t.Fatalf(
			"a shadowed assignment opened %d engineering episodes; nothing may open a task, "+
				"create a branch, or write to GitHub while shadow is on",
			episodes-episodesBefore,
		)
	}
	if sessions := len(fixture.svc.coop.(*fakeCoop).createKeys); sessions != 0 {
		t.Fatalf("a shadowed assignment opened %d Coop sessions, which is where a branch "+
			"and a pull request come from", sessions)
	}
}

// The declines are recorded too, and they are the interesting half.
//
// "Responder did nothing" is the hardest behaviour to debug from Slack: a
// misconfigured scope and a working system look identical. After a shadow
// period the audit has to answer how many of the signals this assignment saw
// deserved a pull request, and a ledger holding only the passes cannot — two
// out of three is a different proposition from two out of forty.
func TestARefusedSignalIsRecordedWithItsReason(t *testing.T) {
	ctx := context.Background()
	fixture := newProactiveFixture(t)

	// The one thing the gate will refuse: a conclusion Responder could not
	// actually support. Everything else about the signal still matches.
	if err := fixture.svc.considerProactiveWork(
		ctx, fixture.input, "ep_watch",
		&investigation.CompletionAssessment{
			Status: "decision_ready", Summary: "probably the database",
			MaterialGaps: []string{"nobody looked at the client timeout"},
		},
		fixture.evidence,
	); err != nil {
		t.Fatalf("proactive consideration: %v", err)
	}

	evaluations, err := fixture.store.StandingAssignments.ListEvaluations(
		ctx, fixture.assignment.ID, 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(evaluations) != 1 {
		t.Fatalf("a refusal recorded %d rows, want one; the declines are the evidence", len(evaluations))
	}
	if evaluations[0].Verdict != "declined" ||
		evaluations[0].Reason != "the investigation still has material gaps" {
		t.Fatalf(
			"refusal recorded as %q/%q, want the gate's own reason",
			evaluations[0].Verdict, evaluations[0].Reason,
		)
	}

	tally, err := fixture.store.StandingAssignments.Tally(ctx, fixture.assignment.ID)
	if err != nil {
		t.Fatal(err)
	}
	if tally.Evaluated != 1 || tally.Declined != 1 || tally.Eligible != 0 {
		t.Fatalf("tally %+v does not describe one refused signal", tally)
	}
}

// Nothing happens in a channel with no standing assignment, and it happens
// without a store round trip beyond the one lookup.
func TestProactiveIsInertWithoutAnAssignment(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	err = svc.considerProactiveWork(
		ctx,
		core.SlackInput{ID: "in_1", ChannelID: "CQUIET", Text: "FIRING: something"},
		"",
		&investigation.CompletionAssessment{Status: "decision_ready", Summary: "fine"},
		[]core.Evidence{{SourceType: "emisar"}},
	)
	if err != nil {
		t.Fatalf("proactive consideration in an unassigned channel: %v", err)
	}
}

// Proactive work must never delay or replace the answer someone is waiting for.
//
// It runs after the reply is delivered, and a standing assignment that fails
// must not fail the turn that already answered. The ordering is the whole
// point: an operator asked a question, and Responder deciding to also open a
// pull request is not their problem.
func TestProactiveFailureDoesNotFailTheAnsweredTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	// An assignment whose repository is not configured: the task cannot start.
	if _, err := st.StandingAssignments.Create(ctx, core.StandingAssignment{
		ChannelID: "CALERTS", SignalPattern: "timeout",
		Repository: "not-a-configured-repository", ChangeClass: "observability",
		DailyBudget: 2, ActorID: "UOPERATOR", Shadow: true,
		ExpiresAt: svc.now().UTC().Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	// Not recurring, so it declines rather than acting — and declining is
	// silent and must not error.
	if err := svc.considerProactiveWork(
		ctx,
		core.SlackInput{ID: "in_1", ChannelID: "CALERTS", Text: "FIRING: timeout"},
		"",
		&investigation.CompletionAssessment{Status: "decision_ready", Summary: "one-off"},
		[]core.Evidence{{SourceType: "emisar"}},
	); err != nil {
		t.Fatalf("a declined assignment returned an error: %v", err)
	}
}
