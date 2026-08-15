// Package branching opens the branches a fan-out was granted, and closes them.
//
// It is the execution half of parallel investigation, and it is a package of
// its own for two reasons. The decision half — internal/fanout — must stay
// unable to reach a database, because a gate that exists to refuse spending is
// a gate whose refusals have to be testable without one. And the service was at
// its line budget, which this repository answers by extracting a cohesive area
// rather than raising the number.
//
// The area is cohesive in a way worth naming: everything here is about the
// difference between a branch and a lead. A branch gets its own child episode,
// its own Coop fork, its own read-only prompt and its own smaller allowance,
// and it never posts, never completes the episode and never offers anything.
// Every one of those is a rule about the same distinction, and the alternative
// was thirty lines of "if this is a branch" scattered through the incident
// path.
package branching

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"log/slog"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/fanout"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/fanoutstore"
)

// branchSourceKind files a branch run under something that is not a Slack
// input, because a branch has no message of its own. It pairs with a source id
// derived from the lead episode and the goal, which is what makes opening a
// fan-out idempotent: agent_runs is unique on (source_kind, source_id), so a
// staging path that runs twice — a retried poll, a restart between the decision
// and the insert — reaches the same two rows rather than four.
const branchSourceKind = "fanout"

// branchTurnBudget is what a lead investigation may spend before its branches
// stop being funded, denominated in attempts.
//
// Attempts rather than tokens is not the preference, it is the measurement that
// exists: Coop's ACP path reports no provider usage at all, so an episode
// denominated only in tokens reads as having spent nothing however long it has
// run. fanout.Spend carries both and prefers tokens whenever a provider
// actually reported some, which is why this is a fallback rather than the rule.
const branchTurnBudget = 12

// Sessions is the slice of Coop a branch needs: a fork of its own, and a way
// back to one it has already been given. Narrow on purpose — nothing here may
// steer, cancel or submit a turn, which stays with the service that owns the
// run loop.
type Sessions interface {
	CreateSession(
		ctx context.Context, key, policy, externalRef string, sources ...coop.SessionSource,
	) (coop.Session, coop.Operation, error)
	GetSession(ctx context.Context, id string) (coop.Session, error)
}

// Runner opens and closes the branches of a parallel investigation.
type Runner struct {
	store *store.Store
	coop  Sessions
	cfg   config.Config
	now   func() time.Time
	log   *slog.Logger
}

func New(
	st *store.Store,
	sessions Sessions,
	cfg config.Config,
	now func() time.Time,
	log *slog.Logger,
) *Runner {
	if now == nil {
		now = time.Now
	}
	return &Runner{store: st, coop: sessions, cfg: cfg, now: now, log: log}
}

// Open decides whether a finished lead sweep has earned parallel
// branches, and opens them.
//
// It runs where the lead's result has just been applied, so the ledger it
// measures ambiguity from already contains everything that turn established.
// Anything it decides is therefore about the investigation as it now stands,
// not as it stood when the turn started.
//
// Silent when the model did not ask. Fan-out is proposed by the model and
// granted by the host, so an episode whose result planned nothing parallel is
// not a fan-out that was refused — it is a fan-out nobody requested, and
// recording a refusal for it would bury the real refusals in noise.
func (r *Runner) Open(
	ctx context.Context,
	run core.AgentRun,
	operations []investigation.ResultOperation,
) error {
	if run.Mode != core.AgentRunIncident || run.IncidentID == "" ||
		fanout.IsBranch(run.ConversationKey) {
		return nil
	}
	proposals := branchProposals(operations)
	if len(proposals) < fanout.MinimumBranches {
		return nil
	}
	episode, err := r.store.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		return nil
	}
	request, err := r.request(ctx, episode, proposals)
	if err != nil {
		return err
	}
	decision := fanout.Decide(request)
	if !decision.Admitted() {
		r.recordRefusal(ctx, run.ID, decision.Refusal)
		return nil
	}
	return r.openBranches(ctx, run, episode, decision.Branches)
}

