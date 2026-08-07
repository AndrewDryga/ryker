package service

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// Memory is only useful if operators can trust where it goes. These assert the
// boundaries directly rather than through a model, because a leak here is the
// most damaging failure the memory system can have and it must be caught on
// every commit, not on an eval run.
func TestMemoryVisibilityBoundaries(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, nil, nil)

	const (
		homeChannel  = "C123ABC"
		otherChannel = "COTHER1"
		operator     = "U123ABC"
		colleague    = "UOTHER1"
	)
	seed := func(entry core.MemoryEntry) {
		t.Helper()
		entry.ExpiresAt = svc.now().Add(24 * time.Hour)
		entry.SourceRef = "slack_seed"
		entry.ActorID = operator
		if _, _, err := st.Memory.UpsertMemoryEntry(ctx, entry, 1000, 100); err != nil {
			t.Fatal(err)
		}
	}

	seed(core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: cfg.Slack.TeamID,
		SubjectKey: "shared_convention", Predicate: "guidance",
		Value:          "workspace-wide guidance",
		VisibilityKind: "workspace", VisibilityID: cfg.Slack.TeamID,
	})
	seed(core.MemoryEntry{
		ScopeKind: "channel", ScopeKey: homeChannel,
		SubjectKey: "channel_convention", Predicate: "guidance",
		Value:          "home channel guidance",
		VisibilityKind: "channel", VisibilityID: homeChannel,
	})
	seed(core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: cfg.Slack.TeamID,
		SubjectKey: "private_preference", Predicate: "guidance",
		Value:          "operator-private guidance",
		VisibilityKind: "operator", VisibilityID: operator,
	})

	values := func(channelID, userID string) map[string]bool {
		t.Helper()
		context, err := svc.loadOperationalMemoryContext(
			ctx, channelID, cfg.Slack.DefaultRepository, userID, "slack_probe", "guidance",
		)
		if err != nil {
			t.Fatal(err)
		}
		seen := map[string]bool{}
		for _, entry := range context.ConfirmedMemory {
			seen[entry.Value] = true
		}
		return seen
	}

	// The operator in their own channel sees all three.
	own := values(homeChannel, operator)
	for _, expected := range []string{
		"workspace-wide guidance", "home channel guidance", "operator-private guidance",
	} {
		if !own[expected] {
			t.Errorf("the owning operator could not see %q", expected)
		}
	}

	// A colleague in the same channel sees the shared entries but never the
	// operator-private one — that is the boundary that lets someone record a
	// personal working preference without broadcasting it.
	other := values(homeChannel, colleague)
	if other["operator-private guidance"] {
		t.Error("operator-private guidance leaked to another operator")
	}
	if !other["home channel guidance"] || !other["workspace-wide guidance"] {
		t.Errorf("shared guidance did not reach a colleague: %+v", other)
	}

	// The same operator in a different channel keeps their private entry and
	// the workspace entry, but not the other channel's.
	elsewhere := values(otherChannel, operator)
	if elsewhere["home channel guidance"] {
		t.Error("channel-scoped guidance leaked across channels")
	}
	if !elsewhere["operator-private guidance"] {
		t.Error("operator-private guidance did not follow its operator")
	}
	if !elsewhere["workspace-wide guidance"] {
		t.Error("workspace guidance did not reach another channel")
	}
}

// Cross-channel recall is what lets the agent carry context between rooms, and
// it is exactly where a private conversation could leak. Only channels
// Responder is present in and that are not private may contribute.
func TestRelatedConversationRecallExcludesPrivateAndAbsentChannels(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	const home = "C123ABC"
	summary := func(channelID, text string) {
		t.Helper()
		if err := st.UpsertConversationMemoryState(ctx, core.ConversationMemory{
			ChannelID: channelID, Repository: cfg.Slack.DefaultRepository,
			LastMessage: "1700.001",
			State:       core.AgentMemory{SituationSummary: text},
		}); err != nil {
			t.Fatal(err)
		}
	}
	summary(home, "home channel situation")
	summary("CPUBLIC", "public channel situation")
	summary("CPRIVATE", "private channel situation")
	summary("CABSENT", "channel responder has left")

	if err := st.ReconcileSlackChannelMemberships(ctx, []store.SlackChannelMembershipObservation{
		{ChannelID: home, ChannelName: "home", Present: true, Private: false},
		{ChannelID: "CPUBLIC", ChannelName: "public", Present: true, Private: false},
		{ChannelID: "CPRIVATE", ChannelName: "private", Present: true, Private: true},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	related, err := st.ListRelatedConversationMemories(
		ctx, home, "", cfg.Slack.DefaultRepository, 40,
	)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, item := range related {
		seen[item.State.SituationSummary] = true
	}
	if seen["private channel situation"] {
		t.Error("a private channel's conversation leaked into cross-channel recall")
	}
	if seen["channel responder has left"] {
		t.Error("a channel Responder is not present in leaked into cross-channel recall")
	}
	if !seen["public channel situation"] {
		t.Errorf("a public channel Responder is in did not contribute: %+v", seen)
	}
}
