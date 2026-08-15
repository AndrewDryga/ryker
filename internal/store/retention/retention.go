// Package retention records, for every table Responder writes, how long its
// rows are kept and why.
//
// The policy used to exist only as the body of Store.Prune, which meant a new
// table acquired a retention policy exactly when somebody remembered to add
// one. Five did not: slack_status_generations, conversation_memory_changes,
// feedback_items, fixture_candidates and replay_cancellations had no DELETE
// anywhere in the tree and no cascading parent, so they grew without bound
// from the day they shipped. None was large enough to notice, which is the
// point — an unbounded table is not a problem until it is, and nothing was
// ever going to raise it.
//
// So the classification is data here, and Policies is checked against the live
// schema by a test. Adding a table without deciding what happens to its rows
// now fails the build rather than quietly starting another leak.
package retention

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Class is what kind of thing a table holds, which is what decides how long it
// is kept. The horizons themselves are operator configuration; these names say
// which one applies.
type Class string

const (
	// Operational is the transport of a turn: message bodies, queue rows,
	// bookkeeping that is spent once the turn is over.
	Operational Class = "operational"
	// History is the account of what an agent was asked to do and what it did.
	// It outlives the transport because it is the record, not the delivery.
	History Class = "episode_history"
	// Audit is the ledger of decisions and their reviews.
	Audit Class = "audit"
	// Memory is what Responder knows about a conversation.
	Memory Class = "conversation_memory"
	// ClosedWork is an incident or task that finished, kept briefly so the
	// close can be inspected.
	ClosedWork Class = "closed_work"
	// Cascade means the rows go when their parent goes; the parent's class is
	// the effective one.
	Cascade Class = "cascade"
	// Kept means the rows are deliberately permanent: configuration an
	// operator set, a decision a person made, or state with exactly one row.
	// This is a decision, not an oversight, and every entry says whose.
	Kept Class = "kept"
)

// Policy is one table's answer.
type Policy struct {
	Table string
	Class Class
	// Why is written for whoever is deciding whether to change it.
	Why string
}

