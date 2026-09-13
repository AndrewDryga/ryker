package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// cyclingCorrectionFixture drives one mention against a model that returns the
// same unusable answer every round — a deep-work reply with no completion
// assessment, which the host refuses as `incomplete` — so the correction loop
// runs until its budget stops it. It is the shape blitz run_3a615b9db had.
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

// Exhausting the preferred rung degrades one retry; it does not erase why the
// run was escalated.
//
// Two production investigations stayed queued for roughly six hours after
// Claude reported its weekly limit even though Codex was healthy. Their stored
// floor was rung 1, so every retry excluded rung 0 and repeated the same
// ladder-exhausted error. After the first fix went live, channel serialization
// overwrote the second run's last error with "waiting for the previous agent
// run" before it could submit — forgetting the exhaustion and setting it up to
// ask for Claude again. The permission to degrade therefore has to ride the run
// context across unrelated defers. Once consumed, an ordinary escalated turn
// must still require rung 1 so Claude remains preferred when it is available.
func TestAFloorLimitedEscalationDegradesOnceWithoutForgettingItsFloor(t *testing.T) {
	ctx := context.Background()
	coopClient := newFakeCoop()
	svc := &Service{coop: coopClient}
	run := core.AgentRun{
		ID:             "run_floor_limited",
		IdempotencyKey: "turn-floor-limited",
		Context: json.RawMessage(
			`{"min_target_index":1,"degraded_target_fallback_pending":true}`,
		),
		LastError: "waiting for the previous agent run in this Slack channel",
	}

	if _, _, err := svc.submitTurnAtLadderFloor(
		ctx, run, "session_codex_claude", 7, "continue", nil,
	); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitFloors) != 1 || coopClient.submitFloors[0] != 0 {
		t.Fatalf("the Claude-limited retry carried floors %v, want [0] so Codex can answer",
			coopClient.submitFloors)
	}
	if len(coopClient.submitRewinds) != 1 {
		t.Fatalf("the Claude-limited retry made %d explicit target rewinds, want 1",
			len(coopClient.submitRewinds))
	}
	if floor := agentRunTargetFloor(run.Context); floor != 1 {
		t.Fatalf("the degraded retry forgot desired escalation floor %d, want 1", floor)
	}

	healthy := run
	healthy.IdempotencyKey = "turn-healthy-escalation"
	healthy.Context = json.RawMessage(`{"min_target_index":1}`)
	healthy.LastError = ""
	if _, _, err := svc.submitTurnAtLadderFloor(
		ctx, healthy, "session_codex_claude", 8, "continue", nil,
	); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitFloors) != 2 || coopClient.submitFloors[1] != 1 {
		t.Fatalf("the healthy escalated turn carried floors %v, want [0 1] so Claude stays preferred",
			coopClient.submitFloors)
	}
	if len(coopClient.submitRewinds) != 1 {
		t.Fatalf("the healthy Claude turn made %d target rewinds, want the prior fallback only",
			len(coopClient.submitRewinds))
	}
}

