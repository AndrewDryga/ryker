package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/fanout"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/fanoutstore"
)

// fanOutHarness is a lead investigation that has finished one sweep and left
// two independent pockets of ambiguity on its ledger: a host claim and a
// dependency claim, nothing observed about either, so the host measures two
// clusters with distinct identities.
type fanOutHarness struct {
	svc      *Service
	store    *store.Store
	incident core.Incident
	lead     core.AgentRun
	episode  core.WorkEpisode
}

func newFanOutHarness(t *testing.T) fanOutHarness {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	incident, created, err := st.CreateManualIncident(
		ctx, "repo", "src_fanout", "Checkout latency", "Checkout latency",
		"U123ABC", "CSOURCE", "1700.001", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create incident = %+v, %v, %v", incident, created, err)
	}
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-fanout"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_lead", "fork-lead", 1); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	lead, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "watch", SourceID: "lead_sweep",
		Repository: incident.Repository, Prompt: "investigate",
		Episode: &core.WorkEpisode{
			Effort:    core.EffortIncidentInvestigation,
			Authority: core.AuthorityReadOnly,
			Activity:  core.ActivityInvestigating,
			Objective: "Find why checkout is slow",
			// Two layers, nothing observed about either. That is two clusters.
			RequiredCoverage:   []string{"host", "dependency"},
			CompletionCriteria: []string{"state current impact"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, lead.ID)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	return fanOutHarness{svc: svc, store: st, incident: incident, lead: lead, episode: episode}
}

// twoIndependentGoals is the lead proposing one read-only goal per cluster,
// each naming the claim id it settles. The binding is by the exact tokens the
// model was handed, never by loose words.
func twoIndependentGoals() []investigation.ResultOperation {
	return []investigation.ResultOperation{
		{
			ID: "op-1", Type: "plan_goal",
			Goal: &investigation.GoalOperation{
				ID: "goal-host", Kind: "check",
				RequestedOutcome:   "Settle host.current_state on the checkout hosts",
				CompletionContract: "host readings quoted with timestamps",
				Authority:          core.AuthorityReadOnly,
			},
		},
		{
			ID: "op-2", Type: "plan_goal",
			Goal: &investigation.GoalOperation{
				ID: "goal-dependency", Kind: "check",
				RequestedOutcome:   "Settle dependency.current_health for the payment gateway",
				CompletionContract: "dependency latency quoted with timestamps",
				Authority:          core.AuthorityReadOnly,
			},
		},
	}
}

// The whole point of option A: a branch is a child episode under the lead,
// sharing the lead's incident. Sharing the incident is what makes the ledger
// shared for free — ListEpisodeEvidence unions the incident's evidence into
// every episode under it — and owning its own episode is what gives each branch
// its own latest_attempt_id, which two concurrent attempts of one episode could
// never have had.
func TestAdmittedFanOutOpensChildEpisodesUnderTheLeadIncident(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)

	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}

	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil {
		t.Fatal(err)
	}
	if len(branches) != 2 {
		t.Fatalf("fan-out opened %d branches, want 2", len(branches))
	}
	seen := map[string]bool{}
	for _, branch := range branches {
		seen[branch.GoalID] = true
		run, err := h.store.GetAgentRun(ctx, branch.RunID)
		if err != nil {
			t.Fatal(err)
		}
		if run.IncidentID != h.incident.ID {
			t.Fatalf("branch %s runs under incident %q, want the lead's %q; "+
				"a branch on another incident does not share the ledger at all",
				branch.GoalID, run.IncidentID, h.incident.ID)
		}
		if !fanout.IsBranch(run.ConversationKey) {
			t.Fatalf("branch %s took conversation key %q, which the lease will "+
				"serialize against the lead", branch.GoalID, run.ConversationKey)
		}
		child, err := h.store.GetWorkEpisode(ctx, branch.EpisodeID)
		if err != nil {
			t.Fatal(err)
		}
		if child.ParentEpisodeID != h.episode.ID {
			t.Fatalf("branch %s hangs off episode %q, want the lead %q",
				branch.GoalID, child.ParentEpisodeID, h.episode.ID)
		}
		if child.Authority != core.AuthorityReadOnly {
			t.Fatalf("branch %s carries %q authority; branches are read-only and "+
				"only the lead writes anywhere", branch.GoalID, child.Authority)
		}
	}
	if !seen["goal-host"] || !seen["goal-dependency"] {
		t.Fatalf("branches went to %v, want one per cluster", seen)
	}
}

