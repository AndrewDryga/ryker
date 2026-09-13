package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Workspace is one Coop session: a checkout on disk with a turn budget, held
// for some piece of Ryker's work.
type Workspace struct {
	ID, Kind, Detail   string
	Policy, Repository string
	State, Activity    string
	Turns, MaxTurns    int
	Queued             int
	Fork, BaseCommit   string
	Href, HrefLabel    string
	PRNumber           int
	Created, Updated   time.Time
	Companions         int
	// Bytes is what this checkout holds on disk, filled in by the handler.
	Bytes int64
}

// TurnPct is how much of the session's turn budget is spent, for the meter.
func (w Workspace) TurnPct() int { return percent(w.Turns, w.MaxTurns) }

// Size renders this checkout for a reader rather than a machine.
func (w Workspace) Size() string { return HumanBytes(w.Bytes) }

// LiveWorkspaces lists the sessions Coop is currently holding.
//
// Only open ones: a discarded session is a directory that no longer exists,
// and 491 of them on the deployed instance would bury the sixteen that are
// real. What became of them is the reclaimed count the page already reports.
func (r *Reader) LiveWorkspaces(ctx context.Context) ([]Workspace, bool, error) {
	// The second return says "Coop state is not attached", which the page uses
	// to explain itself rather than showing an empty list that would read as
	// "Coop is holding nothing".
	if r == nil || r.coop == nil {
		return nil, false, nil
	}
	// Queried through r.coop, not the collect helper: that helper is bound to
	// the Ryker database and would run this against the wrong file.
	rows, err := r.coop.QueryContext(ctx, `
	  SELECT id, COALESCE(external_ref,''), COALESCE(policy,''), COALESCE(repository,''),
	         COALESCE(state,''), COALESCE(activity,''), COALESCE(turns_used,0),
	         COALESCE(max_turns,0), COALESCE(queued_turn_count,0), COALESCE(fork_name,''),
	         COALESCE(base_commit,''), COALESCE(pull_request_number,0),
	         COALESCE(companions,''), created_at, updated_at
	  FROM sessions WHERE state = 'open' ORDER BY updated_at DESC LIMIT 200`)
	if err != nil {
		return nil, true, err
	}
	defer rows.Close()
	items := []Workspace{}
	for rows.Next() {
		var item Workspace
		var reference, companions string
		var created, updated any
		if err := rows.Scan(&item.ID, &reference, &item.Policy, &item.Repository,
			&item.State, &item.Activity, &item.Turns, &item.MaxTurns, &item.Queued,
			&item.Fork, &item.BaseCommit, &item.PRNumber, &companions,
			&created, &updated); err != nil {
			return nil, true, err
		}
		item.Created, item.Updated = coopStamp(created), coopStamp(updated)
		// The repository is stored as its checkout path, which on a single-host
		// deployment is the same forty characters on every row and says only
		// where this machine keeps its code. The name is the part that differs.
		item.Repository = filepath.Base(item.Repository)
		item.Companions = companionCount(companions)
		var channel string
		item.Kind, item.Detail, item.Href, item.HrefLabel, channel = describeWorkspace(reference)
		// An engineering task's reference carries only the incident id, so three
		// of them render as three rows reading "Engineering task" and nothing
		// else. The title is what tells them apart, and it lives in Ryker's
		// own tables rather than in Coop's.
		if item.Kind == "Engineering task" {
			if title, found := strings.CutPrefix(item.Href, "/incidents/"); found {
				item.Detail = cleanTitle(r.incidentTitle(ctx, title))
			}
		}
		// Resolved here rather than in the helper, which stays pure so the
		// classification can be tested without a database behind it.
		if name := r.channelName(ctx, channel); name != "" {
			if item.Detail == "" {
				item.Detail = name
			} else {
				item.Detail = name + " · " + item.Detail
			}
		}
		items = append(items, item)
	}
	return items, true, rows.Err()
}

// coopStamp reads one of Coop's timestamps. Coop stores them as Unix
// nanoseconds rather than the RFC 3339 text Ryker writes, so parseStamp
// cannot be reused; text is still accepted so an older store still renders.
func coopStamp(value any) time.Time {
	switch stamp := value.(type) {
	case int64:
		if stamp == 0 {
			return time.Time{}
		}
		return time.Unix(0, stamp).UTC()
	case string:
		return parseStamp(stamp)
	case []byte:
		return parseStamp(string(stamp))
	}
	return time.Time{}
}

