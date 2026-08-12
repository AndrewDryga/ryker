package episode

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestPreferredWaitingThreadUsesExactHumanConversation(t *testing.T) {
	input := core.SlackInput{ThreadTS: "thread", MessageTS: "message"}
	if got := PreferredWaitingThread(input, "response", false); got != "response" {
		t.Fatalf("response thread = %q", got)
	}
	if got := PreferredWaitingThread(input, "", false); got != "thread" {
		t.Fatalf("input thread = %q", got)
	}
	if got := PreferredWaitingThread(input, "", true); got != "" {
		t.Fatalf("operational thread preference = %q", got)
	}
}

func TestWaitingEpisodeOnlyAcceptsItsOperatorAnswer(t *testing.T) {
	episode := core.WorkEpisode{
		State:       core.EpisodeWaitingOperator,
		Destination: core.BoundDestination{ChannelID: "COPS", ThreadTS: "1.0"},
	}
	if !AcceptsOperatorAnswer(episode, core.SlackInput{
		Kind: "message", ChannelID: "COPS", ThreadTS: "1.0",
	}, "1.0", true) {
		t.Fatal("exact threaded answer did not resume waiting work")
	}
	if AcceptsOperatorAnswer(episode, core.SlackInput{
		Kind: "message", ChannelID: "COTHER", ThreadTS: "1.0",
	}, "1.0", true) {
		t.Fatal("answer from another channel resumed waiting work")
	}
	episode.Destination.ThreadTS = ""
	if !AcceptsOperatorAnswer(episode, core.SlackInput{
		Kind: "message", ChannelID: "COPS",
	}, "", true) {
		t.Fatal("active channel follow-up did not answer a channel-level question")
	}
}
