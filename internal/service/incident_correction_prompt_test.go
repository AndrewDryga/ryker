package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/agentprompt"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// The evidence blitz run_3a615b9db argued with itself about for nineteen
// rounds, harvested in internal/investigation/ledger_conflict_replay_test.go
// and repeated here because that file is package-private to investigation.
// The second claim is the ordinary case rather than the recorded one: a
// refused completion normally carries more than one contradicted claim, and
// one claim's correction already runs past a kilobyte.
const (
	replayConflictingID   = "ev_1e8a0e8029fe43e3685c5e924b2735df"
	replayConflictingText = "blitz-infra run-o2BA7juuNF9VKQCV applied, while va1-apps " +
		"run-UEi6Q77Gdi7CpRB6 exited 1 after cms-server, cms-web, and payments missed their " +
		"healthy deadline and rolled back; this partial rollout affected nomad-hvn03 and is " +
		"separate from the nomad-hvn02 sdb alert."
	replaySupportingID   = "ev_9c22f1a740bb2ec1f0dd42a1c8b6e5aa"
	replaySupportingText = "The saved plan for run-b3d4iNqNaNqj654q contained one in-place " +
		"update to module.realtime_gateway.nomad_job.app, with no creates, deletes, " +
		"replacements, or drift outside that module."
	hostConflictingID   = "ev_5f0be31c884d47a1b0c5f2e6d3a91b47"
	hostConflictingText = "nomad-hvn02 reported sdb unmounted for eleven minutes and the " +
		"allocation directory was unavailable for the whole of that window."
	hostSupportingID   = "ev_2ab4c9d70e18455f9f3d6b21ac57e084"
	hostSupportingText = "All three Nomad clients in va1 reported ready with no drained " +
		"allocations at the time of the snapshot, and nomad-hvn02 sdb was mounted."
)

// recordedContradictionCorrection is what 79445e8 produces for that ledger:
// both sides of every conflict, whole, each with its evidence id, source and
// observation time, and the three moves that close a conflict stated once at
// the top.
func recordedContradictionCorrection(t *testing.T, now time.Time) string {
	t.Helper()
	contract := investigation.InvestigationContract{
		Claims: []investigation.ClaimRequirement{
			{ID: "change.recent", Layer: "change", Required: true},
			{ID: "host.current_state", Layer: "host", Required: true},
		},
		Completion: investigation.CompletionRule{ConclusionKind: "operational_health"},
	}
	evidence := []core.Evidence{
		{
			ID: replaySupportingID, ClaimID: "change.recent", Relation: "supports",
			Observation: replaySupportingText, SourceName: "HCP Terraform plan summary",
			SourceType: "monitoring", ObservedAt: now.Add(-40 * time.Minute),
			Confidence: "high",
		},
		{
			ID: replayConflictingID, ClaimID: "change.recent", Relation: "contradicts",
			Observation: replayConflictingText,
			SourceName:  "TFC agent and Nomad allocation events",
			SourceType:  "monitoring", ObservedAt: now.Add(-20 * time.Minute),
			Confidence: "high", HealthEffect: "risk",
		},
		{
			ID: hostSupportingID, ClaimID: "host.current_state", Relation: "supports",
			Observation: hostSupportingText, SourceName: "Nomad node status",
			SourceType: "monitoring", ObservedAt: now.Add(-35 * time.Minute),
			Confidence: "high",
		},
		{
			ID: hostConflictingID, ClaimID: "host.current_state", Relation: "contradicts",
			Observation: hostConflictingText, SourceName: "Nomad allocation events",
			SourceType: "monitoring", ObservedAt: now.Add(-15 * time.Minute),
			Confidence: "high", HealthEffect: "risk",
		},
	}
	coverage := []core.Coverage{
		{
			Layer: "change", Status: "healthy", ClaimIDs: []string{"change.recent"},
			Detail:     "the alert condition cleared and the rollout reconciled",
			ObservedAt: now.Add(-time.Minute),
		},
		{
			Layer: "host", Status: "healthy", ClaimIDs: []string{"host.current_state"},
			Detail:     "the mount recovered and every client reports ready",
			ObservedAt: now.Add(-time.Minute),
		},
	}
	correction := investigation.BuildLedger(contract, evidence, coverage, now).
		CompletionCorrectionFor("decision_ready", "healthy")
	if correction == "" {
		t.Fatal("the recorded ledger was accepted; this test no longer reproduces a refusal")
	}
	return correction
}

// An incident turn refused for a contradiction is told which records conflict.
//
// 79445e8 made the contradiction correction name both sides of the conflict
// with their evidence ids, because blitz run_3a615b9db spent nineteen rounds
// unable to say which record it was retiring. That landed on the watch path,
// where the correction rides the context envelope into
// watchDecisionCorrectionPrompt. The incident and engineering-task path reads
// it back out of last_error through agentprompt.Continuation, and everything
// between the two was sized for a one-line validator complaint:
//
//   - the continuation only recognises a correction whose text matches one of
//     four phrases, and "required claims still contain unresolved
//     contradictions" is none of them, so the whole block was dropped and the
//     model was re-asked with no idea what was wrong;
//   - both the bound on the way in and the bound on the way out are smaller
//     than one refused completion's correction, so widening the gate alone
//     hands the model a conflict cut off before the ids that name it.
//
// The evidence id is the assertion because it is the part that makes the
// correction actionable: "retract the losing statement" is unanswerable
// without a name for the statement.
func TestAnIncidentContinuationCarriesTheConflictItWasRefusedFor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	correction := recordedContradictionCorrection(t, time.Now().UTC())

	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, ChannelID: "COPS", ThreadTS: "1700.950",
		ConversationKey: "channel:COPS", SourceKind: "slack",
		SourceID: "incident-contradiction", SessionID: "ses_contradiction",
	})
	if err != nil {
		t.Fatal(err)
	}
	assembled, err := json.Marshal(assembledAgentContext{
		Repository: "repo", CapturedAt: time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetAgentRunContext(ctx, queued.ID, assembled); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "coop_turn_contradiction", 1, 0); err != nil {
		t.Fatal(err)
	}
	if err := svc.requeueWithCorrection(
		ctx, leased, correctionIncomplete, correction, 0,
	); err != nil {
		t.Fatal(err)
	}
	requeued, err := st.GetAgentRun(ctx, queued.ID)
	if err != nil {
		t.Fatal(err)
	}

	prompt := agentprompt.Continuation(requeued)
	for _, required := range []string{
		replayConflictingID,
		replaySupportingID,
		hostConflictingID,
		hostSupportingID,
		// The resolution names the field that performs it. Describing the move
		// instead was the next failure: the live model wrote "Supersedes
		// evidence-change-repo." into its observation prose, which retires
		// nothing, and looped to its budget being told to do it again.
		`supersedes:["<the id it retires>"]`,
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("the retry prompt for a refused contradiction omits %q.\n"+
				"correction was %d bytes, prompt is %d:\n%s",
				required, len(correction), len(prompt), prompt)
		}
	}
}