// Policies is every table in the schema, in the order sqlite_master lists them
// so the two can be read side by side.
var Policies = []Policy{
	{"agent_activity", Cascade,
		"what the model did inside a turn — the tool calls, plan revisions, reasoning and " +
			"permission decisions Coop narrated; part of the episode's trace and deleted with " +
			"work_episodes"},
	{"agent_runs", Operational,
		"the transport of one model turn — its assembled input and its reply — deleted on the " +
			"operational horizon once no episode or attempt still points at it, and with its " +
			"incident when closed work is swept"},
	{"audit_events", Audit,
		"the ledger of what Responder decided, who asked for it and who approved it"},
	{"channel_configurations", Kept,
		"operator configuration: which repository a channel maps to, how Responder participates " +
			"there and who it invites. It changes when an operator changes it and goes when they " +
			"forget the channel"},
	{"channel_memories", Operational,
		"what a channel was working on while a Coop session was live; swept on the operational " +
			"horizon once that session's workspace has been reclaimed"},
	{"claim_assessments", Cascade,
		"the judgement passed on one episode's claims; deleted with work_episodes"},
	{"commitments", Cascade,
		"what an episode said it would do; deleted with work_episodes"},
	{"configuration_sessions", Operational,
		"a half-finished channel setup dialog — the transport of a configuration conversation, " +
			"spent once it is saved, cancelled or expired"},
	{"context_artifacts", Operational,
		"the body of an input handed to a model turn, swept by artifactstore.PruneSpent once " +
			"every prompt that referenced it has itself been emptied"},
	{"context_manifest_refs", Cascade,
		"one line of a manifest's inventory; deleted with context_manifests"},
	{"context_manifests", Cascade,
		"what a turn was actually given; deleted with the attempt or episode it describes. Its " +
			"prompt text is emptied earlier, on the operational horizon, leaving the digest"},
	{"conversation_memories", Memory,
		"the per-channel memory of an ongoing conversation, expiring on the conversation-memory " +
			"horizon"},
	{"conversation_memory_changes", History,
		"the before-and-after of one memory write, keyed to the episode that caused it and " +
			"rendered on that episode's page; it expires with the account it belongs to"},
	{"conversation_routes", Memory,
		"where a channel's replies belong — thread or channel — which is part of what Responder " +
			"knows about the conversation and expires with it"},
	{"conversation_sessions", Operational,
		"the Coop session backing a live channel conversation; swept on the operational horizon " +
			"once that session's workspace has been reclaimed"},
	{"coop_cleanup", Audit,
		"the record of a Coop workspace being checked and released. A done row is the receipt " +
			"and expires on the audit horizon; a row not yet done is work still owed and is " +
			"never swept"},
	{"coverage", ClosedWork,
		"what an investigation had and had not looked at; it goes with its incident, and a row " +
			"gathered outside one goes on the operational horizon"},
	{"emisar_approvals", Operational,
		"one granted approval for an infrastructure action, deleted once its own expiry is a " +
			"full operational horizon in the past, and with its incident when closed work is swept"},
	{"episode_attempts", Cascade,
		"one try at an episode; deleted with work_episodes or with the agent run it executed on"},
	{"episode_goals", Cascade,
		"what an episode was aiming at; deleted with work_episodes"},
	{"episode_outcomes", Cascade,
		"what a finished episode amounted to, flattened so a later incident can be told about " +
			"it; deleted with work_episodes, because a recalled outcome that outlived the trace " +
			"proving it would be an unfalsifiable claim about a past nobody can open"},
	{"episode_wakeups", Cascade,
		"a scheduled resume for an episode; deleted with work_episodes, which retention refuses " +
			"to expire while a wakeup is still pending or leased"},
	{"evaluation_decisions", Operational,
		"the per-message judgement of whether this deserved an agent at all; spent once the turn " +
			"it gated is over"},
	{"evidence", ClosedWork,
		"what an investigation found and cited; it goes with its incident, and a row gathered " +
			"outside one goes on the operational horizon"},
	{"feedback_items", Audit,
		"somebody's verdict on an answer. A dismissed or already-converted item is the record of " +
			"a review and expires on the audit horizon; an open one is a person waiting for a " +
			"reply and is never swept"},
	{"fixture_candidates", Audit,
		"a queued correction to model behavior. Rejected and expired candidates are the record " +
			"that a review happened and expire on the audit horizon; pending and approved ones " +
			"pin their episode and outlive every horizon on purpose"},
	{"incidents", ClosedWork,
		"the incident itself, deleted on the closed-work horizon once it is closed, its Coop " +
			"workspace reclaimed and no episode of it still pinned by a review"},
	{"memory_entries", Memory,
		"one durable thing Responder knows about a channel, repository or person, deleted when " +
			"the expiry written on the row itself passes rather than on a sweep horizon"},
	{"memory_review_items", Audit,
		"a memory write queued for a person to confirm. A reviewed one is a decision record on " +
			"the audit horizon; a pending one survives only while the entries it refers to do"},
	{"memory_rollups", Memory,
		"a summary standing in for a batch of memory entries, deleted when the expiry on the row " +
			"passes"},
	{"memory_supersessions", Audit,
		"which memory replaced which and why — the ledger behind a memory's current shape"},
	{"publication_followups", Cascade,
		"a follow-up asked for on a published change; deleted with publications"},
	{"publication_lifecycle_events", Cascade,
		"how a publication moved from draft to published or stale; deleted with publications"},
	{"publications", ClosedWork,
		"the pull request an incident produced, deleted with that incident on the closed-work " +
			"horizon"},
	{"quality_findings", Audit,
		"a confirmed or rejected finding about Responder's own answers, with what was done about " +
			"it. scripts/quality-watch.sh writes these and expires them on its own retention_days " +
			"window, so Prune does not touch them"},
	{"replay_cancellations", Operational,
		"the bookkeeping for cancelling one Coop replay. A completed row is a receipt and " +
			"expires on the operational horizon; a pending one is work still owed to Coop and is " +
			"never swept"},
	{"responder_preferences", Kept,
		"a behavior preference somebody set for a workspace, channel, repository or operator. It " +
			"is kept until the expiry they chose, which Prune honors row by row; no sweep horizon " +
			"applies to it"},
	{"responder_state", Kept,
		"a two-row key/value singleton — the incident card revision and when memory dreaming last " +
			"ran. Nothing accumulates here"},
	{"schedule_proposals", Operational,
		"a scheduled task offered to somebody and waiting on their yes; the offer is spent once " +
			"it is accepted or its own expires_at passes. It was the sixth table found with no " +
			"deletion path, and Sweep now settles it on the same predicate configuration_sessions " +
			"uses"},
	{"scheduled_task_runs", History,
		"one firing of a scheduled task and the episode it produced — the account of a firing " +
			"rather than its transport, so it expires with the episode history it points at " +
			"rather than a day later"},
	{"scheduled_tasks", Kept,
		"a recurring task an operator asked for. It is kept until the expiry they set, which " +
			"Prune honors row by row, or until they delete it"},
	{"schema_version", Kept,
		"one row saying which migration the database is at. Deleting it would make the store " +
			"refuse to open"},
	{"signals", ClosedWork,
		"the alerts and events that opened an incident, deleted with it on the closed-work horizon"},
	{"slack_channel_memberships", Kept,
		"one row per Slack channel Responder can see, mirroring whether it is a member and " +
			"whether onboarding finished. Bounded by the workspace rather than by traffic, and " +
			"removed when an operator forgets the channel"},
	{"slack_deliveries", Operational,
		"one message Responder sent or tried to send — the transport of a reply, expiring on the " +
			"operational horizon once it is sent, failed or superseded"},
	{"slack_inputs", Operational,
		"one inbound Slack event queued for handling, spent as soon as the turn it started is " +
			"done or failed"},
	{"slack_settings", Kept,
		"operator configuration, global or per channel; a value stays until somebody sets or " +
			"unsets it"},
	{"slack_status_generations", Operational,
		"a per-thread counter that stops a stale status update from overwriting a newer one. " +
			"Once the thread has been quiet past the operational horizon there is no delivery " +
			"left for a restarted counter to race"},
	{"standing_assignment_actions", Cascade,
		"what one standing assignment actually did, and the daily budget it spent doing it; " +
			"deleted with standing_assignments"},
	{"standing_assignments", Kept,
		"a standing instruction a person confirmed — this class of change, in this repository, " +
			"up to this many a day. It stays until they disable or delete it"},
	{"standing_rule_runs", History,
		"the account of one standing rule firing and what came of it. It is the only evidence a " +
			"rule ever produces about itself, so it expires on the episode-history horizon rather " +
			"than with the message that triggered it"},
	{"standing_rules", Kept,
		"a rule an operator created, plus the tallies of what it has done. Kept until the expiry " +
			"they set, which Prune honors row by row, or until they delete it"},
	{"timeline_events", ClosedWork,
		"the narrative of what happened during an incident; it goes with its incident, and a row " +
			"recorded outside one goes on the operational horizon"},
	{"webhook_events", Operational,
		"one inbound webhook queued for handling, spent as soon as it is done or failed"},
	{"work_episode_events", Cascade,
		"an episode's own event stream, and the reason retention is episode-granular: thinning it " +
			"in place would leave a record of the work missing whichever parts nobody thought " +
			"were interesting. Deleted with work_episodes"},
	{"work_episode_progress", Cascade,
		"the progress line shown while an episode works; deleted with work_episodes"},
	{"work_episodes", History,
		"the account of what an agent was asked to do and what it did, expiring on the " +
			"episode-history horizon and only when nothing still pins it"},
	{"work_items", Operational,
		"the scheduler queue. A row exists only while its work is pending, running or failed — " +
			"completing the work deletes it, so retention never sees one"},
}

