package resultrecovery

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func TestASecondSchemaFailureStillReturnsTheModelsBoundedReply(t *testing.T) {
	raw := `{"action":"reply","operations":[
		{"id":"e1","type":"record_evidence","evidence":{"claim_id":"impact.current","confidence":3}},
		{"id":"complete-1","type":"complete_episode","completion":{"message":"The endpoint is degraded on two of five paths.","followup_messages":["PR 529 is unrelated."],"completion":{"status":"decision_ready","summary":"degraded"}}}
	]}`
	reply, ok := CompletionReply(raw, true)
	if !ok {
		t.Fatal("the usable completion reply was lost with an invalid evidence record")
	}
	if reply.Message != "The endpoint is degraded on two of five paths." ||
		len(reply.FollowupMessages) != 1 ||
		reply.FollowupMessages[0] != "PR 529 is unrelated." {
		t.Fatalf("recovered reply = %+v", reply)
	}
}

func TestAProseWrappedSecondFailureStillReturnsTheModelsBoundedReply(t *testing.T) {
	// Eighty-three recent results wrapped otherwise usable JSON in prose. The
	// fallback must recover the outer envelope, not make formatting cost the
	// customer the answer after the one repair turn is already spent.
	raw := `Here is the result:\n{"action":"reply","operations":[
		{"id":"complete-1","type":"complete_episode","completion":{"message":"The service is healthy now.","completion":{"status":"decision_ready","summary":"healthy"}}}
	]}\nValidated.`
	reply, ok := CompletionReply(raw, true)
	if !ok || reply.Message != "The service is healthy now." {
		t.Fatalf("prose-wrapped reply = %+v, %t", reply, ok)
	}
}

func TestReplyFallbackNeverTurnsSilenceOrAmbiguityIntoSpeech(t *testing.T) {
	for name, raw := range map[string]string{
		"ignore": `{"action":"ignore","operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"Do not send me.","completion":{"status":"decision_ready","summary":"quiet"}}}]}`,
		"two completions": `{"action":"reply","operations":[
			{"id":"complete-1","type":"complete_episode","completion":{"message":"First.","completion":{"status":"decision_ready","summary":"first"}}},
			{"id":"complete-2","type":"complete_episode","completion":{"message":"Second.","completion":{"status":"decision_ready","summary":"second"}}}
		]}`,
		"no reply": `{"action":"reply","operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"<responder-no-reply/>","completion":{"status":"decision_ready","summary":"quiet"}}}]}`,
		"oversized": `{"action":"reply","operations":[{"id":"complete-1","type":"complete_episode","completion":{"message":"` +
			strings.Repeat("x", 13<<10) +
			`","completion":{"status":"decision_ready","summary":"large"}}}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			if reply, ok := CompletionReply(raw, true); ok {
				t.Fatalf("unsafe fallback recovered %+v", reply)
			}
		})
	}
}

func TestSemanticFallbackKeepsValidRecordsAndDropsUnsafeClaims(t *testing.T) {
	prior := decisionpkg.WatchDecision{
		Action: "reply", Message: "The service is degraded.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "channel", Urgency: 2, Confidence: 3,
			Novelty: 3, Ownership: 2, Contribution: "new_evidence", Material: true,
		},
		Evidence:        []core.Evidence{{ID: "e-1"}},
		Coverage:        []core.Coverage{{Layer: "application"}},
		AlertAssessment: &investigation.AlertAssessment{Verdict: "confirmed_issue"},
		Operations:      []investigation.ResultOperation{{ID: "unsafe"}},
	}
	got, delivered := SemanticWatch(
		core.AgentRun{ID: "run-semantic"}, core.SlackInput{Kind: "mention"},
		decisionpkg.WatchTurnState{}, "cause join is invalid", prior,
	)
	if !delivered || got.Message != prior.Message || len(got.Evidence) != 1 ||
		len(got.Coverage) != 1 || got.AlertAssessment != nil || len(got.Operations) != 0 ||
		got.Completion == nil || got.Completion.Status != "blocked" ||
		got.Attention != prior.Attention {
		t.Fatalf("semantic fallback = %+v, delivered=%t", got, delivered)
	}
}
