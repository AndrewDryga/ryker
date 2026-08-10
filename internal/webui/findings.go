package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"html/template"
	"net/http"
	"strconv"
	"time"
)

// Finding is one defect the quality watcher found in a completed turn, after a
// second reviewer tried to disprove it.
//
// The watcher (scripts/quality-watch.sh) reviews every terminal work episode
// out-of-process and used to keep nothing. A confirmed defect's only durable
// trace was a quarantined Git worktree nobody opens and a line in a log, so a
// week of real analysis of real production turns reached no person. This is the
// page that receives it.
//
// Rejections are shown, not filtered out. The adversarial reviewer overturned
// 23 of 83 proposed defects in the first week; a reader who only sees survivors
// cannot tell whether the skeptic is working, and that is the number that says
// so.
type Finding struct {
	ID          string
	RunID       string
	EpisodeIDs  []string
	Channel     string
	Verdict     string
	Disposition string
	Severity    string
	Summary     string
	Expected    string
	Evidence    []string
	Code        []string
	Components  []string
	Regression  string
	Challenger  string
	Challenged  []string
	Artifacts   string
	Created     time.Time
}

// Confirmed reports whether the adversarial reviewer agreed this is a defect.
func (f Finding) Confirmed() bool { return f.Verdict == "confirmed" }

// Acted reports whether anything beyond recording it was attempted, which is
// only ever true when an operator turned the opt-in fixer on.
func (f Finding) Acted() bool { return f.Disposition != "" && f.Disposition != "recorded" }

const findingsPageSize = 50

const (
	countFindings          = `SELECT COUNT(*) FROM quality_findings`
	countConfirmedFindings = `SELECT COUNT(*) FROM quality_findings WHERE verdict = 'confirmed'`
)

const findingSelect = `
  SELECT id, run_id, episode_ids, channel_id, verdict, disposition, severity,
         summary, expected_behavior, evidence, code_evidence,
         suspected_components, regression_test, challenger_summary,
         challenger_evidence, artifacts, created_at
  FROM quality_findings`

// Findings lists the newest findings first, one page at a time.
func (r *Reader) Findings(ctx context.Context, offset int) ([]Finding, error) {
	return collect(ctx, r, findingSelect+`
	  ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?`,
		scanFinding, findingsPageSize, offset)
}

func scanFinding(rows *sql.Rows) (Finding, error) {
	var (
		item                                            Finding
		episodes, evidence, code, parts, against, stamp string
	)
	if err := rows.Scan(
		&item.ID, &item.RunID, &episodes, &item.Channel, &item.Verdict,
		&item.Disposition, &item.Severity, &item.Summary, &item.Expected,
		&evidence, &code, &parts, &item.Regression, &item.Challenger,
		&against, &item.Artifacts, &stamp,
	); err != nil {
		return Finding{}, err
	}
	item.EpisodeIDs = jsonStrings(episodes)
	item.Evidence = jsonStrings(evidence)
	item.Code = jsonStrings(code)
	item.Components = jsonStrings(parts)
	item.Challenged = jsonStrings(against)
	item.Created = parseStamp(stamp)
	return item, nil
}

// jsonStrings decodes a stored JSON array of strings.
//
// A value it cannot parse is shown verbatim rather than dropped. These columns
// are written by a shell script calling sqlite3, so the failure mode worth
// designing for is a malformed array, and rendering an empty list for one would
// claim the model gave no evidence when it gave evidence nobody can read.
func jsonStrings(raw string) []string {
	var items []string
	if err := json.Unmarshal([]byte(raw), &items); err != nil {
		if raw == "" {
			return nil
		}
		return []string{raw}
	}
	return items
}

// findingsURL rebuilds the list URL for a different page.
func findingsURL(offset int) template.URL {
	if offset <= 0 {
		return template.URL("/findings")
	}
	return template.URL("/findings?offset=" + strconv.Itoa(offset))
}

func (h *Handler) findings(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var failed problems
	offset := pageOffset(r.URL.Query().Get("offset"))
	items, err := h.reader.Findings(ctx, offset)
	failed.note("findings", err)
	total := h.reader.Count(ctx, countFindings)
	confirmed := h.reader.Count(ctx, countConfirmedFindings)

	var newer, older template.URL
	if offset > 0 {
		newer = findingsURL(max(offset-findingsPageSize, 0))
	}
	if offset+len(items) < total {
		older = findingsURL(offset + findingsPageSize)
	}
	h.page(w, r, "findings", "findings", struct {
		Findings         []Finding
		Total, Confirmed int
		Rejected         int
		First, Last      int
		Newer, Older     template.URL
		Errs             problems
	}{
		items, total, confirmed, total - confirmed,
		offset + 1, offset + len(items), newer, older, failed,
	})
}