// The branch session is the authority and transcript the branch was granted.
// Submitting through the lead session collapses both isolation and read-only
// enforcement, which left the carefully created branch fork entirely unused.
func TestABranchTurnSubmitsToItsOwnSession(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if err := h.svc.processAgentRun(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
			t.Fatal(err)
		}
		if len(h.svc.coop.(*fakeCoop).submitSessions) > 0 {
			break
		}
	}
	if len(h.svc.coop.(*fakeCoop).submitSessions) != 1 ||
		h.svc.coop.(*fakeCoop).submitSessions[0] != "ses_1" {
		t.Fatalf("branch submitted through %v, want its own ses_1", h.svc.coop.(*fakeCoop).submitSessions)
	}
}

// A branch is read-only by contract even when it resumes a fork created before
// Coop exposed repository authority. Reusing that fork would preserve ambient
// write access in the one lane whose isolation exists specifically to prevent
// it.
func TestABranchReplacesALegacyWritableSessionBeforeSubmitting(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) == 0 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	run, err := h.store.GetAgentRun(ctx, branches[0].RunID)
	if err != nil {
		t.Fatal(err)
	}
	run.SessionID = "ses_legacy_branch"
	run.SessionGeneration = 1
	goalID, _ := fanout.GoalOf(run.ConversationKey)
	coopClient := h.svc.coop.(*fakeCoop)
	coopClient.session.ID = run.SessionID
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_legacy_branch"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_legacy_branch", SessionID: run.SessionID, Ordinal: 1, State: "running",
	}}
	coopClient.openAfterCreateKey = sessioncreate.Key(
		"responder:session:"+h.incident.ID+fanout.BranchMarker+goalID, 2,
	)

	session, generation, err := h.svc.branches.Session(ctx, run, h.incident)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || !session.RepositoryReadOnly || generation != 2 {
		t.Fatalf("replacement branch session = %+v generation %d", session, generation)
	}
	if len(coopClient.cancelTurns) != 1 || coopClient.cancelTurns[0] != "turn_legacy_branch" {
		t.Fatalf("legacy branch turn remained live: %v", coopClient.cancelTurns)
	}
	cleanup, err := h.store.GetCoopCleanup(ctx, run.SessionID)
	if err != nil || cleanup.State != "pending" {
		t.Fatalf("legacy branch cleanup = %+v, %v", cleanup, err)
	}
}

// A historical branch key can be bound to an older request shape. That
// collision spends one generation; retrying the identical key simply burns
// every run attempt without ever reaching the fresh read-only fork.
func TestABranchAdvancesPastAnIdempotencyConflict(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) == 0 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	run, err := h.store.GetAgentRun(ctx, branches[0].RunID)
	if err != nil {
		t.Fatal(err)
	}
	goalID, _ := fanout.GoalOf(run.ConversationKey)
	coopClient := h.svc.coop.(*fakeCoop)
	coopClient.createErrors = []error{&coop.APIError{Status: 409, Code: "idempotency_conflict"}}
	coopClient.openAfterCreateKey = sessioncreate.Key(
		"responder:session:"+h.incident.ID+fanout.BranchMarker+goalID, 2,
	)

	session, generation, err := h.svc.branches.Session(ctx, run, h.incident)
	if err != nil {
		t.Fatal(err)
	}
	if session.ID != "ses_2" || generation != 2 || len(coopClient.createKeys) != 2 {
		t.Fatalf("branch collision recovery = session %+v generation %d keys %v", session, generation, coopClient.createKeys)
	}
}

