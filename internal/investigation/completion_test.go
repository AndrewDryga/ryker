package investigation

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
)

// A missing runbook is a reproducibility gap, not a blocker.
//
// The contract has said so in prose for a long time and the model ignored it.
// Asked for a scheduled platform health verdict it looked up one published
// runbook, got runbook_not_found from Emisar — correctly; there are no
// published runbooks at all — and returned "blocked" with that as its only
// material gap, never touching the underlying read-only tools. The quality
// judge scored that answer 3.33 for "fails the central request to reach a
// current verdict after exhausting equivalent read-only evidence routes".
func TestAMissingRunbookIsNotABlockerOnItsOwn(t *testing.T) {
	blockedOnTheRunbook := &CompletionAssessment{
		Status: "blocked", Summary: "cannot run the review",
		MaterialGaps: []string{
			"Published runbook deep-infrastructure-health-review-va1 was not found in the Emisar catalog",
		},
		BlockerKind: "source_unavailable",
		Attempts:    []string{"looked up the published runbook"},
		NextAction:  "publish the runbook",
	}
	err := validateBlockedCompletion(blockedOnTheRunbook)
	if err == nil {
		t.Fatal("a missing runbook was accepted as the whole blocker")
	}
	if !strings.Contains(err.Error(), "equivalent read-only checks") {
		t.Errorf("the refusal does not say what to do instead: %v", err)
	}

	// The underlying evidence genuinely being unavailable is a real blocker,
	// and it keeps its block even when a runbook is missing alongside.
	alsoMissingEvidence := &CompletionAssessment{
		Status: "blocked", Summary: "cannot reach the cluster",
		MaterialGaps: []string{
			"Published runbook deep-infrastructure-health-review-va1 was not found",
			"Prometheus is unreachable, so no current service indicator can be read",
		},
		BlockerKind: "source_unavailable",
		Attempts:    []string{"queried Prometheus directly", "looked up the runbook"},
		NextAction:  "restore Prometheus access",
	}
	if err := validateBlockedCompletion(alsoMissingEvidence); err != nil {
		t.Fatalf("a real evidence blocker was refused: %v", err)
	}
}

// A bounded unknown recorded beneath a verdict it cannot reverse keeps the
// completion decision-ready.
//
// The contract asks for exactly this, twice: "preserve bounded unknowns beneath
// it" in the operational-health guidance, and "a fresh degraded or unhealthy
// result may remain decision-ready when secondary coverage is explicitly
// unknown but cannot reverse that negative verdict. Preserve the bounded
// unknown beneath the result". material_gaps is the only list-shaped field a
// completion has, so that is where the model put them — and the host threw the
// whole envelope away with "decision-ready completion cannot contain material
// gaps", losing the reply, the memory, the evidence and every offer with it.
// Nine of these across the two live instances, the last on 2026-08-14.
//
// Both completions below are harvested whole from blitz coop turns
// a3203cffdb219df26aed8c858a16f806 and e20852f570c927eee7b996f458f55493. The
// first is the shape the contract licenses; the second is the one it does not,
// and it stays refused — a gap under a healthy verdict is the unsupported
// success claim this rule exists to stop.
func TestABoundedUnknownUnderAVerdictItCannotReverseStaysDecisionReady(t *testing.T) {
	degraded := &CompletionAssessment{
		Status: "decision_ready", Verdict: "degraded",
		Summary: "This RESOLVED notice was premature: the alert cleared at 18:13:50 because its " +
			"10-minute window rolled past the last kill, but data-api was still serving nothing " +
			"and was killed again at 18:27:50.",
		MaterialGaps: []string{
			"data-api's true peak RSS is unknown because the 10 GiB cgroup limit truncated the spike before it topped out.",
			"The share of end users served from BunnyCDN cache during the data-api gap was not measured, so user impact is bounded by the observed ingress 502s rather than fully quantified.",
			"The specific query or refresh path that allocates the extra ~4 GiB has not been isolated; LOG_LEVEL is set to warning, so application logs did not name it.",
		},
	}
	if err := ValidateCompletion(degraded); err != nil {
		t.Fatalf("a bounded unknown under a degraded verdict was refused: %v", err)
	}

	// The second validator has to agree, or the answer survives the envelope
	// check only to be sent back by the correction loop for the same reason.
	episode := core.WorkEpisode{
		Effort:           core.EffortOperationalAssessment,
		Objective:        "is data-api healthy",
		RequiredCoverage: []string{"workload", "application"},
	}
	coverage := []core.Coverage{
		{Layer: "workload", Status: "degraded", Detail: "data-api was OOM-killed three times against its 10 GiB limit."},
		{Layer: "application", Status: "degraded", Detail: "data-api served nothing for roughly 28 minutes."},
	}
	if got := CompletionCorrection(episode, "reply", coverage, degraded); got != "" {
		t.Fatalf("the correction loop refused what the envelope accepted: %q", got)
	}
}

