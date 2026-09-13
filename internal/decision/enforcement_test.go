package decision

import (
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

func TestStandingRuleReplyDoesNotGuessTitlePresenceFromAProseSubstring(t *testing.T) {
	decision := StandingRuleIncidentAsReply(WatchDecision{
		Title:  "API",
		Reason: "A rapid outage needs investigation.",
		Memory: core.AgentMemory{Decisions: []string{
			"Customer incident response is documented in the runbook.",
		}},
	}, false)
	if !strings.HasPrefix(decision.Message, "**API**\n\n") {
		t.Fatalf("host omitted the structured title because its letters appeared inside prose: %q", decision.Message)
	}
	if !slices.Contains(decision.Memory.Decisions, "Customer incident response is documented in the runbook.") {
		t.Fatalf("host deleted an unrelated memory because its prose contained incident: %#v", decision.Memory.Decisions)
	}
}

// The host generates a recheck, marks it a conversation follow-up so the turn
// carries its thread, and tells the model to return ignore when nothing has
// changed. Validation then rejected that ignore as an unanswered operator, so
// the only way a recheck could pass was to say something — the opposite of what
// a quiet recheck is for.
// Covers finding: 20260810T203749Z-run_4a24bd58eb2ac48341340c40580aac9e
func TestWatchDecisionCorrectionAllowsSilentHostRecheck(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "recheck-1", Kind: "recheck", ChannelID: "C1",
		MessageTS: "1700.500", ReceivedAt: now,
	}
	state := WatchTurnState{ConversationFollowup: true, RecheckKey: "episode-1"}
	silent := WatchDecision{
		Action:    "ignore",
		Reason:    "the blocker and the useful result are unchanged since the last check",
		Attention: AttentionAssessment{Addressee: "responder", Urgency: 1, Confidence: 3},
	}
	if correction := WatchDecisionCorrectionAt(input, state, silent, now, nil); correction != "" {
		t.Fatalf("a silent recheck was corrected: %q", correction)
	}

	// A real conversation follow-up addressed to Ryker still has to be
	// answered. The exemption is for the timer Ryker set itself, not for
	// ignoring people.
	human := input
	human.Kind = "message"
	if correction := WatchDecisionCorrectionAt(human, state, silent, now, nil); correction == "" {
		t.Fatal("an unanswered conversation follow-up was accepted as ignore")
	}
}

// A host-generated retry for a rejected structured result is not an ordinary
// quiet recheck. Accepting ignore here abandoned the exact validation failure
// that scheduled the retry, leaving the episode blocked with no visible answer.
// Covers: TestStructuredValidationRecheckCannotSilentlyIgnoreTheRejectedResult
func TestStructuredValidationRecheckCannotSilentlyIgnoreTheRejectedResult(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "recheck-structured", Kind: "recheck", ChannelID: "C1",
		MessageTS: "1700.501", ReceivedAt: now,
	}
	state := WatchTurnState{
		ConversationFollowup: true,
		RecheckKey:           "structured:run_rejected",
		FailureDetail:        "the alert assessment omitted its evidence references",
	}
	silent := WatchDecision{
		Action: "ignore", Reason: "nothing changed",
		Attention: AttentionAssessment{
			Addressee: "responder", Urgency: 1, Confidence: 3,
		},
	}
	if correction := WatchDecisionCorrectionAt(input, state, silent, now, nil); correction == "" {
		t.Fatal("a structured-validation retry silently abandoned the rejected result")
	}
}