// Session resolves the fork one branch investigates in.
//
// Its own session, never the incident's, and this is the half of the fourth
// serializer that the lease query cannot do on its own. incidents has one
// coop_session_id and one active_turn_id, both write-once against the lead, so
// a branch that reused them would submit its turn into the lead's fork —
// sharing a transcript with the lead and with every sibling, and colliding on
// the single active turn Coop allows per session. Exempting branches from the
// per-incident turn gate is only honest if each of them actually has a session
// of its own.
//
// The Coop idempotency key is derived rather than stored, so a branch that is
// re-prepared after a restart reaches the same fork instead of opening a second
// one. Read-only on the investigate profile: a branch is deep operational
// reading with tools and nothing else, and there is no rung below it to route
// to today.
func (r *Runner) Session(
	ctx context.Context,
	run core.AgentRun,
	incident core.Incident,
) (coop.Session, error) {
	if run.SessionID != "" {
		return r.coop.GetSession(ctx, run.SessionID)
	}
	goalID, _ := fanout.GoalOf(run.ConversationKey)
	repository, ok := r.cfg.RepositoryContext(incident.Repository)
	if !ok {
		return coop.Session{}, fmt.Errorf(
			"repository binding for %q was removed", incident.Repository,
		)
	}
	// The repository's own read-only policy, never the contributor one. A branch
	// is read-only by construction and taskaccess.SessionPolicy exists to decide
	// whether a writable lane was configured — a question a branch never gets to
	// ask.
	policy := repository.SessionProfilePolicy(
		config.ProfileInvestigate, repository.CoopPolicy,
	)
	session, _, err := r.coop.CreateSession(
		ctx,
		"responder:session:"+incident.ID+fanout.BranchMarker+goalID,
		policy,
		"incident:"+incident.ID+" branch:"+goalID,
	)
	return session, err
}

// GoalOf names the goal a run is a branch for, empty for everything else.
//
// The parent check comes first and is not an optimization. parent_episode_id is
// already used by watch correlation, where a follow-up message becomes a child
// of the episode it continues, so the parent alone does not mean branch — but
// no branch lacks one, and almost every episode does, which keeps the run
// lookup off the ordinary result path entirely.
func (r *Runner) GoalOf(
	ctx context.Context,
	runID string,
	episode core.WorkEpisode,
) string {
	if episode.ParentEpisodeID == "" {
		return ""
	}
	run, err := r.store.GetAgentRun(ctx, runID)
	if err != nil {
		return ""
	}
	goalID, _ := fanout.GoalOf(run.ConversationKey)
	return goalID
}

// request assembles what the gate judges: the ambiguity the host measured
// for itself, and what this episode has already cost.
func (r *Runner) request(
	ctx context.Context,
	episode core.WorkEpisode,
	proposals []fanout.Proposal,
) (fanout.Request, error) {
	evidence, err := r.store.Intelligence.ListEpisodeEvidence(ctx, episode.ID, 200)
	if err != nil {
		return fanout.Request{}, err
	}
	coverage, err := r.store.Intelligence.ListEpisodeCoverage(ctx, episode.ID, 200)
	if err != nil {
		return fanout.Request{}, err
	}
	ledger := investigation.BuildLedger(
		investigation.Compile(episode), evidence, coverage, r.now().UTC(),
	)
	tokens, turns, err := r.store.Branches.Spend(ctx, episode.ID)
	if err != nil {
		return fanout.Request{}, err
	}
	branches, err := r.store.Branches.ListForLead(ctx, episode.ID, 32)
	if err != nil {
		return fanout.Request{}, err
	}
	active := 0
	for _, branch := range branches {
		if !branch.Terminal() {
			active++
		}
	}
	return fanout.Request{
		Effort: episode.Effort,
		// An incident investigation is never the bounded conversation lane; the
		// lane is named rather than left empty so the gate's own refusal reads
		// as a decision about this lane rather than about a missing field.
		Lane:             "incident",
		FinishedAttempts: turns,
		Clusters:         fanout.Clusters(ledger),
		Proposals:        proposals,
		ActiveBranches:   active,
		BranchLimit:      fanout.DefaultBranchLimit,
		Spend: fanout.Spend{
			Tokens: tokens, TokenBudget: 0,
			Turns: turns, TurnBudget: branchTurnBudget,
		},
	}, nil
}

