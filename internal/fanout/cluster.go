// Package fanout decides whether an investigation has earned the right to walk
// more than one hypothesis at a time, and owns the identities that let those
// walks actually happen at the same time.
//
// Two rules shape everything here.
//
// Parallelism is proposed by the model and granted by the host. A lead that
// asks to fan out is answered from the claims ledger, not from its own
// assertion that the work is divisible — so an investigation that has found one
// thing to look at cannot spend three turns looking at it. That constraint is
// the operator's, stated when this was accepted: tokens are never burned
// blindly.
//
// And serial first, always. The ambiguity a fan-out spends against is measured
// from a sweep that has already finished. A simple incident never reaches the
// gate, and when it does reach it the gate refuses — which is why every refusal
// here carries a sentence rather than a boolean. A trace through an ambiguous
// incident that took the serial path has to be able to say why, and silence is
// indistinguishable from the feature being broken.
//
// # What is decided here, and what still has to be built
//
// This package is the whole decision and none of the execution: it says whether
// to fan out, into which goals, and what a branch may do. Nothing here starts a
// run. Wiring it up has to clear four serializers, and the count matters
// because missing any one of them produces branches that are queued in
// parallel, reported as parallel, and run one at a time.
//
// Two are solved by BranchConversationKey, and there is a store test standing
// on them: the scheduled work lane and the agent-run lease both refuse a second
// item on a conversation that already has a live one.
//
// The third is work_episodes.latest_attempt_id. It is a single pointer, and an
// attempt that is not the one it names is superseded and cancelled the moment
// it tries to finalize — so two concurrent attempts of one episode destroy each
// other, and making that pointer goal-aware means a goal_id column on
// episode_attempts, which is a schema migration.
//
// That migration is avoidable, and the reason is worth writing down because it
// is not visible from either table. Evidence is keyed by incident, not by
// episode, and ListEpisodeEvidence unions the incident's evidence into every
// episode under it. Branches modelled as child episodes of the lead, sharing
// its incident, therefore write into the one shared ledger for free and each
// carry their own latest_attempt_id — the third serializer disappears rather
// than being worked around. The spec was written as "concurrent goal-scoped
// attempts under one episode", which needs the column; the child-episode shape
// gets the same behaviour without it, and that is a decision to take
// deliberately rather than to discover halfway through a migration.
//
// The fourth is the one neither shape solves. The agent-run lease will not
// start any run against an incident whose active_turn_id is set, because the
// incident has exactly one Coop session and one live turn. Branches need their
// own sessions — incident forks, not the shared channel session — and that gate
// has to become per-session rather than per-incident. Until it does, branches
// admitted here would still take turns.
package fanout