// One production alert inspected blitz-infra, then exposed a confirmable
// "Prepare code fix" control for blitz-rivals-scraper. The unrelated repository
// record was enough to authorize writable work, even though no source evidence
// had inspected the repository the task would change.
func TestEngineeringTaskOfferRequiresEvidenceFromItsTargetRepository(t *testing.T) {
	now := time.Date(2026, 8, 18, 15, 0, 0, 0, time.UTC)
	decision := WatchDecision{
		Action:         "reply",
		TaskRepository: "blitz-rivals-scraper",
		TaskPrompt:     "Recycle stale sessions and bound scraper concurrency.",
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "degraded",
		},
		Evidence: []core.Evidence{{
			ID: "change-repo", ClaimID: "change.recent",
			Claim:       "The candidate repository was inspected.",
			Observation: "The current checkout contains the deployment definition.",
			Relation:    "supports", SourceType: "repository", SourceName: "checkout",
			ObservedAt: now, Confidence: "high",
			Dimensions: map[string]string{
				"repository": "blitz-infra", "environment": "checkout", "revision": "c5b834f",
			},
		}},
	}
	input := core.SlackInput{Kind: "bot_message", Text: "[VA1 FIRING:1] Rivals scrape failures"}
	correction := WatchDecisionCorrectionAt(input, WatchTurnState{}, decision, now, nil)
	if !strings.Contains(correction, "target repository") {
		t.Fatalf("unrelated repository evidence authorized the task offer: %q", correction)
	}

	decision.Evidence[0].Dimensions["repository"] = "blitz-rivals-scraper"
	if correction := WatchDecisionCorrectionAt(input, WatchTurnState{}, decision, now, nil); correction != "" {
		t.Fatalf("target-repository evidence was rejected: %q", correction)
	}
}

// Better Stack reported a Flutter client failure, but the investigation only
// inspected the backend health endpoint, backend status rates, and blitz-infra.
// It then declared the client path unknowable without ever opening the source
// repository that owned that path. The repository requirement is about the
// implicated claim, not whether any repository happened to be mentioned.
func TestBoundedApplicationAlertRequiresSourceEvidenceForItsCause(t *testing.T) {
	now := time.Date(2026, 8, 21, 1, 6, 0, 0, time.UTC)
	input := core.SlackInput{
		Kind:       "bot_message",
		Text:       "New incident for Flutter · 92803b2 · valorant",
		ReceivedAt: now,
	}
	state := WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	evidence := []core.Evidence{
		{
			ID: "infra-change", ClaimID: "change.recent", Relation: "supports",
			HealthEffect: "risk", SourceType: "repository", SourceName: "blitz-infra",
			Target: "declared Valorant backend image", Observation: "The image tag changed before the alert window.",
		},
		{
			ID: "backend-health", ClaimID: "application.functional_behavior", Relation: "supports",
			HealthEffect: "none", SourceType: "emisar", SourceName: "HTTP probe",
			Target: "Valorant backend", Observation: "The backend health endpoint returns HTTP 200.", ObservedAt: now,
		},
		{
			ID: "client-errors", ClaimID: "impact.current", Relation: "contradicts",
			HealthEffect: "degraded", SourceType: "monitoring", SourceName: "Better Stack",
			Target: "Valorant Flutter client", Observation: "Flutter recorded 69 HTTP request failures.", ObservedAt: now,
		},
	}
	decision := WatchDecision{
		Action: "reply", Evidence: evidence,
		AlertAssessment: &AlertAssessment{
			Verdict: "confirmed_issue", Impact: "Flutter requests failed while the backend stayed healthy.",
			CauseStatus: "bounded", Cause: "The failed client HTTP path is not identified.",
			CauseClaimIDs:       []string{"application.functional_behavior", "impact.current"},
			EvidenceRefs:        []string{"backend-health", "client-errors"},
			ImmediateActionKind: "monitor", ImmediateAction: "Watch the client fingerprint.",
			Verification: "Confirm the client errors stop.", LongTermSolution: "Record the failed URL in client telemetry.",
			Scope: &OperationalScope{
				Status: "bounded", CheckedTargets: []string{"Valorant backend", "Valorant Flutter client"},
				UnverifiedTargets: []string{"failed Flutter request path"},
				EvidenceRefs:      []string{"backend-health", "client-errors"},
			},
		},
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "degraded", Summary: "The client alert is real.",
		},
	}
	correction := AlertAssessmentCorrection(input, state, decision, now)
	if !strings.Contains(correction, "source repository") ||
		!strings.Contains(correction, "application.functional_behavior") {
		t.Fatalf("an infrastructure checkout stood in for the unexplored client source: %q", correction)
	}
	blocked := decision
	blocked.Completion = &investigation.CompletionAssessment{
		Status: "blocked", Summary: "The configured checkout does not contain the Flutter client.",
		MaterialGaps: []string{"The owning client source is unavailable."},
		Attempts:     []string{"Searched every configured repository for the client wrapper."},
		NextAction:   "Configure the owning Flutter repository.",
	}
	if correction := AlertAssessmentCorrection(input, state, blocked, now); strings.Contains(correction, "source repository") {
		t.Fatalf("an exact source-access blocker was forced back into investigation: %q", correction)
	}

	decision.Evidence = append(decision.Evidence, core.Evidence{
		ID: "client-source", ClaimID: "application.functional_behavior", Relation: "supports",
		HealthEffect: "unknown", SourceType: "repository", SourceName: "blitz-flutter HTTP client",
		Target: "Valorant Flutter client", Observation: "The client wrapper records a generic error without the failed URL.",
	})
	decision.AlertAssessment.EvidenceRefs = append(decision.AlertAssessment.EvidenceRefs, "client-source")
	if correction := AlertAssessmentCorrection(input, state, decision, now); correction != "" {
		t.Fatalf("source evidence for the implicated application claim was rejected: %q", correction)
	}
}