// A gap under a verdict a gap could reverse is still refused, and the refusal
// names both ways out.
//
// "decision-ready completion cannot contain material gaps" reads as "never put
// anything here", so the model's next move is to blank the field or to switch a
// sound answer to blocked. Neither is what the contract wants. The fork is: a
// gap that can change the verdict makes the result blocked or lowers the
// verdict, and one that cannot belongs beneath the result in the message.
func TestAGapUnderAVerdictItCouldReverseIsRefusedWithBothWaysOut(t *testing.T) {
	// Harvested from blitz coop turn e20852f570c927eee7b996f458f55493: a
	// healthy verdict on a recovered outage, carrying the unverified trigger as
	// a material gap.
	healthy := &CompletionAssessment{
		Status: "decision_ready", Verdict: "healthy",
		Summary: "The Data API 404 was a real 36-minute total outage of data.v2.iesdev.com at the " +
			"VA1 edge, and it has genuinely recovered, verified end to end through CDN, VA1 " +
			"origin, and three representative query paths.",
		MaterialGaps: []string{
			"The specific VA1 event that removed both data-api allocations at 17:04 UTC is unverified: no Emisar MCP tool was exposed in this turn, and Grafana is reachable only on the tailnet, so Nomad allocation history and Reaper progress could not be inspected.",
		},
	}
	err := ValidateCompletion(healthy)
	if err == nil {
		t.Fatal("a material gap under a healthy verdict was accepted as decision-ready")
	}
	for _, want := range []string{"blocked", "material_gaps", "message"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not name %q, so it says only what not to do: %v", want, err)
		}
	}

	// No verdict at all is the same refusal: there is nothing a gap cannot
	// reverse when nothing was concluded.
	if err := ValidateCompletion(&CompletionAssessment{
		Status: "decision_ready", Summary: "Healthy", MaterialGaps: []string{"database"},
	}); err == nil {
		t.Fatal("a material gap with no verdict was accepted as decision-ready")
	}
}

// direct_answer — "what is the disk usage on nomad-hvn03" — defines no
// verdicts, because answering a question is not reaching a verdict. The
// mismatch branch fired anyway and told the model its verdict did not match
// the contract and to "use one of:" followed by nothing at all. There was no
// reply it could have written that would pass: fifty-three corrections across
// eight episodes, every one unanswerable.
func TestNoVerdictContractTellsTheModelToOmitIt(t *testing.T) {
	episode := core.WorkEpisode{Objective: "what is the disk usage on nomad-hvn03"}
	contract := Compile(episode)
	if len(contract.Completion.AllowedVerdicts) != 0 {
		t.Skip("this conclusion kind now defines verdicts; the deadlock cannot arise")
	}
	correction := CompletionCorrection(episode, "reply", nil, &CompletionAssessment{
		Status: "decision_ready", Verdict: "degraded", Summary: "The disk is at 82%.",
	})
	if correction == "" {
		t.Fatal("a verdict on a no-verdict contract was accepted")
	}
	if strings.Contains(correction, "use one of: \n") || strings.HasSuffix(correction, "use one of: ") {
		t.Fatalf("the correction offers an empty list of verdicts: %q", correction)
	}
	if !strings.Contains(correction, "omit completion.verdict") {
		t.Fatalf("the correction does not say what to do instead: %q", correction)
	}

	// Omitting it is accepted, so the instruction is one the model can follow.
	if correction := CompletionCorrection(episode, "reply", nil, &CompletionAssessment{
		Status: "decision_ready", Summary: "The disk is at 82%.",
	}); correction != "" {
		t.Fatalf("omitting the verdict was still corrected: %q", correction)
	}
}

