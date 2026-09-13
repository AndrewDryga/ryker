package evaluation

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	gopath "path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// evaluationCorpora finds every checked-in corpus, at any depth.
//
// A flat glob of testdata/eval/*.jsonl used to do this, and it produced an
// exact inversion: the two corpora under testdata/eval/episode-replay/ are the
// ones scripts/self-deploy.sh actually gates a deployment on, and they were the
// only ones never validated offline, while the corpora this test did cover are
// replayed by nothing. Walking means a corpus cannot hide from validation by
// being filed in a directory.
func evaluationCorpora(t *testing.T) []string {
	t.Helper()
	root := filepath.Join("..", "..", "testdata", "eval")
	var corpora []string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
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
		t.Fatal("no evaluation corpora found; the path has moved")
	}
	// The bug was that nested corpora were invisible, so this asserts the walk
	// still reaches them rather than trusting that it does.
	nested := false
	for _, path := range corpora {
		if rel, relErr := filepath.Rel(root, path); relErr == nil && filepath.Dir(rel) != "." {
			nested = true
			break
		}
	}
	if !nested {
		t.Fatal(
			"every corpus found is at the top level; either the per-deployment replay corpora " +
				"moved or this stopped walking, and the corpora a deployment gates on would go unchecked",
		)
	}
	return corpora
}

