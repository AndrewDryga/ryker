package taskaccess

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store"
)

// accessConfig is the shape the 2026-08-16 refusals happened in: a channel
// pointed at a repository set, an alert posted by an app, and the one
// repository the set actually writes to sitting behind the set's name.
func accessConfig() config.Config {
	return config.Config{
		Slack: config.SlackConfig{
			TeamID:            "T123ABC",
			Operators:         []string{"UOPERATOR"},
			DefaultRepository: "blitz-platform",
		},
		Repositories: map[string]config.Repository{
			"blitz-infra": {
				DisplayName:       "Blitz infrastructure",
				CoopPolicy:        "infra-observe",
				ContributorPolicy: "infra-contributor",
				Path:              "/srv/repos/blitz-infra",
			},
			"blitz-backend": {
				DisplayName:       "Blitz backend",
				CoopPolicy:        "backend-observe",
				ContributorPolicy: "backend-contributor",
				Path:              "/srv/repos/blitz-backend",
			},
			"blitz-ops": {
				DisplayName: "Blitz operations",
				CoopPolicy:  "ops-observe",
				Path:        "/srv/repos/blitz-ops",
			},
		},
		RepositorySets: map[string]config.RepositorySet{
			"blitz-platform": {
				DisplayName:       "All Blitz repositories",
				Primary:           "blitz-infra",
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

// An operator-started Rivals task created and rejected nine read-only Coop
// sessions in thirty minutes, so its accepted engineering run never started.
// Engineering work needs the repository's writable policy regardless of which
// authorized person created it; contributor remains the separate member flag.
func TestOperatorEngineeringTaskUsesTheWritableRepositoryPolicy(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "blitz-infra")
	task, created, err := st.CreateEngineeringTask(
		ctx, "blitz-infra", "operator-engineering", "Fix the drift", "Apply the fix",
		"UOPERATOR", "CALERTS", "1700.001", 10,
	)
	if err != nil || !created {
		t.Fatalf("create operator engineering task = %+v, %t, %v", task, created, err)
	}
	policy, contributor, err := SessionPolicy(ctx, cfg, st, task, cfg.Repositories["blitz-infra"])
	if err != nil {
		t.Fatal(err)
	}
	if policy != "infra-contributor" || contributor {
		t.Fatalf("operator engineering policy = %q, contributor=%t", policy, contributor)
	}
}

func alertInput(channelID string) core.SlackInput {
	return core.SlackInput{
		ID: "slack-alert", EventID: "event-alert", Kind: "bot_message",
		TeamID: "T123ABC", ChannelID: channelID, UserID: "B0910HETYAH",
		Text: "[FIRING] Grafana: deploy pack drift",
	}
}

// The repository the model names is authorized when the channel's configured
// context contains it, and a set contains its primary.
//
// Refused five times on 2026-08-16; no task button was ever rendered for a fix
// the model had named correctly. The author of an alert is the Grafana app,
// which is never an operator, so the offer took the workspace-member path and
// compared "blitz-infra" to the set name "blitz-platform" as strings.
// Covers: TestAlertPreparedFixForRepositorySetPrimaryRemainsActionable
// Covers: TestPreparedAlertTaskUsesActiveRepositorySetWhenOfferNamesItsPrimary
// Covers: TestRepositorySetPrimaryOfferUsesChannelWritableContext
// Covers: TestPrimaryRepositoryOfferUsesTheChannelsRepositorySet
// Covers: TestPreparedFixFromExternalAlertSurvivesBotIdentity
// Covers: TestPrimaryRepositoryOfferUsesAuthorizedRepositorySet
func TestAlertOfferAcceptsTheSetsPrimaryRepository(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "blitz-platform")
	resolved, err := ResolveOfferRepository(ctx, cfg, st, alertInput("CALERTS"), "blitz-infra")
	if err != nil || resolved != "blitz-infra" {
		t.Fatalf("alert offer repository = %q, err=%v", resolved, err)
	}
}

// A workspace member's own message gets the same boundary: the set's primary
// is inside the channel's context, and the task runs in the repository the
// model named rather than in the set's name.
func TestMemberOfferAcceptsTheSetsPrimaryRepository(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "blitz-platform")
	input := core.SlackInput{
		ID: "slack-member", EventID: "event-member", Kind: "message",
		TeamID: "T123ABC", ChannelID: "CALERTS", UserID: "UMEMBER",
		Text: "Can you fix the drifted pack?",
	}
	resolved, err := ResolveOfferRepository(ctx, cfg, st, input, "blitz-infra")
	if err != nil || resolved != "blitz-infra" {
		t.Fatalf("member offer repository = %q, err=%v", resolved, err)
	}
}

// Widening the boundary to a set's primary must not widen it to the set's
// companions: a member's writable boundary is one checkout, not a fleet.
func TestMemberOfferStillRefusesARepositoryOutsideTheChannelContext(t *testing.T) {
	ctx := context.Background()
	cfg := accessConfig()
	st := accessStore(t, "CALERTS", "blitz-platform")
	input := core.SlackInput{
		ID: "slack-member", EventID: "event-member", Kind: "message",
		TeamID: "T123ABC", ChannelID: "CALERTS", UserID: "UMEMBER",
		Text: "Patch the backend instead.",
	}
	resolved, err := ResolveOfferRepository(ctx, cfg, st, input, "blitz-backend")
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
			channelRepository: "blitz-platform", requested: "", want: "blitz-platform",
		},
		"named a repository that is not configured": {
			channelRepository: "blitz-platform", requested: "blitz-unknown", want: "blitz-platform",
		},
		"channel repository has no contributor policy": {
			channelRepository: "blitz-ops", requested: "", want: "blitz-ops",
		},
		"channel is not configured at all": {
			channelRepository: "", requested: "", want: "blitz-platform",
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
	st := accessStore(t, "CALERTS", "blitz-platform")
	if err := ValidateMemberStart(ctx, cfg, st, "CALERTS", "blitz-infra"); err != nil {
		t.Fatalf("member start of the set primary = %v", err)
	}
	if err := ValidateMemberStart(ctx, cfg, st, "CALERTS", "blitz-backend"); err == nil {
		t.Fatal("member started a task outside the channel contributor boundary")
	}
}