// branchProposals reads the parallel goals a lead planned.
//
// Only read-only goals are carried forward, and not as a filter the gate would
// otherwise have to repeat: an incident result routinely plans the remediation
// it intends next, and a repository-write goal offered to the gate would be
// refused as a whole fan-out rather than simply not being a branch. The gate
// still refuses a writable goal that reaches it, because a proposal built
// anywhere else must not be able to smuggle one past.
func branchProposals(operations []investigation.ResultOperation) []fanout.Proposal {
	proposals := make([]fanout.Proposal, 0, len(operations))
	for _, operation := range operations {
		if !strings.EqualFold(strings.TrimSpace(operation.Type), "plan_goal") ||
			operation.Goal == nil {
			continue
		}
		goal := operation.Goal
		if goal.Authority != "" && goal.Authority != core.AuthorityReadOnly {
			continue
		}
		proposals = append(proposals, fanout.Proposal{
			GoalID:             goal.ID,
			Authority:          goal.Authority,
			RequestedOutcome:   goal.RequestedOutcome,
			CompletionContract: goal.CompletionContract,
		})
	}
	return proposals
}

// openBranches creates one child episode per admitted goal.
//
// Child episodes rather than concurrent attempts of the lead, and the reason is
// worth stating where the rows are written: work_episodes.latest_attempt_id is
// a single pointer, and every path treats an attempt that is not the one it
// names as superseded history. Two concurrent attempts of one episode would
// cancel each other on the way to finalizing. A child owns its own pointer, and
// because evidence is keyed by incident — ListEpisodeEvidence unions the
// incident's evidence into every episode under it — the branches still write
// into the one shared ledger the lead will read.
func (r *Runner) openBranches(
	ctx context.Context,
	lead core.AgentRun,
	episode core.WorkEpisode,
	branches []fanout.Branch,
) error {
	for _, branch := range branches {
		child := &core.WorkEpisode{
			ParentEpisodeID: episode.ID,
			Effort:          episode.Effort,
			// Read-only, always. A branch exists to establish one thing and
			// hand it to the lead; the episode's destination, its offers and
			// its remediation belong to the lead alone.
			Authority: core.AuthorityReadOnly,
			Activity:  core.ActivityInvestigating,
			Objective: branchObjective(branch),
			// The lead's coverage contract, not a narrower one. The branch is
			// answering part of the same investigation and its evidence is read
			// back through the same claims.
			RequiredCoverage:   episode.RequiredCoverage,
			CompletionCriteria: episode.CompletionCriteria,
		}
		if _, _, err := r.store.QueueAgentRun(ctx, core.AgentRun{
			Mode: core.AgentRunIncident, IncidentID: lead.IncidentID,
			ChannelID: lead.ChannelID, ThreadTS: lead.ThreadTS,
			ConversationKey: fanout.BranchConversationKey(
				"incident:"+lead.IncidentID, branch.GoalID,
			),
			SourceKind: branchSourceKind,
			SourceID:   branchSourceID(episode.ID, branch.GoalID),
			UserID:     lead.UserID, Repository: lead.Repository,
			Prompt:          branchPrompt(branch),
			CommitmentTitle: branchObjective(branch),
			Episode:         child,
		}); err != nil {
			return fmt.Errorf("open branch %s: %w", branch.GoalID, err)
		}
	}
	r.recordProgress(ctx, lead.ID, fmt.Sprintf(
		"Fan-out admitted: %d branches running in parallel on independent "+
			"pockets of the ledger (%s). Each writes into the shared claims "+
			"ledger; only this episode will synthesize and complete.",
		len(branches), strings.Join(branchGoalIDs(branches), ", "),
	))
	return nil
}

