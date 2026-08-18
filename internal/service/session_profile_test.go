package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/storetest"
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
	coopClient.session.RepositoryReadOnly = false
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"repo-incident", "repo-engineer"}) {
		t.Fatalf("work rooms asked Coop for %v, want [repo-incident repo-engineer]",
			coopClient.createPolicies)
	}
}

// Six parked production incidents still owned writable observe sessions after
// the policy changed. A new read-only incident must reject that authority
// before binding it.
func TestAReadOnlyIncidentNeverBindsANewWritableCoopSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_candidate"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_candidate", SessionID: coopClient.session.ID, Ordinal: 1, State: "running",
	}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	created := workRoom(t, ctx, st, cfg, "new-read-only", "CNEW", "U123ABC", false)
	err = svc.processSessionIncident(ctx, created.ID)
	var deferred scheduledWorkDeferral
	if !errors.As(err, &deferred) {
		t.Fatalf("authority mismatch returned %v, want slow circuit-breaker deferral", err)
	}
	created, err = st.GetIncident(ctx, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if created.CoopSessionID != "" || created.CoopSessionGeneration != 5 ||
		created.Workflow != core.WorkflowHolding {
		t.Fatalf("writable created session remained bound: %+v", created)
	}
	if len(coopClient.createKeys) != sessioncreate.MaxReadOnlyCandidates {
		t.Fatalf("created %d writable candidates, want bounded %d", len(coopClient.createKeys), sessioncreate.MaxReadOnlyCandidates)
	}
	if !slices.Equal(coopClient.cancelTurns, []string{"turn_candidate"}) {
		t.Fatalf("rejected candidate turns were not revoked: %v", coopClient.cancelTurns)
	}
	cleanup, err := st.NextCleanup(ctx, time.Now().Add(time.Minute))
	if err != nil || cleanup.SessionID != coopClient.session.ID {
		t.Fatalf("writable created session cleanup = %+v, %v", cleanup, err)
	}
}

// Engineering is an exact authority lane too. Binding a read-only session to
// confirmed work produces a healthy-looking room whose first edit can never
// succeed.
func TestAnEngineeringTaskNeverBindsAReadOnlyCoopSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	task := workRoom(t, ctx, st, cfg, "read-only-task", "CTASKRO", "U123ABC", true)

	err = svc.processSessionIncident(ctx, task.ID)
	var deferred scheduledWorkDeferral
	if !errors.As(err, &deferred) {
		t.Fatalf("engineering authority mismatch returned %v, want slow circuit-breaker deferral", err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.CoopSessionID != "" || task.CoopSessionGeneration != 5 ||
		task.Workflow != core.WorkflowHolding {
		t.Fatalf("read-only engineering session was bound: %+v", task)
	}
	if len(coopClient.createKeys) != sessioncreate.MaxReadOnlyCandidates {
		t.Fatalf("created %d read-only candidates, want bounded %d", len(coopClient.createKeys), sessioncreate.MaxReadOnlyCandidates)
	}
}

func TestAReadOnlyIncidentRotatesALegacyWritableCoopSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	legacy := workRoom(t, ctx, st, cfg, "legacy-read-only", "CLEGACY", "U123ABC", false)
	if err := st.SetCoopSession(ctx, legacy.ID, coopClient.session.ID, "legacy-fork", 1); err != nil {
		t.Fatal(err)
	}
	if err := svc.pollIncident(ctx, legacy); err != nil {
		t.Fatal(err)
	}
	legacy, err = st.GetIncident(ctx, legacy.ID)
	if err != nil {
		t.Fatal(err)
	}
	if legacy.CoopSessionID != "" || legacy.CoopSessionGeneration != 2 ||
		legacy.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("legacy writable session remained bound: %+v", legacy)
	}
	cleanup, err := st.NextCleanup(ctx, time.Now().Add(time.Minute))
	if err != nil || cleanup.SessionID != coopClient.session.ID {
		t.Fatalf("writable session cleanup = %+v, %v", cleanup, err)
	}
}

func TestAnEngineeringTaskStillBindsAWritableCoopSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)

	task := workRoom(t, ctx, st, cfg, "writable-task", "CTASK", "U123ABC", true)
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.CoopSessionID != coopClient.session.ID || task.CoopSessionGeneration != 1 {
		t.Fatalf("writable engineering session was rotated: %+v", task)
	}
	if _, err := st.GetCoopCleanup(ctx, coopClient.session.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("writable engineering session unexpectedly entered cleanup: %v", err)
	}
}