// A later point probe and a shorter log query are useful current evidence, but
// they do not disprove a firing alert over a different window and population.
// The match is carried in typed dimensions; no alert or result prose is parsed.
// Covers finding: 20260814T035709Z-run_5f96f5d4b8d800f69374d2987f574d26
func TestFiringAlertCannotBeDismissedByAnIncompatibleEvidenceWindow(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		Kind: "bot_message", ReceivedAt: now,
		Text: "[VA1 FIRING:1] Two-hour application error count exceeded 10000000",
	}
	state := WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	evidence := []core.Evidence{
		{ID: "repo", ClaimID: "change.recent", Relation: "supports", SourceType: "repository", SourceName: "blitz repository", Observation: "The route exists."},
		{ID: "probe", ClaimID: "application.functional_behavior", Relation: "supports", HealthEffect: "none", SourceType: "monitoring", SourceName: "HTTP probe", Observation: "A later request returned 200.", Target: "App_svelte", ObservedAt: now, Dimensions: map[string]string{"service": "App_svelte", "indicator": "http_status", "window": "point-in-time", "population": "one synthetic request"}},
		{ID: "logs", ClaimID: "impact.current", Relation: "supports", HealthEffect: "none", SourceType: "monitoring", SourceName: "VictoriaLogs", Observation: "A different 15-minute query found no matching rows.", Target: "App_svelte", ObservedAt: now, Dimensions: map[string]string{"service": "App_svelte", "indicator": "log_matches", "window": "15m", "population": "selected log messages"}},
	}
	decision := WatchDecision{
		Action: "reply", Evidence: evidence,
		AlertAssessment: &AlertAssessment{
			Verdict: "not_issue", Impact: "The historical count is not credible.",
			EvidenceRefs:        []string{"probe", "logs"},
			ImmediateActionKind: "monitor",
			Scope: &OperationalScope{
				Status: "bounded", CheckedTargets: []string{"App_svelte"},
				UnverifiedTargets: []string{"the alerted two-hour population"},
				EvidenceRefs:      []string{"probe", "logs"},
			},
		},
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "healthy", Summary: "Dismissed the alert.",
		},
	}
	correction := WatchDecisionCorrectionAt(input, state, decision, now, nil)
	if !strings.Contains(correction, "still firing") {
		t.Fatalf("incompatible windows dismissed a firing alert: %q", correction)
	}
}

