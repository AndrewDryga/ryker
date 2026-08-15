package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// "What changed?" is the first question of every real incident and Responder
// could not answer it. These tests close that, and the three ways of getting it
// wrong are: not answering it at all, answering it in a turn that should not
// have the section, and letting the answer be read as a cause.

func changeLedgerService(t *testing.T) (*Service, *store.Store, context.Context) {
	t.Helper()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	return svc, st, context.Background()
}

// recordedDeploy puts one change in the ledger through the same normalization
// every adapter goes through, so the test cannot pass on a row no adapter could
// have produced.
func recordedDeploy(t *testing.T, st *store.Store, identity, service string, minutesAgo int) {
	t.Helper()
	change, ok := changeledger.Record(core.ChangeEvent{
		Source: "webhook:deploys", SourceIdentity: identity,
		Kind:       changeledger.KindDeploy,
		OccurredAt: time.Now().UTC().Add(-time.Duration(minutesAgo) * time.Minute),
		Services:   []string{service}, Repositories: []string{"repo"},
		Actor: "dana", Summary: service + " v41 rolled out",
		SourceRef: "https://deploys.example.test/" + identity,
		Revision:  "9f21c0a",
	})
	if !ok {
		t.Fatal("a well-formed deploy was refused by the ledger")
	}
	if _, err := st.Changes.Record(context.Background(), change); err != nil {
		t.Fatal(err)
	}
}

// An operational assessment is told what changed, and told what that does and
// does not license.
//
// The layer is the whole feature, and the framing is the whole risk: a deploy
// listed minutes before an alert is an invitation to name it as the cause, and
// a cause is exactly what needs evidence rather than a coincidence in a list.
// The prompt must carry the only route by which a change can reach a verdict —
// verify it, record_evidence, bind the id — because the host cannot check prose
// and the cause gate will reject the assessment anyway, at which point the
// operator has paid for a turn to learn something the prompt could have said.
func TestAnAssessmentIsToldWhatChangedAndWhatThatDoesNotLicense(t *testing.T) {
	svc, st, ctx := changeLedgerService(t)
	recordedDeploy(t, st, "deploy-checkout", "checkout", 12)

	// The firing alert names its service, which is what turns "everything this
	// repository shipped" into "the thing that is erroring".
	changes := svc.recentChanges(ctx, agentContextRequest{
		ChannelID: "C1", Repository: "repo",
		Effort:       core.EffortOperationalAssessment,
		AlertSignals: []core.Signal{{Labels: map[string]string{"service": "checkout"}}},
	}, decisionpkg.OperationalMemoryContext{})
	if len(changes) != 1 {
		t.Fatalf("an assessment recalled %d changes, want the deploy", len(changes))
	}
	prompt, omitted := svc.watchPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1700.9", Text: "checkout is erroring"},
		"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, changes,
		"repo", nil, WatchPromptBudget(0),
	)
	if len(omitted) != 0 {
		t.Fatalf("an unpressured prompt dropped context: %+v", omitted)
	}
	for _, required := range []string{
		`"recent_changes"`,
		"checkout v41 rolled out",
		"9f21c0a",
		"12m ago",
		// Why the host chose it, so a match on a repository every service
		// shares can be discounted rather than believed.
		"implicated service checkout",
		// The framing, sentence by sentence.
		"correlation material and nothing else",
		"proximity in time is not causation",
		"never authorize an action",
		"record_evidence",
		"cause_claim_ids and evidence_refs",
		"rejected by the",
	} {
		if !strings.Contains(prompt, required) {
			t.Errorf("assessment prompt is missing %q", required)
		}
	}
	// And it arrives inside the untrusted framing, not as host instruction.
	if !strings.Contains(prompt, "<untrusted-prior-operational-context>") &&
		!strings.Contains(prompt, "suppliedContextPolicy") {
		if index := strings.Index(prompt, `"recent_changes"`); index < 0 {
			t.Fatal("recent_changes escaped the untrusted context block")
		}
	}
}