// A crash can leave generation one bound to the previous request shape. The
// accepted work is still valid; generation two is the first key with the exact
// current policy and must be tried without turning the card into a blocker.
func TestAnIncidentAdvancesPastACreateSessionIdempotencyCollision(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.createErrors = []error{&coop.APIError{Status: 409, Code: "idempotency_conflict"}}
	coopClient.openAfterCreateKey = "responder:session:placeholder:2"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "collision", "CCOLLISION", "U123ABC", false)
	coopClient.openAfterCreateKey = sessioncreate.Key("responder:session:"+incident.ID, 2)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.CoopSessionID != "ses_2" || incident.CoopSessionGeneration != 2 ||
		incident.Workflow == core.WorkflowBlocked {
		t.Fatalf("incident collision recovery = %+v", incident)
	}
}

// Exact authority is checked on reuse as well as creation. Otherwise an
// engineering task created before the policy migration keeps a read-only
// checkout forever and every edit fails despite a healthy-looking task card.
func TestAnEngineeringTaskRotatesAnAlreadyBoundReadOnlySession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	task := workRoom(t, ctx, st, cfg, "legacy-engineering", "CLEGACYENG", "U123ABC", true)
	if err := st.SetCoopSession(ctx, task.ID, coopClient.session.ID, "legacy-read-only", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.pollIncident(ctx, task); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.CoopSessionID != "" || task.CoopSessionGeneration != 2 ||
		task.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("legacy read-only engineering session remained bound: %+v", task)
	}
}

// A queued run can race the poller after a policy migration. The submission
// path is therefore an authority boundary of its own: no model turn may start
// in the writable session while the poller is still waiting to rotate it.
func TestAReadOnlyIncidentRunNeverSubmitsToALegacyWritableSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "queued-read-only", "CQUEUED", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	coopClient.session.RepositoryReadOnly = false

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitSessions) != 0 {
		t.Fatalf("read-only run submitted through writable session: %v", coopClient.submitSessions)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.CoopSessionID != "" || incident.CoopSessionGeneration != 2 {
		t.Fatalf("writable incident session was not rotated: %+v", incident)
	}
}

func TestAnEngineeringRunNeverSubmitsToALegacyReadOnlySession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	task := workRoom(t, ctx, st, cfg, "queued-engineering", "CQUEUEDENG", "U123ABC", true)
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	coopClient.session.RepositoryReadOnly = true
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitSessions) != 0 {
		t.Fatalf("engineering run submitted through read-only session: %v", coopClient.submitSessions)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if task.CoopSessionID != "" || task.CoopSessionGeneration != 2 {
		t.Fatalf("read-only engineering session was not rotated: %+v", task)
	}
	run, err := st.GetAgentRunBySource(ctx, "initial", task.ID)
	if err != nil || !strings.Contains(run.LastError, "read-only session") ||
		!strings.Contains(run.LastError, "writable engineering turn") {
		t.Fatalf("engineering authority rotation status = %+v, %v", run, err)
	}
}

// A queued incident run can reach the submission seam while a legacy turn is
// still using write authority. That is convergence work, not a terminal model
// failure: cancel it, preserve the accepted run, and rotate on the next pass.
func TestAnActiveWritableIncidentSessionDefersTheReadOnlyRunAfterRevocation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "queued-active-read-only", "CACTIVEQ", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_legacy_active"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_legacy_active", SessionID: coopClient.session.ID, Ordinal: 1, State: "running",
	}}

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitSessions) != 0 ||
		!slices.Equal(coopClient.cancelTurns, []string{"turn_legacy_active"}) {
		t.Fatalf("authority convergence submitted=%v cancelled=%v", coopClient.submitSessions, coopClient.cancelTurns)
	}
	runs, err := st.ListAgentRunsForIncident(ctx, incident.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("incident runs = %+v, %v", runs, err)
	}
	run := runs[0]
	if err != nil {
		t.Fatal(err)
	}
	if run.State != core.AgentRunPending || run.TerminalState != "" {
		t.Fatalf("accepted run was lost during authority convergence: %+v", run)
	}
}