// The result is untrusted. Calling its own shorter query an exact match cannot
// overrule the host-owned fact that the Grafana condition is still firing.
// The production guard accepted these five nonempty strings as proof without
// comparing any of them with the alert card.
func TestFiringAlertCannotDismissItselfWithModelAttestedExactDimensions(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		Kind: "bot_message", ReceivedAt: now,
		Text: "[VA1 FIRING:1] Two-hour application error count exceeded 10000000",
	}
	state := WatchTurnState{MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	decision := WatchDecision{
		Action: "reply",
		Evidence: []core.Evidence{
			{ID: "repo", ClaimID: "change.recent", Relation: "supports", SourceType: "repository", SourceName: "blitz repository", Observation: "The route exists."},
			{
				ID: "self-attested", ClaimID: "impact.current", Relation: "supports",
				HealthEffect: "none", SourceType: "monitoring", SourceName: "short query",
				Observation: "A different 15-minute query found no rows.", Target: "App_svelte",
				ObservedAt: now, Dimensions: map[string]string{
					"condition_match": "exact", "indicator": "log_matches", "window": "15m",
					"population": "selected logs", "denominator": "selected logs",
				},
			},
		},
		AlertAssessment: &AlertAssessment{
			Verdict: "not_issue", Impact: "The alert is not credible.",
			EvidenceRefs: []string{"self-attested"}, ImmediateActionKind: "monitor",
			Scope: &OperationalScope{
				Status: "bounded", CheckedTargets: []string{"App_svelte"},
				UnverifiedTargets: []string{"the alerted two-hour population"},
				EvidenceRefs:      []string{"self-attested"},
			},
		},
		Completion: &investigation.CompletionAssessment{
			Status: "decision_ready", Verdict: "healthy", Summary: "Dismissed the alert.",
		},
	}
	if correction := WatchDecisionCorrectionAt(input, state, decision, now, nil); !strings.Contains(correction, "still firing") {
		t.Fatalf("model-authored exact dimensions dismissed a firing alert: %q", correction)
	}
}

// A resolution notification confirms an incident happened. It is not evidence
// that the problem is still happening, and the two were conflated: the recovery
// check only ever ran when the model had already said not_issue, so a
// confirmed_issue verdict on a cleared alert went straight through and
// Ryker recommended halting a rollout for a condition that had recovered.
// Covers: TestResolvedAlertRejectsActiveAssessmentWithHealthyCompletion
// Covers: TestResolvedAlertRejectsHistoricalWindowAsCurrentDegradation
// Covers: TestRecoveredAlertCannotBeKeptDegradedByUnrelatedFreshFailure
// Covers finding: 20260810T174527Z-run_b9de8df304246d7931ce96f9520e24a7
// Covers finding: 20260811T033054Z-run_0568ada64142416024262416cd646afa
// Covers finding: 20260812T064909Z-run_04abca0ef360818547439d6c1700807a
// Covers finding: 20260812T164616Z-run_40431d35113ac3726dfb18c469838e15
// Covers finding: 20260816T184357Z-run_ce80c26e8af15a710cdaf9f5fd813e88
func TestResolvedAlertCannotClaimActiveDegradationWithoutSeeingIt(t *testing.T) {
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		ID: "alert-resolved", Kind: "bot_message", ChannelID: "C1", ReceivedAt: now,
		Text: "[RESOLVED] HostOutOfMemory\nStatus: resolved\nalertname = HostOutOfMemory",
	}
	state := WatchTurnState{AlertPolicy: "automatic", MatchedRules: []core.StandingRule{{
		Trigger: "operational_alert", Action: "triage_alert",
	}}}
	// Retrieved a moment ago and describing the incident, not the present.
	historical := []core.Evidence{
		{
			ID: "evidence-host", ClaimID: "host.current_state",
			Observation: "The host reported memory pressure during the window.",
			SourceType:  "monitoring", SourceName: "grafana", Relation: "supports",
			HealthEffect: "none", ObservedAt: now.Add(-2 * time.Minute),
		},
		{
			ClaimID: "change.recent", Observation: "The rollout revision is unchanged.",
			SourceType: "repository", SourceName: "blitz-infra", Relation: "supports",
			HealthEffect: "none", ObservedAt: now.Add(-2 * time.Minute),
		},
	}
	claiming := WatchDecision{
		Action: "reply", Message: "Memory pressure is ongoing; hold the rollout.",
		Evidence: historical,
		AlertAssessment: &AlertAssessment{
			Verdict: "confirmed_issue", Impact: "degraded",
			Cause: "a leak in the new revision", CauseStatus: "identified",
			CauseClaimIDs:   []string{"host.current_state"},
			EvidenceRefs:    []string{"evidence-host"},
			ImmediateAction: "stop the rollout", LongTermSolution: "fix the leak",
			Verification: "watch memory after the fix",
		},
	}
	correction := AlertAssessmentCorrection(input, state, claiming, now)
	if correction == "" || !strings.Contains(correction, "already cleared") {
		t.Fatalf("a resolved alert claimed active degradation unchallenged: %q", correction)
	}

	// A fresh degraded observation about another service cannot keep this
	// resolved memory alert open. It is useful context, but the assessment did
	// not cite it and it says nothing about the exact condition that recovered.
	unrelated := claiming
	unrelated.Evidence = append(append([]core.Evidence{}, historical...), core.Evidence{
		ID: "evidence-rivals", ClaimID: "rivals.current_state",
		Observation: "Rivals requests are still timing out now.",
		SourceType:  "emisar", SourceName: "host-probe", Relation: "supports",
		HealthEffect: "degraded", ObservedAt: now.Add(-1 * time.Minute),
	})
	if correction := AlertAssessmentCorrection(input, state, unrelated, now); !strings.Contains(
		correction, "already cleared",
	) {
		t.Fatalf("unrelated degraded evidence kept a resolved alert active: %q", correction)
	}

	// An observation that actually finds the cited failure still present
	// carries the claim. Freshness says when Ryker looked; the health effect
	// says what it saw, and the assessment link says which alert it supports.
	seen := claiming
	assessment := *claiming.AlertAssessment
	assessment.EvidenceRefs = append(assessment.EvidenceRefs, "evidence-host-live")
	seen.AlertAssessment = &assessment
	seen.Evidence = append(append([]core.Evidence{}, historical...), core.Evidence{
		ID: "evidence-host-live", ClaimID: "host.current_state",
		Observation: "Memory is still above the threshold now.",
		SourceType:  "emisar", SourceName: "host-probe", Relation: "supports",
		HealthEffect: "degraded", ObservedAt: now.Add(-1 * time.Minute),
	})
	if correction := AlertAssessmentCorrection(input, state, seen, now); strings.Contains(
		correction, "already cleared",
	) {
		t.Fatalf("a verified ongoing failure was rejected as cleared: %q", correction)
	}
}