// companionCount counts the extra repositories checked out beside the primary
// one. The column is a JSON array, and anything else counts as none rather
// than failing the page.
func companionCount(raw string) int {
	var companions []json.RawMessage
	if err := json.Unmarshal([]byte(raw), &companions); err != nil {
		return 0
	}
	return len(companions)
}

// describeWorkspace names what a session is holding, from the reference
// Ryker wrote when it created it. Parsing that string beats joining
// Ryker's tables: the reference is written at creation and survives
// whatever happens to the work afterwards, and an evaluation session has no
// row in those tables at all.
//
// The channel id comes back so the caller can trade it for a name; resolving
// it here would put the Reader inside the classification.
func describeWorkspace(externalRef string) (kind, detail, href, hrefLabel, channel string) {
	if id, ok := strings.CutPrefix(externalRef, "engineering-task:"); ok {
		return "Engineering task", "", "/incidents/" + id, "the task →", ""
	}
	if rest, ok := strings.CutPrefix(externalRef, "Slack bounded conversation "); ok {
		token, generation := splitGeneration(rest)
		return "Conversation", generation, "/episodes?channel=" + token, "its episodes →", token
	}
	if rest, ok := strings.CutPrefix(externalRef, "Slack operations channel "); ok {
		token, generation := splitGeneration(rest)
		// A scheduled run borrows the operations-channel shape but names a run
		// instead of a channel, and one run has no page of its own — so the row
		// says what it is and links nowhere rather than somewhere wrong.
		if strings.HasPrefix(token, "scheduled:") {
			return "Scheduled run", generation, "", "", ""
		}
		return "Channel watch", generation, "/episodes?channel=" + token, "its episodes →", token
	}
	if name, ok := strings.CutPrefix(externalRef, "Ryker live model evaluation: "); ok {
		return "Model evaluation", truncate(name, 80), "", "", ""
	}
	return "Other", truncate(externalRef, 80), "", "", ""
}

// splitGeneration reads the "<token> generation <N>" tail both Slack session
// references carry.
func splitGeneration(rest string) (token, generation string) {
	fields := strings.Fields(rest)
	if len(fields) == 0 {
		return "", ""
	}
	if len(fields) >= 3 && fields[1] == "generation" {
		return fields[0], "generation " + fields[2]
	}
	return fields[0], ""
}

// RetainedWorkspace is one Coop session whose fork is still on disk.
//
// Thirty of these sat in coop_cleanup on a production database with no surface
// at all: the App Home shows the count, the count cannot be opened, and the
// only way to learn why a workspace was held — dirty tree, unpublished
// commits, a Coop conflict — was sqlite. The blocked ones are the operator's
// queue: the janitor has already refused them for a stated reason and will
// never look again without a person acting.
type RetainedWorkspace struct {
	SessionID, IncidentID, Reason, State string
	// Refusal is the janitor's own last error, verbatim. It is the answer to
	// "what is held and why", so it is never summarized into a category.
	Refusal                                 string
	IncidentTitle, IncidentStatus, WorkKind string
	Channel                                 string
	Attempts                                int
	AllowUnmerged                           bool
	Created, Eligible, NextAttempt          time.Time
}

// CanDiscard mirrors the gate on the Slack "Discard retained work" button:
// only a closed engineering task, so no agent turn can race the deletion.
// Offering it wider here would make this page the one door without the rule.
func (w RetainedWorkspace) CanDiscard() bool {
	return w.IncidentStatus == "closed" && w.WorkKind == "engineering_task"
}

// CanReclaim offers the record-less discard: a fork with no work record behind
// it, which the incident-shaped controls cannot reach at all. Dirty trees are
// excluded here as everywhere — the service refuses them too, and a page must
// not offer what the service will refuse.
func (w RetainedWorkspace) CanReclaim() bool {
	return w.IncidentID == "" &&
		!strings.HasPrefix(w.Refusal, "workspace has uncommitted changes")
}

// CanPublish mirrors the Slack admission gate, which refuses publish once the
// work is closed. In practice a cleanup row usually exists because the work
// closed, so this is rare here — but a page must not offer what the service
// will refuse.
func (w RetainedWorkspace) CanPublish() bool {
	return w.IncidentID != "" && w.WorkKind == "engineering_task" &&
		w.IncidentStatus != "closed"
}

