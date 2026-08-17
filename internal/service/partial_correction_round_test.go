package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A correction round returns what it is changing, and the host puts back the
// rest.
//
// Every correction used to make the model re-emit the entire result envelope.
// On 2026-08-16 the tenant deployment spent 52 corrections across 92 model turns,
// and the worst episode — episode_run_956b7644b6fbef89b17aa3a9c6df8da8, the
// Terraform run notification these fixtures come from — ran sixteen turns at
// 6,500 to 20,000 output tokens each for $8.84 over a single unexplained
// finding. Measured against the recorded turns, 116,385 of its 233,398 result
// bytes were record_evidence, record_coverage and record_finding operations the
// host was already holding in the run's own context envelope: 56.8% of
// everything the correction rounds emitted, and nothing the host learned
// anything from.
//
// The failure mode this file exists to hold shut is the other direction. A
// round that returns less must never read as a round that discovered less —
// see TestAPartialRoundNeverLosesACarriedFinding, which is the same recorded
// episode's round 12, where the model dropped the finding it could not explain
// and the host went on refusing the completion for it, correctly.
func TestACorrectionRoundMayReturnOnlyWhatItChanges(t *testing.T) {
	corrections, run := runPartialCorrectionRounds(
		t, terraformFirstRound, terraformCorrectedFindingOnly,
	)
	if len(corrections) != 1 ||
		!strings.Contains(corrections[0], "is unexplained") {
		t.Fatalf(
			"want exactly the one earned unexplained-finding correction, got %d: %v",
			len(corrections), corrections,
		)
	}
	decision := parseStagedWatchResult(t, run)
	// The answer still goes out. A partial round carries no evidence of its
	// own, and the lifecycle policy that decides whether a successful run's
	// reply adds anything reads exactly that: before the host restored the
	// records first, this round was suppressed as adding no fresh observation
	// and the operator got silence instead of the answer.
	if decision.Action != "reply" || decision.Suppressed != "" {
		t.Fatalf(
			"a partial round was silenced: action=%q suppressed=%q",
			decision.Action, decision.Suppressed,
		)
	}
	if len(decision.Findings) != 1 || decision.Findings[0].Status != "out_of_scope" {
		t.Fatalf("the corrected finding did not settle the episode: %+v", decision.Findings)
	}
	// The three evidence rows the partial round never mentioned, by the exact
	// ids the first round recorded them under. These are what the reply cites
	// and what the ledger stores; a merge that only fed the validators would
	// leave the operator an answer whose evidence had been thrown away.
	for _, id := range []string{"evidence-infra-run", "evidence-infra-plan", "evidence-apps-run"} {
		if !hasEvidenceID(decision.Evidence, id) {
			t.Fatalf("the merged result dropped carried evidence %q: %+v", id, decision.Evidence)
		}
	}
	if len(decision.Coverage) != 1 || decision.Coverage[0].Layer != "change" {
		t.Fatalf("the merged result dropped the carried coverage: %+v", decision.Coverage)
	}
}

// The safety argument for the whole contract: what a round leaves out, the
// host still holds — including against the model.
//
// Round 12 of the recorded episode dropped the drift finding entirely rather
// than explaining it, and the host refused the completion anyway, quoting a
// finding that round had not sent. That is the behaviour to keep: a partial
// round is a smaller message, not a smaller investigation, and "I stopped
// mentioning it" is not a way to close an unexplained failure.
func TestAPartialRoundNeverLosesACarriedFinding(t *testing.T) {
	corrections, run := runPartialCorrectionRounds(
		t, terraformFirstRound, terraformCompletionOnly, terraformCorrectedFindingOnly,
	)
	if len(corrections) != 2 {
		t.Fatalf("want two corrections, got %d: %v", len(corrections), corrections)
	}
	// The decision before the plumbing: the second refusal has to be about the
	// finding the round omitted, not about the round being short.
	if !strings.Contains(corrections[1], "is unexplained") ||
		!strings.Contains(corrections[1], "121 resources changed outside Terraform") {
		t.Fatalf(
			"a round that omitted its findings was not refused for the carried one: %s",
			corrections[1],
		)
	}
	decision := parseStagedWatchResult(t, run)
	if len(decision.Findings) != 1 || decision.Findings[0].Status != "out_of_scope" {
		t.Fatalf("the finding did not survive two partial rounds: %+v", decision.Findings)
	}
	for _, id := range []string{"evidence-infra-run", "evidence-infra-plan", "evidence-apps-run"} {
		if !hasEvidenceID(decision.Evidence, id) {
			t.Fatalf("the merged result dropped carried evidence %q: %+v", id, decision.Evidence)
		}
	}
}

