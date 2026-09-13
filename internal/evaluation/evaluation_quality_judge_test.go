package evaluation

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackui"
)

// The operator's two complaints this week were that a reply was "extremely long
// and watery" and that it "was posted in the channel itself and I can't even
// tell why (should it be in some thread?)". The judge could see neither: its
// material was a slackui.Message, which carries no destination, and its only
// length criterion was the words "matches the requested depth".
//
// These tests are about what reaches the judge, not about what a model then
// says. A judge that cannot see a failure cannot be persuaded to score it, so
// the visibility is the part that can be proven for free.

// The 01:13Z complaint in the shape the audit found it: a report nobody asked
// for, dropped at channel top level, closing on a gap instead of a finding.
const channelLevelHandBack = "VA1's website has started rolling — first movement since Aug 5. " +
	"The apply that actually deploys the site is the `va1-apps` one, and it's running now: " +
	"`run-QmzuDtmYr4z9MwKJ` (CI apply, `1a9ec54a`) reached Applying at 16:31:15Z, and the " +
	"website's running allocation count stepped 4 → 5 inside the last five minutes against 4 " +
	"declared replicas. It had held the same four allocation IDs all week.\n\n" +
	"The CLI-triggered run discarded a minute earlier is what let CI through, so whatever was " +
	"holding `va1-apps` is clear. It's landed when all four allocation IDs have turned over. " +
	"One gap: `1a9ec54a` isn't in this session's checkout, so I can't tell you which image tag " +
	"it ships."

const runNotification = "Run notification for <https://app.terraform.io/app/SME-Blitz/va1-apps|" +
	"SME-Blitz/va1-apps> <https://app.terraform.io/app/SME-Blitz/va1-apps/runs/" +
	"run-QmzuDtmYr4z9MwKJ|Run run-Qmzu..."

func judgeMeasurements(t *testing.T, testCase EvaluationCase, rendered slackui.Message) map[string]any {
	t.Helper()
	prompt := qualityJudgePrompt(testCase, rendered)
	start := strings.Index(prompt, "<evaluation>")
	end := strings.Index(prompt, "</evaluation>")
	if start < 0 || end < start {
		t.Fatal("the judge prompt no longer wraps its material in an evaluation element")
	}
	var material struct {
		Measured map[string]any `json:"host_measurements"`
	}
	body := strings.TrimSpace(prompt[start+len("<evaluation>") : end])
	if err := json.Unmarshal([]byte(body), &material); err != nil {
		t.Fatalf("decode judge material: %v", err)
	}
	if material.Measured == nil {
		t.Fatal("the judge is handed no host measurements at all")
	}
	return material.Measured
}

// Where the message went reaches the judge, which it never did before.
func TestQualityJudgePromptShowsWhereTheReplyWent(t *testing.T) {
	measured := judgeMeasurements(t, EvaluationCase{
		Name:               "01:13Z-shaped",
		Kind:               "watch",
		Lane:               "investigation",
		Input:              runNotification,
		ReplyPlacement:     "channel",
		WantReplyPlacement: "thread",
	}, slackui.Message{
		Text:     "VA1's website has started rolling.",
		Markdown: channelLevelHandBack,
	})
	for field, want := range map[string]any{
		"posted_in":                 "channel",
		"operator_asked_for":        "thread",
		"posted_in_the_wrong_place": true,
	} {
		if measured[field] != want {
			t.Errorf("%s = %v, want %v", field, measured[field], want)
		}
	}
}

// The same message's closing reaches the judge as the phrase the host matched,
// so a hand-back is a fact rather than a reading.
func TestQualityJudgePromptShowsTheClosingHandBack(t *testing.T) {
	measured := judgeMeasurements(t, EvaluationCase{
		Name:  "01:13Z-shaped",
		Kind:  "watch",
		Lane:  "investigation",
		Input: runNotification,
	}, slackui.Message{
		Text:     "VA1's website has started rolling.",
		Markdown: channelLevelHandBack,
	})
	if measured["closing_hand_back"] != "one gap" {
		t.Errorf("closing_hand_back = %v, want the phrase the host matched", measured["closing_hand_back"])
	}
	// The host posts this one; only its closing is wrong. The judge has to be
	// told exactly that, or it invents a length problem the host does not have.
	if measured["over_word_bound"] != nil {
		t.Errorf("over_word_bound = %v, want absent for a reply inside its bound", measured["over_word_bound"])
	}
}

// Length reaches the judge as the host's own count against the host's own
// ladder, so the rubric caps directness on the same replies production refuses.
func TestQualityJudgePromptMeasuresLengthWithTheHostBound(t *testing.T) {
	// The real 245-word answer to the word "hi", trimmed to its opening and
	// closing: a greeting earns sixty words, and this is far past it.
	watery := strings.Repeat("Supporting detail on the readiness environment and its two blockers. ", 20) +
		"One gap worth naming: no Emisar tool is exposed in this session, so I couldn't check " +
		"the live account or whether anything has deployed."
	measured := judgeMeasurements(t, EvaluationCase{
		Name:  "watery answer to a greeting",
		Kind:  "watch",
		Lane:  "investigation",
		Input: "hi <@ryker>",
	}, slackui.Message{Text: "Still no change to the account.", Markdown: watery})

	bound := decisionpkg.ReplyWordBudget("hi <@ryker>", "investigation")
	words := decisionpkg.ProseWordCount(watery)
	if measured["over_word_bound"] != true {
		t.Fatalf("over_word_bound = %v for %d words against %d", measured["over_word_bound"], words, bound)
	}
	// Taken from reply_shape.go rather than restated here: a judge told a
	// different number from the one production enforces is a second bar.
	if got, want := measured["word_bound"], float64(bound); got != want {
		t.Errorf("word_bound = %v, want the ladder's %v", got, want)
	}
	if got, want := measured["reply_words"], float64(words); got != want {
		t.Errorf("reply_words = %v, want the host's count of %v", got, want)
	}
}

