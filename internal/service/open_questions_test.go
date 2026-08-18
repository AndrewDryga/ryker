package service

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/openquestions"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// The open question survives the trip from the ledger to the channel.
//
// The recorded 2026-08-16 Traefik result is read here exactly as the host reads
// it: cause_status "bounded", one material gap saying the split between
// load-driven growth and a genuine leak "is unresolved" for want of a Go heap
// profile. What the operator actually saw was "Memory tracks load ... raise the
// cap and roll the job", because the reply renderer had a line for a blocked
// completion and no line for anything else. The certainty was the host's, not
// the model's.
func TestBoundedCauseReachesTheSlackReply(t *testing.T) {
	data, err := os.ReadFile("../decision/testdata/traefik_bounded_cause_result.json")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := decisionpkg.ParseWatchDecision(
		string(data), time.Date(2026, 8, 16, 14, 46, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	open := openquestions.For(decision)
	if open.CauseStatus != "bounded" {
		t.Fatalf("the bounded cause did not reach the renderer: %+v", open)
	}
	message := slackui.WithOpenQuestions(
		slackui.EvidenceResponse(
			"Memory tracks load; raise the cap and roll the job.", nil, nil,
			slackui.NewSanitizer(12000),
		),
		open.CauseStatus, open.Cause, open.MaterialGaps, open.Unexplained, open.NextCheck,
		slackui.NewSanitizer(12000),
	)
	line := strings.Join(message.Context, "\n")
	for _, want := range []string{"Cause bounded, not identified", "heap profile", "unresolved"} {
		if !strings.Contains(line, want) {
			t.Fatalf("the reply does not say %q: %q", want, line)
		}
	}

	// A scheduled follow-up is the whole point of the correction that now
	// refuses this result, so the reply has to name it: the operator should read
	// that the question is still open AND that something will answer it.
	scheduled := decision
	scheduled.AppliedOperations = append(append(
		[]investigation.ResultOperation{}, decision.AppliedOperations...),
		investigation.ResultOperation{
			ID: "wait-heap-profile", Type: "wait_external",
			ExternalWait: &investigation.ExternalWaitOperation{
				ID: "wakeup-heap-profile", Kind: "scheduled_verification",
				Verification: "the captured heap profile distinguishes load-driven growth from a leak",
				PollAfter:    "2026-08-16T16:30:00Z", Deadline: "2026-08-16T18:30:00Z",
			},
		})
	next := openquestions.For(scheduled).NextCheck
	if next != "verify the captured heap profile distinguishes load-driven growth from a leak at 16:30 UTC" {
		t.Fatalf("a scheduled verification did not name its success check: %q", next)
	}

	// A blocked completion already renders its own gaps and next action through
	// WithBlockedAssessment; saying it twice under a different word is how a
	// caveat becomes wallpaper.
	blocked := decision
	blockedCompletion := *decision.Completion
	blockedCompletion.Status = "blocked"
	blockedCompletion.NextAction = "Grant the profiler capability, then retry."
	blocked.Completion = &blockedCompletion
	if second := openquestions.For(blocked); len(second.MaterialGaps) != 0 ||
		second.NextCheck != "" || second.CauseStatus != "" {
		t.Fatalf("a blocked completion grew a second caveat line: %+v", second)
	}

	// And a verdict that found no issue has no cause to qualify. "Cause bounded"
	// under "nothing is wrong" is a contradiction the operator has to resolve.
	quiet := decision
	quietAssessment := *decision.AlertAssessment
	quietAssessment.Verdict = "not_issue"
	quiet.AlertAssessment = &quietAssessment
	if status := openquestions.For(quiet).CauseStatus; status != "" {
		t.Fatalf("a not_issue verdict still carried a cause status: %q", status)
	}
}

// End to end, because the unit above proves the rules and not the wiring, and
// the wiring is what failed: every field was recorded and the renderer was never
// called.
//
// The result is handcrafted rather than the harvested envelope because the real
// one names repositories this config does not have. Its shape is the one the new
// correction leaves standing: a confirmed issue whose cause is bounded, and a
// wait_external that will run the check which settles it.
func TestABoundedCauseReplyNamesTheCheckThatWillSettleIt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	observedAt := time.Now().UTC().Format(time.RFC3339)
	pollAfter := time.Now().UTC().Add(45 * time.Minute)
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{fmt.Sprintf(
		`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3,"contribution":"decision","material":true},"operations":[`+
			`{"id":"ev-1","type":"record_evidence","evidence":{"claim_id":"change.recent","claim":"the deployed Cassandra topology is current","observation":"the repository declares the current Cassandra service and operating threshold","relation":"supports","health_effect":"none","source_type":"repository","source_name":"cassandra topology","dimensions":{"repository":"repo","environment":"production","revision":"current"}}},`+
			`{"id":"cassandra-throughput","type":"record_evidence","evidence":{"id":"cassandra-throughput","claim_id":"application.functional_behavior","claim":"Cassandra serves requests above its operating threshold","observation":"fresh monitoring reports total RPS below 4k","relation":"contradicts","health_effect":"unhealthy","source_type":"monitoring","source_name":"Cassandra throughput","target":"cassandra","observed_at":%[1]q,"dimensions":{"service":"cassandra","endpoint":"requests","environment":"production","window":"current"}}},`+
			`{"id":"cov-1","type":"record_coverage","coverage":{"layer":"change","claim_ids":["change.recent"],"status":"healthy","detail":"The current Cassandra topology was reconciled."}},`+
			`{"id":"cov-2","type":"record_coverage","coverage":{"layer":"application","claim_ids":["application.functional_behavior"],"status":"unhealthy","detail":"Current throughput is below 4k."}},`+
			`{"id":"cov-3","type":"record_coverage","coverage":{"layer":"slo","claim_ids":["impact.current"],"status":"unknown","detail":"No separate user-impact measure is available."}},`+
			`{"id":"cov-4","type":"record_coverage","coverage":{"layer":"dependency","claim_ids":["dependency.current_health"],"status":"unknown","detail":"Dependency health does not change the confirmed throughput failure."}},`+
			`{"id":"finding-throughput","type":"record_finding","finding":{"key":"cassandra-throughput-low","what":"Cassandra throughput is below its operating threshold","scope":"cassandra production","status":"unexplained","alternatives":[{"hypothesis":"one serving node is shedding requests","not_checkable":"the scheduled per-node sample has not run yet"}]}},`+
			`{"id":"alert","type":"record_alert_assessment","alert_assessment":{"verdict":"confirmed_issue","impact":"Current Cassandra throughput is below its operating threshold.","cause_status":"bounded","cause":"Throughput falls with no topology change, so the loss is inside the serving path rather than in the deployment.","cause_claim_ids":["application.functional_behavior"],"evidence_refs":["cassandra-throughput"],"immediate_action_kind":"mitigation","immediate_action":"Reduce nonessential Cassandra load while restoring service capacity.","verification":"Confirm fresh total RPS stays above 4k and request errors stop.","long_term_solution":"Add capacity and traffic controls that keep Cassandra above its operating threshold.","scope":{"status":"bounded","checked_targets":["cassandra"],"unverified_targets":["individual Cassandra serving nodes"],"evidence_refs":["cassandra-throughput"]}}},`+
			`{"id":"wait-throughput","type":"wait_external","external_wait":{"id":"wakeup-cassandra-rps","kind":"scheduled_verification","verification":"fresh total RPS stays above 4k and request errors stop","poll_after":%[2]q,"deadline":%[3]q}},`+
			`{"id":"complete","type":"complete_episode","completion":{"message":"Cassandra throughput is below 4k. Reduce nonessential load while restoring capacity, then verify RPS stays above 4k and errors stop.","completion":{"status":"decision_ready","verdict":"unhealthy","summary":"Cassandra throughput is currently below its operating threshold.","material_gaps":["Which of the serving nodes is shedding the requests is unresolved until the next sample lands."]}}}`+
			`]}`,
		observedAt,
		pollAfter.Format(time.RFC3339),
		time.Now().UTC().Add(3*time.Hour).Format(time.RFC3339),
	)}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "slack-app-bounded", EnvelopeID: "env-app-bounded",
		EventID: "EvAppBounded", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.700", UserID: "BBETTERSTACK",
		Text: "FIRING: Cassandra total RPS is below 4k.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("bounded-cause reply posts = %+v", slackClient.posts)
	}
	context := strings.Join(slackClient.posts[0].message.Context, "\n")
	for _, want := range []string{
		"Cause bounded, not identified: Which of the serving nodes",
		"Next check: verify fresh total RPS stays above 4k and request errors stop at " + pollAfter.Format("15:04") + " UTC",
	} {
		if !strings.Contains(context, want) {
			t.Fatalf("the posted reply does not say %q: %q", want, context)
		}
	}
}