// CanRerun offers another pass through the janitor's own checks — the same
// SetCleanupState path the service uses — but only where a second pass could
// end differently. A dirty tree and unpublished commits are policy refusals
// the janitor re-makes deterministically, and a retry that always re-blocks
// is a live-looking control that does nothing.
func (w RetainedWorkspace) CanRerun() bool {
	return w.State == "blocked" &&
		!strings.HasPrefix(w.Refusal, "workspace has uncommitted changes") &&
		!strings.HasPrefix(w.Refusal, "workspace has unpublished committed changes")
}

// Explain says why a held row offers no action, in that row's own terms.
// Empty when an action is offered. A row with neither a button nor a reason
// reads as a rendering fault, and a button that the service would refuse is
// worse.
func (w RetainedWorkspace) Explain() string {
	if w.CanPublish() || w.CanDiscard() || w.CanRerun() || w.CanReclaim() {
		return ""
	}
	if strings.HasPrefix(w.Refusal, "workspace has uncommitted changes") {
		return "Nothing may delete uncommitted work — not the janitor, not Slack, not this page. " +
			"Inspect the fork directly and decide what to preserve; cleanup takes it once the tree is clean."
	}

	return "No Slack-equivalent action applies in this state; the refusal above says what the janitor needs."
}

// RetainedWorkspaces splits the cleanup ledger into the rows waiting on a
// person and the rows the janitor still owns. Done rows are excluded — they
// are reclaimed disk, not a workspace — and counted separately by the page.
func (r *Reader) RetainedWorkspaces(ctx context.Context) (held, queued []RetainedWorkspace, err error) {
	rows, err := collect(ctx, r, `
	  SELECT c.session_id, COALESCE(c.incident_id,''), c.reason, c.state,
	         COALESCE(NULLIF(c.last_error,''),''), c.attempts, c.allow_unmerged,
	         c.created_at, c.eligible_at, c.next_attempt_at,
	         COALESCE(i.title,''), COALESCE(i.status,''), COALESCE(i.work_kind,''),
	         COALESCE((SELECT channel_id FROM channel_memories
	                   WHERE session_id = c.session_id LIMIT 1),
	                  (SELECT channel_id FROM conversation_sessions
	                   WHERE session_id = c.session_id LIMIT 1), '')
	  FROM coop_cleanup AS c
	  LEFT JOIN incidents AS i ON i.id = c.incident_id
	  WHERE c.state != 'done'
	  ORDER BY c.updated_at DESC LIMIT 200`,
		func(rows *sql.Rows) (RetainedWorkspace, error) {
			var item RetainedWorkspace
			var allow int
			var created, eligible, next, channel string
			err := rows.Scan(&item.SessionID, &item.IncidentID, &item.Reason, &item.State,
				&item.Refusal, &item.Attempts, &allow, &created, &eligible, &next,
				&item.IncidentTitle, &item.IncidentStatus, &item.WorkKind, &channel)
			item.AllowUnmerged = allow != 0
			item.Created = parseStamp(created)
			item.Eligible = parseStamp(eligible)
			item.NextAttempt = parseStamp(next)
			item.Channel = r.channelName(ctx, channel)
			// Only rows with a work record get the title treatment: cleanTitle
			// turns an empty string into "Untitled work", which for a session
			// with no incident would invent a work record that does not exist.
			if item.IncidentID != "" {
				item.IncidentTitle = cleanTitle(item.IncidentTitle)
			}
			return item, err
		})
	if err != nil {
		return nil, nil, err
	}
	for _, row := range rows {
		if row.State == "blocked" {
			held = append(held, row)
		} else {
			queued = append(queued, row)
		}
	}
	return held, queued, nil
}

// incidentTitle names one work record, for a page that holds its id and needs
// to say which one it is.
func (r *Reader) incidentTitle(ctx context.Context, incidentID string) string {
	if !r.live() || incidentID == "" {
		return ""
	}
	var title string
	if err := r.lookup.QueryRowContext(ctx,
		`SELECT COALESCE(title,'') FROM incidents WHERE id = ?`, incidentID,
	).Scan(&title); err != nil {
		return ""
	}
	return title
}

