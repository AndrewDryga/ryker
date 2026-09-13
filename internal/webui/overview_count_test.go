package webui

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store"
)

// The overview hero counts the queue while the section under it printed the
// rows the page chose to render — nine waiting in the headline, "Waiting on
// you 8" two hundred pixels below it, because the list is capped at eight.
// Two numbers for one fact on the first screen, and the cheaper one wins the
// reader's trust. The section note must state the queue, not the page.
func TestWaitingSectionCountsTheQueueNotThePage(t *testing.T) {
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	writable, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	stamp := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC).Format(core.TimestampFormat)
	for n := range 9 {
		id := fmt.Sprintf("w%d", n)
		if _, err := writable.ExecContext(context.Background(), `INSERT INTO agent_runs
		  (id, mode, conversation_key, source_kind, source_id, idempotency_key, state,
		   next_attempt_at, created_at, updated_at, channel_id, repository, episode_id, attempt_id)
		  VALUES (?,?,?,?,?,?,'running',?,?,?,'C1','blitz-platform',?,?)`,
			"run_"+id, "triage", "conv_"+id, "slack", "src_"+id, "idem_"+id,
			stamp, stamp, stamp, "ep_"+id, id); err != nil {
			t.Fatal(err)
		}
		if _, err := writable.ExecContext(context.Background(), `INSERT INTO work_episodes
		  (id, agent_run_id, effort, authority, lifecycle_state, objective, created_at, updated_at)
		  VALUES (?,?,'focused_check','read_only','blocked',?,?,?)`,
			"ep_"+id, "run_"+id, "waiting work "+id, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		// Distinct titles, or foldBlocked reads nine untitled rows as one
		// event repeated and the section legitimately counts a single row.
		if _, err := writable.ExecContext(context.Background(), `INSERT INTO commitments
		  (episode_id, title) VALUES (?,?)`, "ep_"+id, "waiting work "+id); err != nil {
			t.Fatal(err)
		}
	}
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })

	body := servePage(t, reader, "/")
	if !strings.Contains(body, "Waiting on you<strong>9</strong>") {
		t.Fatalf("stat band does not state the queue of nine:\n%s", excerpt(body, "Waiting on you"))
	}
	if !strings.Contains(body, `Waiting on you <span class="note">9</span>`) {
		t.Errorf("section note does not state the queue of nine: %s", excerpt(body, "Waiting on you"))
	}
}

// excerpt keeps the failure message readable: the line that mentions the
// marker, not the whole rendered page.
func excerpt(body, marker string) string {
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, marker) {
			return strings.TrimSpace(line)
		}
	}
	return "(marker absent)"
}