// Four rejected candidates are a per-attempt safety bound, not a permanent
// dead end. Persist the next generation so a later retry can move beyond the
// legacy idempotency keys after the policy is repaired.
func TestRejectedBranchAuthorityAdvancesItsDurableGeneration(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	if err := h.svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient := h.svc.coop.(*fakeCoop)
	coopClient.session.RepositoryReadOnly = false
	if err := h.svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil {
		t.Fatal(err)
	}
	advanced := false
	var retryingEpisode string
	for _, branch := range branches {
		run, err := h.store.GetAgentRun(ctx, branch.RunID)
		if err != nil {
			t.Fatal(err)
		}
		if run.SessionGeneration == 5 {
			if run.SessionGeneration != 5 {
				t.Fatalf("rejected branch generation = %d, want 5", run.SessionGeneration)
			}
			if run.Failures != 0 || run.NextAttemptAt.Before(time.Now().Add(25*time.Minute)) {
				t.Fatalf("branch preparation spent model attempts or retried too soon: %+v", run)
			}
			advanced = true
			retryingEpisode = run.EpisodeID
		}
	}
	if !advanced {
		t.Fatal("no branch reached the authority rejection")
	}
	episode, err := h.store.GetWorkEpisode(ctx, retryingEpisode)
	if err != nil || episode.State != core.EpisodeRetrying {
		t.Fatalf("branch preparation state = %+v, %v", episode, err)
	}
	incident, err := h.store.GetIncident(ctx, h.incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.Workflow == core.WorkflowHolding || incident.LastError != "" {
		t.Fatalf("one branch replaced incident-wide custody: %+v", incident)
	}
	card, err := h.svc.incidentCard(ctx, incident)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := slackui.Encode(card)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "1 investigation branch queued") {
		t.Fatalf("queued branch was invisible on incident card: %s", rendered)
	}
}

// Two repository preparation failures used to spend two of the branch's model
// attempts even though Coop never created a session and no model turn started.
// A prolonged repository outage could therefore terminally fail accepted work
// while its card showed no queued branch for the operator to account for.
func TestBranchPreparationFailuresNeverSpendModelAttempts(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) != 2 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	if err := h.svc.processAgentRun(ctx); err != nil { // submit the older lead run
		t.Fatal(err)
	}
	coopClient := h.svc.coop.(*fakeCoop)
	coopClient.createErrors = []error{
		&coop.APIError{Status: 503, Code: "repository_unavailable"},
		&coop.APIError{Status: 503, Code: "repository_unavailable"},
	}

	for range 2 {
		if err := h.svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
	}

	for _, branch := range branches {
		run, err := h.store.GetAgentRun(ctx, branch.RunID)
		if err != nil {
			t.Fatal(err)
		}
		if run.State != core.AgentRunPending || run.Failures != 0 || run.TerminalState != "" {
			t.Fatalf("workspace preparation spent or lost the accepted branch: %+v", run)
		}
		episode, err := h.store.GetWorkEpisode(ctx, run.EpisodeID)
		if err != nil || episode.State != core.EpisodeRetrying ||
			episode.Phase != "preparing_workspace" {
			t.Fatalf("branch preparation custody = %+v, %v", episode, err)
		}
	}
}