func branchSourceID(leadEpisodeID, goalID string) string {
	return "branch_" + leadEpisodeID + "_" + goalID
}

func branchGoalIDs(branches []fanout.Branch) []string {
	ids := make([]string, 0, len(branches))
	for _, branch := range branches {
		ids = append(ids, branch.GoalID)
	}
	return ids
}

func branchObjective(branch fanout.Branch) string {
	return "Branch " + branch.GoalID + ": settle " + branch.Cluster.Identity
}

// branchPrompt tells a branch what it is and what it may not do.
//
// The bound is stated as the reason rather than as a rule, because the failure
// this prevents is a well-meaning one: a branch that settled its cluster
// correctly and then concluded the incident from a third of the evidence.
func branchPrompt(branch fanout.Branch) string {
	return "You are one branch of a parallel investigation, running read-only " +
		"beside other branches on the same incident.\n\n" +
		"Your goal is " + branch.GoalID + ". Settle only these claims: " +
		strings.Join(branch.Cluster.ClaimIDs, ", ") + " — about " +
		strings.Join(branch.Cluster.Targets, ", ") + ".\n\n" +
		"Record what you establish with record_evidence and record_coverage, " +
		"mark your goal with update_goal, and report_progress. You cannot " +
		"complete the episode and must not offer anything to the operator: you " +
		"have seen the evidence for your own goal and not the evidence for the " +
		"others. The lead attempt merges every branch's findings and decides."
}

// recordRefusal puts the host's reason on the lead episode.
//
// The gate's refusals are operator-facing sentences already, and this is where
// they have to land: an operator reading a trace of an obviously ambiguous
// incident that ran serially needs the host's reason, and without it the only
// available conclusion is that the feature is broken. That conclusion has been
// drawn from silence before.
func (r *Runner) recordRefusal(ctx context.Context, runID, reason string) {
	r.recordProgress(ctx, runID, "Parallel investigation refused: "+reason)
}

// summaryKey makes the progress row idempotent on what it says.
//
// The staging path can run twice on one result — a retried poll, a restart
// between the decision and the write — and a refusal recorded twice reads as
// the host refusing twice.
func summaryKey(summary string) string {
	digest := sha256.Sum256([]byte(summary))
	return hex.EncodeToString(digest[:8])
}

func (r *Runner) recordProgress(ctx context.Context, runID, summary string) {
	payload, err := json.Marshal(episodepkg.Transition{
		Phase: "investigating", Summary: summary,
	})
	if err != nil {
		return
	}
	if _, err := r.store.AppendWorkEpisodeEvent(ctx, runID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventProgressReported, Actor: "responder",
		IdempotencyKey: "fanout:" + runID + ":" + summaryKey(summary),
		Payload:        payload,
	}); err != nil && r.log != nil {
		r.log.Warn("record fan-out decision", "run", runID, "error", err)
	}
}

// Finish ends a branch without touching the room.
//
// A branch never posts. One public failure per blocker generation still holds,
// and a fan-out that failed two of three branches would otherwise report the
// same incident twice to the same channel — the exact behaviour the visibility
// gate exists to stop, arriving through a new door and multiplied by the branch
// cap. What the branch learned is already in the shared ledger; the lead reports
// it, once, having read all of it.
func (r *Runner) Finish(ctx context.Context, run core.AgentRun) error {
	state := core.EpisodeCompleted
	status, next := "Branch complete", "Wait for the lead to synthesize"
	if run.TerminalState != "completed" {
		// Blocked, not failed. The incident is not over — the other branches are
		// still running and the lead has not synthesized — and a blocked branch
		// is information the synthesis wants, because "this could not be
		// established" is half of most operational answers.
		state = core.EpisodeBlocked
		status, next = "Branch blocked", "The lead will synthesize what was established"
	}
	if err := r.store.SetWorkEpisodePhase(
		ctx, run.ID, state, "investigating", status, next, time.Time{},
	); err != nil {
		return err
	}
	if err := r.store.FinishAgentRun(ctx, run.ID); err != nil {
		return err
	}
	return r.SynthesizeIfReady(ctx, run)
}

