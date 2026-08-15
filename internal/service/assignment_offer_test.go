package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/assignments"
	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const assignmentEpisode = "episode_assignment"

// seedAssignmentEpisode writes the run and episode an offer is made from.
// Rows rather than service calls, for the reason the knowledge seeds are rows:
// the handler has to be graded against what is recorded.
func seedAssignmentEpisode(t *testing.T, db *sql.DB) {
	t.Helper()
	stamp := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	for _, statement := range []struct {
		query string
		args  []any
	}{
		{`INSERT INTO agent_runs (
		    id, mode, channel_id, conversation_key, source_kind, source_id, prompt,
		    idempotency_key, state, next_attempt_at, created_at, updated_at, episode_id
		  ) VALUES ('run_a', 'triage', 'COPS', 'conv_a', 'slack', 'input_a', 'watch drift',
		    'idem_a', 'completed', ?, ?, ?, ?)`,
			[]any{stamp, stamp, stamp, assignmentEpisode}},
		{`INSERT INTO work_episodes (
		    id, agent_run_id, effort, authority, objective, channel_id,
		    destination_channel_id, created_at, updated_at
		  ) VALUES (?, 'run_a', 'incident_investigation', 'repository_write', 'watch drift',
		    'COPS', 'COPS', ?, ?)`,
			[]any{assignmentEpisode, stamp, stamp}},
	} {
		if _, err := db.Exec(statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}
}

// assignmentOperation is the offer an operator's sentence produces. The bounds
// are deliberately the un-normalized shapes a human sentence carries — a class
// with a space in it, a repository with whitespace, a duplicated glob — so the
// card and the row are graded on the normalization rather than on a value that
// needed none.
func assignmentOperation() investigation.ResultOperation {
	return investigation.ResultOperation{
		ID: "assign-1", Type: "offer_assignment",
		AssignmentOffer: &core.StandingAssignmentOffer{
			Repository: " AndrewDryga/responder ", ChangeClass: "Dependency Upgrade",
			SignalPattern: "terraform  plan\ndrift",
			PathGlobs:     []string{"infra/**", "infra/**", " "},
			DailyBudget:   2, ExpiryDays: 30,
			Rationale: "You have asked me to open these three times this week.",
		},
	}
}

// recordAssignmentOffer writes the offer to the episode's event stream the way
// applyResultOperation does, which is where the confirmation reads it back from.
func recordAssignmentOffer(
	t *testing.T, db *sql.DB, operation investigation.ResultOperation,
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
		"event_"+operation.ID, assignmentEpisode, episodepkg.EventAssignmentOffered,
		"result:"+operation.ID, string(payload), time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}
}

func assignmentConfirmationInput(
	cfg config.Config, id, user string, payload assignments.Confirmation,
) core.SlackInput {
	encoded, _ := json.Marshal(payload)
	return core.SlackInput{
		ID: id, EnvelopeID: "env_" + id, EventID: "event_" + id,
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "COPS", MessageTS: "1700.001",
		UserID: user, ActionID: slackui.ActionConfirmAssignmentOffer,
		ActionValue: string(encoded),
	}
}