// An active-alert update is as long as its delta. The prompt asked for "two
// short paragraphs under 100 words" while this checker rejected anything over
// 90, so a model obeying the instruction it was given was still sent back.
// Eight rounds and ~$3.60 on 2026-08-16 to trim an update from 98 words to 80
// while the prompt said "under 100" — fourteen minutes of an active alert spent
// on ten words that changed nothing an operator would act on, across updates of
// 98, 91, 96, 98 and 94 words. Length alone corrects nothing here now; the
// prompt asks for concision, and internal/replypolicy.ReplyWordBudget still
// catches an answer that blows the corpus budget several times over.
func TestActiveAlertUpdateIsNotCorrectedForLength(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 FIRING:1] WARNING | Cassandra repair overdue",
	}
	// 140 words of plain operational English: no banned opener, no typed
	// verdict label, no acknowledgement narration, no monitoring shorthand, and
	// one implementation term at most.
	update := "**`sts_ks` repair is behind schedule.** Its last finished cycle was " +
		"5.6 days ago, past the five-day interval plus grace, so the overdue gauge " +
		"is up. The repair now running moved from 73.10% to 74.62% during this " +
		"check, so it is slow rather than stuck, and customer traffic " +
		"shows no error spike in the last hour. All three database nodes answer " +
		"normally with no sign of data loss.\n\n" +
		"This matches the known slow-repair problem the team hit last month, and " +
		"the 5.0.0 upgrade that fixes it is already rolling out to this region " +
		"tonight. Nothing needs a hand right now: starting a second repair would " +
		"only make it slower. Let the running cycle finish. Success is progress " +
		"reaching 100% and the overdue gauge going back to zero, and I will look " +
		"again once the upgrade lands and report what I find."
	if words := len(strings.Fields(update)); words != 140 {
		t.Fatalf("the fixture is meant to be 140 words, got %d", words)
	}
	decision := WatchDecision{Action: "reply", Message: update}
	if correction := AlertReplyLanguageCorrectionWithContext(
		input, WatchTurnState{}, decision,
	); correction != "" {
		t.Fatalf("a plain 140-word active-alert update was corrected for length: %q", correction)
	}
}