// Every checked-in evaluation corpus must decode and validate.
//
// A malformed case fails only when someone runs the credentialed suite, which
// is exactly when nobody wants to be debugging JSON. Validation is entirely
// deterministic, so it belongs here where it runs on every commit.
func TestEveryEvaluationCorpusIsValid(t *testing.T) {
	for _, path := range evaluationCorpora(t) {
		t.Run(filepath.Base(path), func(t *testing.T) {
			file, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()

			// Three corpora, three shapes: scenarios carry seeds and steps,
			// calibration carries a labelled response, everything else is a case.
			var names []string
			switch filepath.Base(path) {
			case "scenarios.jsonl":
				scenarios, err := decodeEvaluationScenarios(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, scenario := range scenarios {
					names = append(names, scenario.Name)
				}
			case "quality-calibration.jsonl":
				cases, err := decodeQualityCalibrationCases(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, testCase := range cases {
					names = append(names, testCase.Name)
				}
			default:
				cases, err := decodeEvaluationCases(file)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				for _, testCase := range cases {
					names = append(names, testCase.Name)
					checkCapabilityTags(t, testCase)
					// The live harness must be able to build the case's input.
					// The prompts corpus shipped with sender_type "app" while
					// the harness accepted only "external_app", so six of its
					// ten cases were never evaluated by the credentialed gate
					// they existed for — and nothing offline said so, because
					// decoding validated the JSON without asking the harness.
					// The gate looked like a gate from the day it landed and
					// was not one.
					if testCase.Kind == "watch" {
						if _, _, _, err := liveEvaluationWatchContext(
							testCase, "corpus-check", "UEVALOPERATOR",
						); err != nil {
							t.Errorf("case %q cannot reach the live harness: %v",
								testCase.Name, err)
						}
					}
				}
			}
			if len(names) == 0 {
				t.Fatal("corpus has no cases")
			}
			seen := make(map[string]bool, len(names))
			for _, name := range names {
				if seen[name] {
					t.Errorf("duplicate case name %q", name)
				}
				seen[name] = true
			}
		})
	}
}

// checkCapabilityTags rejects a capability tag that cannot name anything.
//
// Whether the slug is a row of section 24 is decided by the coverage ratchet in
// internal/episode_replay_coverage_test.go, which parses the matrix out of the
// design document; restating the matrix here would give it two owners. What is
// checked here is the shape, because the shape is what broke: promotion wrote
// four fixtures tagged "capability:" with nothing after it, and an empty slug
// is not a missing tag but a claim to cover a capability that does not exist.
func checkCapabilityTags(t *testing.T, testCase EvaluationCase) {
	t.Helper()
	for _, tag := range testCase.Tags {
		slug, ok := strings.CutPrefix(tag, "capability:")
		if !ok {
			continue
		}
		switch {
		case strings.TrimSpace(slug) == "":
			t.Errorf("case %q claims an empty capability; the tag names nothing", testCase.Name)
		case slug != strings.ToLower(slug), strings.ContainsAny(slug, " \t"):
			t.Errorf(
				"case %q claims capability %q; slugs are lowercase and hyphenated, "+
					"and one that is not can never match the matrix",
				testCase.Name, slug,
			)
		}
	}
}

// evaluatedCorpusInputs reads the Makefile and returns what actually gets
// replayed: the exact corpus paths passed with --input, and the directories a
// target selects within from a variable.
//
// Only --input counts. Being mentioned somewhere in the Makefile is not being
// run, and the distinction is the entire bug: REGRESSION_CORPUS was assigned at
// the top of the file and referenced twice more, both times inside an echo in a
// failure message, which reads like wiring and executes nothing.
//
// A variable whose value contains a slash is expanded, because it names a
// corpus. One that does not — DEPLOYMENT, whose value is a bare selector — is
// left alone, and the directory it selects within is recorded instead. Expanding
// it would resolve to the default deployment and report every other
// deployment's corpus as unreachable.
func evaluatedCorpusInputs(t *testing.T, makefile string) (map[string]bool, map[string]bool) {
	t.Helper()
	paths := regexp.MustCompile(`(?m)^([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(\S*/\S*)\s*$`)
	values := make(map[string]string)
	for _, match := range paths.FindAllStringSubmatch(makefile, -1) {
		values[match[1]] = match[2]
	}
	exact := make(map[string]bool)
	parameterized := make(map[string]bool)
	inputs := regexp.MustCompile(`--input\s+"?([^"\s]+)"?`)
	for _, match := range inputs.FindAllStringSubmatch(makefile, -1) {
		token := match[1]
		for name, value := range values {
			token = strings.ReplaceAll(token, "$("+name+")", value)
		}
		if strings.Contains(token, "$(") {
			parameterized[gopath.Dir(token)] = true
			continue
		}
		exact[token] = true
	}
	if len(exact) == 0 {
		t.Fatal("no --input corpus found in the Makefile; this stopped parsing anything")
	}
	return exact, parameterized
}

// Every checked-in corpus must be passed to something that runs it.
//
// testdata/eval/regressions.jsonl existed for a day with no target, no script,
// and no CI job passing it to anything. It was written by promotion, hand
// reviewed, committed, and then read by nobody — the only references to it in
// the whole repository were an assignment and two echo strings inside a failure
// message. A corpus nothing replays is not a weak gate, it is the appearance of
// one, and there is nothing about the file itself that says which it is.
func TestEveryCorpusIsRunBySomeTarget(t *testing.T) {
	root := filepath.Join("..", "..")
	makefile, err := os.ReadFile(filepath.Join(root, "Makefile"))
	if err != nil {
		t.Fatal(err)
	}
	exact, parameterized := evaluatedCorpusInputs(t, string(makefile))
	for _, path := range evaluationCorpora(t) {
		rel, err := filepath.Rel(root, path)
		if err != nil {
			t.Fatal(err)
		}
		rel = filepath.ToSlash(rel)
		// testdata/eval itself never counts as a parameterized directory, or
		// every top-level corpus would pass for free.
		dir := gopath.Dir(rel)
		if exact[rel] || (dir != "testdata/eval" && parameterized[dir]) {
			continue
		}
		t.Errorf(
			"no Makefile target passes %s to --input, so nothing ever replays it; "+
				"a corpus nobody runs looks exactly like a gate and is not one",
			rel,
		)
	}
}

// committedBaselines maps each reviewed baseline to the corpus it grades.
//
// The file is named for the make target that records it — the same prefix its
// results carry in EVAL_HISTORY, so `make eval-baseline-update` can find the
// newest run — and a target's name is not always its corpus's, so the pairing
// is declared rather than guessed. A baseline with no entry here fails below:
// an ungraded file in that directory is a number nothing is held to.
var committedBaselines = map[string]string{
	"regressions": "regressions.jsonl",
}

// A committed baseline must still name cases the corpus has.
//
// The gate joins a run to its baseline by case name, so a case that was renamed
// or deleted takes its recorded rate with it and fails model-release-check —
// an hour of credentialed evaluation to be told about an edit that was visible
// the moment it was made. Corpus growth is deliberately not a failure here:
// promotion adds cases, and a baseline that had to be rewritten every time the
// corrections loop worked would be rewritten without being read.
func TestACommittedBaselineNamesCasesTheCorpusStillHas(t *testing.T) {
	root := filepath.Join("..", "..", "testdata", "eval")
	entries, err := os.ReadDir(filepath.Join(root, "baselines"))
	if os.IsNotExist(err) {
		t.Skip("no baseline has been recorded yet")
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		name := strings.TrimSuffix(entry.Name(), ".json")
		corpus, declared := committedBaselines[name]
		if !declared {
			t.Errorf(
				"baseline %s names no corpus in committedBaselines, so nothing checks it",
				entry.Name(),
			)
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, "baselines", entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		var baseline EvaluationBaseline
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&baseline); err != nil {
			t.Fatalf("decode %s: %v", entry.Name(), err)
		}
		if baseline.Version != 1 || len(baseline.CasePassRates) == 0 {
			t.Fatalf("%s records no case rates: %+v", entry.Name(), baseline)
		}
		file, err := os.Open(filepath.Join(root, corpus))
		if err != nil {
			t.Fatal(err)
		}
		cases, err := decodeEvaluationCases(file)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
		present := make(map[string]bool, len(cases))
		for _, testCase := range cases {
			present[testCase.Name] = true
		}
		for name := range baseline.CasePassRates {
			if !present[name] {
				t.Errorf(
					"%s grades case %q, which %s no longer has; record a new baseline "+
						"with `make eval-baseline-update` from a run of the corpus as it is now",
					entry.Name(), name, corpus,
				)
			}
		}
	}
}

// The promoted corpus stays replayable against any deployment's config.
//
// eval-episode-replay is split per deployment because a fixture that names a
// repository needs the config that has it, and no single config could pass both
// files. The promoted corpus is deliberately not split, which is only safe
// because the recorder never writes a repository onto a fixture. If that ever
// changes, one deployment's promoted lesson starts failing every other
// deployment's gate with "repository ... is not configured", and the honest fix
// is to split this corpus too — not to loosen its pass rate. Failing here is
// how that decision gets made deliberately.
func TestThePromotedCorpusBindsNoRepository(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "eval", "regressions.jsonl")
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		t.Skip("nothing has been promoted yet")
	}
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	for _, testCase := range cases {
		if strings.TrimSpace(testCase.Repository) != "" {
			t.Errorf(
				"promoted case %q binds repository %q; a single-file corpus cannot be replayed "+
					"against every deployment once a case needs one deployment's repositories",
				testCase.Name, testCase.Repository,
			)
		}
	}
}