func clickAssignmentConfirmation(
	t *testing.T, svc *Service, st *store.Store, in core.SlackInput,
) {
	t.Helper()
	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, in); err != nil || !created {
		t.Fatalf("admit assignment confirmation = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
}

func storedAssignments(t *testing.T, st *store.Store) []core.StandingAssignment {
	t.Helper()
	found, err := st.StandingAssignments.ListForChannel(context.Background(), "COPS", 20)
	if err != nil {
		t.Fatal(err)
	}
	return found
}

// Offering a standing assignment grants nothing, and the card states the
// NORMALIZED bounds.
//
// Both halves are the point of moving creation off the slash command. `create`
// wrote the row the moment it parsed, so the only thing an operator ever
// confirmed was their own typing — a miscounted `paths=` was a repository-wide
// grant that read as a narrow one. Here the offer is posted, zero rows exist,
// and every bound on the card is the value that would be stored: the repository
// trimmed, the class as the allowlist spells it, the budget and the expiry
// filled in, the duplicate and empty globs dropped.
func TestAnUnconfirmedAssignmentOfferGrantsNothingAndShowsNormalizedBounds(t *testing.T) {
	ctx := context.Background()
	svc, st, raw, _ := grantService(t)
	seedAssignmentEpisode(t, raw)

	svc.offerStandingAssignment(
		ctx, core.AgentRun{ID: "run_a", EpisodeID: assignmentEpisode}, "", "COPS",
		[]investigation.ResultOperation{assignmentOperation()},
	)
	if stored := storedAssignments(t, st); len(stored) != 0 {
		t.Fatalf("offering a standing assignment created %d grants", len(stored))
	}
	// The offer still has to have been made, or this would pass for the wrong
	// reason — a path that posts nothing also grants nothing.
	var body string
	if err := raw.QueryRow(
		`SELECT body_json FROM slack_deliveries WHERE kind = 'assignment_offer'`,
	).Scan(&body); err != nil {
		t.Fatalf("no assignment offer card was posted: %v", err)
	}
	for _, want := range []string{
		"AndrewDryga/responder",         // repository, trimmed
		"dependency upgrade",            // change class, off the allowlist
		"up to 2 a day",                 // daily budget
		"expires 30 days after confirm", // expiry, as the span that was agreed
		"infra/**",                      // path globs
		"terraform plan drift",          // signal pattern, collapsed
		"shadow, opens nothing",         // the authority that is withheld
		"Nothing is granted yet",        // and that nothing exists yet
	} {
		if !strings.Contains(body, want) {
			t.Errorf("the confirmation card omits the normalized bound %q:\n%s", want, body)
		}
	}
	// A duplicate glob rendered twice would mean the card is showing the offer
	// rather than the grant.
	if strings.Count(body, "infra/**") != 1 {
		t.Errorf("the card renders the proposal's duplicate globs:\n%s", body)
	}
}

// The offer the model made is recorded where the confirmation reads it back.
//
// Every other test in this file seeds that row directly, which is right for
// grading the handler and wrong for proving the seam: delete the
// `offer_assignment` case from applyResultOperation and all of them still pass
// while every card in production becomes permanently unclickable, because the
// click resolves an offer the episode never recorded. This is the one test that
// walks the apply path.
func TestAnOfferedAssignmentIsRecordedOnTheEpisodeTheClickWillRead(t *testing.T) {
	ctx := context.Background()
	svc, _, raw, _ := grantService(t)
	seedAssignmentEpisode(t, raw)

	if err := svc.recordResultOperationEvents(
		ctx, "run_a", []investigation.ResultOperation{assignmentOperation()},
	); err != nil {
		t.Fatal(err)
	}
	var kind string
	if err := raw.QueryRow(
		`SELECT kind FROM work_episode_events WHERE episode_id = ? AND idempotency_key = ?`,
		assignmentEpisode, "result:assign-1",
	).Scan(&kind); err != nil {
		t.Fatalf("the offer was not recorded on the episode: %v", err)
	}
	if kind != episodepkg.EventAssignmentOffered {
		t.Fatalf(
			"the offer is recorded as %q, which the confirmation refuses as unrecorded", kind,
		)
	}
}

// An offer whose bounds cannot be normalized draws no card at all.
//
// Silence rather than a refusal in the channel: an operator who did not ask for
// standing authority must never see a card offering it, and a model proposing a
// change class the allowlist does not hold is a prompt problem the log line is
// the evidence of.
func TestAnUngrantableAssignmentOfferDrawsNoCard(t *testing.T) {
	ctx := context.Background()
	svc, _, raw, _ := grantService(t)
	seedAssignmentEpisode(t, raw)

	operation := assignmentOperation()
	operation.AssignmentOffer.ChangeClass = "rewrite the payments service"
	svc.offerStandingAssignment(
		ctx, core.AgentRun{ID: "run_a", EpisodeID: assignmentEpisode}, "", "COPS",
		[]investigation.ResultOperation{operation},
	)
	var deliveries int
	if err := raw.QueryRow(
		`SELECT count(*) FROM slack_deliveries WHERE kind = 'assignment_offer'`,
	).Scan(&deliveries); err != nil {
		t.Fatal(err)
	}
	if deliveries != 0 {
		t.Fatalf("an ungrantable assignment was offered %d times", deliveries)
	}
}

// The confirmation re-authorizes, and it re-authorizes on both axes.
//
// The button reached a Slack client, so who pressed it is a question this
// handler asks again rather than a property of the message it was posted on.
// This is the widest authority a single click in this product grants, and both
// a non-operator and a deactivated member must leave the row count at zero.
func TestConfirmingAnAssignmentOfferReauthorizesTheOperator(t *testing.T) {
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
			slack := &fakeSlack{}
			if refusal.denied {
				slack.deniedUsers = map[string]bool{cfg.Slack.Operators[0]: true}
			}
			svc.slack = slack
			seedAssignmentEpisode(t, raw)
			recordAssignmentOffer(t, raw, assignmentOperation())

			clickAssignmentConfirmation(t, svc, st, assignmentConfirmationInput(
				cfg, "slack_asg_"+strings.ReplaceAll(refusal.name, " ", "_"),
				refusal.user(cfg),
				assignments.NewConfirmation(
					assignmentEpisode, "assign-1", "COPS", time.Now().UTC(),
				),
			))
			if stored := storedAssignments(t, st); len(stored) != 0 {
				t.Fatalf("%s was granted a standing assignment", refusal.name)
			}
		})
	}
}

