package store

import "strings"

// schemaV46 rewrites every stored timestamp to a fixed width.
//
// Timestamps are TEXT and SQLite compares them as text, so their text order has
// to match their chronological order. Under RFC3339Nano it did not: the format
// strips trailing zeros, and the terminating Z sorts after every digit, so a
// shorter fraction loses to any longer one that extends it inside the same
// second. ".5Z" sorts after ".53Z". Every "WHERE ... <= ?" over a timestamp —
// 72 of them — could skip a row for the rest of its second and then find it.
//
// This was documented and left alone on the finding that no mis-ordering pair
// existed in the deployed data. That finding no longer held. Measured across
// both deployed databases on 2026-08-07: 339 values carried no fraction at all,
// widths ranged from 0 to 9 digits, and 86 distinct seconds already contained a
// pair that compared backwards.
//
// It covers every column in one migration on purpose. A fixed-width value
// compares just as wrongly against a variable-width one, so a column left
// behind would not stay half-broken — it would disagree with every column that
// was migrated.
var schemaV46 = buildTimestampWidthMigration(timestampColumnsAtV46)

// timestampColumnsAtV46 is every TEXT column ending in _at at schema 46.
//
// Frozen here rather than read from the schema at migration time: a migration
// has to do the same thing to every database that runs it.
// TestMigrationCoversEveryTimestampColumn checks this list against the live
// schema, so a new table cannot be forgotten.
var timestampColumnsAtV46 = []string{
	"action_proposals.expires_at", "action_proposals.created_at", "action_proposals.updated_at",
	"agent_runs.next_attempt_at", "agent_runs.created_at", "agent_runs.updated_at",
	"agent_runs.started_at", "agent_runs.completed_at", "audit_events.created_at",
	"channel_configurations.created_at", "channel_configurations.updated_at",
	"channel_memories.session_started_at", "channel_memories.rotated_at",
	"channel_memories.updated_at", "claim_assessments.updated_at",
	"configuration_sessions.expires_at", "configuration_sessions.created_at",
	"configuration_sessions.updated_at", "context_manifests.created_at",
	"conversation_memories.updated_at", "conversation_memories.last_recalled_at",
	"conversation_routes.updated_at", "conversation_sessions.session_started_at",
	"conversation_sessions.rotated_at", "conversation_sessions.updated_at",
	"coop_cleanup.eligible_at", "coop_cleanup.next_attempt_at", "coop_cleanup.created_at",
	"coop_cleanup.updated_at", "coverage.observed_at", "coverage.created_at",
	"emisar_approvals.next_check_at", "emisar_approvals.expires_at", "emisar_approvals.terminal_at",
	"emisar_approvals.created_at", "emisar_approvals.updated_at", "episode_attempts.lease_expires_at",
	"episode_attempts.started_at", "episode_attempts.completed_at", "episode_attempts.created_at",
	"episode_attempts.updated_at", "episode_goals.created_at", "episode_goals.updated_at",
	"episode_goals.completed_at", "episode_wakeups.due_at", "episode_wakeups.lease_expires_at",
	"episode_wakeups.created_at", "episode_wakeups.updated_at", "episode_wakeups.resolved_at",
	"evaluation_decisions.created_at", "evidence.observed_at", "evidence.created_at",
	"feedback_items.created_at", "feedback_items.updated_at", "fixture_candidates.created_at",
	"fixture_candidates.expires_at", "fixture_candidates.updated_at", "incidents.created_at",
	"incidents.updated_at", "incidents.last_firing_at", "incidents.resolve_due_at",
	"incidents.resolved_at", "incidents.closed_at", "incidents.channel_state_changed_at",
	"incidents.channel_checked_at", "memory_entries.expires_at", "memory_entries.created_at",
	"memory_entries.updated_at", "memory_entries.last_recalled_at", "memory_entries.last_reviewed_at",
	"memory_review_items.reviewed_at", "memory_review_items.created_at",
	"memory_review_items.updated_at", "memory_rollups.last_recalled_at", "memory_rollups.expires_at",
	"memory_rollups.created_at", "memory_rollups.updated_at", "memory_supersessions.created_at",
	"proposal_approvals.created_at", "publication_followups.merged_at",
	"publication_followups.next_check_at", "publication_followups.created_at",
	"publication_followups.updated_at", "publication_lifecycle_events.created_at",
	"publications.created_at", "publications.updated_at", "publications.published_at",
	"responder_preferences.expires_at", "responder_preferences.created_at",
	"responder_preferences.updated_at", "responder_state.updated_at", "schedule_proposals.expires_at",
	"schedule_proposals.created_at", "schedule_proposals.updated_at",
	"scheduled_task_runs.started_at", "scheduled_task_runs.completed_at",
	"scheduled_task_runs.created_at", "scheduled_task_runs.updated_at", "scheduled_tasks.start_at",
	"scheduled_tasks.next_run_at", "scheduled_tasks.last_run_at", "scheduled_tasks.expires_at",
	"scheduled_tasks.created_at", "scheduled_tasks.updated_at", "signals.starts_at",
	"signals.ends_at", "signals.received_at", "signals.updated_at",
	"slack_channel_memberships.joined_at", "slack_channel_memberships.observed_at",
	"slack_deliveries.next_attempt_at", "slack_deliveries.created_at", "slack_deliveries.updated_at",
	"slack_inputs.next_attempt_at", "slack_inputs.received_at", "slack_inputs.updated_at",
	"slack_settings.updated_at", "slack_status_generations.updated_at",
	"standing_assignment_actions.created_at", "standing_assignments.confirmed_at",
	"standing_assignments.expires_at", "standing_assignments.created_at",
	"standing_assignments.updated_at", "standing_rule_runs.created_at",
	"standing_rules.last_triggered_at", "standing_rules.expires_at", "standing_rules.created_at",
	"standing_rules.updated_at", "timeline_events.created_at", "webhook_events.next_attempt_at",
	"webhook_events.received_at", "webhook_events.updated_at", "work_episode_events.created_at",
	"work_episode_progress.created_at", "work_episodes.last_progress_at",
	"work_episodes.progress_due_at", "work_episodes.created_at", "work_episodes.updated_at",
	"work_episodes.completed_at", "work_items.available_at", "work_items.lease_expires_at",
	"work_items.rerun_at", "work_items.deadline_at", "work_items.created_at", "work_items.updated_at",
}

// buildTimestampWidthMigration pads each column's fraction to nine digits.
//
// The transform is written once and applied to every column rather than spelled
// out 145 times, so no column can quietly get a different one.
//
// Values not ending in Z are skipped: the expression would mangle a numeric
// offset, and every stored value is written in UTC —
// TestNoStoredTimestampCarriesANumericOffset holds that.
func buildTimestampWidthMigration(columns []string) string {
	const statement = "UPDATE @t SET @c = substr(@c,1,19) || '.' ||\n" +
		"  substr(replace(replace(substr(@c,20),'.',''),'Z','')" +
		" || '000000000', 1, 9) || 'Z'\n" +
		"  WHERE @c LIKE '%Z' AND length(@c) <> 30;\n"
	var out strings.Builder
	for _, qualified := range columns {
		table, column, ok := strings.Cut(qualified, ".")
		if !ok {
			panic("timestamp column must be table.column: " + qualified)
		}
		expanded := strings.ReplaceAll(statement, "@t", table)
		out.WriteString(strings.ReplaceAll(expanded, "@c", column))
	}
	return out.String()
}