// Lookup answers for one table, reporting whether any policy exists at all.
func Lookup(table string) (Policy, bool) {
	for _, policy := range Policies {
		if policy.Table == table {
			return policy, true
		}
	}
	return Policy{}, false
}

// Sweep deletes the rows Store.Prune does not reach. It runs inside Prune's
// transaction, so a failure here rolls the whole pass back rather than leaving
// a half-swept database.
//
// Each statement below names the rows it must never touch, because for three
// of these tables the difference between a spent row and a live one is the
// whole policy: an unreviewed lesson, an unanswered complaint and a pending
// cancellation all look like old rows and none of them is.
// The horizons arrive as instants and are rendered here, so a caller cannot
// hand one sweep a differently formatted timestamp than another — string
// comparison against these columns is only correct while every writer agrees
// on the format.
func Sweep(ctx context.Context, tx *sql.Tx, operational string, history, audit time.Time) (int64, error) {
	historyText, auditText := timestamp(history), timestamp(audit)
	var total int64
	for _, sweep := range []struct {
		query string
		arg   string
	}{
		// A generation counter stops a stale status update from overwriting a
		// newer one in the same thread. Once a thread has been quiet past the
		// operational horizon there is no status left to lose a race with:
		// slack_deliveries expires on the same horizon, so no delivery old
		// enough to race a restarted counter still exists.
		{`DELETE FROM slack_status_generations WHERE updated_at < ?`, operational},
		// A completed cancellation is a receipt. A pending one is work still
		// owed to Coop, and deleting it would strand the replay it cancels.
		{`DELETE FROM replay_cancellations WHERE state = 'completed' AND updated_at < ?`, operational},
		// The before-and-after of a memory write, keyed to the episode that
		// caused it and rendered on that episode's page. It expires with the
		// account it belongs to rather than before it.
		{`DELETE FROM conversation_memory_changes WHERE created_at < ?`, historyText},
		// A correction nobody kept. Pending is an unreviewed lesson and
		// approved is a kept one; both outlive this sweep deliberately, which
		// is the one place where "some memory we might keep indefinitely"
		// actually is indefinite.
		{`DELETE FROM fixture_candidates WHERE status IN ('rejected', 'expired') AND updated_at < ?`, auditText},
		// Feedback that was dismissed or already converted into durable
		// guidance. The guidance itself lives in memory_entries and outlives
		// this row. An open item is a person waiting on an answer and is never
		// swept.
		{`DELETE FROM feedback_items WHERE status <> 'open' AND updated_at < ?`, auditText},
		// A scheduled task offered to somebody and waiting on their yes. The
		// same shape and the same predicate as configuration_sessions above it
		// in Prune: settled once accepted or expired, and dead once its own
		// deadline passes, because every read of a pending proposal already
		// requires expires_at to be in the future.
		//
		// Deleting a lapsed offer lets the same source_ref be proposed again,
		// which is the wanted behaviour rather than a hazard: the offer really
		// did lapse, and the Slack message that would re-propose it expires on
		// this same horizon.
		{`DELETE FROM schedule_proposals
		   WHERE (status IN ('accepted', 'expired') AND updated_at < ?1) OR expires_at < ?1`, operational},
	} {
		result, err := tx.ExecContext(ctx, sweep.query, sweep.arg)
		if err != nil {
			return total, fmt.Errorf("retention sweep %q: %w", sweep.query, err)
		}
		affected, err := result.RowsAffected()
		if err != nil {
			return total, err
		}
		total += affected
	}
	return total, nil
}

// timestamp renders an instant the way every writer in this database renders
// one. The columns these sweeps compare against hold text, so a sweep using a
// different layout would silently match nothing — which is why the layout is
// taken from core rather than copied here.
func timestamp(at time.Time) string {
	return at.UTC().Format(core.TimestampFormat)
}