import (
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// Cluster is one pocket of unresolved ambiguity: the claims still open about a
// single thing, and every name that thing is known by.
//
// Claims join the same cluster when they share a target, because one branch
// sent to look at that target answers all of them. Claims that share no target
// are the only shape of ambiguity a branch can be spent on.
type Cluster struct {
	// Identity is the stable name of the cluster, chosen so the order branches
	// are planned in does not move between runs.
	Identity string
	// ClaimIDs are the unresolved claims bound to this cluster, sorted.
	ClaimIDs []string
	// Targets is every target identity merged into this cluster, sorted. A
	// synthetic layer identity appears here when nothing was observed at all.
	Targets []string
	// Terms are the exact tokens a planned goal may name this cluster by: the
	// claim ids from the contract the model was given, and the targets it wrote
	// into its own evidence. Synthetic layer identities are deliberately absent
	// — "host" is a word that appears in half of all operational prose, and
	// binding a goal on it would match by accident.
	Terms []string
}

// Clusters groups the ledger's unresolved claims into independent pockets of
// ambiguity.
//
// The grouping is transitive: a claim naming two targets is itself the evidence
// that those two targets are one investigation, and merges them. Without that,
// a host and the dependency it talks to would be funded as two branches on the
// strength of a claim that already said they were the same question.
func Clusters(ledger investigation.Ledger) []Cluster {
	type claimNode struct {
		claimID string
		targets []string
		terms   []string
	}
	nodes := make([]claimNode, 0, len(ledger.Contract.Claims))
	for _, requirement := range ledger.Contract.Claims {
		view, ok := ledger.Claims[requirement.ID]
		if !ok || view.Resolved || view.State == investigation.ClaimNotApplicable {
			continue
		}
		targets, observed := claimTargets(view)
		terms := []string{strings.ToLower(strings.TrimSpace(requirement.ID))}
		if observed {
			terms = append(terms, targets...)
		}
		nodes = append(nodes, claimNode{claimID: requirement.ID, targets: targets, terms: terms})
	}
	parent := make([]int, len(nodes))
	for index := range parent {
		parent[index] = index
	}
	var find func(int) int
	find = func(index int) int {
		for parent[index] != index {
			parent[index] = parent[parent[index]]
			index = parent[index]
		}
		return index
	}
	owner := make(map[string]int, len(nodes))
	for index, node := range nodes {
		for _, target := range node.targets {
			existing, seen := owner[target]
			if !seen {
				owner[target] = index
				continue
			}
			left, right := find(index), find(existing)
			if left != right {
				parent[right] = left
			}
		}
	}
	grouped := make(map[int]*Cluster, len(nodes))
	order := make([]int, 0, len(nodes))
	for index, node := range nodes {
		root := find(index)
		cluster, ok := grouped[root]
		if !ok {
			cluster = &Cluster{}
			grouped[root] = cluster
			order = append(order, root)
		}
		cluster.ClaimIDs = append(cluster.ClaimIDs, node.claimID)
		cluster.Targets = append(cluster.Targets, node.targets...)
		cluster.Terms = append(cluster.Terms, node.terms...)
	}
	result := make([]Cluster, 0, len(order))
	for _, root := range order {
		cluster := grouped[root]
		sort.Strings(cluster.ClaimIDs)
		cluster.Targets = sortedUnique(cluster.Targets)
		cluster.Terms = sortedUnique(cluster.Terms)
		cluster.Identity = cluster.Targets[0]
		result = append(result, *cluster)
	}
	sort.Slice(result, func(left, right int) bool {
		return result[left].Identity < result[right].Identity
	})
	return result
}

// claimTargets names what a claim is about, and reports whether anything was
// actually observed.
//
// Stale evidence counts. An observation that has aged out still says which host
// it was about, and dropping it would send a claim whose target is perfectly
// well known back to its layer identity — splitting one investigation into two
// branches that go and look at the same machine.
func claimTargets(view investigation.ClaimView) ([]string, bool) {
	seen := make(map[string]bool, 4)
	targets := make([]string, 0, 4)
	for _, set := range [][]core.Evidence{view.Evidence, view.Contradictions, view.StaleEvidence} {
		for _, item := range set {
			target := strings.ToLower(strings.TrimSpace(item.Target))
			if target == "" || seen[target] {
				continue
			}
			seen[target] = true
			targets = append(targets, target)
		}
	}
	if len(targets) > 0 {
		sort.Strings(targets)
		return targets, true
	}
	// A claim nothing has been observed about still names what it is about: the
	// layer it asks after. Without this fallback every unexamined claim would
	// share the empty identity and collapse into a single cluster, so the host
	// would report one thing to look at at exactly the moment there are several
	// — which is the case fan-out exists for.
	layer := strings.ToLower(strings.TrimSpace(view.Requirement.Layer))
	if layer == "" {
		return []string{"claim:" + strings.ToLower(strings.TrimSpace(view.Requirement.ID))}, false
	}
	return []string{"layer:" + layer}, false
}

func sortedUnique(values []string) []string {
	seen := make(map[string]bool, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
