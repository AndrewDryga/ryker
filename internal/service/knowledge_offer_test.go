package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/knowledgeoffer"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const knowledgeEpisode = "episode_knowledge"

// seedVerifiedKnowledgeEpisode writes the shape a verified remediation leaves
// on disk: an episode whose outcome row says verified, and one Emisar approval
// that succeeded and is reachable through the same join the outcome projection
// uses. Rows rather than service calls, for the reason the grant seeds are
// rows — the handler must be graded against what is recorded.
func seedVerifiedKnowledgeEpisode(t *testing.T, db *sql.DB, verified int) {
	t.Helper()
	stamp := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	for _, statement := range []struct {
		query string
		args  []any
	}{
		{`INSERT INTO agent_runs (
		    id, mode, channel_id, conversation_key, source_kind, source_id, prompt,
		    idempotency_key, state, next_attempt_at, created_at, updated_at, episode_id
		  ) VALUES ('run_k', 'triage', 'COPS', 'conv_k', 'slack', 'input_k', 'verify',
		    'idem_k', 'completed', ?, ?, ?, ?)`,
			[]any{stamp, stamp, stamp, knowledgeEpisode}},
		{`INSERT INTO work_episodes (
		    id, agent_run_id, effort, authority, objective, channel_id,
		    destination_channel_id, created_at, updated_at
		  ) VALUES (?, 'run_k', 'incident_investigation', 'governed_operation', 'verify',
		    'COPS', 'COPS', ?, ?)`,
			[]any{knowledgeEpisode, stamp, stamp}},
		{`INSERT INTO episode_outcomes (
		    episode_id, channel_id, repository, terminal_state, terminal_at,
		    alert_group_key, root_cause, verification, verified, created_at
		  ) VALUES (?, 'COPS', 'repo', 'completed', ?, 'grafana:api-5xx', 'Registration lost',
		    'Error rate back to baseline', ?, ?)`,
			[]any{knowledgeEpisode, stamp, verified, stamp}},
		{`INSERT INTO emisar_approvals (
		    request_id, channel_id, source_input, requested_by, run_id, operation_id,
		    action_id, pack_ref, runner_ref, status, approval_url, next_check_at,
		    expires_at, created_at, updated_at
		  ) VALUES ('req_k', 'COPS', 'input_k', 'U0', 'emisarrun_k', 'op_k',
		    'nomad.job.restart', 'nomad@1.4.0+sha256:1111', 'prod~7f3c', 'success',
		    'https://e/a', ?, ?, ?, ?)`,
			[]any{stamp, stamp, stamp, stamp}},
	} {
		if _, err := db.Exec(statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}
}

func runbookOperation() investigation.ResultOperation {
	return investigation.ResultOperation{
		ID: "rb-1", Type: "offer_runbook_draft",
		RunbookOffer: &core.RunbookDraftOffer{
			Title:   "Restart a job that lost its registration",
			Slug:    "nomad-lost-registration",
			Summary: "Run when allocations are healthy but the service is not routable.",
			// Deliberately the recorded identity, so a test that fails is
			// failing about the gate rather than about a typo.
			ActionID: "nomad.job.restart", PackRef: "nomad@1.4.0+sha256:1111",
			RunnerRef: "prod~7f3c",
		},
	}
}

// recordKnowledgeOffer writes the offer to the episode's event stream the way
// applyResultOperation does, which is where the confirmation reads it back from.
func recordKnowledgeOffer(
	t *testing.T,
	db *sql.DB,
	operation investigation.ResultOperation,
) {
	t.Helper()
	payload, err := json.Marshal(operation)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO work_episode_events (
		  id, episode_id, sequence, kind, actor, idempotency_key, payload_json, created_at
		) VALUES (?, ?, 1, ?, 'agent', ?, ?, ?)`,
		"event_"+operation.ID, knowledgeEpisode, episodepkg.EventKnowledgeOffered,
		"result:"+operation.ID, string(payload), time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}
}

func knowledgeConfirmationInput(
	cfg config.Config,
	id string,
	user string,
	payload knowledgeoffer.Confirmation,
) core.SlackInput {
	encoded, _ := json.Marshal(payload)
	return core.SlackInput{
		ID: id, EnvelopeID: "env_" + id, EventID: "event_" + id,
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "COPS", MessageTS: "1700.001",
		UserID: user, ActionID: slackui.ActionConfirmKnowledgeOffer,
		ActionValue: string(encoded),
	}
}

func clickKnowledgeConfirmation(t *testing.T, svc *Service, st *store.Store, in core.SlackInput) {
	t.Helper()
	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, in); err != nil || !created {
		t.Fatalf("admit knowledge confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
}

// Nothing is created until an operator presses the button.
//
// The claim on the card is "nothing exists yet", and the only way to hold it is
// to assert the absence directly: an offer that was posted and never confirmed
// must leave zero Emisar calls behind. A counter that only ever went up would
// not distinguish "the draft was not created" from "it was created twice".
func TestAnUnconfirmedKnowledgeOfferCreatesNothing(t *testing.T) {
	ctx := context.Background()
	svc, _, raw, _ := grantService(t)
	emisarClient := &fakeEmisar{}
	svc.SetEmisar(emisarClient)
	seedVerifiedKnowledgeEpisode(t, raw, 1)

	svc.offerEpisodeKnowledge(
		ctx, core.AgentRun{ID: "run_k", EpisodeID: knowledgeEpisode}, "", "COPS",
		[]investigation.ResultOperation{runbookOperation()},
	)
	if len(emisarClient.drafts) != 0 {
		t.Fatalf("offering a runbook created %d Emisar drafts", len(emisarClient.drafts))
	}
	if len(emisarClient.drafts) != 0 {
		t.Fatalf("offering a runbook created %d Emisar drafts", len(emisarClient.drafts))
	}
	// The offer still has to have been made, or the test would pass for the
	// wrong reason — a path that posts nothing also creates nothing.
	var deliveries int
	if err := raw.QueryRow(
		`SELECT count(*) FROM slack_deliveries WHERE kind = 'knowledge_offer'`,
	).Scan(&deliveries); err != nil {
		t.Fatal(err)
	}
	if deliveries != 1 {
		t.Fatalf("knowledge offer deliveries = %d, want the card to have been posted", deliveries)
	}
	// And no pull request is on its way either. A knowledge card becomes an
	// engineering task, which is an incident row; zero of those is how "no PR
	// was opened" is checkable without a GitHub client in the test.
	var tasks int
	if err := raw.QueryRow(`SELECT count(*) FROM incidents`).Scan(&tasks); err != nil {
		t.Fatal(err)
	}
	if tasks != 0 {
		t.Fatalf("offering knowledge started %d engineering tasks", tasks)
	}
}

// An episode that never verified its fix draws no card at all.
//
// This is the gate that keeps the confirmation meaningful. A card on every
// completion would be background noise within a week, and a runbook drafted
// from an unverified episode is a procedure asserting something nobody checked.
func TestANonVerifiedEpisodeDrawsNoKnowledgeOffer(t *testing.T) {
	ctx := context.Background()
	svc, _, raw, _ := grantService(t)
	seedVerifiedKnowledgeEpisode(t, raw, 0)

	svc.offerEpisodeKnowledge(
		ctx, core.AgentRun{ID: "run_k", EpisodeID: knowledgeEpisode}, "", "COPS",
		[]investigation.ResultOperation{runbookOperation()},
	)
	var deliveries int
	if err := raw.QueryRow(
		`SELECT count(*) FROM slack_deliveries WHERE kind = 'knowledge_offer'`,
	).Scan(&deliveries); err != nil {
		t.Fatal(err)
	}
	if deliveries != 0 {
		t.Fatalf("an unverified episode was offered a runbook draft %d times", deliveries)
	}
}

// The confirmation re-authorizes, and it re-authorizes on both axes.
//
// The button reached a Slack client, so who pressed it is a question this
// handler has to ask again rather than a property of the message it was posted
// on. A non-operator and a non-member both get a refusal and, more importantly,
// Emisar hears nothing.
func TestConfirmingAKnowledgeOfferReauthorizesTheOperator(t *testing.T) {
	for _, refusal := range []struct {
		name   string
		user   func(config.Config) string
		denied bool
	}{
		{"a non-operator", func(config.Config) string { return "U_BYSTANDER" }, false},
		{"a deactivated member", func(c config.Config) string { return c.Slack.Operators[0] }, true},
	} {
		t.Run(refusal.name, func(t *testing.T) {
			svc, st, raw, cfg := grantService(t)
			emisarClient := &fakeEmisar{}
			svc.SetEmisar(emisarClient)
			slack := &fakeSlack{}
			if refusal.denied {
				slack.deniedUsers = map[string]bool{cfg.Slack.Operators[0]: true}
			}
			svc.slack = slack
			seedVerifiedKnowledgeEpisode(t, raw, 1)
			recordKnowledgeOffer(t, raw, runbookOperation())

			clickKnowledgeConfirmation(t, svc, st, knowledgeConfirmationInput(
				cfg, "slack_kb_"+strings.ReplaceAll(refusal.name, " ", "_"),
				refusal.user(cfg),
				knowledgeoffer.NewConfirmation(
					knowledgeoffer.KindRunbook, knowledgeEpisode, "rb-1", "COPS",
					time.Now().UTC(),
				),
			))
			if len(emisarClient.drafts) != 0 {
				t.Fatalf("%s created an Emisar runbook draft", refusal.name)
			}
		})
	}
}

// The confirmed draft carries the refs the host recorded, not the ones that
// came back through the operator's browser.
//
// This is the assertion the whole feature rests on. The button value is edited
// to name a different action — the shape a tampered or simply stale payload
// takes — and what Emisar receives is still the identity from the approval row,
// because the payload never carried an action in the first place.
func TestAConfirmedRunbookDraftSendsTheRecordedRefsToEmisar(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	emisarClient := &fakeEmisar{}
	svc.SetEmisar(emisarClient)
	seedVerifiedKnowledgeEpisode(t, raw, 1)
	recordKnowledgeOffer(t, raw, runbookOperation())

	clickKnowledgeConfirmation(t, svc, st, knowledgeConfirmationInput(
		cfg, "slack_kb_confirm", cfg.Slack.Operators[0],
		knowledgeoffer.NewConfirmation(
			knowledgeoffer.KindRunbook, knowledgeEpisode, "rb-1", "COPS", time.Now().UTC(),
		),
	))
	if len(emisarClient.drafts) != 1 {
		t.Fatalf("Emisar drafts = %d, want exactly one", len(emisarClient.drafts))
	}
	arguments := emisarClient.drafts[0]
	if arguments["slug"] != "nomad-lost-registration" {
		t.Fatalf("slug = %v", arguments["slug"])
	}
	definition := arguments["definition"].(map[string]any)
	stage := definition["stages"].([]any)[0].(map[string]any)
	step := stage["steps"].([]any)[0].(map[string]any)
	if step["action"] != "nomad.job.restart" {
		t.Fatalf("action = %v, want the recorded approval's action id", step["action"])
	}
	if got := step["pack"].(map[string]any)["id"]; got != "nomad" {
		t.Fatalf("pack id = %v", got)
	}
	refs := step["targets"].(map[string]any)["refs"].([]any)
	if len(refs) != 1 || refs[0] != "runner:prod~7f3c" {
		t.Fatalf("targets = %v, want the recorded runner", refs)
	}
	if !strings.Contains(
		definition["context_markdown"].(string), "nomad@1.4.0+sha256:1111",
	) {
		t.Fatal("the draft context lost the immutable pack ref the fix was verified on")
	}
}

// A confirmation naming an offer the episode never carried creates nothing.
//
// The button value is the one thing a client could edit, and this is what it
// buys: an episode id and an operation id that have to resolve to a recorded
// offer. They do not, so the click is stale and Emisar hears nothing.
func TestAConfirmationForAnUnrecordedOfferCreatesNothing(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	emisarClient := &fakeEmisar{}
	svc.SetEmisar(emisarClient)
	seedVerifiedKnowledgeEpisode(t, raw, 1)

	clickKnowledgeConfirmation(t, svc, st, knowledgeConfirmationInput(
		cfg, "slack_kb_ghost", cfg.Slack.Operators[0],
		knowledgeoffer.NewConfirmation(
			knowledgeoffer.KindRunbook, knowledgeEpisode, "rb-never-offered", "COPS",
			time.Now().UTC(),
		),
	))
	if len(emisarClient.drafts) != 0 {
		t.Fatalf("an unrecorded offer created %d drafts", len(emisarClient.drafts))
	}
}

func cardOperation() investigation.ResultOperation {
	return investigation.ResultOperation{
		ID: "kb-1", Type: "offer_kb_card",
		CardOffer: &core.KnowledgeCardOffer{
			Slug:  "nomad-lost-registration",
			Title: "A drained node leaves an allocation unroutable",
			Body:  "The allocation stays healthy while Consul has dropped its registration.",
		},
	}
}

// A confirmed knowledge card becomes an engineering task carrying the exact
// document, and never a commit this host made itself.
//
// It rides the existing propose-to-PR path rather than a new one, and that is a
// decision worth pinning: the publisher only ever pushes a tree Coop reviewed
// and hashed, so a host-side "write this file and commit it" would have been a
// second route to the default branch with none of the review on it. What this
// asserts is the seam — a task exists, and its prompt names the file and holds
// the host-written provenance the model could not have authored.
func TestAConfirmedKnowledgeCardBecomesAnEngineeringTaskForTheExactFile(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	emisarClient := &fakeEmisar{}
	svc.SetEmisar(emisarClient)
	seedVerifiedKnowledgeEpisode(t, raw, 1)
	recordKnowledgeOffer(t, raw, cardOperation())

	clickKnowledgeConfirmation(t, svc, st, knowledgeConfirmationInput(
		cfg, "slack_kb_card", cfg.Slack.Operators[0],
		knowledgeoffer.NewConfirmation(
			knowledgeoffer.KindCard, knowledgeEpisode, "kb-1", "COPS", time.Now().UTC(),
		),
	))
	if len(emisarClient.drafts) != 0 {
		t.Fatalf("a knowledge card reached Emisar %d times", len(emisarClient.drafts))
	}
	var title, summary string
	if err := raw.QueryRow(`
		SELECT incident.title, signal.summary
		FROM incidents AS incident
		JOIN signals AS signal ON signal.incident_id = incident.id
		ORDER BY incident.created_at DESC LIMIT 1`,
	).Scan(&title, &summary); err != nil {
		t.Fatalf("no engineering task was started: %v", err)
	}
	if !strings.Contains(title, "A drained node leaves an allocation unroutable") {
		t.Fatalf("the task is not titled after the card: %q", title)
	}
	for _, want := range []string{
		".agent/kb/nomad-lost-registration.md",
		"# A drained node leaves an allocation unroutable",
		"episode `" + knowledgeEpisode + "`",
	} {
		if !strings.Contains(summary, want) {
			t.Fatalf("the task prompt omits %q:\n%s", want, summary)
		}
	}
}
