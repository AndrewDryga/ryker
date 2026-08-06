package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func (s *Store) UpsertPreference(
	ctx context.Context,
	preference core.ResponderPreference,
	maxTotal int,
	maxPerScope int,
) (core.ResponderPreference, bool, error) {
	if err := validatePreference(preference); err != nil {
		return core.ResponderPreference{}, false, err
	}
	if maxTotal < 1 || maxPerScope < 1 || maxPerScope > maxTotal {
		return core.ResponderPreference{}, false, errors.New("preference limits are invalid")
	}
	now := s.now().UTC()
	if preference.ExpiresAt.IsZero() || !preference.ExpiresAt.After(now) {
		return core.ResponderPreference{}, false, errors.New(
			"preference expiry must be in the future",
		)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.ResponderPreference{}, false, err
	}
	defer tx.Rollback()

	var existingID, createdAt string
	err = tx.QueryRowContext(ctx, `
		SELECT id, created_at
		FROM responder_preferences
		WHERE scope_kind = ? AND scope_key = ? AND name = ?`,
		preference.ScopeKind, preference.ScopeKey, preference.Name,
	).Scan(&existingID, &createdAt)
	replaced := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return core.ResponderPreference{}, false, err
	}
	if !replaced {
		var total, scoped int
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM responder_preferences WHERE expires_at > ?`,
			now.Format(timestampFormat),
		).Scan(&total); err != nil {
			return core.ResponderPreference{}, false, err
		}
		if total >= maxTotal {
			return core.ResponderPreference{}, false, fmt.Errorf(
				"preference capacity reached (%d unexpired entries)", maxTotal,
			)
		}
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM responder_preferences
			WHERE scope_kind = ? AND scope_key = ? AND expires_at > ?`,
			preference.ScopeKind, preference.ScopeKey, now.Format(timestampFormat),
		).Scan(&scoped); err != nil {
			return core.ResponderPreference{}, false, err
		}
		if scoped >= maxPerScope {
			return core.ResponderPreference{}, false, fmt.Errorf(
				"preference capacity reached for %s scope %q (%d unexpired entries)",
				preference.ScopeKind, preference.ScopeKey, maxPerScope,
			)
		}
		preference.ID, err = core.NewID("pref")
		if err != nil {
			return core.ResponderPreference{}, false, err
		}
		preference.CreatedAt = now
	} else {
		preference.ID = existingID
		preference.CreatedAt = parseTime(createdAt)
	}
	preference.Enabled = true
	preference.UpdatedAt = now
	_, err = tx.ExecContext(ctx, `
		INSERT INTO responder_preferences (
		  id, scope_kind, scope_key, name, value, enabled, source_ref, actor_id,
		  expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
		ON CONFLICT(scope_kind, scope_key, name) DO UPDATE SET
		  value = excluded.value,
		  enabled = 1,
		  source_ref = excluded.source_ref,
		  actor_id = excluded.actor_id,
		  expires_at = excluded.expires_at,
		  updated_at = excluded.updated_at`,
		preference.ID, preference.ScopeKind, preference.ScopeKey, preference.Name,
		preference.Value, preference.SourceRef, preference.ActorID,
		preference.ExpiresAt.UTC().Format(timestampFormat),
		preference.CreatedAt.UTC().Format(timestampFormat),
		preference.UpdatedAt.UTC().Format(timestampFormat),
	)
	if err != nil {
		return core.ResponderPreference{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return core.ResponderPreference{}, false, err
	}
	return preference, replaced, nil
}