// A transient Coop failure while revoking legacy write authority used to spend
// the accepted run's model-attempt budget even though no safe session existed
// and no model turn had started. Enough transient failures then discarded the
// operator's request at the repository-authority boundary.
func TestAuthorityConvergenceFailuresNeverSpendModelAttempts(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "convergence-failure", "CCONVERGE", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_legacy_active"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_legacy_active", SessionID: coopClient.session.ID, Ordinal: 1, State: "running",
	}}
	coopClient.cancelErrors = []error{
		&coop.APIError{Status: 503, Code: "internal_error"},
	}

	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	runs, err := st.ListAgentRunsForIncident(ctx, incident.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("incident runs = %+v, %v", runs, err)
	}
	if runs[0].State != core.AgentRunPending || runs[0].Failures != 0 ||
		runs[0].TerminalState != "" {
		t.Fatalf("authority convergence spent or lost accepted work: %+v", runs[0])
	}
}

// Two transient reads of the bound Coop session used to spend two model
// attempts even though neither read reached submission. A long Coop outage
// could therefore discard an accepted lead investigation without a turn.
func TestLeadSessionLookupFailuresNeverSpendModelAttempts(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "lookup-failure", "CLOOKUP", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	coopClient.getSessionErr = &coop.APIError{Status: 503, Code: "internal_error"}

	for attempt := 0; attempt < 2; attempt++ {
		if attempt > 0 {
			storetest.MakeAgentRunDue(t, cfg.StateDir, "initial", incident.ID)
		}
		leased, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := svc.prepareIncidentAgentRun(ctx, leased); err != nil {
			t.Fatal(err)
		}
	}
	runs, err := st.ListAgentRunsForIncident(ctx, incident.ID)
	if err != nil || len(runs) != 1 {
		t.Fatalf("incident runs = %+v, %v", runs, err)
	}
	if runs[0].State != core.AgentRunPending || runs[0].Failures != 0 ||
		runs[0].TerminalState != "" || len(coopClient.submitSessions) != 0 {
		t.Fatalf("lead lookup spent or submitted accepted work: run=%+v submits=%v", runs[0], coopClient.submitSessions)
	}
}

// The incident binding can be cleared after a run leases but before it reads
// the session. That race used to classify the vanished binding as terminal and
// fail the request immediately. It must instead preserve the run and let the
// incident provision the next durable generation.
func TestLeadBindingLossReprovisionsWithoutLosingTheAcceptedRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "binding-loss", "CBINDLOSS", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if rotated, err := st.IncidentSessions.RotateReadOnly(
		ctx, incident.ID, incident.CoopSessionID, incident.CoopSessionGeneration,
		"test binding loss", time.Now().UTC(),
	); err != nil || !rotated {
		t.Fatalf("clear bound session = %t, %v", rotated, err)
	}
	if err := svc.prepareIncidentAgentRun(ctx, leased); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRun(ctx, leased.ID)
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		run.TerminalState != "" || len(coopClient.submitSessions) != 0 {
		t.Fatalf("binding-loss custody run=%+v submits=%v err=%v", run, coopClient.submitSessions, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.CoopSessionID != "" ||
		incident.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("binding loss did not return to provisioning: %+v, %v", incident, err)
	}
}

// A session can close after the incident queues its lead run. The old path
// treated that pre-submission lifecycle race as a terminal run failure. The
// accepted investigation instead needs a fresh generation and durable cleanup
// ownership for the closed session.
func TestLeadTerminalSessionReprovisionsWithoutSpendingTheRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "terminal-session", "CTERMINAL", "U123ABC", false)
	if err := svc.processSessionIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient.session.State = "closed"
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.prepareIncidentAgentRun(ctx, leased); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRun(ctx, leased.ID)
	if err != nil || run.State != core.AgentRunPending || run.Failures != 0 ||
		run.TerminalState != "" || len(coopClient.submitSessions) != 0 {
		t.Fatalf("terminal-session custody run=%+v submits=%v err=%v", run, coopClient.submitSessions, err)
	}
	refreshed, err := st.GetIncident(ctx, incident.ID)
	if err != nil || refreshed.CoopSessionID != "" ||
		refreshed.CoopSessionGeneration != incident.CoopSessionGeneration+1 ||
		refreshed.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("terminal session did not return to provisioning: %+v, %v", refreshed, err)
	}
	cleanup, err := st.GetCoopCleanup(ctx, incident.CoopSessionID)
	if err != nil || cleanup.State != "pending" {
		t.Fatalf("terminal session cleanup = %+v, %v", cleanup, err)
	}
}