// A confirmed offer creates the assignment, in shadow, with the bounds the
// host recorded.
//
// Shadow is the assertion that carries the weight. Migration v78 landed the
// creation path with the authority withheld because the eligibility gate leans
// on completion.status == decision_ready, which was the largest single source
// of defects on 2026-08-09, and the shadow audit is the evidence that gate holds
// against real traffic. A confirmation path that produced a live grant would
// have quietly deleted the reason this feature was allowed to exist — and it
// would look exactly like this test passing on everything else.
func TestAConfirmedAssignmentIsCreatedInShadowWithTheRecordedBounds(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	seedAssignmentEpisode(t, raw)
	recordAssignmentOffer(t, raw, assignmentOperation())

	clickAssignmentConfirmation(t, svc, st, assignmentConfirmationInput(
		cfg, "slack_asg_confirm", cfg.Slack.Operators[0],
		assignments.NewConfirmation(assignmentEpisode, "assign-1", "COPS", time.Now().UTC()),
	))
	stored := storedAssignments(t, st)
	if len(stored) != 1 {
		t.Fatalf("stored %d standing assignments, want exactly one", len(stored))
	}
	granted := stored[0]
	if !granted.Shadow {
		t.Fatal("a confirmed offer granted authority to open pull requests unattended")
	}
	if granted.Repository != "AndrewDryga/responder" ||
		granted.ChangeClass != "dependency_upgrade" ||
		granted.SignalPattern != "terraform plan drift" || granted.DailyBudget != 2 ||
		len(granted.PathGlobs) != 1 || granted.PathGlobs[0] != "infra/**" {
		t.Fatalf("the stored grant is not the normalized one that was shown: %+v", granted)
	}
	if granted.ActorID != cfg.Slack.Operators[0] {
		t.Fatalf("the grant records %q as its confirmer", granted.ActorID)
	}
	if !granted.ExpiresAt.After(time.Now().UTC().Add(29 * 24 * time.Hour)) {
		t.Fatalf("expiry = %s, want the thirty days the card offered", granted.ExpiresAt)
	}
}

// A confirmation naming an offer the episode never carried grants nothing.
//
// The button value is the one thing a client could edit, and this is what it
// buys: an episode id and an operation id that have to resolve to a recorded
// offer. They do not, so the click is stale and no authority is granted.
func TestAConfirmationForAnUnrecordedAssignmentGrantsNothing(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	seedAssignmentEpisode(t, raw)

	clickAssignmentConfirmation(t, svc, st, assignmentConfirmationInput(
		cfg, "slack_asg_ghost", cfg.Slack.Operators[0],
		assignments.NewConfirmation(
			assignmentEpisode, "assign-never-offered", "COPS", time.Now().UTC(),
		),
	))
	if stored := storedAssignments(t, st); len(stored) != 0 {
		t.Fatalf("an unrecorded offer granted %d assignments", len(stored))
	}
}

// A card older than a day grants nothing.
//
// The bounds were agreed to in a conversation, and the conversation has moved
// on. Every other confirmation in this product expires after twenty-four hours;
// this one grants weeks of unattended pull-request authority, so it is the last
// place to make an exception.
func TestAStaleAssignmentConfirmationGrantsNothing(t *testing.T) {
	svc, st, raw, cfg := grantService(t)
	seedAssignmentEpisode(t, raw)
	recordAssignmentOffer(t, raw, assignmentOperation())

	clickAssignmentConfirmation(t, svc, st, assignmentConfirmationInput(
		cfg, "slack_asg_stale", cfg.Slack.Operators[0],
		assignments.NewConfirmation(
			assignmentEpisode, "assign-1", "COPS", time.Now().UTC().Add(-25*time.Hour),
		),
	))
	if stored := storedAssignments(t, st); len(stored) != 0 {
		t.Fatalf("a day-old card granted %d assignments", len(stored))
	}
}

// The retired slash verb answers with the conversation that replaced it, and
// grants nothing on the way past.
//
// `/responder assignments create` was the ONLY way to grant a standing
// assignment for the day and a half between the feature landing and this
// operation, so it is the spelling an operator has muscle memory for. The
// answer has to name where the capability went: "unknown subcommand" tells
// somebody who typed a command that worked last week that they typed it wrong.
func TestTheRetiredAssignmentCreateVerbAnswersWithTheConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "slash-asg-create", EnvelopeID: "env-slash-asg-create",
		EventID: "event-slash-asg-create", Kind: "slash",
		TeamID: cfg.Slack.TeamID, ChannelID: "CRETIRED",
		UserID: cfg.Slack.Operators[0], ActionID: "/responder",
		Text: "assignments create repo=AndrewDryga/responder class=observability signal=drift",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("`assignments create` answers = %+v", slackClient.ephemerals)
	}
	answer := renderedSlackMessage(slackClient.ephemerals[0].message)
	for _, required := range []string{"is gone", "Ask for it in the channel", "confirmation card"} {
		if !strings.Contains(answer, required) {
			t.Errorf("the retired create verb does not say %q: %s", required, answer)
		}
	}
	found, err := st.StandingAssignments.ListForChannel(ctx, "CRETIRED", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 0 {
		t.Fatalf("the retired verb created %d assignments", len(found))
	}
}