// WorkspaceDisk is what the checkouts actually cost, which is the question
// this page exists to answer and the one thing it never showed.
//
// A session's identity told the operator nothing: on the deployed instance
// sixteen of seventeen rows read "parked · blitz-infra · 11 companion repos"
// and differed only in a label. Meanwhile the directory those rows stand for
// held twenty-three gigabytes, and a checkout whose session had already closed
// was still holding one and a fifth of them with nothing on the page to say so.
type WorkspaceDisk struct {
	// Total is every byte under Coop's repositories directory, including the
	// orphans, because that is what the filesystem is actually giving up.
	Total int64
	// Sizes is per session id. A session absent from it holds no checkout yet:
	// Coop materializes one on first use, so an open session and a directory
	// on disk are different facts and the page must not merge them.
	Sizes map[string]int64
	// Orphans are directories whose session has ended or was never recorded.
	// Nothing will read them again.
	Orphans []WorkspaceOrphan
	// Measured is when the walk ran, and Available says whether one could.
	Measured  time.Time
	Available bool
}

// WorkspaceOrphan is a checkout on disk that no live session owns.
type WorkspaceOrphan struct {
	SessionID string
	State     string
	Bytes     int64
}

// Disk measures what the workspaces cost, cached because the walk is not free.
//
// Fifteen session directories are thirteen thousand files each and a little
// over a second to stat warm. That is affordable once and wasteful on every
// render, so the answer is held for a minute — long enough that opening the
// page twice does not pay twice, short enough that a reclaim shows up while
// the operator is still looking at the consequence of it.
func (r *Reader) Disk(ctx context.Context, root string, live []Workspace) WorkspaceDisk {
	if r == nil || root == "" {
		return WorkspaceDisk{}
	}
	r.diskOnce.Lock()
	defer r.diskOnce.Unlock()
	// Keyed on the root as well as the clock. There is one root in production,
	// so a time-only cache looked correct and was not: asked about a different
	// directory inside the minute it answered about the previous one.
	if r.diskRoot == root && r.disk.Available && time.Since(r.disk.Measured) < time.Minute {
		return r.diskFor(live)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		r.diskRoot, r.disk = root, WorkspaceDisk{}
		return WorkspaceDisk{}
	}
	measured := WorkspaceDisk{
		Sizes: map[string]int64{}, Measured: time.Now(), Available: true,
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		size := directoryBytes(ctx, filepath.Join(root, entry.Name()))
		measured.Sizes[entry.Name()] = size
		measured.Total += size
	}
	r.diskRoot, r.disk = root, measured
	return r.diskFor(live)
}

// diskFor names the orphans by comparing what is on disk against what is live.
func (r *Reader) diskFor(live []Workspace) WorkspaceDisk {
	result := r.disk
	result.Orphans = nil
	held := make(map[string]struct{}, len(live))
	for _, workspace := range live {
		held[workspace.ID] = struct{}{}
	}
	for id, size := range result.Sizes {
		if _, alive := held[id]; alive {
			continue
		}
		result.Orphans = append(result.Orphans, WorkspaceOrphan{SessionID: id, Bytes: size})
	}
	sort.SliceStable(result.Orphans, func(i, j int) bool {
		return result.Orphans[i].Bytes > result.Orphans[j].Bytes
	})
	return result
}

// directoryBytes sums a tree, counting what the files hold rather than what
// they claim: a walk that fails partway returns what it managed, because an
// approximate size is a better answer than none for a number whose job is to
// say "this is large".
func directoryBytes(ctx context.Context, path string) int64 {
	var total int64
	_ = filepath.WalkDir(path, func(_ string, entry os.DirEntry, err error) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil || entry.IsDir() {
			return nil //nolint:nilerr // an unreadable subtree is skipped, not fatal
		}
		if info, statErr := entry.Info(); statErr == nil {
			total += info.Size()
		}
		return nil
	})
	return total
}

// HumanBytes renders a size the way an operator reads one.
func HumanBytes(bytes int64) string {
	switch {
	case bytes >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(bytes)/(1<<30))
	case bytes >= 1<<20:
		return fmt.Sprintf("%d MB", bytes/(1<<20))
	case bytes > 0:
		return fmt.Sprintf("%d KB", max(bytes/(1<<10), 1))
	default:
		// Not "—". A checkout of zero bytes and a checkout nobody measured are
		// different facts, and the page has to be able to print both.
		return "0 B"
	}
}

// Headline is what the page leads with: the total, or the plain statement that
// there is nothing rather than a zero the reader has to interpret.
func (d WorkspaceDisk) Headline() string {
	if d.Total == 0 {
		return "Nothing on disk"
	}
	return HumanBytes(d.Total) + " on disk"
}
