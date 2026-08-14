package investigation

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// The correction used to be the claim id and nothing else, so the model was
// told two of its own observations conflicted and not which two. It had to
// guess which one to supersede, and guessing wrong cost a whole turn — thirty
// of these in two days, on episodes that then spent every attempt they had.
func TestContradictionCorrectionNamesWhatDisagrees(t *testing.T) {
	now := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	view := ClaimView{
		Requirement: ClaimRequirement{ID: "change.recent", Layer: "change", Required: true},
		State:       ClaimMixed,
		Evidence: []core.Evidence{{
			Observation: "The deployed revision matches the requested one.",
			SourceName:  "tenant-infra", ObservedAt: now.Add(-2 * time.Minute),
		}},
		Contradictions: []core.Evidence{{
			Observation: "The running pods still report the previous revision.",
			SourceName:  "emisar", ObservedAt: now.Add(-30 * time.Minute),
		}},
	}
	detail := contradictionDetail(view)
	for _, want := range []string{
		"change.recent", "deployed revision matches", "contradicted by",
		"still report the previous revision", "emisar",
	} {
		if !strings.Contains(detail, want) {
			t.Fatalf("contradiction detail %q does not name %q", detail, want)
		}
	}

	// With nothing recorded to quote, it falls back to the claim id rather than
	// producing a sentence with a hole in it.
	bare := ClaimView{Requirement: ClaimRequirement{ID: "slo.error_budget"}, State: ClaimMixed}
	if got := contradictionDetail(bare); got != "slo.error_budget" {
		t.Fatalf("bare contradiction detail = %q, want the claim id alone", got)
	}
}

// Evidence may legally carry dimensions and no observation prose, and a
// contradiction set made only of such records rendered as nothing: a live
// tenant correction on 2026-08-14 read "host.current_state (nomad-hst01 through
// nomad-hst05 returned fresh snapshots… — contradicted by: )", which told the
// model to reconcile a contradiction the host never named. There is no reply
// that satisfies that; the episode spent its attempts against an empty clause.
func TestAContradictionWithoutProseStillGetsNamed(t *testing.T) {
	now := time.Date(2026, 8, 14, 19, 55, 0, 0, time.UTC)
	view := ClaimView{
		Requirement: ClaimRequirement{ID: "host.current_state", Layer: "host", Required: true},
		State:       ClaimMixed,
		Evidence: []core.Evidence{{
			Observation: "nomad-hst01 through nomad-hst05 returned fresh snapshots.",
			SourceName:  "Emisar five-host load and memory snapshot",
			ObservedAt:  now.Add(-time.Minute),
		}},
		Contradictions: []core.Evidence{{
			// No observation prose — dimensions-only, as ValidateEvidence allows.
			SourceName: "nomad node status",
			Dimensions: map[string]string{"host": "nomad-hst03", "state": "draining"},
			ObservedAt: now.Add(-2 * time.Minute),
		}},
	}
	detail := contradictionDetail(view)
	if strings.Contains(detail, "contradicted by: )") ||
		strings.HasSuffix(strings.TrimSpace(detail), "contradicted by:") {
		t.Fatalf("the contradiction clause is still empty: %q", detail)
	}
	for _, want := range []string{"host.current_state", "nomad node status", "host=nomad-hst03"} {
		if !strings.Contains(detail, want) {
			t.Fatalf("contradiction detail %q does not name %q", detail, want)
		}
	}
}