// The same rule on the recovery side, which rejected a closure over 60 words:
// a recovery with anything worth saying about what completed paid a correction
// round for saying it. The link rule is the one that survives — a closure still
// has to point at the message it closes — so this fixture leaves
// state.RecentMessages empty, which is the only way to prove that length alone
// corrects nothing.
func TestRecoveredAlertClosureIsNotCorrectedForLength(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:1] WARNING | Cassandra repair overdue",
	}
	closure := "**`sts_ks` is fully repaired.** The cycle that was running when this " +
		"fired reached 100% about twenty minutes ago, the overdue gauge is back to " +
		"zero, and the completion-age metric reset with it, so the condition that " +
		"opened this alert is genuinely gone rather than merely unwatched.\n\n" +
		"The whole cycle took a little over six days against a five-day cadence " +
		"target, which is why the overdue check tripped, and the 5.0.0 upgrade " +
		"rolling out this week is the fix for exactly that slowness. Nothing " +
		"needs to be done right now. If the next cycle " +
		"also runs long after that upgrade lands, the cadence itself is worth a " +
		"second look, and I will say so then rather than guess at it today."
	if words := len(strings.Fields(closure)); words != 120 {
		t.Fatalf("the fixture is meant to be 120 words, got %d", words)
	}
	decision := WatchDecision{
		Action:          "reply",
		Message:         closure,
		AlertAssessment: &AlertAssessment{Verdict: "not_issue"},
	}
	if correction := AlertReplyLanguageCorrectionWithContext(
		input, WatchTurnState{}, decision,
	); correction != "" {
		t.Fatalf("a plain 120-word recovery closure was corrected for length: %q", correction)
	}
}

// Five posts on 2026-08-16; the model was told to stay silent unless something
// changed and the host forbade it.
//
// One Grafana stream oscillating around a memory threshold produced seven cards
// in ninety minutes. The prompt says "stay silent unless you add a newly
// verified consequence, problem, or next action", and this correction rejected
// every ignore whose card mentioned firing, warning or failed — so a flapping
// alert was guaranteed one post per card no matter what the model decided. Two
// of the five said only that a node had crossed back over the same line.
//
// The state is the whole fix: an answer already posted on this stream is what
// makes silence legitimate, and the correction could not see it.
func TestRepeatFiringOnAnAnsweredStreamMayStaySilent(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 FIRING:3] WARNING | Traefik memory above 95 percent",
	}
	answered := WatchTurnState{
		AlertPolicy:           "reply",
		StreamAnsweredAt:      "2026-08-16T14:51:00Z",
		StreamAnsweredVerdict: "confirmed_issue",
		StreamAnsweredAction:  "Raise the memory cap and roll the job.",
	}
	silent := WatchDecision{
		Action: "ignore",
		Reason: "this card restates the condition already answered in this thread",
	}
	if correction := AlertPolicyCorrection(input, answered, silent); correction != "" {
		t.Fatalf("a repeat card on an answered stream was forced to post: %q", correction)
	}
}

// The other half of the same rule, which must not move: the FIRST card of a
// stream has no earlier answer, so an ignore there is an alert nobody looked
// at. Without this the fix above reads as "alerts may be ignored".
func TestFirstFiringStillRequiresAnAnswer(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 FIRING:1] WARNING | Traefik memory above 95 percent",
	}
	silent := WatchDecision{Action: "ignore", Reason: "nothing to add"}
	correction := AlertPolicyCorrection(input, WatchTurnState{AlertPolicy: "reply"}, silent)
	if !strings.Contains(correction, "requires an evidence-backed in-place") {
		t.Fatalf("the first firing card was allowed to pass unanswered: %q", correction)
	}
}

// A resolve is not a repeat. A stream answered while it was firing still owes
// the channel a closure when it recovers, so the answered state must not let a
// recovery card be ignored.
func TestRecoveryOnAnAnsweredStreamStillRequiresAnAnswer(t *testing.T) {
	input := core.SlackInput{
		Kind: "bot_message",
		Text: "[VA1 RESOLVED:3] WARNING | Traefik memory back under 95 percent",
	}
	answered := WatchTurnState{
		AlertPolicy:           "reply",
		StreamAnsweredAt:      "2026-08-16T14:51:00Z",
		StreamAnsweredVerdict: "confirmed_issue",
		StreamAnsweredAction:  "Raise the memory cap and roll the job.",
	}
	silent := WatchDecision{Action: "ignore", Reason: "already answered"}
	correction := AlertPolicyCorrection(input, answered, silent)
	if !strings.Contains(correction, "requires an evidence-backed in-place") {
		t.Fatalf("a recovery on an answered stream was allowed to pass silently: %q", correction)
	}
}

