package fanout

import (
	"fmt"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// DefaultBranchLimit caps a single fan-out.
//
// Three, because the cap is what stops a model that found eight loose threads
// from opening eight sessions, and because the fourth branch of an incident is
// reliably the one nobody reads. Clusters past the cap are not lost — they stay
// on the ledger for the lead to walk serially, which is what would have
// happened to all of them without this feature.
const DefaultBranchLimit = 3

// MinimumBranches is two, and the reason is worth stating: one branch is the
// serial path with extra bookkeeping. It investigates the same single thing the
// lead would have, and then charges an entire synthesis attempt to merge one
// result into a ledger that already contained it.
const MinimumBranches = 2

// Proposal is one goal the lead asked to run as a branch.
//
// It binds to a cluster through the prose it was planned with, because
// plan_goal has no field naming the claims a goal will settle. That is a real
// weakness and worth fixing at the schema rather than here: a goal that said
// which claims it answers would remove the matching entirely. Until then the
// match is on exact tokens the model was handed — contract claim ids, and the
// targets it wrote into its own evidence — never on loose words.
type Proposal struct {
	GoalID             string
	Authority          core.AuthorityBoundary
	RequestedOutcome   string
	CompletionContract string
}

// Spend is what the episode has already cost, in both figures.
//
// Both, because "zero tokens" and "nobody measured" are different facts and a
// budget that cannot tell them apart is not a budget. Coop reports no usage at
// all on the ACP path, so an episode denominated only in tokens reads as having
// spent nothing however long it has been running, and would fan out forever.
type Spend struct {
	Tokens      int64
	TokenBudget int64
	Turns       int
	TurnBudget  int
}

// Exhausted reports whether the episode has spent what it was given, preferring
// the token figure and falling back to turns when no usage was ever reported.
func (spend Spend) Exhausted() bool {
	if spend.Tokens > 0 {
		return spend.TokenBudget > 0 && spend.Tokens >= spend.TokenBudget
	}
	return spend.TurnBudget > 0 && spend.Turns >= spend.TurnBudget
}

type Request struct {
	Effort core.EffortContract
	// Lane is the triage lane. The bounded conversation lane never fans out.
	Lane string
	// FinishedAttempts is how many sweeps have already run to a conclusion.
	FinishedAttempts int
	Clusters         []Cluster
	Proposals        []Proposal
	// ActiveBranches counts branches already running for this episode, so a
	// second fan-out cannot exceed the pool the first one drew from.
	ActiveBranches int
	BranchLimit    int
	Spend          Spend
}

// Branch is one admitted goal and the pocket of ambiguity it answers.
type Branch struct {
	GoalID  string
	Cluster Cluster
}

// Decision is the host's answer. Exactly one of the two fields is meaningful:
// branches to run, or the sentence explaining why none.
type Decision struct {
	Branches []Branch
	Refusal  string
}

func (decision Decision) Admitted() bool { return len(decision.Branches) > 0 }

// Decide is the whole gate, in the order the checks are cheapest to explain.
//
// Every arm returns a refusal naming what stopped it, because these are
// recorded as episode progress. An operator reading a trace of an obviously
// ambiguous incident that ran serially needs the host's reason; without it the
// only available conclusion is that fan-out is broken, and that conclusion has
// been drawn from silence before.
func Decide(request Request) Decision {
	switch {
	case strings.EqualFold(strings.TrimSpace(request.Lane), "conversation"):
		return refuse("the bounded conversation lane answers a person in a thread and never fans out")
	case request.Effort != core.EffortOperationalAssessment &&
		request.Effort != core.EffortIncidentInvestigation:
		return refuse(fmt.Sprintf(
			"effort contract %s does not fan out; only %s and %s do",
			request.Effort, core.EffortOperationalAssessment, core.EffortIncidentInvestigation,
		))
	case request.FinishedAttempts < 1:
		return refuse("the first sweep of an investigation always runs alone, " +
			"so the ambiguity a branch is spent on is measured rather than assumed")
	case len(request.Clusters) < MinimumBranches:
		return refuse(fmt.Sprintf(
			"the ledger leaves %s of unresolved ambiguity, so there is one thing "+
				"to look at and that is the serial path",
			plural(len(request.Clusters), "independent pocket", "independent pockets"),
		))
	case len(request.Proposals) < MinimumBranches:
		return refuse(fmt.Sprintf(
			"the lead proposed %d parallel goals against %d independent clusters; "+
				"fan-out is proposed by the model, never imposed",
			len(request.Proposals), len(request.Clusters),
		))
	}
	if spent := request.Spend; spent.Exhausted() {
		return refuse(fmt.Sprintf(
			"this episode has spent its budget (%s); branches are not funded past it",
			spent.describe(),
		))
	}
	limit := request.BranchLimit
	if limit <= 0 {
		limit = DefaultBranchLimit
	}
	headroom := limit - request.ActiveBranches
	if headroom < MinimumBranches {
		return refuse(fmt.Sprintf(
			"the workspace has capacity for %d more concurrent branches against a limit of %d, "+
				"and a single branch is the serial path with extra bookkeeping",
			max(headroom, 0), limit,
		))
	}
	branches := make([]Branch, 0, len(request.Proposals))
	claimed := make(map[string]string, len(request.Proposals))
	for _, proposal := range request.Proposals {
		if proposal.Authority != "" && proposal.Authority != core.AuthorityReadOnly {
			return refuse(fmt.Sprintf(
				"branch goal %s asks for %s authority; branches are read-only, "+
					"and only the lead writes anywhere",
				proposal.GoalID, proposal.Authority,
			))
		}
		cluster, err := bind(request.Clusters, proposal)
		if err != nil {
			return refuse(err.Error())
		}
		if other, taken := claimed[cluster.Identity]; taken {
			return refuse(fmt.Sprintf(
				"branch goals %s and %s both answer the same cluster (%s); "+
					"two turns would learn what one turn learns",
				other, proposal.GoalID, cluster.Identity,
			))
		}
		claimed[cluster.Identity] = proposal.GoalID
		branches = append(branches, Branch{GoalID: proposal.GoalID, Cluster: cluster})
	}
	if len(branches) > headroom {
		branches = branches[:headroom]
	}
	if len(branches) < MinimumBranches {
		return refuse(fmt.Sprintf(
			"only %s survived the gate, which is the serial path with extra bookkeeping",
			plural(len(branches), "branch", "branches"),
		))
	}
	return Decision{Branches: branches}
}

func refuse(reason string) Decision { return Decision{Refusal: reason} }

// plural keeps the refusals readable. They are recorded as episode progress and
// read by an operator asking why an incident ran serially, so "1 independent
// pockets" is a sentence that makes the host look like it is guessing.
func plural(count int, one, many string) string {
	if count == 1 {
		return fmt.Sprintf("%d %s", count, one)
	}
	return fmt.Sprintf("%d %s", count, many)
}

func (spend Spend) describe() string {
	if spend.Tokens > 0 {
		return fmt.Sprintf("%d of %d tokens", spend.Tokens, spend.TokenBudget)
	}
	// Said this way on purpose: no provider usage was reported, which is not the
	// same claim as "it cost nothing", and an operator reading the refusal needs
	// to know which figure stopped the fan-out.
	return fmt.Sprintf("%d of %d turns, with no provider usage reported",
		spend.Turns, spend.TurnBudget)
}

// bind matches a proposed goal to the one cluster it names.
//
// A goal that names none is a hypothesis the ledger does not support, and
// admitting it is exactly the blind spend this gate exists to stop. A goal that
// names several is not an independent question at all — it is the lead's whole
// investigation with a goal id attached, and running it as a branch would fence
// the episode's own work behind a read-only session.
func bind(clusters []Cluster, proposal Proposal) (Cluster, error) {
	text := strings.ToLower(proposal.RequestedOutcome + " " + proposal.CompletionContract)
	matched := make([]Cluster, 0, 2)
	for _, cluster := range clusters {
		for _, term := range cluster.Terms {
			if term != "" && strings.Contains(text, term) {
				matched = append(matched, cluster)
				break
			}
		}
	}
	switch len(matched) {
	case 1:
		return matched[0], nil
	case 0:
		return Cluster{}, fmt.Errorf(
			"branch goal %s names none of the unresolved claims or targets the ledger measured (%s)",
			proposal.GoalID, strings.Join(clusterIdentities(clusters), ", "),
		)
	default:
		return Cluster{}, fmt.Errorf(
			"branch goal %s spans %d independent clusters (%s) and is not one question",
			proposal.GoalID, len(matched), strings.Join(clusterIdentities(matched), ", "),
		)
	}
}

func clusterIdentities(clusters []Cluster) []string {
	result := make([]string, 0, len(clusters))
	for _, cluster := range clusters {
		result = append(result, cluster.Identity)
	}
	sort.Strings(result)
	return result
}