// Coop revisions move during cancellation. A retry with the old operation key
// but a new expected revision is a different request and Coop rejects it as an
// idempotency conflict, leaving the writable turn alive forever.
func TestWritableAuthorityRevocationQualifiesRetryKeysByRevision(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_conflict"
	coopClient.listTurns = []coop.Turn{{
		ID: "turn_conflict", SessionID: coopClient.session.ID, Ordinal: 1, State: "running",
	}}
	coopClient.cancelErrors = []error{&coop.APIError{Status: 409, Code: "revision_conflict"}}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "revision-read-only", "CREVISION", "U123ABC", false)
	if err := st.SetCoopSession(ctx, incident.ID, coopClient.session.ID, "legacy-fork", 1); err != nil {
		t.Fatal(err)
	}

	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.cancelKeys) != 2 || coopClient.cancelKeys[0] == coopClient.cancelKeys[1] ||
		!strings.HasSuffix(coopClient.cancelKeys[0], ":1") ||
		!strings.HasSuffix(coopClient.cancelKeys[1], ":2") {
		t.Fatalf("revision-qualified cancel keys = %v revisions=%v", coopClient.cancelKeys, coopClient.cancelRevisions)
	}
}

// A terminal session is an outcome, not a candidate for migration. Rotating
// one reopened completed production work under a new generation instead of
// closing the incident that had finished.
func TestAClosedLegacyWritableSessionClosesItsIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.State = "closed"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "closed-read-only", "CCLOSED", "U123ABC", false)
	if err := st.SetCoopSession(ctx, incident.ID, coopClient.session.ID, "legacy-fork", 1); err != nil {
		t.Fatal(err)
	}
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.Status != core.IncidentClosed || incident.CoopSessionGeneration != 1 {
		t.Fatalf("closed legacy session was reopened: %+v", incident)
	}
}

// Discarded is just as terminal as closed. Treating it as a migration
// candidate reopened completed work or produced a misleading authority error.
func TestADiscardedSessionClosesItsIncidentRegardlessOfRepositoryAuthority(t *testing.T) {
	for _, readOnly := range []bool{false, true} {
		t.Run(map[bool]string{false: "writable", true: "read-only"}[readOnly], func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { st.Close() })
			coopClient := newFakeCoop()
			coopClient.session.RepositoryReadOnly = readOnly
			coopClient.session.State = "discarded"
			svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
			incident := workRoom(t, ctx, st, cfg, fmt.Sprintf("discarded-%t", readOnly), "CDISCARD", "U123ABC", false)
			if err := st.SetCoopSession(ctx, incident.ID, coopClient.session.ID, "legacy-fork", 1); err != nil {
				t.Fatal(err)
			}
			if err := svc.pollIncident(ctx, incident); err != nil {
				t.Fatal(err)
			}
			incident, err = st.GetIncident(ctx, incident.ID)
			if err != nil {
				t.Fatal(err)
			}
			if incident.Status != core.IncidentClosed || incident.CoopSessionGeneration != 1 {
				t.Fatalf("discarded session was reopened: %+v", incident)
			}
		})
	}
}

// Covers: TestLegacyWritableTurnsAreRevokedBeforeAuthorityRotation
// A migration cannot merely wait for old writable turns: a queued turn can
// start at any moment and retain ambient write authority after the policy has
// been revoked. Cancel the entire nonterminal cohort before replacing it.
func TestLegacyWritableTurnsAreRevokedBeforeAuthorityRotation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.session.RepositoryReadOnly = false
	coopClient.session.ActiveTurnID = "turn_active"
	coopClient.session.QueuedTurnCount = 1
	coopClient.listTurns = []coop.Turn{
		{ID: "turn_active", SessionID: coopClient.session.ID, Ordinal: 1, State: "running"},
		{ID: "turn_queued", SessionID: coopClient.session.ID, Ordinal: 2, State: "queued"},
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	incident := workRoom(t, ctx, st, cfg, "active-read-only", "CACTIVE", "U123ABC", false)
	if err := st.SetCoopSession(ctx, incident.ID, coopClient.session.ID, "legacy-fork", 1); err != nil {
		t.Fatal(err)
	}

	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(coopClient.cancelTurns, []string{"turn_active", "turn_queued"}) {
		t.Fatalf("revoked turns = %v", coopClient.cancelTurns)
	}
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.CoopSessionID != "" || incident.CoopSessionGeneration != 2 {
		t.Fatalf("revoked writable session remained bound: %+v", incident)
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