// One recorded episode replays once, in one corpus.
//
// Promotion already learned this the hard way within a single batch: two
// corrections landed on one episode and wrote two fixtures with the same name.
// The remaining hole is across files, where the same recorded history can be
// filed twice under different names, replay twice, and count twice toward
// coverage — a capability that looks doubly proven by one episode.
func TestEveryRecordedEpisodeAppearsInOneCorpus(t *testing.T) {
	origin := make(map[string]string)
	for _, path := range evaluationCorpora(t) {
		base := filepath.Base(path)
		if base == "scenarios.jsonl" || base == "quality-calibration.jsonl" {
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		cases, err := decodeEvaluationCases(file)
		file.Close()
		if err != nil {
			t.Fatalf("%s: decode: %v", base, err)
		}
		for _, testCase := range cases {
			for _, tag := range testCase.Tags {
				episode, ok := strings.CutPrefix(tag, "source:episode/")
				if !ok {
					continue
				}
				if first, seen := origin[episode]; seen {
					t.Errorf(
						"episode %s is recorded in both %s and %s; one history must replay once",
						episode, first, base,
					)
					continue
				}
				origin[episode] = base
			}
		}
	}
}

// The memory corpus is the regression net for recall, and its value is entirely
// in what each case forbids: a case that only asserts a reply happened would
// pass while the agent forgot everything it was taught.
func TestMemoryCorpusAssertsRecallBehaviour(t *testing.T) {
	file, err := os.Open(filepath.Join("..", "..", "testdata", "eval", "memory.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeEvaluationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 5 {
		t.Fatalf("memory corpus has %d cases, want at least 5", len(cases))
	}
	for _, testCase := range cases {
		t.Run(testCase.Name, func(t *testing.T) {
			if len(testCase.Memories) == 0 {
				t.Error("a memory case with no memories in context proves nothing")
			}
			asserts := len(testCase.ForbidMessageContains) > 0 ||
				len(testCase.WantMessageContains) > 0 ||
				len(testCase.ForbidEvidenceSources) > 0 ||
				len(testCase.WantMemoryContains) > 0
			if !asserts {
				t.Error("case asserts nothing about how the memory was used")
			}
		})
	}
}

// No new fixture may ask half a question.
//
// A fixture's input used to be copied from the episode objective, which is a
// display headline the host builds with TruncateUTF8WithSuffix(text, 180,
// "..."). So a promoted case asked the model a question that stopped
// mid-sentence, and then the corpus scored the model's entirely reasonable
// request for the rest of it as a regression. The recorder refuses to write one
// now; this stops the two that predate the fix from being joined by more.
//
// The two are grandfathered rather than deleted because they are the only proof
// for their capabilities, their originating slack_inputs rows are pruned, and
// so the choice is between imperfect proof and moving two capabilities to the
// acknowledged-gap list — a coverage decision, not a cleanup. They are named
// here so that the choice stays visible instead of dissolving into the file.
func TestNoNewCorpusFixtureAsksATruncatedQuestion(t *testing.T) {
	// Both were replayed against a real model on 2026-08-10 and both passed, so
	// the truncated input is not stopping them from proving what they claim.
	// That is the whole argument for keeping them: the alternative was dropping
	// two capabilities into the acknowledged-gap list, which is a coverage
	// decision that would have slowed the lifecycle cutover on the assumption
	// they were worthless. They are not.
	unrepairable := map[string]string{
		"progress-updates":             "episode d01ca30b; slack_inputs row pruned; replay passes 2026-08-10",
		"thread-and-channel-switching": "episode 3d6fb54e; slack_inputs row pruned; replay passes 2026-08-10",
	}
	seen := map[string]bool{}
	for _, path := range evaluationCorpora(t) {
		// Scenarios and calibration carry their own shapes and no input field.
		switch filepath.Base(path) {
		case "scenarios.jsonl", "quality-calibration.jsonl":
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		cases, err := decodeEvaluationCases(file)
		file.Close()
		if err != nil {
			t.Fatalf("%s: decode: %v", path, err)
		}
		for _, testCase := range cases {
			if !strings.HasSuffix(testCase.Input, "...") {
				continue
			}
			capability := ""
			for _, tag := range testCase.Tags {
				if rest, ok := strings.CutPrefix(tag, "capability:"); ok && rest != "" {
					capability = rest
				}
			}
			reason, allowed := unrepairable[capability]
			if !allowed {
				t.Errorf(
					"%s: case %q asks a truncated question. Its input is the 180-byte "+
						"objective headline, not the text that triggered the episode, so "+
						"nothing can answer it. Re-record it with ryker record-episode.",
					path, testCase.Name,
				)
				continue
			}
			seen[capability] = true
			t.Logf("%s: %q is grandfathered truncated (%s)", path, testCase.Name, reason)
		}
	}
	// If a grandfathered case is repaired or dropped, its exemption must go
	// with it, or the list quietly becomes permission for the next one.
	for capability := range unrepairable {
		if !seen[capability] {
			t.Errorf(
				"the truncated-input exemption for %q matches no case any more; delete it",
				capability,
			)
		}
	}
}

// A corpus naming a repository must be run by a deployment-aware target.
//
// The two deployments configure different repositories, so a case naming one
// needs the config that has it. eval-health names blitz-infra, which only the
// blitz deployment configures, and its Makefile target takes no DEPLOYMENT — so
// against emisar every case failed with "repository is not configured", one
// model call at a time, reported as a provider refusal. The corpus had never
// run anywhere, and nothing said so.
//
// eval-episode-replay already solved this by parameterising on DEPLOYMENT and
// picking the matching corpus. This is the rule that says every corpus with the
// same need is treated the same way.
func TestACorpusNamingARepositoryIsRunPerDeployment(t *testing.T) {
	root := filepath.Join("..", "..")
	makefile, err := os.ReadFile(filepath.Join(root, "Makefile"))
	if err != nil {
		t.Fatal(err)
	}
	_, parameterized := evaluatedCorpusInputs(t, string(makefile))
	checked := 0
	for _, path := range evaluationCorpora(t) {
		switch filepath.Base(path) {
		case "scenarios.jsonl", "quality-calibration.jsonl":
			continue
		// golden.jsonl is replayed with --replay, which calls no model and
		// opens no session, so it never resolves a repository against a
		// config. The field is inert there and carrying it is not a defect.
		case "golden.jsonl":
			continue
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		cases, err := decodeEvaluationCases(file)
		file.Close()
		if err != nil {
			t.Fatalf("%s: decode: %v", path, err)
		}
		named := map[string]bool{}
		for _, testCase := range cases {
			if repository := strings.TrimSpace(testCase.Repository); repository != "" {
				named[repository] = true
			}
		}
		if len(named) == 0 {
			continue
		}
		checked++
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			t.Fatal(relErr)
		}
		// Either the corpus lives in a per-deployment directory the target
		// globs, or its target names the deployment it needs. Both say the
		// same thing out loud: this corpus does not run just anywhere.
		dir := gopath.Dir(filepath.ToSlash(rel))
		declared := targetDeclaresDeployment(string(makefile), filepath.ToSlash(rel))
		if !declared && (dir == "testdata/eval" || !parameterized[dir]) {
			repositories := make([]string, 0, len(named))
			for repository := range named {
				repositories = append(repositories, repository)
			}
			sort.Strings(repositories)
			t.Errorf(
				"%s names %v but its target takes no DEPLOYMENT, so it can only run "+
					"against whichever deployment happens to configure them. Either move it "+
					"beside the per-deployment corpora or drop the repository from its cases.",
				rel, repositories,
			)
		}
	}
	if checked == 0 {
		t.Fatal("no corpus named a repository; this test is checking nothing")
	}
}

// targetDeclaresDeployment reports whether the Makefile target that runs this
// corpus sets DEPLOYMENT for itself, which is how a target says which
// deployment's configuration its cases need.
func targetDeclaresDeployment(makefile, corpus string) bool {
	for _, line := range strings.Split(makefile, "\n") {
		if !strings.Contains(line, corpus) {
			continue
		}
		// Walk back to the target this recipe belongs to and look for a
		// target-scoped DEPLOYMENT assignment above it.
		before := makefile[:strings.Index(makefile, line)]
		for _, earlier := range strings.Split(before, "\n") {
			if strings.Contains(earlier, ": DEPLOYMENT =") ||
				strings.Contains(earlier, "DEPLOYMENT ?=") {
				return true
			}
		}
	}
	return false
}