func validatePreference(preference core.ResponderPreference) error {
	switch preference.ScopeKind {
	case "workspace", "channel", "repository", "operator":
	default:
		return fmt.Errorf("preference scope %q is invalid", preference.ScopeKind)
	}
	switch preference.Name {
	case "health_check_depth":
		switch preference.Value {
		case "quick", "standard", "deep":
		default:
			return fmt.Errorf(
				"health_check_depth value %q is invalid", preference.Value,
			)
		}
	case "response_detail":
		switch preference.Value {
		case "concise", "standard", "detailed":
		default:
			return fmt.Errorf("response_detail value %q is invalid", preference.Value)
		}
	case "response_location":
		if preference.ScopeKind == "repository" {
			return errors.New(
				"response_location does not support repository scope",
			)
		}
		switch preference.Value {
		case "follow_context", "prefer_thread", "prefer_channel":
		default:
			return fmt.Errorf("response_location value %q is invalid", preference.Value)
		}
	default:
		return fmt.Errorf("preference name %q is invalid", preference.Name)
	}
	for name, value := range map[string]string{
		"scope key":        preference.ScopeKey,
		"source reference": preference.SourceRef,
		"actor":            preference.ActorID,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("preference %s is required", name)
		}
	}
	if len(preference.ScopeKey) > 200 || len(preference.SourceRef) > 200 ||
		len(preference.ActorID) > 64 {
		return errors.New("preference contains an oversized field")
	}
	return nil
}

func (s *Store) GetPreference(
	ctx context.Context,
	id string,
) (core.ResponderPreference, error) {
	return scanPreference(s.db.QueryRowContext(
		ctx, preferenceSelect+` WHERE id = ?`, id,
	))
}

func (s *Store) ListPreferencesForContext(
	ctx context.Context,
	workspaceID string,
	channelID string,
	repository string,
	operatorID string,
	enabledOnly bool,
	limit int,
) ([]core.ResponderPreference, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("preference context limit must be between 1 and 100")
	}
	enabled := ""
	if enabledOnly {
		enabled = " AND enabled = 1"
	}
	rows, err := s.db.QueryContext(ctx, preferenceSelect+`
		WHERE expires_at > ?`+enabled+`
		  AND (
		    (scope_kind = 'workspace' AND scope_key = ?) OR
		    (scope_kind = 'channel' AND scope_key = ?) OR
		    (scope_kind = 'repository' AND scope_key = ?) OR
		    (scope_kind = 'operator' AND scope_key = ?)
		  )
		ORDER BY
		  CASE scope_kind
		    WHEN 'operator' THEN 0
		    WHEN 'channel' THEN 1
		    WHEN 'repository' THEN 2
		    ELSE 3
		  END,
		  updated_at DESC
		LIMIT ?`,
		s.nowText(), workspaceID, channelID, repository, operatorID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanPreferences(rows)
}

func (s *Store) ListPreferencesForHome(
	ctx context.Context,
	limit int,
) ([]core.ResponderPreference, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("home preference limit must be between 1 and 100")
	}
	rows, err := s.db.QueryContext(ctx, preferenceSelect+`
		WHERE expires_at > ?
		ORDER BY updated_at DESC
		LIMIT ?`, s.nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanPreferences(rows)
}

func (s *Store) SetPreferenceEnabled(
	ctx context.Context,
	id string,
	enabled bool,
) (core.ResponderPreference, error) {
	value := 0
	if enabled {
		value = 1
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE responder_preferences SET enabled = ?, updated_at = ?
		WHERE id = ? AND expires_at > ?`,
		value, s.nowText(), id, s.nowText(),
	)
	if err := expectOne(result, err, "set preference state"); err != nil {
		return core.ResponderPreference{}, err
	}
	return s.GetPreference(ctx, id)
}

func (s *Store) DeletePreference(
	ctx context.Context,
	id string,
) (core.ResponderPreference, error) {
	preference, err := s.GetPreference(ctx, id)
	if err != nil {
		return core.ResponderPreference{}, err
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM responder_preferences WHERE id = ?`, id)
	if err := expectOne(result, err, "delete preference"); err != nil {
		return core.ResponderPreference{}, err
	}
	return preference, nil
}