// A refused rung is the only reading Ryker gets of where the ladder ends.
//
// Coop publishes the session's current target but not the policy's list of
// them, so the floor was computed as repeats-1 with no ceiling at all. Rungs
// 10, 11 and 12 asked for and refused on 2026-08-16 while a thirteen-round
// correction loop ran: run_532f8d62871320dc9d0696cb334d3503 on blitz was
// corrected thirteen times, and from about the tenth repeat every round cost a
// SubmitTurn refused with `invalid_request (400): min_target_index …`, a
// `model.escalation`/`unavailable` audit line, and a second round trip to
// deliver the correction the ordinary way — while the ledger kept climbing into
// rungs that do not exist and would be refused again next round.
//
// The refusal is durable for that reason: it is the one fact about the ladder's
// length this host can ever learn, and forgetting it between rounds is what
// turned one refusal into three.
func TestEscalationStopsClimbingAfterCoopRefusesARung(t *testing.T) {
	ctx, cfg, st, svc, coopClient, input := cyclingCorrectionFixture(
		t, "CLADDERTOP", "ladder-top",
	)
	seeded := mustRunBySource(t, ctx, st, input)
	// The state the production run was in when it started asking for rungs
	// that are not there: three corrections of the class already counted, and a
	// rung 3 that Coop refused — a refusal that also dropped the floor to zero,
	// which is why the run is sitting on the session's own rung.
	for round := 0; round < 3; round++ {
		if _, err := st.NoteAgentRunCorrectionClass(
			ctx, seeded.ID, string(correctionIncomplete),
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.SetAgentRunTargetFloor(ctx, seeded.ID, 0, 3); err != nil {
		t.Fatal(err)
	}

	runCorrectionRounds(t, ctx, st, svc, input, 2)

	run := mustRunBySource(t, ctx, st, input)
	if floor := agentRunTargetFloor(run.Context); floor >= 3 {
		t.Fatalf("the ledger climbed to rung %d past a rung 3 Coop had already "+
			"refused, so every round from here pays for a refused submit", floor)
	}
	for round, floor := range coopClient.submitFloors {
		if floor >= 3 {
			t.Fatalf("submission %d asked Coop for rung %d after it refused rung 3: %v",
				round+1, floor, coopClient.submitFloors)
		}
	}
	// The trace has to say why the same model is answering again. Without the
	// sentence an operator reads a repeated `incomplete` correction with no
	// escalation beside it and concludes the escalation is broken.
	tops := 0
	for _, entry := range auditOutcomes(t, cfg, "result.correction", "") {
		if strings.Contains(entry,
			"ladder top: rung 3 was refused by Coop; the retry stays at rung 0",
		) {
			tops++
		}
	}
	if tops == 0 {
		t.Fatalf("no correction said the ladder had run out: %v",
			auditOutcomes(t, cfg, "result.correction", ""))
	}
	// And it never pays the refusal a second time.
	if refusals := auditOutcomes(t, cfg, "model.escalation", ""); len(refusals) != 0 {
		t.Fatalf("a known-refused rung was asked for again: %v", refusals)
	}
}

// A refusal Coop sends once is remembered on the run that earned it.
//
// Rungs 10, 11 and 12 asked for and refused on 2026-08-16 while a thirteen-round
// correction loop ran. The refusal path already dropped the floor and resubmitted
// on the ordinary rung, so the correction was always delivered — but it dropped
// the floor and nothing else, and the next repeat computed a higher rung from the
// same repeat count and asked again. The number Coop refused is the ceiling, and
// it has to survive the requeue that carries the run to its next round.
func TestARefusedFloorIsRememberedOnTheRun(t *testing.T) {
	ctx, _, st, svc, coopClient, input := cyclingCorrectionFixture(
		t, "CREFUSEDRUNG", "refused-rung-remembered",
	)
	// The exact refusal the production Coop sends, which the host classifies on
	// the status rather than on the words: a current Coop names the field and a
	// Coop older than the escalation API says only that the body is invalid.
	coopClient.floorErrs = []error{&coop.APIError{
		Status: 400, Code: "invalid_request",
		Detail: "min_target_index 1 is not a rung of this session's 1-rung target ladder",
	}}
	// Two rounds earn the escalation to rung 1; the third submission is the one
	// that carries it and is refused.
	runCorrectionRounds(t, ctx, st, svc, input, 2)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}

	run := mustRunBySource(t, ctx, st, input)
	if _, refused := agentRunLadderFloors(run.Context); refused != 1 {
		t.Fatalf("Coop refused rung 1 and the run remembers rung %d, so the next "+
			"repeat asks for a higher rung of the same absent ladder", refused)
	}
	fields := map[string]json.RawMessage{}
	if err := json.Unmarshal(run.Context, &fields); err != nil {
		t.Fatal(err)
	}
	if string(fields["refused_target_floor"]) != "1" {
		t.Fatalf("refused_target_floor = %s, want 1", fields["refused_target_floor"])
	}
	// The watch envelope is decoded strictly, so a key its state struct does not
	// declare is not a lost field but a failed turn: the run's very next round
	// would end on `invalid persisted triage context`.
	if _, err := decodeWatchRunContext(run); err != nil {
		t.Fatalf("remembering the refused rung broke the envelope it lives in: %v", err)
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

// Once the model has the exact schema and a validator, unreadable output gets
// one repair turn. A second copy with one usable completion message is answered
// through the reply-only fallback, not sent up a ladder for more formatting
// rounds. The linked ads.txt episode spent 15 corrections doing exactly that.
func TestRepeatedUnreadableResultUsesReplyFallbackBeforeTheLadder(t *testing.T) {
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
	if floor := agentRunTargetFloor(run.Context); floor != 0 {
		t.Fatalf("two unreadable answers climbed to rung %d instead of using the reply fallback", floor)
	}
	if run.State == core.AgentRunPending {
		t.Fatalf("the second unreadable answer started another correction round: %+v", state)
	}
	if state.StructuredCorrections != 1 {
		t.Fatalf("recorded schema repair rounds = %d, want exactly one", state.StructuredCorrections)
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
