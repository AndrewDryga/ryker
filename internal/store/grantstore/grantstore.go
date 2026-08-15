// Package grantstore persists the remediation trust ladder and recomputes the
// evidence a promotion rests on.
//
// It is a repository rather than methods on Store for the reason the other
// extractions here exist — a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
//
// It decides nothing. Which grant applies, whether an offer is earned, and what
// a demotion does are pure functions in internal/remediation, and this package
// reads rows in and writes rows out. That split is deliberate for an authority
// record: the interesting questions are then answerable by a table test with no
// database at all, and the only thing left here is whether the SQL says what the
// Go says.
package grantstore

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/remediation"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// ErrNotFound is no grant on file for that identity.
var ErrNotFound = errors.New("remediation grant not found")

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

const grantColumns = `
  id, alert_group_key, channel_id, repository, action_id, pack_ref, runner_ref,
  rung, granted_by, granted_at, expires_at, success_count, last_verified_at,
  demoted_reason, demoted_at`

func scanGrant(rows interface{ Scan(...any) error }) (remediation.Grant, error) {
	var grant remediation.Grant
	var rung, grantedAt, expiresAt string
	var lastVerified, demotedAt sql.NullString
	if err := rows.Scan(
		&grant.ID, &grant.Trigger.AlertGroupKey, &grant.Trigger.ChannelID,
		&grant.Trigger.Repository, &grant.Action.ActionID, &grant.Action.PackRef,
		&grant.Action.RunnerRef, &rung, &grant.GrantedBy, &grantedAt, &expiresAt,
		&grant.SuccessCount, &lastVerified, &grant.DemotedReason, &demotedAt,
	); err != nil {
		return remediation.Grant{}, err
	}
	grant.Rung = remediation.Rung(rung)
	grant.GrantedAt = sqlutil.ParseTime(grantedAt)
	grant.ExpiresAt = sqlutil.ParseTime(expiresAt)
	grant.LastVerifiedAt = sqlutil.ScanTime(lastVerified)
	grant.DemotedAt = sqlutil.ScanTime(demotedAt)
	return grant, nil
}

