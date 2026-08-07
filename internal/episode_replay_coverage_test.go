// Coverage ratchet for the episode replay corpus.
//
// docs/architecture-next.md forbids deleting a legacy projection until a
// fixture proves its capability still works. That rule was written in prose,
// which means it was enforced by whoever remembered it. This file enforces it:
// the capability matrix is parsed out of the document itself, so a capability
// added there with no fixture and no acknowledged gap fails the build.
//
// The gap list below is deliberately long and deliberately checked in. The
// corpus is built from sanitized dogfooding history, and history that has not
// happened yet cannot be fabricated into a fixture — a synthetic recording
// dressed up as a real one would make the cutover argument worse, not better,
// because it would look like proof. What this ratchet guarantees instead is
// that the gap is measured, visible, and can only shrink.
package internal_test

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// acknowledgedCoverageGaps are capabilities from the matrix with no replay
// fixture yet. Covering one means deleting its line here; the test fails if a
// gap is listed that is in fact covered, so the list cannot rot in the other
// direction either.
//
// Every entry needs sanitized history from a real deployment. Until that
// history exists, the honest statement is "not proven", and the phase of the
// migration that would delete this capability's legacy projection stays shut.
var acknowledgedCoverageGaps = map[string]string{
	"reactions":                                      "needs a recorded reaction-only signal",
	"attachments-and-screenshots":                    "needs a sanitized manifest recording",
	"generated-charts-and-files":                     "needs a recorded upload, including one that failed",
	"channel-setup-and-conversational-configuration": "needs a recorded wizard transcript",
	"slash-commands-and-app-home":                    "needs recorded management-view interactions",
	"durable-preferences-and-rules":                  "needs a recorded confirmed preference",
	"freeform-operator-guidance":                     "needs a recorded guidance note with provenance",
	"cross-channel-memory":                           "needs a recall pair across two channels with a privacy boundary",
	"standing-assignments":                           "needs a recorded assignment through pause and expiry",
	"incidents":                                      "needs a recorded escalation into a room",
	"incident-timeline-and-postmortem":               "needs a recorded postmortem derived from verified events",
	"engineering-changes":                            "needs a recorded writable-fork task",
	"diff-and-draft-pr-controls":                     "needs recorded revision-bound controls",
	"contextual-next-step-controls":                  "needs a recorded stale-control replacement",
	"pr-checks-merge-deployment-verification":        "needs a recorded follow-through with a missing webhook",
	"emisar-actions-and-approvals":                   "needs a recorded approval without an incident room",
	"scheduled-and-recurring-work":                   "needs a recorded schedule firing a child episode",
	"multi-repository-work":                          "needs a recorded parent episode with child goals",
	"model-choice-and-byoc":                          "needs recordings across two execution profiles",
	"cleanup":                                        "needs a recorded retention pass",
}

// capabilitySlug normalizes a matrix row or a fixture tag to one spelling.
func capabilitySlug(name string) string {
	slug := strings.ToLower(strings.TrimSpace(name))
	slug = strings.NewReplacer(
		" and ", "-and-", ", ", "-", " ", "-", "/", "-", ",", "-",
	).Replace(slug)
	return regexp.MustCompile(`-+`).ReplaceAllString(slug, "-")
}

// matrixCapabilities parses section 24's table out of the design document.
// Reading the document rather than restating it is the whole point: a
// capability added to the architecture cannot silently skip the corpus.
func matrixCapabilities(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(repoRoot(t), "docs", "architecture-next.md"))
	if err != nil {
		t.Fatal(err)
	}
	var capabilities []string
	inMatrix := false
	for _, line := range strings.Split(string(data), "\n") {
		switch {
		case strings.HasPrefix(line, "## 24. Capability preservation matrix"):
			inMatrix = true
			continue
		case inMatrix && strings.HasPrefix(line, "## "):
			inMatrix = false
		}
		if !inMatrix || !strings.HasPrefix(line, "| ") {
			continue
		}
		name := strings.TrimSpace(strings.Split(strings.TrimPrefix(line, "| "), " | ")[0])
		if name == "Capability" || strings.HasPrefix(name, "---") {
			continue
		}
		capabilities = append(capabilities, capabilitySlug(name))
	}
	if len(capabilities) == 0 {
		t.Fatal("section 24 of the design document has no capability rows; the parser has drifted")
	}
	return capabilities
}

// coveredCapabilities reads the replay corpus and returns the capabilities its
// fixtures claim, by "capability:" tag.
func coveredCapabilities(t *testing.T) map[string][]string {
	t.Helper()
	file, err := os.Open(filepath.Join(repoRoot(t), "testdata", "eval", "episode-replay.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	covered := make(map[string][]string)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), 1<<22)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		var fixture struct {
			Name string   `json:"name"`
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal([]byte(text), &fixture); err != nil {
			t.Fatalf("episode-replay.jsonl line %d: %v", line, err)
		}
		for _, tag := range fixture.Tags {
			if capability, ok := strings.CutPrefix(tag, "capability:"); ok {
				covered[capability] = append(covered[capability], fixture.Name)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	return covered
}

// Every capability is either proven by a fixture or listed as a known gap.
// Adding a capability to the matrix without doing one of the two fails here,
// which is the point: the migration document's safety rule now has teeth.
func TestEveryCapabilityIsProvenOrAcknowledged(t *testing.T) {
	covered := coveredCapabilities(t)
	var unaccounted []string
	for _, capability := range matrixCapabilities(t) {
		if len(covered[capability]) > 0 {
			continue
		}
		if _, acknowledged := acknowledgedCoverageGaps[capability]; acknowledged {
			continue
		}
		unaccounted = append(unaccounted, capability)
	}
	if len(unaccounted) > 0 {
		sort.Strings(unaccounted)
		t.Fatalf(
			"capabilities with neither a replay fixture nor an acknowledged gap: %s\n"+
				"Add a fixture to testdata/eval/episode-replay.jsonl tagged "+
				"\"capability:<slug>\", or record why it cannot be covered yet in "+
				"acknowledgedCoverageGaps.",
			strings.Join(unaccounted, ", "),
		)
	}
}

// The gap list may only shrink. A capability that has gained a fixture must
// lose its entry, or the list stops describing anything and the next reader
// cannot tell which gaps are real.
func TestAcknowledgedGapsAreStillGaps(t *testing.T) {
	covered := coveredCapabilities(t)
	matrix := make(map[string]bool)
	for _, capability := range matrixCapabilities(t) {
		matrix[capability] = true
	}
	for capability, reason := range acknowledgedCoverageGaps {
		if !matrix[capability] {
			t.Errorf(
				"acknowledged gap %q is not a capability in the matrix; the document renamed or "+
					"removed it and this entry was left behind",
				capability,
			)
		}
		if fixtures := covered[capability]; len(fixtures) > 0 {
			t.Errorf(
				"capability %q is covered by %v but is still listed as a gap (%q); delete the entry",
				capability, fixtures, reason,
			)
		}
	}
}

// A fixture may not claim a capability the matrix does not have. Without this,
// a typo in a tag reads as coverage and hides a real gap.
func TestFixturesClaimOnlyRealCapabilities(t *testing.T) {
	matrix := make(map[string]bool)
	for _, capability := range matrixCapabilities(t) {
		matrix[capability] = true
	}
	for capability, fixtures := range coveredCapabilities(t) {
		if !matrix[capability] {
			t.Errorf(
				"fixtures %v claim capability %q, which is not in the matrix in section 24",
				fixtures, capability,
			)
		}
	}
}