func (s *Store) UpsertStandingRule(
	ctx context.Context,
	rule core.StandingRule,
	maxTotal int,
	maxPerChannel int,
) (core.StandingRule, bool, error) {
	if err := validateStandingRule(rule); err != nil {
		return core.StandingRule{}, false, err
	}
	if maxTotal < 1 || maxPerChannel < 1 || maxPerChannel > maxTotal {
		return core.StandingRule{}, false, errors.New("standing rule limits are invalid")
	}
	now := s.now().UTC()
	if rule.ExpiresAt.IsZero() || !rule.ExpiresAt.After(now) {
		return core.StandingRule{}, false, errors.New(
			"standing rule expiry must be in the future",
		)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.StandingRule{}, false, err
	}
	defer tx.Rollback()
	var existingID, createdAt string
	err = tx.QueryRowContext(ctx, `
		SELECT id, created_at
		FROM standing_rules
		WHERE channel_id = ? AND trigger_name = ? AND action_name = ?
		  AND repository = ? AND source_kind = ?`,
		rule.ChannelID, rule.Trigger, rule.Action, rule.Repository, rule.SourceKind,
	).Scan(&existingID, &createdAt)
	replaced := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return core.StandingRule{}, false, err
	}
	if !replaced {
		var total, channel int
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM standing_rules WHERE expires_at > ?`,
			now.Format(timestampFormat),
		).Scan(&total); err != nil {
			return core.StandingRule{}, false, err
		}
		if total >= maxTotal {
			return core.StandingRule{}, false, fmt.Errorf(
				"standing rule capacity reached (%d unexpired rules)", maxTotal,
			)
		}
		if err := tx.QueryRowContext(ctx, `
			SELECT count(*) FROM standing_rules
			WHERE channel_id = ? AND expires_at > ?`,
			rule.ChannelID, now.Format(timestampFormat),
		).Scan(&channel); err != nil {
			return core.StandingRule{}, false, err
		}
		if channel >= maxPerChannel {
			return core.StandingRule{}, false, fmt.Errorf(
				"standing rule capacity reached for channel %q (%d unexpired rules)",
				rule.ChannelID, maxPerChannel,
			)
		}
		rule.ID, err = core.NewID("rule")
		if err != nil {
			return core.StandingRule{}, false, err
		}
		rule.CreatedAt = now
	} else {
		rule.ID = existingID
		rule.CreatedAt = parseTime(createdAt)
	}
	rule.Enabled = true
	rule.UpdatedAt = now
	_, err = tx.ExecContext(ctx, `
		INSERT INTO standing_rules (
		  id, channel_id, repository, trigger_name, action_name, source_kind,
		  enabled, source_ref, actor_id, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
		ON CONFLICT(channel_id, trigger_name, action_name, repository, source_kind)
		DO UPDATE SET
		  enabled = 1,
		  source_ref = excluded.source_ref,
		  actor_id = excluded.actor_id,
		  expires_at = excluded.expires_at,
		  updated_at = excluded.updated_at`,
		rule.ID, rule.ChannelID, rule.Repository, rule.Trigger, rule.Action,
		rule.SourceKind, rule.SourceRef, rule.ActorID,
		rule.ExpiresAt.UTC().Format(timestampFormat),
		rule.CreatedAt.UTC().Format(timestampFormat),
		rule.UpdatedAt.UTC().Format(timestampFormat),
	)
	if err != nil {
		return core.StandingRule{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return core.StandingRule{}, false, err
	}
	return rule, replaced, nil
}

func validateStandingRule(rule core.StandingRule) error {
	validPair := (rule.Trigger == "terraform_plan" && rule.Action == "review_terraform_plan") ||
		(rule.Trigger == "deployment" && rule.Action == "verify_deployment") ||
		(rule.Trigger == "operational_alert" && rule.Action == "triage_alert")
	if !validPair {
		return fmt.Errorf(
			"standing rule pair %q/%q is invalid", rule.Trigger, rule.Action,
		)
	}
	switch rule.SourceKind {
	case "any", "human", "app":
	default:
		return fmt.Errorf("standing rule source kind %q is invalid", rule.SourceKind)
	}
	for name, value := range map[string]string{
		"channel": rule.ChannelID, "repository": rule.Repository,
		"source reference": rule.SourceRef, "actor": rule.ActorID,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("standing rule %s is required", name)
		}
	}
	if len(rule.ChannelID) > 64 || len(rule.Repository) > 63 ||
		len(rule.SourceRef) > 200 || len(rule.ActorID) > 64 {
		return errors.New("standing rule contains an oversized field")
	}
	return nil
}

func (s *Store) GetStandingRule(ctx context.Context, id string) (core.StandingRule, error) {
	return scanStandingRule(s.db.QueryRowContext(
		ctx, standingRuleSelect+` WHERE id = ?`, id,
	))
}

func (s *Store) ListStandingRulesForChannel(
	ctx context.Context,
	channelID string,
	enabledOnly bool,
	limit int,
) ([]core.StandingRule, error) {
	if channelID == "" || limit < 1 || limit > 100 {
		return nil, errors.New("standing rule list requires a channel and limit between 1 and 100")
	}
	enabled := ""
	if enabledOnly {
		enabled = " AND enabled = 1"
	}
	rows, err := s.db.QueryContext(ctx, standingRuleSelect+`
		WHERE channel_id = ? AND expires_at > ?`+enabled+`
		ORDER BY updated_at DESC
		LIMIT ?`, channelID, s.nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanStandingRules(rows)
}

func (s *Store) ListStandingRulesForHome(
	ctx context.Context,
	limit int,
) ([]core.StandingRule, error) {
	if limit < 1 || limit > 100 {
		return nil, errors.New("home standing rule limit must be between 1 and 100")
	}
	rows, err := s.db.QueryContext(ctx, standingRuleSelect+`
		WHERE expires_at > ?
		ORDER BY updated_at DESC
		LIMIT ?`, s.nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanStandingRules(rows)
}

func (s *Store) SetStandingRuleEnabled(
	ctx context.Context,
	id string,
	enabled bool,
) (core.StandingRule, error) {
	value := 0
	if enabled {
		value = 1
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE standing_rules SET enabled = ?, updated_at = ?
		WHERE id = ? AND expires_at > ?`,
		value, s.nowText(), id, s.nowText(),
	)
	if err := expectOne(result, err, "set standing rule state"); err != nil {
		return core.StandingRule{}, err
	}
	return s.GetStandingRule(ctx, id)
}