// A good short answer must arrive clean, or the new criteria fail everything
// and get switched off.
func TestQualityJudgePromptLeavesAGoodShortReplyAlone(t *testing.T) {
	terminal := "`run-bKF5rzjVPbyKW9sg` is now terminal: `planned_and_finished` with no changes. " +
		"Nothing was applied, nothing is waiting on a confirm, and the plan was empty, so there " +
		"is nothing to do here."
	measured := judgeMeasurements(t, EvaluationCase{
		Name:               "terminal run report",
		Kind:               "watch",
		Lane:               "investigation",
		Input:              runNotification,
		ReplyPlacement:     "thread",
		WantReplyPlacement: "thread",
	}, slackui.Message{Text: "run-bKF5rzjVPbyKW9sg is now terminal.", Markdown: terminal})
	for _, field := range []string{
		"over_word_bound", "closing_hand_back", "posted_in_the_wrong_place",
	} {
		if measured[field] != nil {
			t.Errorf("%s = %v on a reply the host posts as written", field, measured[field])
		}
	}
}

// Every measurement handed over has to be named in the rubric.
//
// This is the regression guard for the original bug rather than for a symptom
// of it. A field the judge is given and never told how to read is a field it
// will average away, which is how "matches the requested depth" survived beside
// a measured word ladder for as long as it did.
func TestQualityJudgeRubricNamesEveryMeasurementItHandsOver(t *testing.T) {
	prompt := qualityJudgePrompt(EvaluationCase{Name: "any", Kind: "watch"}, slackui.Message{
		Text: "Anything.",
	})
	rubric, _, found := strings.Cut(prompt, "<evaluation>")
	if !found {
		t.Fatal("the judge prompt no longer wraps its material in an evaluation element")
	}
	fields := reflect.TypeOf(decisionpkg.ReplyJudgement{})
	for index := range fields.NumField() {
		name, _, _ := strings.Cut(fields.Field(index).Tag.Get("json"), ",")
		if name == "" || strings.Contains(rubric, name) {
			continue
		}
		t.Errorf(
			"the judge is handed %q and the rubric never mentions it, so nothing tells it "+
				"what the number means",
			name,
		)
	}
}

// The calibration corpus and the host bound have to agree about the good cases.
//
// A judge that fails everything is as useless as one that passes everything, so
// this is the guard against the new criteria over-firing: any case labelled
// want_pass must be inside the word bound, must not close on a hand-back, and
// must not be recorded in the wrong place. If one is, the rubric would reject a
// reply the corpus calls good, and the corpus would be arguing with itself.
//
// It also asserts the reverse, that some failing case exercises each new
// criterion — a rubric nothing in the corpus trips is a rubric nobody has
// checked.
func TestQualityCalibrationCorpusAgreesWithTheHostBound(t *testing.T) {
	path := filepath.Join("..", "..", "testdata", "eval", "quality-calibration.jsonl")
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	cases, err := decodeQualityCalibrationCases(file)
	if err != nil {
		t.Fatal(err)
	}
	good, overBound := 0, 0
	handBacks, misplaced := 0, 0
	for _, item := range cases {
		prose := item.Response.Markdown
		if prose == "" {
			prose = item.Response.Text
		}
		judged := decisionpkg.MeasureReply(
			item.Input, item.Lane, prose, item.ReplyPlacement, item.WantReplyPlacement,
		)
		if item.WantPass {
			good++
			switch {
			case judged.OverWordBound:
				t.Errorf(
					"case %q is labelled good and runs %d words against a bound of %d, "+
						"which the rubric caps directness for",
					item.Name, judged.Words, judged.WordBound,
				)
			case judged.ClosingHandBack != "":
				t.Errorf(
					"case %q is labelled good and closes on %q, which the rubric calls a "+
						"critical failure",
					item.Name, judged.ClosingHandBack,
				)
			case judged.WrongPlace:
				t.Errorf(
					"case %q is labelled good and went to the %s after the %s was asked for",
					item.Name, judged.PostedIn, judged.AskedFor,
				)
			}
			continue
		}
		if judged.OverWordBound {
			overBound++
		}
		if judged.ClosingHandBack != "" {
			handBacks++
		}
		if judged.WrongPlace {
			misplaced++
		}
	}
	t.Logf(
		"%d calibration cases: %d labelled good and clean on every measured axis; "+
			"of the rest, %d over the word bound, %d closing on a hand-back, %d in the wrong place",
		len(cases), good, overBound, handBacks, misplaced,
	)
	switch {
	case overBound == 0:
		t.Error("no case is over the word bound, so the directness cap is never exercised")
	case handBacks == 0:
		t.Error("no case closes on a hand-back, so that critical failure is never exercised")
	case misplaced == 0:
		t.Error("no case lands in the wrong place, so the destination is never exercised")
	}
}
