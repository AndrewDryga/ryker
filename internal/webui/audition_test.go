package webui

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

type auditionAttempt struct {
	id, mode, profile string
	provider, model   string
	input, output     int
	costUSD           float64
	costedTurns       int
	episode           string
	corrections       int
}

// seedAudition writes attempts, their manifests, the profile each asked for and
// the corrections the host issued against them, into a database the store
// itself migrated.
func seedAudition(t *testing.T, attempts ...auditionAttempt) *Reader {
	t.Helper()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	writable, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := writable.ExecContext(context.Background(), query, args...); err != nil {
			t.Fatalf("%v\n%s", err, query)
		}
	}
	stamp := time.Now().UTC().Format(core.TimestampFormat)
	seen := map[string]bool{}
	for _, item := range attempts {
		run, episode := "run_"+item.id, item.episode
		if episode == "" {
			episode = "ep_" + item.id
		}
		exec(`INSERT INTO agent_runs
		  (id, mode, conversation_key, source_kind, source_id, idempotency_key, state,
		   next_attempt_at, created_at, updated_at, channel_id, episode_id, attempt_id)
		  VALUES (?,?,?,'slack',?,?,'completed',?,?,?,'C1',?,?)`,
			run, item.mode, "conv_"+item.id, "src_"+item.id, "idem_"+item.id,
			stamp, stamp, stamp, episode, item.id)
		if !seen[episode] {
			seen[episode] = true
			exec(`INSERT INTO work_episodes
			  (id, agent_run_id, effort, authority, lifecycle_state, objective, created_at, updated_at)
			  VALUES (?,?,'focused_check','read_only','completed','work',?,?)`,
				episode, run, stamp, stamp)
		}
		exec(`INSERT INTO episode_attempts
		  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
		   created_at, updated_at)
		  VALUES (?,?,?,?,'succeeded',?,?,?)`,
			item.id, episode, run, auditionVersion(item.id)+1, "man_"+item.id, stamp, stamp)
		exec(`INSERT INTO context_manifests
		  (id, episode_id, attempt_id, version, provider, model, reasoning_effort, created_at,
		   usage_input_tokens, usage_output_tokens, usage_cost_usd, usage_costed_turns)
		  VALUES (?,?,?,?,?,?,'high',?,?,?,?,?)`,
			"man_"+item.id, episode, item.id, len(seen)+auditionVersion(item.id),
			item.provider, item.model, stamp,
			item.input, item.output, item.costUSD, item.costedTurns)
		if item.profile != "" {
			exec(`INSERT INTO context_manifest_refs
			  (id, manifest_id, kind, source_ref, content_digest, source_revision,
			   visibility, ordinal, omitted_reason, metadata_json)
			  VALUES (?,?,'execution_profile',?,'','','private',1,'','{}')`,
				"ref_"+item.id, "man_"+item.id, "profile:"+item.profile)
		}
		for index := 0; index < item.corrections; index++ {
			exec(`INSERT INTO audit_events
			  (id, incident_id, kind, actor_id, object_id, outcome, detail, created_at)
			  VALUES (?,'','result.correction','responder',?,'unreadable','',?)`,
				"aud_"+item.id+"_"+string(rune('a'+index)), run, stamp)
		}
	}
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

// context_manifests is UNIQUE(episode_id, version), so two attempts of one
// episode need two versions.
func auditionVersion(id string) int {
	if strings.HasSuffix(id, "b") {
		return 1
	}
	return 0
}