// A conversational turn never sees a change event.
//
// This is the layer that would be most tempting to apply everywhere, and it is
// the wrong instinct: a question about what a flag does is not helped by this
// morning's deploys, and the section would be paid for out of the context the
// answer actually needs. The gate is the effort contract, which admission
// already committed to, rather than anything the turn can talk its way past.
func TestAConversationalTurnIsNeverToldWhatChanged(t *testing.T) {
	svc, st, ctx := changeLedgerService(t)
	recordedDeploy(t, st, "deploy-checkout", "checkout", 12)

	for _, effort := range []core.EffortContract{
		core.EffortConversational,
		core.EffortFocusedCheck,
		core.EffortEngineeringTask,
	} {
		changes := svc.recentChanges(ctx, agentContextRequest{
			ChannelID: "C1", Repository: "repo", Effort: effort,
		}, decisionpkg.OperationalMemoryContext{})
		if len(changes) != 0 {
			t.Fatalf("effort %q recalled %d changes", effort, len(changes))
		}
	}
	// And the assembled conversational prompt carries no trace of one, which is
	// the assertion that survives someone later passing the layer in by hand.
	prompt := svc.conversationPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1700.9", Text: "what does the flag do?"},
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo",
	)
	for _, forbidden := range []string{
		"recent_changes", "checkout v41 rolled out", "9f21c0a",
	} {
		if strings.Contains(prompt, forbidden) {
			t.Errorf("the conversational lane leaked %q", forbidden)
		}
	}
}

// Under budget pressure the layer goes early and says so.
//
// It goes second, after recalled history and before the channel transcript,
// because it is the only other layer that is not about the conversation being
// answered — and because a deploy an operator can still look up themselves
// costs less to lose than the message the turn is replying to. The omission is
// recorded under its own key: an incident that could not be told what changed
// has a different cause from one that could not be told about a past episode,
// and an operator reading a thin answer needs to know which.
func TestABudgetedTurnDropsTheChangesBeforeTheTranscriptAndRecordsIt(t *testing.T) {
	svc, st, ctx := changeLedgerService(t)
	for index, name := range []string{"checkout", "cart", "payments"} {
		recordedDeploy(t, st, "deploy-"+name, name, index+1)
	}
	changes := svc.recentChanges(ctx, agentContextRequest{
		ChannelID: "C1", Repository: "repo",
		Effort: core.EffortIncidentInvestigation,
	}, decisionpkg.OperationalMemoryContext{})
	if len(changes) != 3 {
		t.Fatalf("recalled %d changes, want three", len(changes))
	}
	// More than minimumWatchMessages, so trimming the transcript is a real
	// alternative the budget could take. At or below the floor the transcript
	// is protected anyway and this test would pass whatever the order was —
	// which it did, on the first version of this fixture.
	recent := []decisionpkg.WatchContextMessage{
		{Text: "the oldest message in the transcript"},
	}
	for index := 0; index < 15; index++ {
		recent = append(recent, decisionpkg.WatchContextMessage{
			Text: "an ordinary channel message " + strings.Repeat("x", 200),
		})
	}
	input := core.SlackInput{ChannelID: "C1", MessageTS: "1799.000", Text: "status?"}
	// The budget is exactly the prompt this turn would produce with no change
	// layer at all, plus room for the sentence that reports the drop. Anything
	// looser tests nothing; anything tighter would drop a second layer and the
	// test would stop being about ordering.
	withoutChanges, _ := svc.watchPrompt(
		input, "U999BOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "repo", nil,
		WatchPromptBudget(0),
	)
	prompt, omitted := svc.watchPrompt(
		input, "U999BOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, changes, "repo", nil,
		len(withoutChanges)+len(changeledger.DroppedReason)+64,
	)
	if strings.Contains(prompt, "checkout v41 rolled out") {
		t.Fatal("a pressured prompt kept the change layer")
	}
	// The whole transcript survives, oldest message included. Under any order
	// that drops the changes later than this, the budget would have been found
	// by trimming these instead — which is the trade this ordering exists to
	// refuse.
	if !strings.Contains(prompt, "the oldest message in the transcript") {
		t.Fatal("the changes outlived transcript messages they should have gone before")
	}
	var reasons []string
	for _, omission := range omitted {
		if omission.Kind == changeledger.Layer {
			reasons = append(reasons, omission.Reason)
		}
	}
	if len(reasons) != 1 {
		t.Fatalf("the dropped change layer recorded %d omissions: %+v", len(reasons), omitted)
	}
	if reasons[0] != changeledger.DroppedReason {
		t.Fatalf("omission reason = %q", reasons[0])
	}
	// The model is told in the prompt too, not only on the trace: silently
	// thinner context reads as confident ignorance.
	if !strings.Contains(prompt, changeledger.DroppedReason) {
		t.Fatal("the turn was not told its change context had been cut")
	}
	// And no manifest reference may claim the model read what the budget
	// removed. That reading is exactly how an operator would explain an answer.
	if refs := changeledger.References(changes, changeledger.Dropped(omitted)); len(refs) != 0 {
		t.Fatalf("a dropped layer still recorded %d manifest references", len(refs))
	}
}