// Replacing a record means sending it again under the same id. There is no
// delete, and a second copy of the same record is not a second record.
func TestReSendingAnIdReplacesThatRecord(t *testing.T) {
	_, run := runPartialCorrectionRounds(
		t, terraformFirstRound, terraformCorrectedFindingOnly,
	)
	decision := parseStagedWatchResult(t, run)
	if len(decision.Findings) != 1 {
		t.Fatalf(
			"re-sending finding-drift left %d findings, not one replaced record: %+v",
			len(decision.Findings), decision.Findings,
		)
	}
	if decision.Findings[0].Status != "out_of_scope" {
		t.Fatalf("the replaced record kept the old status: %+v", decision.Findings[0])
	}
	records := 0
	for _, operation := range decision.Operations {
		switch operation.Type {
		case "record_finding":
			records++
		case "record_evidence":
			records++
		}
	}
	// Three evidence rows and one finding: the carried records are restored
	// once each, never beside a copy of themselves.
	if records != 4 {
		t.Fatalf("the merged operation stream carries %d records, want 4: %+v", records, decision.Operations)
	}
}

// A round that returns nothing at all is still refused.
//
// The partial contract says a round may leave out what it is not changing. It
// never says a round may change nothing: the completion and the reply are the
// conclusion, they are usually what the correction is about, and a round that
// returns neither has answered no question. Accepting it would let a corrected
// turn go silent — the answer the operator was waiting for replaced by the
// model declining to speak.
func TestAnEmptyCorrectionRoundIsStillRefused(t *testing.T) {
	corrections, _ := runPartialCorrectionRounds(
		t, terraformFirstRound, terraformEmptyRound, terraformCorrectedFindingOnly,
	)
	if len(corrections) != 2 {
		t.Fatalf("want two corrections, got %d: %v", len(corrections), corrections)
	}
	if !strings.Contains(corrections[1], "returned no operations") {
		t.Fatalf("an empty correction round was not refused for being empty: %s", corrections[1])
	}
}

// runPartialCorrectionRounds answers the recorded Terraform card with the given
// rounds in order and returns the corrections the host wrote and the run it
// finished with.
func runPartialCorrectionRounds(t *testing.T, rounds ...string) ([]string, core.AgentRun) {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	cfg.Limits.MaxAgentRunAttempts = 8
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}

	coopClient := newFakeCoop()
	for _, round := range rounds {
		coopClient.completeQueue = append(coopClient.completeQueue, freshenTerraformRound(round))
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	input := core.SlackInput{
		ID: "slack-run-applied", EnvelopeID: "env-run-applied", EventID: "EvRunApplied",
		Kind: "bot_message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.600", UserID: "BTERRAFORM", ReceivedAt: time.Now().UTC(),
		Text: terraformAppliedCard,
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run := core.AgentRun{}
	for round := 0; round < len(rounds)+2; round++ {
		if err := svc.processAgentRun(ctx); err != nil {
			t.Fatal(err)
		}
		svc.pollAgentRuns(ctx)
		run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if run.State != core.AgentRunPending {
			break
		}
	}
	if run.State == core.AgentRunPending {
		t.Fatalf("the correction loop never resolved: %+v", run.State)
	}
	return auditOutcomes(t, cfg, "result.correction", ""), run
}

// freshenTerraformRound re-stamps the recorded observation times onto this
// run's clock. The rounds are otherwise verbatim; only freshness, which is
// measured against wall time, would otherwise decide the test by its age.
func freshenTerraformRound(round string) string {
	now := time.Now().UTC().Add(-time.Minute).Format(time.RFC3339)
	return strings.NewReplacer(
		`"observed_at":"2026-08-16T16:57:28Z"`, `"observed_at":"`+now+`"`,
		`"observed_at":"2026-08-16T16:57:38Z"`, `"observed_at":"`+now+`"`,
		`"observed_at":"2026-08-16T16:57:39Z"`, `"observed_at":"`+now+`"`,
		`"observed_at":"2026-08-16T16:59:43Z"`, `"observed_at":"`+now+`"`,
	).Replace(round)
}

func parseStagedWatchResult(t *testing.T, run core.AgentRun) decisionpkg.WatchDecision {
	t.Helper()
	decision, err := decisionpkg.ParseWatchDecision(string(run.Result), time.Now().UTC())
	if err != nil {
		t.Fatalf("the staged result does not parse: %v\n%s", err, run.Result)
	}
	return decision
}

func hasEvidenceID(evidence []core.Evidence, id string) bool {
	for _, item := range evidence {
		if item.ID == id {
			return true
		}
	}
	return false
}
