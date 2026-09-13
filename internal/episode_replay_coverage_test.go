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
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/core"
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
	"app-home-and-the-web-control-plane":             "needs recorded management-view interactions",
	"durable-preferences-and-rules":                  "needs a recorded confirmed preference",
	"freeform-operator-guidance":                     "needs a recorded guidance note with provenance",
	"cross-channel-memory":                           "needs a recall pair across two channels with a privacy boundary",
	// Still a gap on purpose, and now for a different reason. Until 2026-08-15
	// there was no way to create a standing assignment at all: both deployments
	// held zero rows, so no episode had ever exercised one and no fixture could
	// be harvested from history that did not exist. The creation path and the
	// shadow ledger land in that commit, and the evaluation is appended to the
	// episode's own event stream — which is the only thing record-episode
	// reads — so the recording is possible now rather than merely wanted.
	// It stays listed because fixtures are harvested and not invented: this
	// closes when a real assignment has run through pause and expiry on a
	// deployment and `ryker record-episode --capability
	// standing-assignments` has captured it.
	"standing-assignments":                    "needs a recorded assignment through pause and expiry",
	"diff-and-draft-pr-controls":              "needs recorded revision-bound controls",
	"contextual-next-step-controls":           "needs a recorded stale-control replacement",
	"pr-checks-merge-deployment-verification": "needs a recorded follow-through with a missing webhook",
	"emisar-actions-and-approvals":            "needs a recorded approval without an incident room",
	"multi-repository-work":                   "needs a recorded parent episode with child goals",
	"cleanup":                                 "needs a recorded retention pass",
}

// deletedLegacyPath is one legacy path the migration has already removed, and
// the single capability whose fixture permitted removing it.
type deletedLegacyPath struct {
	// Capability is the matrix slug the deletion rests on. It must be proven by
	// the corpus, not merely present in the matrix.
	Capability string
	// Symbol is an identifier that must no longer appear in non-test source.
	// This is what makes the marker a check rather than a note: the claim
	// "this path is gone" is re-verified on every run.
	Symbol string
	// Note says what the path was, for whoever finds the entry later.
	Note string
}

// deletedLegacyPaths records every legacy path deleted under section 24's
// per-capability rule.
//
// Section 24 used to be read as one gate over the whole migration: nothing may
// be deleted until everything is proven. That reading made the least-covered
// capability in a phase hold the other twenty-three shut, and the corpus only
// grows at the speed of real usage, so the wait had no end anyone could name.
// The rule now counts proof and deletion the same way — per capability — and
// this list is where a deletion says which proof it stands on.
//
// An entry is rejected three ways, and each corresponds to a mistake that would
// otherwise read as progress:
//
//   - naming a capability the corpus does not prove is the deletion section 24
//     forbids, wearing a marker as if it were permission;
//   - naming a capability still listed in acknowledgedCoverageGaps is the same
//     mistake with the evidence sitting twenty lines above it;
//   - naming a symbol that is still in the tree is a deletion that did not
//     happen, or one that grew back — and a legacy path that grows back is
//     exactly the dual write the migration rules forbid, now with a test
//     asserting it is gone.
//
// Shared plumbing does not belong here. A path several capabilities route
// through is proven only when every one of them is proven; deleting it on one
// fixture removes the others untested, which is the neighbour's-proof deletion
// section 24 rules out.
var deletedLegacyPaths = []deletedLegacyPath{}