// A branch fork can disappear after its run has durably bound it. The missing
// session used to be treated as a terminal model failure. Its generation must
// advance, and a simultaneous preparation outage must leave the branch queued
// without submitting or spending an attempt.
func TestMissingBoundBranchSessionAdvancesWithoutLosingTheRun(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	if err := h.svc.processAgentRun(ctx); err != nil { // submit the older lead
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) != 2 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	leased, err := h.store.LeaseAgentRun(ctx)
	if err != nil || leased.ID != branches[0].RunID {
		t.Fatalf("leased branch = %+v, %v", leased, err)
	}
	if err := h.store.BindAgentRunSession(
		ctx, leased.ID, "ses_missing_branch", 1, leased.Repository, 0, leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := h.store.DeferAgentRun(ctx, leased.ID, "test bound branch", time.Now()); err != nil {
		t.Fatal(err)
	}
	coopClient := h.svc.coop.(*fakeCoop)
	coopClient.getSessionErr = &coop.APIError{Status: 404, Code: "session_not_found"}
	coopClient.createErrors = []error{
		&coop.APIError{Status: 503, Code: "repository_unavailable"},
	}
	if err := h.svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := h.store.GetAgentRun(ctx, leased.ID)
	if err != nil || run.State != core.AgentRunPending || run.TerminalState != "" ||
		run.Failures != 0 || run.SessionGeneration != 2 || len(coopClient.submitSessions) != 0 {
		t.Fatalf("missing branch custody run=%+v submits=%v err=%v", run, coopClient.submitSessions, err)
	}
}

// Opening a fan-out has to be idempotent on the result, not on the attempt. The
// staging path can run twice on one turn — a retried poll, a restart between
// the decision and the insert — and a second pass that opened two more branches
// would double the spend the gate just budgeted.
func TestReappliedLeadResultDoesNotOpenTheSameBranchesTwice(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)

	for range 2 {
		if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
			t.Fatal(err)
		}
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil {
		t.Fatal(err)
	}
	if len(branches) != 2 {
		t.Fatalf("re-applying one result left %d branches, want 2", len(branches))
	}
}