// Matching returns every grant recorded for one trigger class, expired ones
// included.
//
// Expired rows are returned on purpose. remediation.Decide is the single place
// that decides what a lapsed grant means, and filtering here would put half of
// that decision in SQL where no table test can see it — and would also lose the
// difference between "no grant covers this" and "the grant for this expired",
// which is the more useful thing to tell an operator.
func (r *Repository) Matching(
	ctx context.Context,
	class remediation.TriggerClass,
) ([]remediation.Grant, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT`+grantColumns+`
		FROM remediation_grants
		WHERE alert_group_key = ? AND channel_id = ?
		ORDER BY granted_at DESC`,
		class.AlertGroupKey, class.ChannelID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var grants []remediation.Grant
	for rows.Next() {
		grant, err := scanGrant(rows)
		if err != nil {
			return nil, err
		}
		grants = append(grants, grant)
	}
	return grants, rows.Err()
}

// Get returns the grant for one exact trigger class and action ref.
func (r *Repository) Get(
	ctx context.Context,
	class remediation.TriggerClass,
	action remediation.ActionRef,
) (remediation.Grant, error) {
	grant, err := scanGrant(r.db.QueryRowContext(ctx, `
		SELECT`+grantColumns+`
		FROM remediation_grants
		WHERE alert_group_key = ? AND channel_id = ? AND repository = ?
		  AND action_id = ? AND pack_ref = ? AND runner_ref = ?`,
		class.AlertGroupKey, class.ChannelID, class.Repository,
		action.ActionID, action.PackRef, action.RunnerRef,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return remediation.Grant{}, ErrNotFound
	}
	return grant, err
}

// Confirm records an operator-confirmed grant, replacing whatever rung the same
// identity held before.
//
// It refuses anything Grant.Validate refuses, which is what makes "no permanent
// grants" and "every grant names its operator" structural rather than a rule
// each caller has to remember. The upsert keys on the full six-column identity,
// so a retried click lands on the row that is already there instead of minting
// a second grant for the same authority.
func (r *Repository) Confirm(
	ctx context.Context,
	grant remediation.Grant,
) (remediation.Grant, error) {
	if err := grant.Validate(); err != nil {
		return remediation.Grant{}, err
	}
	now := r.clock().UTC()
	if grant.ID == "" {
		id, err := core.NewID("grant")
		if err != nil {
			return remediation.Grant{}, err
		}
		grant.ID = id
	}
	if grant.GrantedAt.IsZero() {
		grant.GrantedAt = now
	}
	if _, err := r.db.ExecContext(ctx, `
		INSERT INTO remediation_grants (
		  id, alert_group_key, channel_id, repository, action_id, pack_ref,
		  runner_ref, rung, granted_by, granted_at, expires_at, success_count,
		  created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(alert_group_key, channel_id, repository, action_id, pack_ref, runner_ref)
		DO UPDATE SET
		  rung = excluded.rung, granted_by = excluded.granted_by,
		  granted_at = excluded.granted_at, expires_at = excluded.expires_at,
		  success_count = excluded.success_count,
		  -- A confirmed promotion clears the previous demotion note. Leaving it
		  -- would make the card say a live grant was demoted.
		  demoted_reason = '', demoted_at = NULL,
		  updated_at = excluded.updated_at`,
		grant.ID, grant.Trigger.AlertGroupKey, grant.Trigger.ChannelID,
		grant.Trigger.Repository, grant.Action.ActionID, grant.Action.PackRef,
		grant.Action.RunnerRef, string(grant.Rung), grant.GrantedBy,
		sqlutil.TimeText(grant.GrantedAt), sqlutil.TimeText(grant.ExpiresAt),
		grant.SuccessCount, sqlutil.TimeText(now), sqlutil.TimeText(now),
	); err != nil {
		return remediation.Grant{}, err
	}
	return r.Get(ctx, grant.Trigger, grant.Action)
}

// Demote drops every grant for one action ref a rung and records why.
//
// It takes the action ref rather than a grant id because the callers are
// automatic: a supervised run reaching a terminal state knows which action it
// was, not which grant somebody confirmed for it. Every trigger class that
// granted this exact action loses the rung, which is the conservative reading —
// the action just failed, and nothing about that failure is specific to the
// alert that happened to fire.
func (r *Repository) Demote(
	ctx context.Context,
	action remediation.ActionRef,
	reason remediation.DemotionReason,
) ([]remediation.Grant, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT`+grantColumns+`
		FROM remediation_grants
		WHERE action_id = ? AND pack_ref = ? AND runner_ref = ? AND rung != 'observe'`,
		action.ActionID, action.PackRef, action.RunnerRef,
	)
	if err != nil {
		return nil, err
	}
	var live []remediation.Grant
	for rows.Next() {
		grant, err := scanGrant(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		live = append(live, grant)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	now := r.clock().UTC()
	demoted := make([]remediation.Grant, 0, len(live))
	for _, grant := range live {
		next := remediation.Demote(grant, reason, now)
		if _, err := r.db.ExecContext(ctx, `
			UPDATE remediation_grants
			SET rung = ?, success_count = 0, demoted_reason = ?, demoted_at = ?, updated_at = ?
			WHERE id = ?`,
			string(next.Rung), next.DemotedReason, sqlutil.TimeText(next.DemotedAt),
			sqlutil.TimeText(now), next.ID,
		); err != nil {
			return nil, err
		}
		demoted = append(demoted, next)
	}
	return demoted, nil
}

// RecordVerification stamps when a grant was last confirmed to have worked.
func (r *Repository) RecordVerification(ctx context.Context, id string, when time.Time) error {
	now := r.clock().UTC()
	result, err := r.db.ExecContext(ctx, `
		UPDATE remediation_grants SET last_verified_at = ?, updated_at = ? WHERE id = ?`,
		sqlutil.TimeText(when.UTC()), sqlutil.TimeText(now), id,
	)
	return sqlutil.ExpectOne(result, err, "record remediation grant verification")
}

// VerifiedSuccesses is the host's own count of how often this exact action, for
// this exact trigger class, was run through Emisar and then verified.
//
// This is the number a promotion is graded on, and the reason a model's claimed
// count is only ever checked against it. Every clause is doing work:
//
//   - the three action columns are the immutable Emisar identity, so a pack
//     upgrade or a different runner starts the count again from zero;
//   - a.status = 'success' means Emisar itself reported the run finished, which
//     is the only authority on that question;
//   - the join through agent_runs.source_kind is the durable link the approval
//     continuation already writes ("emisar_approval:<request id>"), so this
//     counts the episode that went and CHECKED the action's effect rather than
//     the episode that asked for it;
//   - o.verified = 1 is episode_outcomes' own field — a closing assessment that
//     named how the fix was checked, on an episode that then completed. This
//     package does not redefine it;
//   - the outcome's channel, alert group and repository are the trigger class,
//     so successes earned on one alert never fund a grant for another.
//
// The repository clause is an exact match INCLUDING empty, and it is the one
// clause here that was originally written the other way — as "no repository
// means any repository". That reads like a convenience and is a privilege
// escalation: remediation.TriggerClass compares repository exactly, so a
// confirmation payload that simply omitted it described a WIDER grant than the
// card offered and was then funded by every repository's successes at once. A
// counter must never be more permissive than the matcher it feeds.
//
// COUNT(DISTINCT episode_id) rather than COUNT(*): one episode that verified the
// same action twice is one piece of evidence, and a retried continuation must
// not be able to buy a rung.
func (r *Repository) VerifiedSuccesses(
	ctx context.Context,
	class remediation.TriggerClass,
	action remediation.ActionRef,
) (int, error) {
	if !class.Complete() || !action.Complete() {
		return 0, nil
	}
	var count int
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(DISTINCT o.episode_id)
		FROM emisar_approvals a
		JOIN agent_runs r ON r.source_kind = 'emisar_approval:' || a.request_id
		JOIN episode_outcomes o ON o.episode_id = r.episode_id
		WHERE a.action_id = ? AND a.pack_ref = ? AND a.runner_ref = ?
		  AND a.status = 'success'
		  AND o.verified = 1
		  AND o.channel_id = ?
		  AND o.alert_group_key = ?
		  AND o.repository = ?`,
		action.ActionID, action.PackRef, action.RunnerRef,
		class.ChannelID, class.AlertGroupKey, class.Repository,
	).Scan(&count)
	return count, err
}