// deletionObjections returns every reason a marker is not permitted, in the
// words the reader needs to act on. Empty means the deletion stands.
//
// Split from the test so the rule itself can be tested against a synthetic
// marker: the real list is expected to pass, and a rule that is only ever
// exercised by inputs that pass it is a rule nobody has seen work.
func deletionObjections(
	entry deletedLegacyPath,
	matrix map[string]bool,
	covered map[string][]string,
	gaps map[string]string,
	stillPresentIn []string,
) []string {
	var objections []string
	if !matrix[entry.Capability] {
		objections = append(objections, fmt.Sprintf(
			"capability %q is not in the matrix in section 24", entry.Capability,
		))
	}
	if reason, gap := gaps[entry.Capability]; gap {
		objections = append(objections, fmt.Sprintf(
			"capability %q is an acknowledged gap (%q); section 24 permits deleting a legacy "+
				"path only for a capability the corpus proves",
			entry.Capability, reason,
		))
	}
	if len(covered[entry.Capability]) == 0 {
		objections = append(objections, fmt.Sprintf(
			"no replay fixture proves capability %q, so deleting %s removed behavior nothing "+
				"replays",
			entry.Capability, entry.Symbol,
		))
	}
	if len(stillPresentIn) > 0 {
		objections = append(objections, fmt.Sprintf(
			"%s is recorded as deleted but still appears in %s", entry.Symbol, strings.Join(stillPresentIn, ", "),
		))
	}
	return objections
}

