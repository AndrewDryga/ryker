package service

import (
	"io/fs"
	"os"
	gopath "path"
	"path/filepath"
	"regexp"
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
