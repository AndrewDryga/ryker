package evaluation

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
)

// A replayed episode must not push the contract it is graded against out of
// the turn.
//
// This is the measurement that explained the promoted corpus. Assembled whole,
// the three fixtures came to 69,930, 84,129 and 122,885 bytes against a 65,536
// cap. Coop elides the middle of anything oversized, and the middle of those
// prompts is the tail of the watch instructions, the entire investigation
// contract, and up to half the recorded evidence — so every reported failure to
// honour the completion contract was reported against a turn the contract had
// been cut out of. The pass rates ran in the same order as the overflow: the
// 4 KB case passed two runs in three, the 19 KB and 57 KB cases passed none.
//
// The corpus is real and it grows by promotion, so this is a standing bound
// rather than a one-off measurement.
func TestReplayedEpisodesFitBesideTheirContract(t *testing.T) {
	paths, err := filepath.Glob(
		filepath.Join("..", "..", "testdata", "eval", "episode-replay", "*.jsonl"),
	)
	if err != nil {
		t.Fatal(err)
	}
	paths = append(paths, filepath.Join("..", "..", "testdata", "eval", "regressions.jsonl"))
	cfg := serviceConfig(t)
	measured := 0
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		cases, err := decodeEvaluationCases(strings.NewReader(string(data)))
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		for _, testCase := range cases {
			base, err := liveEvaluationPrompt(cfg, testCase, cfg.Slack.DefaultRepository, "fit")
			if err != nil {
				t.Fatalf("%s / %s: %v", filepath.Base(path), testCase.Name, err)
			}
			prompt, err := deterministicEpisodeReplayPrompt(base, testCase)
			if err != nil {
				t.Fatalf("%s / %s: %v", filepath.Base(path), testCase.Name, err)
			}
			measured++
			if len(prompt) > coop.MaxPromptBytes {
				t.Errorf(
					"the replay prompt for %q is %d bytes, %d over the %d cap; "+
						"the transport will elide its middle, which is where the contract lives",
					testCase.Name, len(prompt), len(prompt)-coop.MaxPromptBytes, coop.MaxPromptBytes,
				)
			}
			// The contract is the thing a replay grades against, so it has to
			// survive whole however large the recording beside it is.
			for _, required := range []string{
				"<host-investigation-contract>",
				"</host-investigation-contract>",
				"<host-deterministic-episode-replay>",
			} {
				if !strings.Contains(prompt, required) {
					t.Errorf("the replay prompt for %q lost %s", testCase.Name, required)
				}
			}
		}
	}
	if measured == 0 {
		t.Fatal("no episode-replay fixture was measured; this bound is checking nothing")
	}
	t.Logf("%d replay fixtures fit beside their contract", measured)
}

func TestEvaluationTurnCleanupRetryIsBoundedAndRecovers(t *testing.T) {
	client := newFakeCoop()
	client.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:            "completed",
			AssistantMessage: `{"action":"ignore"}`,
		},
	}
	response, turnID, calls, err := runEvaluationTurnWithRetry(
		context.Background(),
		client,
		client.session.ID,
		"responder:test-eval-turn",
		"evaluate",
		time.Millisecond,
	)
	if err != nil {
		t.Fatal(err)
	}
	if response != `{"action":"ignore"}` || turnID == "" || calls != 3 {
		t.Fatalf(
			"retry result = response %q, turn %q, calls %d",
			response,
			turnID,
			calls,
		)
	}
	if want := []string{
		"responder:test-eval-turn",
		"responder:test-eval-turn:cleanup-retry:1",
		"responder:test-eval-turn:cleanup-retry:2",
	}; !slices.Equal(client.submitKeys, want) {
		t.Fatalf("retry keys = %v, want %v", client.submitKeys, want)
	}
}