// nonTestSourceMentioning returns the non-test source files that mention a
// symbol, repo-relative.
func nonTestSourceMentioning(t *testing.T, symbol string) []string {
	t.Helper()
	root := repoRoot(t)
	var found []string
	for _, dir := range []string{"internal", "cmd"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if strings.Contains(string(data), symbol) {
				relative, err := filepath.Rel(root, path)
				if err != nil {
					relative = path
				}
				found = append(found, relative)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	sort.Strings(found)
	return found
}

// Every deleted legacy path names one capability the corpus proves, and is
// actually gone.
//
// This is the enforcing half of the section 24 amendment. The prose permits
// deleting capability by capability; without this the permission would be
// self-certified, which is how the rule was enforced before the ratchet existed
// — by whoever remembered it.
func TestDeletedLegacyPathsRestOnAProvenCapability(t *testing.T) {
	covered := coveredCapabilities(t)
	matrix := make(map[string]bool)
	for _, capability := range matrixCapabilities(t) {
		matrix[capability] = true
	}
	for _, entry := range deletedLegacyPaths {
		objections := deletionObjections(
			entry, matrix, covered, acknowledgedCoverageGaps, nonTestSourceMentioning(t, entry.Symbol),
		)
		for _, objection := range objections {
			t.Errorf("deleted legacy path %q (%s): %s", entry.Symbol, entry.Note, objection)
		}
	}
}

// The marker rejects the deletions section 24 forbids.
//
// Exercised against synthetic entries because the real list must always pass:
// a guard whose failing branch has never run is a guard nobody has seen work,
// and this one exists to stop a deletion that would otherwise look like
// progress in a diff.
func TestADeletionNamingAnUnprovenCapabilityIsRejected(t *testing.T) {
	matrix := map[string]bool{"incidents": true, "reactions": true}
	covered := map[string][]string{"incidents": {"case incidents"}}
	gaps := map[string]string{"reactions": "needs a recorded reaction-only signal"}

	for _, testCase := range []struct {
		name    string
		entry   deletedLegacyPath
		present []string
		want    string
	}{
		{
			name:  "capability outside the matrix",
			entry: deletedLegacyPath{Capability: "invented", Symbol: "legacyThing"},
			want:  "not in the matrix",
		},
		{
			name:  "capability still an acknowledged gap",
			entry: deletedLegacyPath{Capability: "reactions", Symbol: "legacyThing"},
			want:  "acknowledged gap",
		},
		{
			name:    "path recorded as deleted but still present",
			entry:   deletedLegacyPath{Capability: "incidents", Symbol: "legacyThing"},
			present: []string{"internal/store/legacy.go"},
			want:    "still appears in",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			objections := deletionObjections(testCase.entry, matrix, covered, gaps, testCase.present)
			if len(objections) == 0 {
				t.Fatalf("deletion %+v was permitted; section 24 forbids it", testCase.entry)
			}
			if !slices.ContainsFunc(objections, func(o string) bool {
				return strings.Contains(o, testCase.want)
			}) {
				t.Fatalf("objections %q do not say %q", objections, testCase.want)
			}
		})
	}

	permitted := deletedLegacyPath{Capability: "incidents", Symbol: "legacyThing"}
	if objections := deletionObjections(permitted, matrix, covered, gaps, nil); len(objections) > 0 {
		t.Fatalf(
			"deleting a proven capability's path was objected to (%q); the amendment permits it",
			objections,
		)
	}
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
	// Every deployment's corpus, not one of them. A capability proven by a
	// fixture recorded in one deployment is proven; reading a single file would
	// report it as an uncovered gap and invite a duplicate recording.
	//
	// Every directory under testdata/eval, not just episode-replay/. Promoted
	// corrections are recorded episodes like any other — the promoter writes
	// them through the same recorder and tags them the same way — but they land
	// in regressions.jsonl, and a glob of episode-replay/ could not see them.
	// That is how four fixtures tagged "capability:" sat in the tree for a day
	// with the test that rejects exactly that tag looking straight past them.
	root := filepath.Join(repoRoot(t), "testdata", "eval")
	var corpora []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && filepath.Ext(path) == ".jsonl" {
			corpora = append(corpora, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(corpora) == 0 {
		t.Fatalf("no corpora found under %s; coverage would read as total", root)
	}
	covered := make(map[string][]string)
	for _, corpus := range corpora {
		readCorpusInto(t, corpus, covered)
	}
	if len(covered) == 0 {
		t.Fatalf("no fixture under %s claims a capability; coverage would read as total", root)
	}
	return covered
}

func readCorpusInto(t *testing.T, path string, covered map[string][]string) {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), 1<<22)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		var fixture struct {
			Name                      string                          `json:"name"`
			Tags                      []string                        `json:"tags"`
			RecordedExecutionProfiles []core.ExecutionProfileIdentity `json:"recorded_execution_profiles"`
		}
		if err := json.Unmarshal([]byte(text), &fixture); err != nil {
			t.Fatalf("%s line %d: %v", filepath.Base(path), line, err)
		}
		// Only a replay fixture proves a capability still works, and only a
		// replay fixture is tagged episode-replay. Every corpus is read now, so
		// without this a hand-written live or proactive case could claim
		// coverage it never replays and close a gap by assertion.
		if !slices.Contains(fixture.Tags, "episode-replay") {
			continue
		}
		for _, tag := range fixture.Tags {
			if capability, ok := strings.CutPrefix(tag, "capability:"); ok {
				if capability == "model-choice-and-byoc" &&
					!executionProfilesProveChoice(fixture.RecordedExecutionProfiles) {
					t.Fatalf(
						"%s line %d: model-choice-and-byoc needs exact metadata across two execution profiles",
						filepath.Base(path), line,
					)
				}
				covered[capability] = append(covered[capability], fixture.Name)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
}

func executionProfilesProveChoice(profiles []core.ExecutionProfileIdentity) bool {
	distinct := make(map[string]bool)
	for _, profile := range profiles {
		if strings.TrimSpace(profile.ManifestID) == "" || profile.Version <= 0 ||
			strings.TrimSpace(profile.Preset) == "" || strings.TrimSpace(profile.Provider) == "" ||
			strings.TrimSpace(profile.Model) == "" || strings.TrimSpace(profile.ReasoningEffort) == "" {
			return false
		}
		distinct[profile.Preset] = true
	}
	return len(distinct) >= 2
}

// A capability tag alone is an assertion, not replay evidence. This invariant
// keeps a hand-edited or older recorder output from closing model-choice on one
// default execution path with no record of who actually answered.
func TestModelChoiceCoverageRequiresExactMetadataAcrossTwoProfiles(t *testing.T) {
	profile := core.ExecutionProfileIdentity{
		ManifestID: "manifest-chat", Version: 1, Preset: "platform-conversation",
		Provider: "codex", Model: "gpt-5.6-terra", ReasoningEffort: "high",
	}
	if executionProfilesProveChoice([]core.ExecutionProfileIdentity{profile}) {
		t.Fatal("one execution profile proved model choice")
	}
	second := profile
	second.ManifestID = "manifest-watch"
	second.Version = 2
	second.Preset = "platform-watch"
	if !executionProfilesProveChoice([]core.ExecutionProfileIdentity{profile, second}) {
		t.Fatal("two exact execution profiles did not prove model choice")
	}
	second.Provider = ""
	if executionProfilesProveChoice([]core.ExecutionProfileIdentity{profile, second}) {
		t.Fatal("incomplete provider metadata proved model choice")
	}
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
				"Add a fixture to testdata/eval/episode-replay/<deployment>.jsonl tagged "+
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

// A promoted correction labels itself, so the labels it can produce must be
// matrix rows too.
//
// Nothing else checks this. The promoter does not read section 24, and the tag
// it writes reaches the corpus without a human choosing it, so a slug that
// drifts from the document — or is empty, which is what shipped — becomes a
// fixture claiming coverage of a capability nobody has. Checked here because
// this is the only test that already parses the matrix.
func TestPromotedCorrectionsClaimRealCapabilities(t *testing.T) {
	matrix := make(map[string]bool)
	for _, capability := range matrixCapabilities(t) {
		matrix[capability] = true
	}
	promotable := core.PromotableCapabilities()
	if len(promotable) == 0 {
		t.Fatal("promotion can label nothing; every promoted fixture would claim an empty capability")
	}
	for _, capability := range promotable {
		if !matrix[capability] {
			t.Errorf(
				"promotion can tag a fixture %q, which is not a capability in the matrix in section 24",
				capability,
			)
		}
	}
	if !matrix[core.DefaultFixtureCapability()] {
		t.Errorf(
			"the default promotion tag %q is not a capability in the matrix in section 24",
			core.DefaultFixtureCapability(),
		)
	}
	// Promotion must not be able to close a gap on its own. Deleting a line
	// from acknowledgedCoverageGaps is a claim that a capability is proven, and
	// an automatic label is not evidence for it.
	for _, capability := range promotable {
		if reason, gap := acknowledgedCoverageGaps[capability]; gap {
			t.Errorf(
				"promotion can tag a fixture %q, which is an acknowledged gap (%q); "+
					"an automatic label would close a gap nobody proved",
				capability, reason,
			)
		}
	}
}

// Capabilities proven in different deployments must add up.
//
// The corpus is split per deployment, so a capability proven by an emisar
// recording and one proven by a blitz recording live in different files. If
// coverage read a single file, the other deployment's fixtures would report as
// uncovered gaps and invite a duplicate recording of work already done.
//
// This is tested directly because the real corpora cannot currently show it:
// every capability tag today happens to sit in one file, so reading one or both
// gives the same answer. That will stop being true with the next emisar
// recording, and this fails first if the merge is ever lost.
func TestCoverageMergesEveryDeploymentsCorpus(t *testing.T) {
	dir := t.TempDir()
	write := func(name, capability string) string {
		path := filepath.Join(dir, name)
		line := `{"name":"case ` + capability +
			`","tags":["episode-replay","capability:` + capability + `"]}`
		if err := os.WriteFile(path, []byte("# header\n"+line+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	first := write("alpha.jsonl", "incidents")
	second := write("beta.jsonl", "cleanup")

	covered := make(map[string][]string)
	readCorpusInto(t, first, covered)
	readCorpusInto(t, second, covered)

	for _, capability := range []string{"incidents", "cleanup"} {
		if len(covered[capability]) != 1 {
			t.Fatalf(
				"%q is proven in one deployment's corpus but not counted: %+v",
				capability, covered,
			)
		}
	}
}
