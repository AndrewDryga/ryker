package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// cyclingCorrectionFixture drives one mention against a model that returns the
// same unusable answer every round — a deep-work reply with no completion
// assessment, which the host refuses as `incomplete` — so the correction loop
// runs until its budget stops it. It is the shape tenant run_3a615b9db had.
func cyclingCorrectionFixture(
	t *testing.T, channel, inputID string,
) (context.Context, config.Config, *store.Store, *Service, *fakeCoop, core.SlackInput) {
	t.Helper()
	// Returned on EVERY submission, not once: the run being reproduced is a
	// model that answers the same unusable way every round, and a queue that
	// drains would leave the second turn running forever instead.
	return cyclingCorrectionFixtureAnswering(t, channel, inputID,
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,`+
			`"ownership":3,"contribution":"decision","material":true},`+
			`"reason":"checked production","operations":[{"id":"complete",`+
			`"type":"complete_episode","completion":{"message":"Production is healthy."}}]}`)
}

// cyclingCorrectionFixtureAnswering is the same drive against a chosen answer,
// so a case can pick which correction class the loop keeps producing.
func cyclingCorrectionFixtureAnswering(
	t *testing.T, channel, inputID, answer string,
) (context.Context, config.Config, *store.Store, *Service, *fakeCoop, core.SlackInput) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 5
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = answer
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: inputID, EnvelopeID: "env-" + inputID, EventID: "event-" + inputID,
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: channel,
		MessageTS: "1700.900", UserID: "U123ABC",
		Text: "<@UBOT> Give me a decision-ready production health assessment. " +
			"Cover recent changes, hosts, workloads, dependencies, application " +
			"behavior, and SLOs.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	return ctx, cfg, st, svc, coopClient, input
}

// runCorrectionRounds advances the run until it stops being pending, or until
// the round cap, and returns how many rounds actually ran.
func runCorrectionRounds(
	t *testing.T, ctx context.Context, st *store.Store, svc *Service,
	input core.SlackInput, rounds int,
) int {
	t.Helper()
	for round := 1; round <= rounds; round++ {
		if err := svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		svc.pollAgentRuns(ctx)
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if run.State != core.AgentRunPending {
			return round
		}
	}
	return rounds
}

// A model that fails the same way twice is asked on a bigger one.
//
// run_3a615b9db spent nineteen correction rounds and twenty-two minutes on an
// alert that had already recovered, every round class `incomplete`, every round
// resubmitting a ~146KB briefing; by round fifteen the host was saying outright
// "return decision_ready with the healthy verdict" and it still took four more.
// Understanding was never the blocker, and five runs did the same thing that
// day. Rewording is what the correction text already is, so the remaining lever
// is the ladder: from the SECOND time one class fires on an attempt, the retry
// is delivered no lower than the next rung.
//
// The first correction still runs on the rung it is on. A model that has not
// yet been told what is wrong has not failed at anything, and escalating it
// would spend the expensive rung on every ordinary first miss.
func TestARepeatedCorrectionClassEscalatesTheRetryUpTheLadder(t *testing.T) {
	ctx, cfg, st, svc, coopClient, input := cyclingCorrectionFixture(
		t, "CESCALATE", "escalating-correction",
	)
	runCorrectionRounds(t, ctx, st, svc, input, 4)

	if len(coopClient.submitFloors) < 3 {
		t.Fatalf("the loop submitted %d turns, too few to show an escalation: %v",
			len(coopClient.submitFloors), coopClient.submitFloors)
	}
	if coopClient.submitFloors[0] != 0 {
		t.Fatalf("the first turn of a run asked for rung %d, want the ordinary rung",
			coopClient.submitFloors[0])
	}
	if coopClient.submitFloors[1] != 0 {
		t.Fatalf("a first correction escalated to rung %d; the model had not yet "+
			"been told what was wrong", coopClient.submitFloors[1])
	}
	if coopClient.submitFloors[2] != 1 {
		t.Fatalf("a second correction of the same class asked for rung %d, want 1: %v",
			coopClient.submitFloors[2], coopClient.submitFloors)
	}
	if len(coopClient.submitFloors) > 3 && coopClient.submitFloors[3] != 2 {
		t.Fatalf("a third correction asked for rung %d, want 2: %v",
			coopClient.submitFloors[3], coopClient.submitFloors)
	}

	// The rung transition rides the correction's own audit event, so an episode
	// trace says why the same question came back on a different model.
	escalations := 0
	for _, entry := range auditOutcomes(t, cfg, "result.correction", "") {
		if !strings.Contains(entry, "policy ladder rung 1") {
			continue
		}
		escalations++
		// A rung is a different model, so the escalated retry also carries the
		// full briefing again. The note has to say so: without it the trace
		// shows a prompt that went from twelve kilobytes back to a hundred and
		// forty with nothing recorded to explain it, and the reader's first
		// guess is a delta-turn regression.
		if !strings.Contains(entry, "The retry carries the full briefing again.") {
			t.Fatalf("the escalation trace does not explain the larger prompt: %q", entry)
		}
	}
	if escalations != 1 {
		t.Fatalf("the rung transition was audited %d times, want once", escalations)
	}
}

// A floor Coop will not honour costs one round trip, not the correction.
//
// Two different refusals arrive as the same 400 and mean the same thing here: a
// Coop older than the escalation API rejects the unknown field (saying only
// that the body is invalid JSON, naming nothing), and a current Coop refuses a
// rung a single-rung policy does not have — which is most deployments the first
// time a correction repeats. The correction still has to be delivered, so the
// floor is dropped, the retry goes out on the session's own rung, and the
// operator can see in the trace that the escalation did not happen.
func TestAnEscalationCoopRefusesStillDeliversItsCorrection(t *testing.T) {
	ctx, cfg, st, svc, coopClient, input := cyclingCorrectionFixture(
		t, "CNORUNG", "refused-escalation",
	)
	coopClient.floorErrs = []error{&coop.APIError{
		Status: 400, Code: "invalid_request",
		Detail: "min_target_index 1 is not a rung of this session's 1-rung target ladder",
	}}
	// Two rounds to earn the escalation, then the third submission on its own,
	// so the run is read at the moment the refusal lands rather than after the
	// correction that follows has raised the floor again.
	runCorrectionRounds(t, ctx, st, svc, input, 2)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}

	if len(coopClient.submitFloors) != 4 {
		t.Fatalf("the refused submission was not retried: %v", coopClient.submitFloors)
	}
	if coopClient.submitFloors[2] != 1 || coopClient.submitFloors[3] != 0 {
		t.Fatalf("a refused floor was not stripped and retried: %v", coopClient.submitFloors)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if floor := agentRunTargetFloor(run.Context); floor != 0 {
		t.Fatalf("a floor Coop refused is still on the run at rung %d, so every "+
			"ordinary retry pays for it again", floor)
	}
	// Its own audit kind. Every counter of `result.correction` — the audition
	// lane's correction rate above all — would otherwise charge the model for a
	// rung its deployment does not have.
	audited := auditOutcomes(t, cfg, "model.escalation", "")
	if len(audited) != 1 || !strings.HasPrefix(audited[0], "unavailable:") {
		t.Fatalf("a refused escalation left no trace an operator could read: %v", audited)
	}
	for _, entry := range auditOutcomes(t, cfg, "result.correction", "") {
		if strings.Contains(entry, "would not deliver this turn") {
			t.Fatalf("a refused escalation was counted as a correction: %q", entry)
		}
	}
}

// The two classes that are not capability problems stay on their rung.
//
// `shape` is an answer that is right and reads badly, and `rejected` is a
// malformed artifact attached to a sound conclusion — a bigger model produces
// the same content in both cases, so escalating them would spend the expensive
// rung on a formatting note.
func TestAShapeOrRejectedCorrectionNeverClimbsTheLadder(t *testing.T) {
	for _, class := range []correctionClass{correctionShape, correctionRejected} {
		if correctionEscalates(class) {
			t.Errorf("class %q escalates; only an unusable answer earns a rung", class)
		}
	}
	for _, class := range []correctionClass{correctionIncomplete, correctionUnreadable} {
		if !correctionEscalates(class) {
			t.Errorf("class %q does not escalate, so a repeat has no remaining lever", class)
		}
	}
	if floor := escalationFloorForRepeats(1); floor != 0 {
		t.Errorf("a first correction asked for rung %d, want the ordinary rung", floor)
	}
	if floor := escalationFloorForRepeats(2); floor != 1 {
		t.Errorf("a second correction asked for rung %d, want 1", floor)
	}
	if floor := escalationFloorForRepeats(4); floor != 3 {
		t.Errorf("a fourth correction asked for rung %d, want 3", floor)
	}
}

// A model that has just been re-briefed owes nothing to the rounds before it.
//
// Raising the floor also restates the whole briefing, because the rung it
// raises to is a different model. That model has not yet failed to read
// anything, so carrying the previous rung's `unreadable` tally forward would
// charge it for a schema it had never been shown — on tenant on 2026-08-16 the
// escalated model answered `unknown field "completion_contract"` and then
// `unknown field "record_evidence"`, two rounds spent learning a contract the
// host had not sent it, against a counter that was already at its limit.
//
// Deliberately only this class, and deliberately not the run-wide budget:
// `StructuredCorrections` is the hard bound on how long one run may argue with
// the model, and a reset there would turn a bounded loop into an unbounded one.
func TestRebriefedModelStartsWithAFreshUnreadableCount(t *testing.T) {
	// The recorded shape of the production failure: a well-formed envelope
	// carrying a field the result contract does not have, which strict decoding
	// refuses as unreadable rather than merely incomplete.
	ctx, _, st, svc, _, input := cyclingCorrectionFixtureAnswering(
		t, "CREBRIEF", "rebriefed-model",
		`{"action":"reply","attention":{"addressee":"responder","confidence":3,`+
			`"ownership":3,"contribution":"decision","material":true},`+
			`"reason":"checked production","completion_contract":{"status":"decision_ready"},`+
			`"operations":[{"id":"complete","type":"complete_episode",`+
			`"completion":{"message":"Production is healthy."}}]}`,
	)
	runCorrectionRounds(t, ctx, st, svc, input, 2)

	run, err := st.GetAgentRun(ctx, mustRunBySource(t, ctx, st, input).ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		t.Fatal(err)
	}
	if floor := agentRunTargetFloor(run.Context); floor != 1 {
		t.Fatalf("two unreadable answers left the run on rung %d, so this test "+
			"never reached the escalation it is about: %s", floor, run.LastError)
	}
	if repeats := state.CorrectionClasses[string(correctionUnreadable)]; repeats != 0 {
		t.Fatalf("the re-briefed model starts owing %d unreadable rounds it did "+
			"not spend", repeats)
	}
	// The hard bound is untouched. It is what stops a run arguing forever, and
	// the reset above must never be mistaken for a second chance at it.
	if state.StructuredCorrections < 2 {
		t.Fatalf("the run-wide correction budget was reset to %d; only the class "+
			"counter starts fresh", state.StructuredCorrections)
	}
}

func mustRunBySource(
	t *testing.T, ctx context.Context, st *store.Store, input core.SlackInput,
) core.AgentRun {
	t.Helper()
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	return run
}
