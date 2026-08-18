package service

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// routedTurn is what one proactively watched message asked Coop for.
type routedTurn struct {
	policies []string
	prompt   string
	profiles []string
}

// watchTurnUnderProfile drives one unaddressed channel message end to end and
// reports the Coop submission it produced. watchPolicy is the policy an
// operator pointed the watch profile at, or "" for a deployment that has
// configured no profiles at all.
func watchTurnUnderProfile(t *testing.T, watchPolicy string) routedTurn {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CROUTE"}
	cfg.Slack.SummonChannels = nil
	if watchPolicy != "" {
		repository := cfg.Repositories["repo"]
		repository.Profiles = map[string]config.SessionProfile{
			config.ProfileWatch: {Policy: watchPolicy},
		}
		cfg.Repositories["repo"] = repository
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"ignore","attention":{"addressee":"human","urgency":0,"confidence":3,` +
			`"novelty":0,"ownership":0,"contribution":"none","material":false},` +
			`"reason":"humans talking to each other","operations":[]}`,
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	// Both turns of the byte-identity comparison read one frozen instant. The
	// prompt embeds current_time_utc at whole seconds, and two builds that
	// straddled a boundary differed by exactly one byte at offset ~16565 —
	// a flake in the one test whose whole claim is "not one byte".
	svc.SetClock(func() time.Time {
		return time.Date(2026, time.August, 15, 6, 0, 0, 0, time.UTC)
	})
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	input := core.SlackInput{
		ID: "slack-routed", EnvelopeID: "env-routed", EventID: "event-routed",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CROUTE",
		MessageTS: "1700.100", UserID: "U456DEF",
		Text: "deploy finished, going to grab lunch",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("the watched message submitted %d turns, want 1",
			len(coopClient.submitPrompts))
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the attempt's context manifest: %v", err)
	}
	var profiles []string
	for _, reference := range manifest.References {
		if reference.Kind == executionProfileKind {
			profiles = append(profiles, reference.SourceRef)
		}
	}
	return routedTurn{
		policies: coopClient.createPolicies,
		prompt:   coopClient.submitPrompts[0],
		profiles: profiles,
	}
}

// Routing is allowed to change which rung answers and nothing else.
//
// This is the spine of the effort-profile slice, and it holds two claims shut
// at once. A deployment that has configured no profiles must ask Coop for the
// policy it asked for before profiles existed — routing arrives switched off,
// and an operator turns one lane on at a time rather than discovering their
// whole watch lane moved on upgrade. And a deployment that HAS routed a lane
// must send that lane's rung the same bytes: the moment a profile can reach the
// prompt, a cheap-rung experiment stops measuring the rung and starts measuring
// a second prompt nobody wrote down, which is how a routing change becomes
// unattributable.
func TestProfileRoutingChangesThePolicyAndNotOneByteOfTheTurn(t *testing.T) {
	unrouted := watchTurnUnderProfile(t, "")
	routed := watchTurnUnderProfile(t, "repo-watch")

	if !slices.Equal(unrouted.policies, []string{"repo-observe"}) {
		t.Fatalf("a deployment with no profiles configured asked Coop for %v, "+
			"want the watch lane's own coop_policy [repo-observe]", unrouted.policies)
	}
	if !slices.Equal(routed.policies, []string{"repo-watch"}) {
		t.Fatalf("a routed watch profile asked Coop for %v, want [repo-watch]",
			routed.policies)
	}
	if unrouted.prompt != routed.prompt {
		t.Fatalf("routing the watch lane changed the submitted turn.\n"+
			"unrouted (%d bytes):\n%.2000s\n\nrouted (%d bytes):\n%.2000s",
			len(unrouted.prompt), unrouted.prompt,
			len(routed.prompt), routed.prompt)
	}
	// The profile is recorded either way. An unrouted deployment still gets the
	// attribution, which is what makes "what would this have cost on another
	// rung" answerable before anybody changes a policy.
	for _, turn := range []routedTurn{unrouted, routed} {
		if !slices.Equal(turn.profiles, []string{"profile:watch"}) {
			t.Fatalf("the manifest recorded profiles %v, want [profile:watch]",
				turn.profiles)
		}
	}
}

// A later attempt says which profile IT asked for, not which one its
// predecessor did.
//
// Attempt N+1 inherits every still-eligible reference from attempt N, which is
// right for context — the model should keep seeing what it saw — and wrong for
// a fact about the attempt that made it. The profile moves: the bounded
// conversation lane escalates to the investigation lane mid-episode, and a
// manifest listing both would answer "what was this routed as" by ordinal.
func TestARoutedRetryCarriesForwardTheContextAndNotThePreviousProfile(t *testing.T) {
	merged := mergeContextReferences(
		[]core.ContextReference{
			{Kind: "source_input", SourceRef: "slack:1700.100", Visibility: "eligible"},
			{Kind: executionProfileKind, SourceRef: "profile:chat", Visibility: "private"},
		},
		[]core.ContextReference{
			{Kind: executionProfileKind, SourceRef: "profile:investigate", Visibility: "private"},
		},
	)
	var profiles, kinds []string
	for _, reference := range merged {
		kinds = append(kinds, reference.Kind)
		if reference.Kind == executionProfileKind {
			profiles = append(profiles, reference.SourceRef)
		}
	}
	if !slices.Equal(profiles, []string{"profile:investigate"}) {
		t.Fatalf("the escalated attempt's manifest lists profiles %v, "+
			"want only the one it asked for", profiles)
	}
	if !slices.Contains(kinds, "source_input") {
		t.Fatalf("the carried-forward context was dropped: %v", kinds)
	}
}

// A scheduled verification changed legally from watch to investigate, but the
// store treated the attempt-local routing label like durable context. The same
// manifest error then consumed all 20 retries over roughly 64 minutes without
// starting one model turn. Persisting the merged child is the boundary the
// older in-memory-only test did not cross.
func TestARoutedRetryPersistsOnlyItsCurrentProfile(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CROUTE",
		ConversationKey: "channel:CROUTE", SourceKind: "recheck", SourceID: "wake-profile",
		Episode: &core.WorkEpisode{Effort: core.EffortFocusedCheck},
	})
	if err != nil || !created {
		t.Fatalf("queue routed retry = %+v, %t, %v", run, created, err)
	}
	parentRefs := []core.ContextReference{
		{Kind: "source_input", SourceRef: "slack:1700.100", Visibility: "eligible"},
		{Kind: executionProfileKind, SourceRef: "profile:watch", Visibility: "private"},
	}
	parent, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: run.EpisodeID, AttemptID: run.AttemptID,
		References: parentRefs,
	})
	if err != nil {
		t.Fatal(err)
	}
	childRefs := mergeContextReferences(parentRefs, []core.ContextReference{{
		Kind: executionProfileKind, SourceRef: "profile:investigate", Visibility: "private",
	}})
	child, err := st.CreateContextManifest(ctx, core.ContextManifest{
		EpisodeID: run.EpisodeID, AttemptID: run.AttemptID,
		ParentManifestID: parent.ID, References: childRefs,
	})
	if err != nil {
		t.Fatalf("persist routed retry manifest: %v", err)
	}
	var profiles []string
	var carriedSource bool
	for _, ref := range child.References {
		if ref.Kind == executionProfileKind {
			profiles = append(profiles, ref.SourceRef)
		}
		if ref.Kind == "source_input" && ref.SourceRef == "slack:1700.100" {
			carriedSource = true
		}
	}
	if !slices.Equal(profiles, []string{"profile:investigate"}) || !carriedSource {
		t.Fatalf("persisted routed references = %+v", child.References)
	}
}

// workRoom creates one incident or engineering task ready for its Coop session.
func workRoom(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	cfg config.Config,
	sourceID, channelID, userID string,
	task bool,
) core.Incident {
	t.Helper()
	create := st.CreateManualIncident
	if task {
		create = st.CreateEngineeringTask
	}
	incident, created, err := create(
		ctx, "repo", sourceID, "Work "+sourceID, "Work "+sourceID, userID,
		"CSOURCE", "1700.001", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create %s = %+v, %v, %v", sourceID, incident, created, err)
	}
	if err := st.SetChannel(ctx, incident.ID, channelID, "room-"+sourceID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	return incident
}

// An incident room and an engineering task are different work at different
// authority, and each asks for the profile that names it. They shared one
// coop_policy before profiles existed and still do by default; what this holds
// shut is that a deployment which separates them gets the separation it asked
// for, in the room where the writable fork is.
func TestAWorkRoomAsksForTheProfileThatNamesTheWorkItIs(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.Profiles = map[string]config.SessionProfile{
		config.ProfileInvestigate: {Policy: "repo-incident"},
		config.ProfileEngineer:    {Policy: "repo-engineer"},
	}
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	incident := workRoom(t, ctx, st, cfg, "incident", "CINCIDENT", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	task := workRoom(t, ctx, st, cfg, "task", "CTASK", "U123ABC", true)
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"repo-incident", "repo-engineer"}) {
		t.Fatalf("work rooms asked Coop for %v, want [repo-incident repo-engineer]",
			coopClient.createPolicies)
	}
}

// A profile selects which rung answers. It must never be able to answer the
// separate question of whether this deployment has a writable contributor lane
// at all — that refusal is an authority boundary, and a repository with no
// contributor policy has to keep refusing a teammate's writable task however
// its engineer profile is configured.
func TestAnEngineerProfileDoesNotSupplyAMissingContributorPolicy(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.ContributorPolicy = ""
	repository.Profiles = map[string]config.SessionProfile{
		config.ProfileEngineer: {Policy: "repo-engineer"},
	}
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	// U777MEM is not a configured operator, so the task runs on contributor
	// authority — the lane this repository has not configured.
	task := workRoom(t, ctx, st, cfg, "member-task", "CMEMBER", "U777MEM", true)
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	blocked, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if blocked.Workflow != core.WorkflowBlocked {
		t.Fatalf("a contributor task on a repository with no contributor policy "+
			"reached workflow %q, want blocked", blocked.Workflow)
	}
	if len(coopClient.createPolicies) != 0 {
		t.Fatalf("the engineer profile supplied a writable policy an operator "+
			"never configured: Coop was asked for %v", coopClient.createPolicies)
	}
}
