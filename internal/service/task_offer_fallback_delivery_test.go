package service

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The 2026-08-20 Better Stack Starfall incident spent its report-repair budget
// on one optional engineering offer, then Responder suppressed the valid
// diagnosis as ambient chatter. The exact alert received no reply after a
// nine-minute investigation. A rejected button must never eat the answer.
func TestARejectedTaskOfferCannotSilenceAnOperationalInvestigation(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	result := withCheckoutTaskOffer(t, confirmedAlertReplyResult(observedAt))
	result = rewriteFixture(t, result,
		`"repository":"repo"}},{"id":"complete"`,
		`"repository":"repo","prompt":"Improve checkout failure telemetry."}},{"id":"complete"`,
		`"completion":{"status":"decision_ready","verdict":"unhealthy","summary":"The checkout alert is a confirmed current issue with a bounded immediate remediation."}`,
		`"completion":{"status":"blocked","verdict":"degraded","summary":"The diagnosis is complete but the optional repository change is not authorized.","material_gaps":["operator approval for repository work"],"blocker_kind":"access_denied","attempts":["Completed the read-only diagnosis."],"next_action":"Deliver the diagnosis without offering writable work."}`,
	)
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	_, st, slackClient, svc, card := streamFixtureOn(
		t, cfg, "CTASKFALLBACK", result, result, result,
	)
	card.ID, card.EnvelopeID = "task-fallback-card", "env-task-fallback-card"
	card.EventID, card.MessageTS = "event-task-fallback-card", "1787258846.135009"

	ctx := context.Background()
	if created, err := st.AdmitSlackInput(ctx, card); err != nil || !created {
		t.Fatalf("admit card = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		finishQueuedAgentRun(t, ctx, svc)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", card.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("operational investigation = %+v, %v", run, err)
	}
	decision := parseStagedWatchResult(t, run)
	if decision.TaskPrompt != "" || decision.TaskTitle != "" || decision.TaskRepository != "" {
		t.Fatalf("rejected task offer survived the final result: %+v", decision)
	}
	if decision.Completion == nil || decision.Completion.BlockerKind != "access_denied" {
		t.Fatalf("valid investigation completion was replaced: %+v", decision.Completion)
	}
	if len(slackClient.posts) != 1 || slackClient.posts[0].thread != card.MessageTS ||
		slackClient.posts[0].message.Text == "" {
		t.Fatalf("evidence-backed investigation reply = %+v", slackClient.posts)
	}
}
