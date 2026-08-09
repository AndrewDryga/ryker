package decision_test

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"

	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// replayReply is one posted reply as scripts/reply-shape-replay.sh recovers it
// from a live state database.
type replayReply struct {
	Host    string `json:"host"`
	At      string `json:"at"`
	Episode string `json:"episode"`
	Effort  string `json:"effort"`
	// Lane is what the run recorded, or "" when its context was already
	// cleared. Most of the corpus is "".
	Lane string `json:"lane"`
	// Trigger is the message answered, and TriggerState says how much of it
	// survived: "exact", "recovered" from a run context, or "missing" when only
	// the 180-byte objective prefix is left.
	Trigger      string `json:"trigger"`
	TriggerState string `json:"trigger_state"`
	Reply        string `json:"reply"`
}

// TestReplyShapeReplay scores every posted reply in a state database against
// the bounds this package enforces, and prints what it found.
//
// It asserts almost nothing. The point is the number: how often the host would
// spend an extra model turn, broken down by which rule spent it, so the rate is
// a measurement rather than a hope. What it does assert is that the rate stays
// inside the range a reader signed off on — a validator that starts rejecting a
// fifth of production is one nobody will leave switched on, and a validator
// that rejects nothing has stopped being a validator.
func TestReplyShapeReplay(t *testing.T) {
	path := os.Getenv("RESPONDER_REPLY_SHAPE_CORPUS")
	if path == "" {
		t.Skip("set RESPONDER_REPLY_SHAPE_CORPUS, or run scripts/reply-shape-replay.sh")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var replies []replayReply
	if err := json.Unmarshal(raw, &replies); err != nil {
		t.Fatal(err)
	}
	if len(replies) == 0 {
		t.Fatal("the corpus is empty")
	}

	lengths := make([]int, 0, len(replies))
	counts := map[string]int{}
	byLane := map[string]int{}
	byEffort := map[string]int{}
	rejected, undecided := 0, 0
	for _, reply := range replies {
		lane := reply.Lane
		if lane == "" {
			// Unknown, and the ladder only asks whether the lane is the
			// bounded one. Investigation is the wider bound, so an unknown
			// lane under-reports rejections rather than inventing them.
			lane = "investigation"
		}
		words := decisionpkg.ProseWordCount(reply.Reply)
		lengths = append(lengths, words)
		verdict := replayVerdict(reply.Trigger, lane, reply.Reply)
		if reply.TriggerState == "missing" &&
			verdict != replayVerdict(reply.Trigger+longTrigger, lane, reply.Reply) {
			// Only the trigger's first 180 bytes survive, and the two ends of
			// the ladder disagree about it. Nothing honest can be said here.
			undecided++
			continue
		}
		counts[verdict]++
		byLane[reply.Lane+"/"+verdict]++
		byEffort[reply.Effort+"/"+verdict]++
		if verdict == "accept" {
			continue
		}
		rejected++
		t.Logf("reject %-8s %s %s %s %s trigger=%dw(%s) reply=%dw budget=%d closing=%q",
			verdict, reply.Host, reply.At[:min(19, len(reply.At))], reply.Episode,
			reply.Effort, len(strings.Fields(reply.Trigger)), reply.TriggerState,
			words, decisionpkg.ReplyWordBudget(reply.Trigger, lane),
			decisionpkg.HandBackClosing(reply.Reply))
	}

	sort.Ints(lengths)
	quantile := func(fraction float64) int {
		index := min(int(fraction*float64(len(lengths))), len(lengths)-1)
		return lengths[index]
	}
	share := 100 * float64(rejected) / float64(len(replies))
	t.Logf("corpus %d replies: median %d words, p90 %d, p98 %d, longest %d",
		len(replies), quantile(0.5), quantile(0.9), quantile(0.98),
		lengths[len(lengths)-1])
	t.Logf("verdicts %v (%.1f%% rejected, %d undecided trigger)", counts, share, undecided)
	t.Logf("by recorded lane %v", byLane)
	t.Logf("by effort %v", byEffort)

	switch {
	case share > maxRejectedShare:
		t.Errorf("the host would reject %.1f%% of posted replies, over the %.0f%% this "+
			"calibration was signed off at; read the rejections above before moving the "+
			"line, because the ladder that ran at 11%% was rejecting good answers",
			share, maxRejectedShare)
	case rejected == 0:
		t.Errorf("the host would reject none of %d posted replies, so the bound is "+
			"no longer measuring anything", len(replies))
	}
}

// longTrigger is appended to a trigger that survived only as its first 180
// bytes, to score it at the top of the ladder as well as the bottom.
var longTrigger = strings.Repeat(" filler", 60)

// maxRejectedShare is the rejection rate this calibration was signed off at,
// with room above it. The ladder that shipped first measured 11.0% against the
// same corpus and a read of all 27 of those rejections found 22 to be good
// answers; this one measures 4.5%. Eight is far enough above that ordinary
// drift does not trip it and near enough that a return to the old behaviour
// does.
const maxRejectedShare = 8.0

func replayVerdict(trigger, lane, reply string) string {
	correction := decisionpkg.ReplyShapeCorrection(trigger, lane, "reply", reply)
	switch {
	case strings.Contains(correction, "bound for a message"):
		return "length"
	case strings.Contains(correction, "hands the question back"):
		return "handback"
	default:
		return "accept"
	}
}
