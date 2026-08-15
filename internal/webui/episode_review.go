package webui

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// ReviewRow is what the daily self-improvement pass recorded about this
// episode's ending, and whether the ending it recorded is still the one on the
// page.
//
// Present and Awaiting are both answers, and they are both true at once for an
// episode whose ending moved after somebody read it — a blocked trace that
// revived and completed carries a real review of a trace that no longer exists.
// Collapsing them into one boolean would make that case read either as "judged"
// (and the new ending never gets read) or as "never judged" (and the reader is
// not told a previous pass looked and what it thought).
type ReviewRow struct {
	Reviewer string
	Note     string
	At       time.Time
	// Present is a recorded review, whatever ending it describes.
	Present bool
	// Awaiting is a finished episode whose CURRENT ending nobody has judged.
	// False for work still running, which has no ending to judge yet.
	Awaiting bool
}

// EpisodeReview reads one episode's row out of the review ledger.
//
// It answers for every episode rather than only the reviewed ones, because the
// page has to be able to say "nobody has read this" in words. This page's rule
// is that absence reads as a state: a terminal episode rendering no review
// panel at all is indistinguishable from a reviewed one whose panel failed, and
// a reader draws the same conclusion from both.
func (r *Reader) EpisodeReview(ctx context.Context, episodeID string) (ReviewRow, error) {
	if !r.live() {
		return ReviewRow{}, nil
	}
	var row ReviewRow
	var reviewedAt string
	var present, awaiting int
	err := r.db.QueryRowContext(ctx, `
	  SELECT COALESCE(rev.reviewer, ''), COALESCE(rev.note, ''),
	         COALESCE(rev.reviewed_at, ''), rev.episode_id IS NOT NULL,
	         (`+awaitingReview+`)
	  FROM work_episodes AS e
	  LEFT JOIN episode_reviews AS rev ON rev.episode_id = e.id
	  WHERE e.id = ?`, episodeID).Scan(
		&row.Reviewer, &row.Note, &reviewedAt, &present, &awaiting)
	if errors.Is(err, sql.ErrNoRows) {
		return ReviewRow{}, nil
	}
	if err != nil {
		return ReviewRow{}, err
	}
	row.At = parseStamp(reviewedAt)
	row.Present, row.Awaiting = present != 0, awaiting != 0
	return row, nil
}