// SynthesizeIfReady wakes the lead once every branch has stopped.
//
// Stopped, not succeeded — see fanout.SynthesisReady. The last branch to finish
// is the one that queues it, so the synthesis is scheduled exactly once without
// anything having to poll for it.
func (r *Runner) SynthesizeIfReady(ctx context.Context, branch core.AgentRun) error {
	episode, err := r.store.GetWorkEpisodeByRun(ctx, branch.ID)
	if err != nil || episode.ParentEpisodeID == "" {
		return nil
	}
	lead, err := r.store.GetWorkEpisode(ctx, episode.ParentEpisodeID)
	if err != nil {
		return nil
	}
	siblings, err := r.store.Branches.ListForLead(ctx, lead.ID, 32)
	if err != nil {
		return err
	}
	states := make(map[string]core.EpisodeGoalState, len(siblings))
	goalIDs := make([]string, 0, len(siblings))
	for _, sibling := range siblings {
		if sibling.GoalID == "" {
			continue
		}
		goalIDs = append(goalIDs, sibling.GoalID)
		// The child episode's lifecycle is what says a branch has stopped. Its
		// goal state is the model's account of the same thing, and a branch that
		// died never wrote one — waiting on the goal would hang the synthesis on
		// exactly the branch that most needs reporting.
		if sibling.Terminal() {
			states[sibling.GoalID] = core.GoalCompleted
			continue
		}
		states[sibling.GoalID] = core.GoalWorking
	}
	if !fanout.SynthesisReady(states, goalIDs) {
		return nil
	}
	incident, err := r.store.GetIncident(ctx, branch.IncidentID)
	if err != nil {
		return err
	}
	// The lead's own conversation key, so the synthesis takes the incident's
	// session and waits behind the per-incident turn gate like every other lead
	// turn. It carries the lead's contract rather than a fresh one: the merged
	// ledger has to be judged by the claims the investigation committed to, not
	// by whatever a default would have compiled.
	_, _, err = r.store.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.ConversationThreadTS(),
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      branchSourceKind, SourceID: "synthesis_" + lead.ID,
		UserID: branch.UserID, Repository: incident.Repository,
		Prompt: synthesisPrompt(siblings), CommitmentTitle: incident.Title,
		Episode: &core.WorkEpisode{
			Effort: lead.Effort, Authority: lead.Authority,
			Activity: core.ActivityInvestigating, Objective: lead.Objective,
			RequiredCoverage:   lead.RequiredCoverage,
			CompletionCriteria: lead.CompletionCriteria,
		},
	})
	return err
}

// synthesisPrompt hands the lead the merged ledger and the branch outcomes.
func synthesisPrompt(branches []fanoutstore.Branch) string {
	lines := make([]string, 0, len(branches))
	for _, branch := range branches {
		lines = append(lines, "- "+branch.GoalID+": "+branch.State+" — "+branch.Objective)
	}
	return "Every parallel branch of this investigation has stopped. Their " +
		"findings are already in the shared claims ledger below.\n\n" +
		strings.Join(lines, "\n") + "\n\n" +
		"Synthesize across all of them: reconcile what the branches established, " +
		"say what is now known and what remains open, and complete the episode " +
		"only if the completion contract is actually met. A branch that blocked " +
		"is a finding, not a gap to re-investigate."
}
