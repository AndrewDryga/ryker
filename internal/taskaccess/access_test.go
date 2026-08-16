package taskaccess

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// accessConfig is the shape the 2026-08-16 refusals happened in: a channel
// pointed at a repository set, an alert posted by an app, and the one
// repository the set actually writes to sitting behind the set's name.
func accessConfig() config.Config {
	return config.Config{
		Slack: config.SlackConfig{
			TeamID:            "T123ABC",
			Operators:         []string{"UOPERATOR"},
			DefaultRepository: "tenant-platform",
		},
		Repositories: map[string]config.Repository{
			"tenant-infra": {
				DisplayName:       "Tenant infrastructure",
				CoopPolicy:        "infra-observe",
				ContributorPolicy: "infra-contributor",
				Path:              "/srv/repos/tenant-infra",
			},
			"tenant-backend": {
				DisplayName:       "Tenant backend",
				CoopPolicy:        "backend-observe",
				ContributorPolicy: "backend-contributor",
				Path:              "/srv/repos/tenant-backend",
			},
			"tenant-ops": {
				DisplayName: "Tenant operations",
				CoopPolicy:  "ops-observe",
				Path:        "/srv/repos/tenant-ops",
			},
		},
		RepositorySets: map[string]config.RepositorySet{
			"tenant-platform": {
				DisplayName:       "All Tenant repositories",
				Primary:           "tenant-infra",
				CoopPolicy:        "platform-observe",
				ContributorPolicy: "platform-contributor",
			},
		},
	}
}

// accessStore opens a store whose channel is configured for repository, or for
// nothing at all when repository is empty.
func accessStore(t *testing.T, channelID, repository string) *store.Store {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if repository == "" {
		return st
	}
	if _, err := st.SaveChannelConfiguration(context.Background(), core.ChannelConfiguration{
		ChannelID: channelID, Participation: "proactive", Repository: repository,
		AlertPolicy: "offer", ActorID: "UOPERATOR",
	}); err != nil {
		t.Fatal(err)
	}
	return st
}

func alertInput(channelID string) core.SlackInput {
	return core.SlackInput{
		ID: "slack-alert", EventID: "event-alert", Kind: "bot_message",
		TeamID: "T123ABC", ChannelID: channelID, UserID: "B0TENANTBT3",
		Text: "[FIRING] Grafana: deploy pack drift",
	}
}

// The repository the model names is authorized when the channel's configured
// context contains it, and a set contains its primary.
//
// Refused five times on 2026-08-16; no task button was ever rendered for a fix
// the model had named correctly. The author of an alert is the Grafana app,
// which is never an operator, so the offer took the workspace-member path and
// compared "tenant-infra" to the set name "tenant-platform" as strings.
func TestAlertOfferAcceptsTheSetsPrimaryRepository(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "tenant-platform")
	resolved, err := ResolveOfferRepository(ctx, cfg, st, alertInput("CALERTS"), "tenant-infra")
	if err != nil || resolved != "tenant-infra" {
		t.Fatalf("alert offer repository = %q, err=%v", resolved, err)
	}
}

// A workspace member's own message gets the same boundary: the set's primary
// is inside the channel's context, and the task runs in the repository the
// model named rather than in the set's name.
func TestMemberOfferAcceptsTheSetsPrimaryRepository(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "tenant-platform")
	input := core.SlackInput{
		ID: "slack-member", EventID: "event-member", Kind: "message",
		TeamID: "T123ABC", ChannelID: "CALERTS", UserID: "UMEMBER",
		Text: "Can you fix the drifted pack?",
	}
	resolved, err := ResolveOfferRepository(ctx, cfg, st, input, "tenant-infra")
	if err != nil || resolved != "tenant-infra" {
		t.Fatalf("member offer repository = %q, err=%v", resolved, err)
	}
}

// Widening the boundary to a set's primary must not widen it to the set's
// companions: a member's writable boundary is one checkout, not a fleet.
func TestMemberOfferStillRefusesARepositoryOutsideTheChannelContext(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "tenant-platform")
	input := core.SlackInput{
		ID: "slack-member", EventID: "event-member", Kind: "message",
		TeamID: "T123ABC", ChannelID: "CALERTS", UserID: "UMEMBER",
		Text: "Patch the backend instead.",
	}
	resolved, err := ResolveOfferRepository(ctx, cfg, st, input, "tenant-backend")
	if err == nil || !strings.Contains(err.Error(), "not authorized for this channel") {
		t.Fatalf("cross-context member offer = %q, err=%v", resolved, err)
	}
}

// An app has no authority of its own to check, so an alert is never asked to
// pick a repository — the human who clicks the offer is authorized at click
// time by handleWatchTaskOfferAction.
//
// On 2026-08-16 every alert reply of the day ended in "Which configured
// repository should I use for this engineering task", addressed to a Grafana
// bot that cannot answer.
func TestBotAlertOfferFallsBackToTheChannelRepositoryInsteadOfAsking(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	for name, test := range map[string]struct {
		channelRepository string
		requested         string
		want              string
	}{
		"named nothing": {
			channelRepository: "tenant-platform", requested: "", want: "tenant-platform",
		},
		"named a repository that is not configured": {
			channelRepository: "tenant-platform", requested: "tenant-unknown", want: "tenant-platform",
		},
		"channel repository has no contributor policy": {
			channelRepository: "tenant-ops", requested: "", want: "tenant-ops",
		},
		"channel is not configured at all": {
			channelRepository: "", requested: "", want: "tenant-platform",
		},
	} {
		t.Run(name, func(t *testing.T) {
			st := accessStore(t, "CALERTS", test.channelRepository)
			resolved, err := ResolveOfferRepository(
				ctx, cfg, st, alertInput("CALERTS"), test.requested,
			)
			if err != nil || resolved != test.want {
				t.Fatalf("alert offer repository = %q, want %q, err=%v", resolved, test.want, err)
			}
		})
	}
}

// The click side carries the same boundary as the offer side. Without this the
// fix above would render a button that refuses itself.
func TestMemberStartAcceptsTheSetsPrimaryRepository(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "tenant-platform")
	if err := ValidateMemberStart(ctx, cfg, st, "CALERTS", "tenant-infra"); err != nil {
		t.Fatalf("member start of the set primary = %v", err)
	}
	if err := ValidateMemberStart(ctx, cfg, st, "CALERTS", "tenant-backend"); err == nil {
		t.Fatal("member started a task outside the channel contributor boundary")
	}
}
