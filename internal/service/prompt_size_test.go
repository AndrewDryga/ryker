package service

import (
	"sort"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// promptCeilings caps the static instruction size of each prompt with empty
// context.
//
// A Coop turn is capped at 64 KiB. Whatever the instructions do not use is what
// the model gets to see of the actual conversation — so this is not a style
// budget, it is the context budget. Lower an entry when a diet phase lands;
// raising one means every future turn sees less of its channel, which needs a
// reason written here.
var promptCeilings = map[string]int{
	"watch": 50 * 1024,
}

func TestStaticPromptSizeIsBounded(t *testing.T) {
	sizes := staticPromptSizes(t)
	for name, ceiling := range promptCeilings {
		size, ok := sizes[name]
		if !ok {
			t.Fatalf("no measurement for the %q prompt; update this test", name)
		}
		remaining := coop.MaxPromptBytes - size
		t.Logf(
			"%s prompt: %d bytes of instructions, %d bytes (%d%%) left for context",
			name, size, remaining, remaining*100/coop.MaxPromptBytes,
		)
		if size > ceiling {
			t.Errorf(
				"the %s prompt is %d bytes of static instructions, over its %d ceiling; "+
					"that is %d bytes taken from what the model sees of the conversation",
				name, size, ceiling, size-ceiling,
			)
		}
	}
}

// TestStaticPromptSectionSizes reports where the budget actually goes, so a
// diet targets the expensive blocks instead of the obvious ones.
func TestStaticPromptSectionSizes(t *testing.T) {
	type section struct {
		name  string
		bytes int
	}
	sections := []section{
		{"operationalMemoryPolicy", len(operationalMemoryPolicy)},
		{"behaviorOfferPolicy", len(behaviorOfferPolicy)},
		{"compoundRequestPolicy", len(compoundRequestPolicy)},
		{"emisarGovernedActionPolicy", len(emisarGovernedActionPolicy)},
		{"slackReplyFormattingPolicy", len(slackReplyFormattingPolicy)},
		{"investigation.ResultOperationsPrompt", len(investigation.ResultOperationsPrompt())},
	}
	total := staticPromptSizes(t)["watch"]
	accounted := 0
	sort.Slice(sections, func(i, j int) bool { return sections[i].bytes > sections[j].bytes })
	for _, item := range sections {
		accounted += item.bytes
		t.Logf("%-40s %6d bytes (%2d%% of the watch prompt)",
			item.name, item.bytes, item.bytes*100/total)
	}
	t.Logf("%-40s %6d bytes", "named policy blocks, total", accounted)
	t.Logf("%-40s %6d bytes", "inline instructions and scaffolding", total-accounted)
}

func staticPromptSizes(t *testing.T) map[string]int {
	t.Helper()
	svc := &Service{cfg: serviceConfig(t)}
	return map[string]int{
		"watch": len(svc.unboundedWatchPrompt(
			core.SlackInput{ChannelID: "C1", Text: "check the api"},
			"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
			operationalMemoryContext{}, "emisar", nil,
		)),
	}
}