// A simple incident must cost exactly what it cost before this feature existed.
// One cluster is one thing to look at, and one thing to look at is the serial
// path — the gate says so in a sentence, on the lead's own timeline, because an
// operator reading a trace that ran serially needs the host's reason and
// silence is indistinguishable from the feature being broken.
func TestASingleClusterInvestigationStaysSerialAndSaysWhy(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateManualIncident(
		ctx, "repo", "src_simple", "One thing", "One thing",
		"U123ABC", "CSOURCE", "1700.001", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-simple"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	lead, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: "1700.001",
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "watch", SourceID: "simple_sweep",
		Episode: &core.WorkEpisode{
			Effort: core.EffortIncidentInvestigation, Authority: core.AuthorityReadOnly,
			Activity: core.ActivityInvestigating, Objective: "One thing",
			// One layer is one cluster.
			RequiredCoverage: []string{"host"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, lead.ID)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	if err := svc.branches.Open(ctx, lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := st.Branches.ListForLead(ctx, episode.ID, 32)
	if err != nil {
		t.Fatal(err)
	}
	if len(branches) != 0 {
		t.Fatalf("a one-cluster investigation opened %d branches; simple "+
			"incidents must cost what they cost today", len(branches))
	}
	if !episodeSaysFanOutRefused(t, st, episode.ID) {
		t.Fatal("fan-out was refused with no reason on the episode; an operator " +
			"reading a serial trace cannot tell a refusal from a broken feature")
	}
}

// A result that planned nothing parallel is not a refused fan-out — it is a
// fan-out nobody asked for, and a refusal recorded for every ordinary
// investigation would bury the refusals that mean something.
func TestAnInvestigationThatProposedNothingRecordsNoRefusal(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)

	if err := h.svc.branches.Open(ctx, h.lead, nil); err != nil {
		t.Fatal(err)
	}
	if episodeSaysFanOutRefused(t, h.store, h.episode.ID) {
		t.Fatal("an investigation that proposed no parallel goals was told it " +
			"was refused one")
	}
}

// A branch sees the evidence for its own goal and not the evidence for the
// others, so a completion from one is a conclusion drawn from a third of the
// incident. It completes its own child episode and nothing else — the lead's
// episode has to still be open, because the lead has not synthesized yet and
// only the lead may.
//
// The rest of the branch's result survives. Discarding the whole turn would
// throw away the evidence the synthesis is waiting for, and the branch may well
// have settled its own cluster correctly.
func TestABranchCompletionNeverCompletesTheLead(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) != 2 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}
	branch := branches[0]

	if err := h.svc.recordResultOperationEvents(ctx, branch.RunID, []investigation.ResultOperation{
		{ID: "op-evidence", Type: "record_evidence"},
		{ID: "op-done", Type: "complete_episode"},
	}); err != nil {
		t.Fatal(err)
	}

	lead, err := h.store.GetWorkEpisode(ctx, h.episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if lead.State == core.EpisodeCompleted {
		t.Fatal("a branch completed the lead episode; only the lead synthesizes, " +
			"and it has not run its synthesis attempt yet")
	}
	events, err := h.store.ListEpisodeEvents(ctx, branch.EpisodeID, 100)
	if err != nil {
		t.Fatal(err)
	}
	var completionSubmitted, evidenceRecorded, refused bool
	for _, event := range events {
		switch {
		case event.Kind == episodepkg.EventCompletionSubmitted:
			completionSubmitted = true
		case event.Kind == episodepkg.EventEvidenceRecorded:
			evidenceRecorded = true
		case strings.Contains(string(event.Payload), "cannot complete the episode"):
			refused = true
		}
	}
	if completionSubmitted {
		t.Fatal("the branch's complete_episode was applied to its own episode; " +
			"a branch has not seen the other branches' evidence")
	}
	if !evidenceRecorded {
		t.Fatal("the branch's evidence was discarded along with its completion; " +
			"the synthesis is waiting for exactly that evidence")
	}
	if !refused {
		t.Fatal("the refused completion left no trace on the branch's timeline")
	}
}

// The synthesis is queued by the last branch to stop, so it is scheduled
// exactly once and nothing has to poll for it. Stopped, not succeeded: a
// blocked branch is a finding, and waiting for success would hang the incident
// on the branch that most needs reporting.
func TestTheLeadSynthesisQueuesOnlyWhenEveryBranchHasStopped(t *testing.T) {
	ctx := context.Background()
	h := newFanOutHarness(t)
	if err := h.svc.branches.Open(ctx, h.lead, twoIndependentGoals()); err != nil {
		t.Fatal(err)
	}
	branches, err := h.store.Branches.ListForLead(ctx, h.episode.ID, 32)
	if err != nil || len(branches) != 2 {
		t.Fatalf("branches = %+v, %v", branches, err)
	}

	stop := func(branch fanoutstore.Branch, state core.WorkEpisodeState) {
		t.Helper()
		if err := h.store.SetWorkEpisodePhase(
			ctx, branch.RunID, state, "investigating", "Branch done", "Wait", time.Time{},
		); err != nil {
			t.Fatal(err)
		}
		run, err := h.store.GetAgentRun(ctx, branch.RunID)
		if err != nil {
			t.Fatal(err)
		}
		if err := h.svc.branches.SynthesizeIfReady(ctx, run); err != nil {
			t.Fatal(err)
		}
	}

	// One branch down, one still running: the ledger is still being written.
	stop(branches[0], core.EpisodeCompleted)
	if synthesisQueued(t, h.store, h.episode.ID) {
		t.Fatal("the synthesis was queued while a branch was still running; it " +
			"would merge a ledger that is still being written")
	}

	// The second stops blocked, which is a finding rather than a reason to wait.
	stop(branches[1], core.EpisodeBlocked)
	if !synthesisQueued(t, h.store, h.episode.ID) {
		t.Fatal("every branch stopped and the lead was never queued to " +
			"synthesize; the incident would sit unanswered forever")
	}
}

func synthesisQueued(t *testing.T, st *store.Store, leadEpisodeID string) bool {
	t.Helper()
	_, err := st.GetAgentRunBySource(
		context.Background(), "fanout", "synthesis_"+leadEpisodeID,
	)
	return err == nil
}

func episodeSaysFanOutRefused(t *testing.T, st *store.Store, episodeID string) bool {
	t.Helper()
	events, err := st.ListEpisodeEvents(context.Background(), episodeID, 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if strings.Contains(string(event.Payload), "Parallel investigation refused") {
			return true
		}
	}
	return false
}