func laneFor(t *testing.T, reader *Reader, model string) (attempts, corrections int, found bool) {
	t.Helper()
	lanes, err := reader.AuditionLanes(
		context.Background(), time.Now().UTC().Add(-24*time.Hour),
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, lane := range lanes {
		if lane.Model == model {
			return lane.Attempts, lane.Corrections, true
		}
	}
	return 0, 0, false
}

// The whole point of an audition: a correction has to land on the model that
// earned it. The audit row names only the agent run, so the attribution walks
// run -> attempt -> manifest, and a join that lost its way would spread one
// model's corrections evenly over every model that ran that week — which is
// exactly the report somebody would use to move a lane onto the wrong model.
func TestACorrectionLandsOnTheModelThatEarnedIt(t *testing.T) {
	reader := seedAudition(t,
		auditionAttempt{id: "att_1", mode: "triage", provider: "anthropic", model: "sonnet",
			input: 100, output: 10, corrections: 3},
		auditionAttempt{id: "att_2", mode: "triage", provider: "openai", model: "gpt",
			input: 100, output: 10, corrections: 0},
	)
	if _, corrections, found := laneFor(t, reader, "sonnet"); !found || corrections != 3 {
		t.Fatalf("sonnet reported %d corrections (found=%t), want the 3 it earned",
			corrections, found)
	}
	if _, corrections, found := laneFor(t, reader, "gpt"); !found || corrections != 0 {
		t.Fatalf("gpt reported %d corrections (found=%t), want none of sonnet's",
			corrections, found)
	}
}

// The join warned about by name. An episode has many manifests and many runs,
// so joining agent_runs on episode_id multiplies the two against each other —
// on a production database it turned 351 manifests into 953 rows, every extra
// one counted as an attempt that never happened. Two attempts of one episode
// must count two.
func TestTwoAttemptsOfOneEpisodeCountTwiceAndNotFourTimes(t *testing.T) {
	reader := seedAudition(t,
		auditionAttempt{id: "att_a", mode: "triage", provider: "anthropic", model: "sonnet",
			episode: "ep_shared", input: 100, output: 10},
		auditionAttempt{id: "att_b", mode: "triage", provider: "anthropic", model: "sonnet",
			episode: "ep_shared", input: 100, output: 10},
	)
	attempts, _, found := laneFor(t, reader, "sonnet")
	if !found {
		t.Fatal("the shared-episode lane vanished entirely")
	}
	if attempts != 2 {
		t.Fatalf("attempts = %d, want 2; the episode join fanned the rows against each other",
			attempts)
	}
}

// A run corrected three times must not become three attempts. audit_events has
// no unique key on object_id, so a plain second LEFT JOIN would multiply the
// attempt row — and with it every token and every dollar on the lane.
func TestRepeatedCorrectionsDoNotMultiplyTheAttemptTheyLandOn(t *testing.T) {
	reader := seedAudition(t,
		auditionAttempt{id: "att_1", mode: "triage", provider: "anthropic", model: "sonnet",
			input: 100, output: 10, costUSD: 0.5, costedTurns: 1, corrections: 3},
	)
	lanes, err := reader.AuditionLanes(context.Background(), time.Now().UTC().Add(-24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(lanes) != 1 {
		t.Fatalf("lanes = %d, want one", len(lanes))
	}
	lane := lanes[0]
	if lane.Attempts != 1 {
		t.Fatalf("attempts = %d, want 1; three corrections became three attempts", lane.Attempts)
	}
	if lane.ReportedUSD != 0.5 || lane.Tokens.InputTokens != 100 {
		t.Fatalf("one corrected attempt reported %v USD over %d input tokens, want 0.50 and 100 "+
			"— the correction join tripled the money", lane.ReportedUSD, lane.Tokens.InputTokens)
	}
	if lane.Corrections != 3 || lane.CorrectedAttempts != 1 {
		t.Fatalf("corrections = %d over %d attempts, want 3 over 1",
			lane.Corrections, lane.CorrectedAttempts)
	}
}

// The profile a turn ASKED for beside the model that answered, because they
// disagree exactly when the question matters: a profile picks a session policy,
// sessions outlive the turn that opened them, and Coop's ladder rotates
// underneath both.
func TestTheLaneReportsTheProfileAskedForBesideTheModelThatAnswered(t *testing.T) {
	reader := seedAudition(t,
		auditionAttempt{id: "att_1", mode: "triage", profile: "deep", provider: "anthropic",
			model: "sonnet", input: 100, output: 10},
	)
	lanes, err := reader.AuditionLanes(context.Background(), time.Now().UTC().Add(-24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(lanes) != 1 || lanes[0].Profile != "deep" {
		t.Fatalf("lanes = %+v, want one asking for the \"deep\" profile", lanes)
	}
	if lanes[0].Provider != "anthropic" || lanes[0].Model != "sonnet" {
		t.Fatalf("the effective target was lost: %+v", lanes[0])
	}
}

// The panel is on the page, and it carries the two cost figures apart. A single
// combined number is the failure this guards: reported money is an invoice and
// an estimate is arithmetic, and no reader can un-add them once they are one.
func TestTheDecisionsPageShowsTheAuditionWithBothCostFiguresApart(t *testing.T) {
	reader := seedAudition(t,
		auditionAttempt{id: "att_1", mode: "triage", profile: "deep", provider: "anthropic",
			model: "sonnet", input: 100, output: 10, costUSD: 0.5, costedTurns: 1, corrections: 2},
	)
	body := servePage(t, reader, "/decisions")
	if strings.Contains(body, "Could not load") {
		t.Fatalf("the decisions page failed to render with the audition panel:\n%s", body)
	}
	for _, want := range []string{
		"Audition", "anthropic:sonnet", "deep",
		"Provider-reported", "estimated", "never added together",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("the audition panel does not show %q", want)
		}
	}
	// The panel must say where the half it does not carry lives, rather than
	// rendering an empty gate-pass column that reads as broken.
	if !strings.Contains(body, "responder audition") {
		t.Fatal("the panel does not name the command that prints the gate-pass and judge halves")
	}
}

// An empty deployment must not render a blank panel. Every empty names the
// thing that would fill it, so nobody debugs a machine that is simply new.
func TestAnEmptyAuditionPanelSaysWhatWouldFillIt(t *testing.T) {
	reader := migratedReader(t)
	panel, err := reader.AuditionPanel(context.Background(), config.Pricing{}, 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(panel.Rows) != 0 {
		t.Fatalf("an empty database produced %d lanes", len(panel.Rows))
	}
	if len(panel.Gaps) == 0 {
		t.Fatal("the empty panel offered no explanation of what would fill it")
	}
}