func (s *Store) DeleteStandingRule(
	ctx context.Context,
	id string,
) (core.StandingRule, error) {
	rule, err := s.GetStandingRule(ctx, id)
	if err != nil {
		return core.StandingRule{}, err
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM standing_rules WHERE id = ?`, id)
	if err := expectOne(result, err, "delete standing rule"); err != nil {
		return core.StandingRule{}, err
	}
	return rule, nil
}

func (s *Store) RecordStandingRuleRun(
	ctx context.Context,
	ruleID string,
	sourceInput string,
	eventID string,
	outcome string,
) (bool, error) {
	if ruleID == "" || sourceInput == "" || eventID == "" || outcome == "" {
		return false, errors.New("standing rule run fields are required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO standing_rule_runs
		  (rule_id, source_input, event_id, outcome, created_at)
		VALUES (?, ?, ?, ?, ?)`,
		ruleID, sourceInput, eventID, outcome, now,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if rows == 1 {
		result, err = tx.ExecContext(ctx, `
			UPDATE standing_rules
			SET trigger_count = trigger_count + 1,
			    last_triggered_at = ?,
			    updated_at = ?
			WHERE id = ?`,
			now, now, ruleID,
		)
		if err := expectOne(result, err, "record standing rule trigger"); err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return rows == 1, nil
}

func (s *Store) DeleteChannelBehavior(
	ctx context.Context,
	channelID string,
) (int64, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()
	preferences, err := tx.ExecContext(ctx, `
		DELETE FROM responder_preferences
		WHERE scope_kind = 'channel' AND scope_key = ?`, channelID)
	if err != nil {
		return 0, 0, err
	}
	rules, err := tx.ExecContext(ctx, `DELETE FROM standing_rules WHERE channel_id = ?`, channelID)
	if err != nil {
		return 0, 0, err
	}
	preferenceCount, err := preferences.RowsAffected()
	if err != nil {
		return 0, 0, err
	}
	ruleCount, err := rules.RowsAffected()
	if err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return preferenceCount, ruleCount, nil
}

func (s *Store) PruneOrphanBehavior(
	ctx context.Context,
	validRepositories []string,
) (int64, int64, error) {
	if len(validRepositories) == 0 {
		return 0, 0, errors.New("valid repository list is empty")
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(validRepositories)), ",")
	args := make([]any, 0, len(validRepositories))
	for _, repository := range validRepositories {
		args = append(args, repository)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback()
	preferences, err := tx.ExecContext(ctx, `
		DELETE FROM responder_preferences
		WHERE scope_kind = 'repository' AND scope_key NOT IN (`+placeholders+`)`,
		args...,
	)
	if err != nil {
		return 0, 0, err
	}
	rules, err := tx.ExecContext(ctx, `
		DELETE FROM standing_rules WHERE repository NOT IN (`+placeholders+`)`,
		args...,
	)
	if err != nil {
		return 0, 0, err
	}
	preferenceCount, err := preferences.RowsAffected()
	if err != nil {
		return 0, 0, err
	}
	ruleCount, err := rules.RowsAffected()
	if err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, err
	}
	return preferenceCount, ruleCount, nil
}

const preferenceSelect = `
	SELECT id, scope_kind, scope_key, name, value, enabled, source_ref, actor_id,
	  expires_at, created_at, updated_at
	FROM responder_preferences`

func scanPreference(row rowScanner) (core.ResponderPreference, error) {
	var preference core.ResponderPreference
	var enabled int
	var expiresAt, createdAt, updatedAt string
	err := row.Scan(
		&preference.ID, &preference.ScopeKind, &preference.ScopeKey,
		&preference.Name, &preference.Value, &enabled, &preference.SourceRef,
		&preference.ActorID, &expiresAt, &createdAt, &updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ResponderPreference{}, ErrNotFound
	}
	if err != nil {
		return core.ResponderPreference{}, err
	}
	preference.Enabled = enabled == 1
	preference.ExpiresAt = parseTime(expiresAt)
	preference.CreatedAt = parseTime(createdAt)
	preference.UpdatedAt = parseTime(updatedAt)
	return preference, nil
}

func scanPreferences(rows *sql.Rows) ([]core.ResponderPreference, error) {
	var result []core.ResponderPreference
	for rows.Next() {
		preference, err := scanPreference(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, preference)
	}
	return result, rows.Err()
}

const standingRuleSelect = `
	SELECT id, channel_id, repository, trigger_name, action_name, source_kind,
	  enabled, source_ref, actor_id, trigger_count, last_triggered_at,
	  expires_at, created_at, updated_at
	FROM standing_rules`

func scanStandingRule(row rowScanner) (core.StandingRule, error) {
	var rule core.StandingRule
	var enabled int
	var lastTriggered sql.NullString
	var expiresAt, createdAt, updatedAt string
	err := row.Scan(
		&rule.ID, &rule.ChannelID, &rule.Repository, &rule.Trigger, &rule.Action,
		&rule.SourceKind, &enabled, &rule.SourceRef, &rule.ActorID,
		&rule.TriggerCount, &lastTriggered, &expiresAt, &createdAt, &updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.StandingRule{}, ErrNotFound
	}
	if err != nil {
		return core.StandingRule{}, err
	}
	rule.Enabled = enabled == 1
	if lastTriggered.Valid {
		rule.LastTriggered = parseTime(lastTriggered.String)
	}
	rule.ExpiresAt = parseTime(expiresAt)
	rule.CreatedAt = parseTime(createdAt)
	rule.UpdatedAt = parseTime(updatedAt)
	return rule, nil
}

func scanStandingRules(rows *sql.Rows) ([]core.StandingRule, error) {
	var result []core.StandingRule
	for rows.Next() {
		rule, err := scanStandingRule(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, rule)
	}
	return result, rows.Err()
}
