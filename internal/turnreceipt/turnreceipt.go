// Package turnreceipt answers what one finished turn actually did.
//
// The card in front of an operator shows a turn while it runs and then rewrites
// itself, because it is an instrument rather than a log. A minute after the
// turn stops there is nothing on the surface saying what it read, what it
// changed, or what it cost — and the only account that survives is the model's
// own, which is exactly the account this whole card system exists because it
// could not trust. A real 57-minute turn made 119 tool calls and said "Still
// working" twice.
//
// So the receipt is assembled from records rather than from prose, and from
// four of them, because no single one holds the whole answer:
//
//   - the run row, which is Responder's own and outlives everything else here,
//     for identity and for how long the turn took;
//   - the activity ledger, for what the turn did, counted against the turn id
//     Coop stamped on each narrated moment;
//   - the evidence table, for what the turn established;
//   - Coop, for what the turn spent.
//
// The reads are declared as four narrow interfaces so this package can state
// what it is allowed to know. It holds no Slack client, no clock, and no way to
// reach the rest of the database. What it owns is the judgement — which run is
// "that turn", which findings belong to it, and when a number is missing rather
// than zero — which is the part worth testing on its own.
package turnreceipt

import (
	"context"
	"log/slog"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// NoFinishedTurn is the answer when nothing has stopped yet.
//
// It is a fact about the asker's timing rather than about the work, so it says
// what a receipt is for and when to ask again instead of reporting an error
// about a turn that is doing nothing wrong.
const NoFinishedTurn = "*No turn has finished here yet.* A receipt describes " +
	"work that has already stopped — what it read, what it changed, and what " +
	"it cost. Ask again once this turn ends."

// evidenceScanLimit bounds the findings read. A receipt is about the newest
// finished turn, so the newest rows are the ones that can fall inside its
// window; reading the whole table to count a handful would cost the incident's
// entire history on every click.
const evidenceScanLimit = 200

// Runs reads the incident's agent runs.
type Runs interface {
	ListAgentRunsForIncident(ctx context.Context, incidentID string) ([]core.AgentRun, error)
}

// Activity counts what a single turn narrated.
type Activity interface {
	CountsForTurn(ctx context.Context, episodeID, turnID string) (core.AgentTurnActivity, error)
}

// Findings reads what the work established.
type Findings interface {
	ListEvidence(
		ctx context.Context, incidentID, channelID string, limit int,
	) ([]core.Evidence, error)
}

// Turns re-reads a finished turn from the agent host.
type Turns interface {
	GetTurn(ctx context.Context, sessionID, turnID string) (coop.Turn, error)
}

// Sources are the four records a receipt is assembled from. Any of them may be
// absent; a receipt missing a source states what it does not know rather than
// failing, because a partial account of a finished turn is still worth having
// and a refusal is not.
type Sources struct {
	Runs     Runs
	Activity Activity
	Findings Findings
	Turns    Turns
	Log      *slog.Logger
}

// Compose reads the newest finished turn of an incident.
//
// It reports false when no turn has finished, which is a real answer rather
// than an error: a task whose first turn is still running has nothing to
// receipt yet, and the caller says so in words.
func Compose(
	ctx context.Context,
	sources Sources,
	incidentID string,
) (slackui.TurnReceipt, bool, error) {
	run, ok, err := latestFinishedRun(ctx, sources.Runs, incidentID)
	if err != nil || !ok {
		return slackui.TurnReceipt{}, false, err
	}
	receipt := slackui.TurnReceipt{RunID: run.ID}
	if !run.StartedAt.IsZero() && run.CompletedAt.After(run.StartedAt) {
		receipt.Duration = run.CompletedAt.Sub(run.StartedAt)
		receipt.DurationKnown = true
	}
	if sources.Activity != nil {
		counts, err := sources.Activity.CountsForTurn(ctx, run.EpisodeID, run.CoopTurnID)
		if err != nil {
			return slackui.TurnReceipt{}, false, err
		}
		receipt.Moments = counts.Moments
		receipt.ToolCalls = counts.ToolCalls
		receipt.Files = counts.Files
		if !receipt.DurationKnown && counts.Last.After(counts.First) {
			// The narration brackets the turn from the outside, and is a
			// shorter span than the run — the first moment arrives after the
			// turn starts. It is used only where the run's own clocks say
			// nothing at all.
			receipt.Duration = counts.Last.Sub(counts.First)
			receipt.DurationKnown = true
		}
	}
	receipt.Evidence = evidenceRecordedDuring(ctx, sources, incidentID, run)
	if usage, ok := spend(ctx, sources, run); ok {
		receipt.TokensRecorded = true
		receipt.InputTokens = usage.InputTokens
		receipt.CachedTokens = usage.CachedInputTokens
		receipt.OutputTokens = usage.OutputTokens
		receipt.ReasoningTokens = usage.ReasoningTokens
		receipt.CostRecorded = usage.CostRecorded
		receipt.CostUSD = usage.CostUSD
	}
	return receipt, true, nil
}

// latestFinishedRun is the newest run that has stopped and knows which Coop
// turn it was.
//
// Newest finished rather than newest: a task with a turn running right now
// still has a finished turn behind it, and "what did that turn do" is a
// question about the one that finished. A run that never reached Coop has no
// turn id and nothing to report, so it is not the answer either.
func latestFinishedRun(
	ctx context.Context,
	runs Runs,
	incidentID string,
) (core.AgentRun, bool, error) {
	if runs == nil {
		return core.AgentRun{}, false, nil
	}
	items, err := runs.ListAgentRunsForIncident(ctx, incidentID)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	for index := len(items) - 1; index >= 0; index-- {
		if items[index].CoopTurnID != "" && items[index].TerminalState != "" {
			return items[index], true, nil
		}
	}
	return core.AgentRun{}, false, nil
}

// spend re-reads what the turn cost.
//
// Re-reading beats storing a copy because it needs no plumbing that does not
// already exist: GetTurn is the same call the terminal poll makes to learn how
// a turn ended, asked again a few minutes later. What that gives up is
// durability, and the loss is bounded — if Coop has forgotten the session the
// receipt loses its tokens and keeps everything else, because everything else
// was never Coop's to forget.
//
// Failure here is ordinary rather than exceptional. The caller renders "not
// recorded", which is the same thing it renders for a provider that never
// measured the turn, and both are true statements of the same fact: nobody
// here knows.
func spend(ctx context.Context, sources Sources, run core.AgentRun) (coop.Usage, bool) {
	if sources.Turns == nil || run.SessionID == "" || run.CoopTurnID == "" {
		return coop.Usage{}, false
	}
	turn, err := sources.Turns.GetTurn(ctx, run.SessionID, run.CoopTurnID)
	if err != nil {
		warn(sources.Log, "could not re-read a finished turn for its receipt",
			"error", err.Error(), "run", run.ID, "turn", run.CoopTurnID)
		return coop.Usage{}, false
	}
	if !turn.Usage.Recorded() {
		return coop.Usage{}, false
	}
	return turn.Usage, true
}

// evidenceRecordedDuring counts the findings the turn left behind.
//
// Evidence rows carry no turn id — they are the incident's, recorded by
// whichever turn happened to find them — so the turn's own window is what
// attributes them. That is an attribution rather than a key, and it is the
// honest one available: a row written while the turn was running was written by
// it. A run without both clocks stamped gets no count rather than the
// incident's total, which would be a different number wearing this one's label.
func evidenceRecordedDuring(
	ctx context.Context,
	sources Sources,
	incidentID string,
	run core.AgentRun,
) int {
	if sources.Findings == nil || run.StartedAt.IsZero() || run.CompletedAt.IsZero() {
		return 0
	}
	evidence, err := sources.Findings.ListEvidence(ctx, incidentID, "", evidenceScanLimit)
	if err != nil {
		warn(sources.Log, "could not count the evidence a turn recorded",
			"error", err.Error(), "incident", incidentID)
		return 0
	}
	count := 0
	for _, item := range evidence {
		if within(item.CreatedAt, run.StartedAt, run.CompletedAt) {
			count++
		}
	}
	return count
}

func within(moment, start, end time.Time) bool {
	return !moment.Before(start) && !moment.After(end)
}

func warn(log *slog.Logger, message string, args ...any) {
	if log != nil {
		log.Warn(message, args...)
	}
}
