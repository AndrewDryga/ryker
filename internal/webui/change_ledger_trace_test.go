package webui

import (
	"context"
	"strings"
	"testing"
	"time"
)

// The manifest stores "change:<id>" and nothing else, so every word the page
// says about a recorded change has to come back out of the ledger.
//
// This row is the only place the trace explains why a prompt spent budget on a
// deploy, and it is the row an operator opens when a verdict blamed one. Three
// states have to read as something: the ledger has the row, the ledger has a
// row whose sender sent no summary, and retention has already pruned the change
// while the manifest reference citing it is kept.
func TestARecordedChangeIsNamedByWhatChangedNotItsID(t *testing.T) {
	reader := recordedChangeFixture(t)
	defer reader.Close()

	manifests, err := reader.Manifests(context.Background(), "episode-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) != 1 {
		t.Fatalf("manifests = %+v, want the one seeded attempt", manifests)
	}
	named := map[string]string{}
	for _, ref := range manifests[0].Refs {
		if ref.Kind == recentChangeRefKind {
			named[strings.TrimPrefix(ref.FullDigest, "digest-")] = ref.What
		}
	}
	for id, want := range map[string]string{
		"chg_deploy": "deploy: checkout v41 rolled out",
		// No summary from the sender, so the revision is the most useful thing
		// the ledger holds. An id in this cell would be a dead end.
		"chg_bare": "merge: 9f21c0a",
		// Pruned by retention. It still has to render as something rather than
		// blanking the cell on an old trace.
		"chg_pruned": "deploy: change chg_pruned",
	} {
		if got := named[id]; got != want {
			t.Errorf("change %s named %q, want %q", id, got, want)
		}
	}
}

// The role column says plainly what the model was shown.
//
// A change listed beside a firing alert is an invitation to name it as the
// cause, and naming a cause is exactly what the host gates on recorded
// evidence. An operator reading this page to check a correlation needs the row
// to say that the section was correlation material, not a finding.
func TestARecordedChangeRowSaysItIsNotACause(t *testing.T) {
	runtime, replay := contextReferenceDetails([]ContextRef{
		{Kind: recentChangeRefKind, What: "deploy: checkout v41 rolled out",
			Visibility: "eligible"},
	}, func(value string) string { return value }, nil)
	if len(replay) != 0 || len(runtime) != 1 || runtime[0].Table == nil ||
		len(runtime[0].Table.Rows) != 1 {
		t.Fatalf("context details = %+v / %+v, want one runtime row", runtime, replay)
	}
	row := runtime[0].Table.Rows[0]
	if row.Cells[0] != "Recent change" ||
		row.Cells[1] != "deploy: checkout v41 rolled out" {
		t.Fatalf("change row = %+v, want the label and what changed", row.Cells)
	}
	for _, want := range []string{"correlation", "never a cause"} {
		if !strings.Contains(row.Cells[3], want) {
			t.Fatalf("change role = %q, want it to carry %q", row.Cells[3], want)
		}
	}
}

func recordedChangeFixture(t *testing.T) *Reader {
	t.Helper()
	fixture := newEpisodeProjectionFixture(t)
	stamp := time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC).Format(time.RFC3339Nano)
	fixture.exec(`INSERT INTO episode_attempts
	  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
	   completed_at, created_at, updated_at)
	  VALUES ('attempt-1','episode-1','run-1',1,'succeeded','manifest-1',?,?,?)`,
		stamp, stamp, stamp)
	fixture.exec(`INSERT INTO context_manifests
	  (id, episode_id, attempt_id, version, provider, model, reasoning_effort,
	   prompt_version, contract_version, tool_schema_version, preset, submitted_prompt, created_at)
	  VALUES ('manifest-1','episode-1','attempt-1',1,'claude','opus','high',
	          'responder-prompt-v3','investigation-contract-v1','result-operations-v2',
	          'emisar-conversation','',?)`, stamp)
	for ordinal, recorded := range []struct{ id, kind, summary, revision string }{
		{"chg_deploy", "deploy", "checkout v41 rolled out", "9f21c0a"},
		{"chg_bare", "merge", "", "9f21c0a"},
		{"chg_pruned", "deploy", "", ""},
	} {
		if recorded.summary != "" || recorded.revision != "" {
			fixture.exec(`INSERT INTO change_events
			  (id, source, source_identity, kind, occurred_at, actor, summary,
			   source_ref, revision, created_at)
			  VALUES (?,'webhook:deploys',?,?,?,'dana',?,'',?,?)`,
				recorded.id, recorded.id, recorded.kind, stamp,
				recorded.summary, recorded.revision, stamp)
		}
		fixture.exec(`INSERT INTO context_manifest_refs
		  (id, manifest_id, kind, source_ref, visibility, content_digest, ordinal, metadata_json)
		  VALUES (?,'manifest-1',?,?,'eligible',?,?,?)`,
			"ref-"+recorded.id, recentChangeRefKind, "change:"+recorded.id,
			"digest-"+recorded.id, ordinal+1,
			`{"kind":"`+recorded.kind+`","source":"webhook:deploys"}`)
	}
	return fixture.reader()
}