// A pack the evidence names in its own identifier is a pack the evidence names.
//
// The rule is real: a capability gap that asserts "pack linux-core is not
// advertised" must rest on an observation of that pack, or it is a guess in the
// shape of a finding. But it only ever read the evidence's PROSE, and the model
// puts a catalog entry's identity where a catalog entry's identity goes — the
// source_id, `linux.disk_usage@linux-core-0.4.1`. So the same answer passed or
// failed on whether the sentence happened to repeat the pack name: three smoke
// runs passed, and on 2026-08-16 two consecutive runs failed on different cases,
// each one a well-formed capability gap whose evidence identified the pack
// exactly where an identifier belongs.
func TestAPackNamedInItsEvidenceIdentifierIsIdentified(t *testing.T) {
	data, err := os.ReadFile("testdata/smoke_capability_gap_pack_in_id.json")
	if err != nil {
		t.Fatal(err)
	}
	// The recorded answer opens with a sentence of prose before its envelope,
	// which is exactly what the host's own parser recovers from, so the fixture
	// stays byte-for-byte what the model sent.
	start := strings.Index(string(data), "{")
	if start < 0 {
		t.Fatal("the harvested answer carries no envelope")
	}
	var envelope struct {
		Operations []ResultOperation `json:"operations"`
	}
	if err := json.Unmarshal(data[start:], &envelope); err != nil {
		t.Fatal(err)
	}
	var completion *CompletionAssessment
	evidence := make([]core.Evidence, 0, len(envelope.Operations))
	for _, operation := range envelope.Operations {
		switch operation.Type {
		case "record_evidence":
			item := *operation.Evidence
			if item.ID == "" {
				item.ID = operation.ID
			}
			evidence = append(evidence, item)
		case "complete_episode":
			completion = operation.Completion.Completion
		}
	}
	if completion == nil || len(completion.CapabilityGaps) != 1 {
		t.Fatalf("the harvested answer is meant to carry one capability gap: %+v", completion)
	}
	gap := completion.CapabilityGaps[0]
	if gap.PackID != "linux-core" {
		t.Fatalf("harvested pack id = %q", gap.PackID)
	}
	// The claim it was judged on says nothing about the pack; the source_id it
	// cites says everything.
	if err := ValidateCapabilityGapEvidence(completion, evidence); err != nil {
		t.Fatalf("a pack identified by its evidence's own identifier was refused: %v", err)
	}
}

// And the rule still holds where it should: a gap naming a pack no cited
// evidence mentions anywhere — prose, identifier or source — is still a guess.
func TestAPackNoEvidenceMentionsIsStillRefused(t *testing.T) {
	evidence := []core.Evidence{{
		ID: "evidence-runners", SourceType: "emisar",
		SourceID: "emisar-list-runners", SourceName: "Emisar runner inventory",
		Claim: "The runner inventory was read.", Observation: "Two runners answered.",
	}}
	completion := &CompletionAssessment{
		Status: "blocked",
		CapabilityGaps: []CapabilityGap{{
			Capability: "Read filesystem usage", Status: "not_advertised",
			PackID: "linux-core", EvidenceRefs: []string{"evidence-runners"},
			Recommendation: "Deploy the pack.",
		}},
	}
	if err := ValidateCapabilityGapEvidence(completion, evidence); err == nil {
		t.Fatal("a pack no evidence mentions at all was accepted")
	}
}