// terraformRunApplied is the recorded model answer to the Terraform Cloud card
// whose last line is `Run Applied`, harvested whole out of the eval corpus case
// "terminal app event carries a completion verdict": a reply carrying apply
// evidence, runner evidence, change coverage, and a decision_ready
// complete_episode whose verdict is succeeded.
func terraformRunApplied(t *testing.T) WatchDecision {
	t.Helper()
	data, err := os.ReadFile("testdata/terraform_run_applied_result.txt")
	if err != nil {
		t.Fatal(err)
	}
	decision, err := ParseWatchDecision(
		string(data), time.Date(2026, 8, 16, 18, 55, 0, 0, time.UTC),
	)
	if err != nil {
		t.Fatal(err)
	}
	return decision
}

// terraformRunAppliedCard is the corpus case's own input: an external app
// message on a channel whose alert policy is anything but automatic.
func terraformRunAppliedCard() core.SlackInput {
	return core.SlackInput{
		Kind: "bot_message",
		Text: "Run notification for <https://app.terraform.io/app/Dryga/emisar|Dryga/emisar>\n" +
			"<https://app.terraform.io/app/Dryga/emisar/runs/run-nyi5FEjCdPDiXTdH|Run run-nyi5FEjCdPDiXTdH>\n" +
			"main 3d794f517e6848d43f8563125b501675606d8ed5 (@AndrewDryga, gh run 31745692023)\n" +
			"Run Applied",
	}
}

// Success is a decision to record, not just news to relay.
//
// The "terminal app event carries a completion verdict" corpus case has failed
// since 2026-08-15 with "completion assessment is missing"; the host had a
// correction for it that only knew the failure vocabulary.
// ExternalAppEventRequiresDecision matched errored, failed, failure, firing,
// critical and warning, so a terminal APPLY — the most common terminal card
// Ryker sees — was the one terminal event whose reply could be posted with
// no verdict behind it at all, and production posted them.
func TestAReplyToATerminalSuccessEventCarriesACompletion(t *testing.T) {
	input := terraformRunAppliedCard()
	state := WatchTurnState{AlertPolicy: "reply"}
	decision := terraformRunApplied(t)
	if decision.Action != "reply" {
		t.Fatalf("the harvested answer is meant to be a reply, got %q", decision.Action)
	}
	if decision.Completion == nil || decision.Completion.Verdict != "succeeded" {
		t.Fatalf("the harvested answer is meant to carry a succeeded verdict, got %+v",
			decision.Completion)
	}

	// What production posted: the same reply, the same evidence, and nothing
	// completing the episode behind it.
	withoutCompletion := decision
	withoutCompletion.Completion = nil
	correction := AlertPolicyCorrection(input, state, withoutCompletion)
	if !strings.Contains(correction, "no completion verdict") {
		t.Fatalf("a reply to `Run Applied` was allowed to finish with no verdict: %q", correction)
	}

	if correction := AlertPolicyCorrection(input, state, decision); correction != "" {
		t.Fatalf("the harvested decision_ready completion was corrected anyway: %q", correction)
	}
}

// The reply is what owes a verdict, not the card that owes a reply.
//
// A routine success is the thing the reply policy tells the model to stay quiet
// about, so forcing a post on every applied run would trade this defect for the
// flapping-alert defect above — five posts in ninety minutes for one unchanged
// assessment. Only a terminal success the model CHOSE to answer must complete.
func TestATerminalSuccessEventMayStillBeIgnored(t *testing.T) {
	input := terraformRunAppliedCard()
	state := WatchTurnState{AlertPolicy: "reply"}
	silent := WatchDecision{
		Action: "ignore",
		Reason: "the apply is routine and the card already says so",
	}
	if correction := AlertPolicyCorrection(input, state, silent); correction != "" {
		t.Fatalf("a routine applied run was forced into a post: %q", correction)
	}
}
