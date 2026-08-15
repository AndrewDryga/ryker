package service

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// An Emisar approval exists because a governed mutation takes longer than a
// turn. The rows describing where it came from do not: slack_inputs,
// slack_deliveries and agent_runs all expire on the OPERATIONAL horizon, and
// emisar_approvals lives to its own expires_at.
//
// So the completion path used to load the Slack input and the card delivery,
// return their ErrNotFound to the work queue, and never queue the verification
// turn — for exactly the long-running action the approval was created for, in
// exactly the ordinary thread that has no incident room to fall back on. The
// operator who pressed approve was told nothing, ever.
//
// The episode is the durable answer, and phase 5 is what lets this path ask it:
// work_episodes lives on the episode-history horizon and carries the bound,
// revisioned destination the answer belongs in.
func TestAnApprovalCompletesInItsThreadAfterTheTransportRowsExpire(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	input := core.SlackInput{
		ID: "slack_roomless", EnvelopeID: "env_roomless", EventID: "EvRoomless",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.100", ThreadTS: "1700.100", UserID: cfg.Slack.Operators[0],
		Text: "Enable the exact governed setting.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	origin, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		ConversationKey: "channel:" + input.ChannelID,
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		Repository: cfg.Slack.DefaultRepository, Prompt: "enable the setting",
		CommitmentTitle: "Enable the governed setting",
		Episode: &core.WorkEpisode{
			Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
			Objective: "Enable the exact governed setting",
		},
	})
	if err != nil || origin.EpisodeID == "" {
		t.Fatalf("origin run = %+v, %v", origin, err)
	}

	approval, created, err := st.Approvals.Record(ctx, core.EmisarApproval{
		RequestID: "apr_roomless", EpisodeID: origin.EpisodeID,
		ChannelID: input.ChannelID, SourceInput: input.ID, RequestedBy: input.UserID,
		RunID: "run_roomless", OperationID: "op_roomless",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_roomless",
		ExpiresAt:   time.Now().UTC().Add(24 * time.Hour),
	})
	if err != nil || !created {
		t.Fatalf("record approval = %+v, %t, %v", approval, created, err)
	}
	body, err := slackui.Encode(slackui.WithEmisarApproval(
		slackui.ConversationResponse("Ready for approval.", slackui.NewSanitizer(12000)),
		approval,
	))
	if err != nil {
		t.Fatal(err)
	}
	deliveryID := "watch_reply_" + input.ID
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: deliveryID, Operation: "post", Kind: "notice",
		ChannelID: input.ChannelID, ThreadTS: input.ThreadTS, Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Approvals.BindDelivery(ctx, approval.RequestID, deliveryID); err != nil {
		t.Fatal(err)
	}

	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetEmisar(&fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "success",
		RunURL: "https://emisar.dev/app/acme/runs/run_roomless",
	}})
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}

	// The operational horizon passes while Emisar is still working. Everything
	// that described the conversation goes; the approval and the episode stay.
	expireRows(t, cfg.StateDir,
		`DELETE FROM slack_deliveries`,
		`DELETE FROM slack_inputs`,
		`DELETE FROM agent_runs WHERE source_kind = 'watch'`,
	)

	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatalf("approval completion after transport expiry: %v", err)
	}

	// The decision before the plumbing: the verification turn exists, and it is
	// bound to the same episode rather than forking a new one.
	run, err := st.GetAgentRunBySource(
		ctx, "emisar_approval:"+approval.RequestID, input.ID,
	)
	if err != nil {
		t.Fatalf(
			"no verification turn was queued for a completed governed mutation: %v; "+
				"the operator who approved it is told nothing", err,
		)
	}
	if run.EpisodeID != origin.EpisodeID {
		t.Fatalf("continuation episode = %q, want %q", run.EpisodeID, origin.EpisodeID)
	}
	if run.ChannelID != input.ChannelID || run.ThreadTS != input.ThreadTS {
		t.Fatalf(
			"continuation destination = %q/%q, want the episode's bound %q/%q",
			run.ChannelID, run.ThreadTS, input.ChannelID, input.ThreadTS,
		)
	}
	stored, err := st.Approvals.Get(ctx, approval.RequestID)
	if err != nil || !stored.ContinuationQueued || stored.Status != "success" {
		t.Fatalf("completed approval = %+v, %v", stored, err)
	}
}

// The same completion with no card at all. message_ts is only written when the
// Slack delivery lands, so a superseded or permanently failed card left the
// approval re-queueing itself once a second forever: never terminal, never
// verified, never mentioned in a log line or an audit event.
func TestACompletedApprovalStopsWaitingForACardThatWillNeverArrive(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	input := core.SlackInput{
		ID: "slack_nocard", EnvelopeID: "env_nocard", EventID: "EvNoCard",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.200", ThreadTS: "1700.200", UserID: cfg.Slack.Operators[0],
		Text: "Enable the exact governed setting.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	origin, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: input.ChannelID, ThreadTS: input.ThreadTS,
		ConversationKey: "channel:" + input.ChannelID,
		SourceKind:      "watch", SourceID: input.ID, UserID: input.UserID,
		Repository: cfg.Slack.DefaultRepository, Prompt: "enable the setting",
		CommitmentTitle: "Enable the governed setting",
		Episode: &core.WorkEpisode{
			Effort: core.EffortFocusedCheck, Authority: core.AuthorityReadOnly,
			Objective: "Enable the exact governed setting",
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	// Terminal already, and the card never landed: message_ts is empty and no
	// delivery is bound.
	terminal := time.Now().UTC().Add(-time.Hour)
	if _, _, err := st.Approvals.Record(ctx, core.EmisarApproval{
		RequestID: "apr_nocard", EpisodeID: origin.EpisodeID,
		ChannelID: input.ChannelID, SourceInput: input.ID, RequestedBy: input.UserID,
		RunID: "run_nocard", OperationID: "op_nocard",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_nocard",
		ExpiresAt:   time.Now().UTC().Add(24 * time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.Approvals.Advance(
		ctx, "apr_nocard", "success",
		"https://emisar.dev/app/acme/runs/run_nocard", "", terminal,
	); err != nil {
		t.Fatal(err)
	}
	expireRows(t, cfg.StateDir, `
		UPDATE emisar_approvals
		SET terminal_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 hour')
		WHERE request_id = 'apr_nocard'`)

	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetEmisar(&fakeEmisar{})
	if err := svc.processEmisarApproval(ctx, "apr_nocard"); err != nil {
		t.Fatalf("terminal approval with no card: %v", err)
	}

	if _, err := st.GetAgentRunBySource(
		ctx, "emisar_approval:apr_nocard", input.ID,
	); err != nil {
		t.Fatalf(
			"a completed governed mutation queued no verification turn because its "+
				"card was missing: %v", err,
		)
	}
	stored, err := st.Approvals.Get(ctx, "apr_nocard")
	if err != nil || !stored.ContinuationQueued {
		t.Fatalf("approval never finished: %+v, %v", stored, err)
	}
}

// expireRows imitates a retention pass on the operational horizon from outside
// the store package, which has no raw-SQL hook and should not grow one for a
// test.
func expireRows(t *testing.T, stateDir string, statements ...string) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("%s: %v", statement, err)
		}
	}
}
