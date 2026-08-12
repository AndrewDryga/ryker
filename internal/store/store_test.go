package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestOpenLiveWritesCurrentDatabaseWithoutMigration(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	owner, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	live, err := OpenLive(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()
	input := core.SlackInput{
		ID: "slack_live_control", EnvelopeID: "env_live_control",
		EventID: "event_live_control", Kind: "mention", TeamID: "T123",
		ChannelID: "C123", MessageTS: "1700.001", UserID: "U123", Text: "verify",
	}
	if created, err := live.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit through live store = %v, %v", created, err)
	}
	stored, err := owner.GetSlackInput(ctx, input.ID)
	if err != nil || stored.Text != input.Text {
		t.Fatalf("owner observed live write = %+v, %v", stored, err)
	}
}

func TestListSlackDeliveriesByPrefixIncludesMultipartAndFilesOnly(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, delivery := range []core.SlackDelivery{
		{ID: "watch_reply_replay_part_001", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"one"}`)},
		{ID: "watch_reply_replay_part_999", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"two"}`)},
		{ID: "watch_reply_replay_visual_01", Operation: "file", Kind: "generated_visual", ChannelID: "C123", Body: []byte(`{"file":"chart"}`)},
		{ID: "watch_reply_other", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"other"}`)},
	} {
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || !created {
			t.Fatalf("enqueue %s = %v, %v", delivery.ID, created, err)
		}
	}
	deliveries, err := st.ListSlackDeliveriesByPrefix(ctx, "watch_reply_replay")
	if err != nil {
		t.Fatal(err)
	}
	if len(deliveries) != 3 {
		t.Fatalf("prefix deliveries = %+v", deliveries)
	}
	for _, delivery := range deliveries {
		if !strings.HasPrefix(delivery.ID, "watch_reply_replay") || delivery.ID == "watch_reply_other" {
			t.Fatalf("unexpected prefix delivery = %+v", delivery)
		}
	}
}

func TestRetryLatestGeneratedVisualIsConversationScoped(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, delivery := range []core.SlackDelivery{
		{
			ID: "visual-channel", Operation: "file", Kind: "generated_visual",
			ChannelID: "C123", Body: []byte(`{"filename":"channel.png"}`),
		},
		{
			ID: "visual-thread", Operation: "file", Kind: "generated_visual",
			ChannelID: "C123", ThreadTS: "1700.1", Body: []byte(`{"filename":"thread.png"}`),
		},
	} {
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", delivery.ID, created, err)
		}
		leased, err := st.LeaseSlackDelivery(ctx, nil)
		if err != nil || leased.ID != delivery.ID {
			t.Fatalf("lease %s = %+v, %v", delivery.ID, leased, err)
		}
		if err := st.RetrySlackDelivery(
			ctx, leased.ID, "old failure", time.Now().Add(time.Hour), false, true,
		); err != nil {
			t.Fatal(err)
		}
	}

	retried, err := st.RetryLatestGeneratedVisual(ctx, "C123", "")
	if err != nil {
		t.Fatal(err)
	}
	if retried.ID != "visual-channel" || retried.State != "retry" ||
		retried.Attempts != 0 || retried.LastError != "" || retried.NextAttemptAt.After(time.Now()) {
		t.Fatalf("retried channel visual = %+v", retried)
	}
	thread, err := st.GetSlackDelivery(ctx, "visual-thread")
	if err != nil || thread.State != "failed" || thread.LastError != "old failure" {
		t.Fatalf("unrelated thread visual = %+v, %v", thread, err)
	}
	if _, err := st.RetryLatestGeneratedVisual(ctx, "C999", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing visual retry error = %v", err)
	}
}

func TestSlackStatusGenerationMakesClearMonotonic(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	activeGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	active := core.SlackDelivery{
		ID: "status_active", Operation: "status", Kind: "status",
		ChannelID: "C1", ThreadTS: "1700.001", Status: "is investigating...",
		CoalesceKey: "status:C1:1700.001", CardVersion: activeGeneration,
	}
	if created, err := st.EnqueueSlackDelivery(ctx, active); err != nil || !created {
		t.Fatalf("enqueue active status = %v, %v", created, err)
	}
	clearGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	clear := core.SlackDelivery{
		ID: "status_clear", Operation: "status", Kind: "status",
		ChannelID: "C1", ThreadTS: "1700.001",
		CoalesceKey: "status:C1:1700.001", CardVersion: clearGeneration,
	}
	if created, err := st.EnqueueSlackDelivery(ctx, clear); err != nil || !created {
		t.Fatalf("enqueue status clear = %v, %v", created, err)
	}
	stale := active
	stale.ID = "status_stale_late"
	if created, err := st.EnqueueSlackDelivery(ctx, stale); err != nil || created {
		t.Fatalf("late stale status = %v, %v", created, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	nextGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil || nextGeneration != clearGeneration+1 {
		t.Fatalf("persisted status generation = %d, %v", nextGeneration, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != active.ID || leased.Status == "" {
		t.Fatalf("pending status was not delivered before clear = %+v, %v", leased, err)
	}
	if err := st.FinishSlackDelivery(ctx, leased.ID, "", "sending"); err != nil {
		t.Fatal(err)
	}
	leased, err = st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != clear.ID || leased.Status != "" {
		t.Fatalf("monotonic status clear = %+v, %v", leased, err)
	}
}

func TestEngineeringTaskIsDistinctAndIdempotent(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvTask", "Audit infrastructure packs",
		"Update infra/ to install every required pack.", "U123ABC",
		"COPS", "1700.2", 100,
	)
	if err != nil || !created || !first.IsEngineeringTask() {
		t.Fatalf("engineering task first = %+v, %v, %v", first, created, err)
	}
	if !first.IsThreadScoped() ||
		first.WorkKind != core.WorkKindEngineeringTask ||
		first.WorkScope != core.WorkScopeThread ||
		first.OriginChannelID != "COPS" ||
		first.OriginThreadTS != "1700.2" ||
		first.ConversationThreadTS() != "1700.2" {
		t.Fatalf("engineering task scope = %+v", first)
	}
	signals, err := st.ListSignals(ctx, first.ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Labels["work_kind"] != "engineering_task" ||
		signals[0].Labels["slack_origin_channel"] != "COPS" {
		t.Fatalf("engineering task source = %+v, %v", signals, err)
	}
	second, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvTask", "Audit infrastructure packs",
		"Update infra/ to install every required pack.", "U123ABC",
		"COPS", "1700.2", 100,
	)
	if err != nil || created || second.ID != first.ID || !second.IsEngineeringTask() {
		t.Fatalf("engineering task duplicate = %+v, %v, %v", second, created, err)
	}
}

func TestMemberEngineeringTaskAdmissionIsAttributedRateLimitedAndQuotaBound(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
	st.SetClock(func() time.Time { return now })
	create := func(source, user string) (core.Incident, bool, error) {
		return st.CreateMemberEngineeringTask(
			ctx, "repo", source, "Member task", "summary", user,
			"COPS", "1700."+source, 100, 2, 30*time.Second,
		)
	}
	first, created, err := create("member-1", "UMEMBER")
	if err != nil || !created {
		t.Fatalf("first member task = %+v, created=%t, err=%v", first, created, err)
	}
	creator, err := st.EngineeringTaskCreator(ctx, first.ID)
	if err != nil || creator != "UMEMBER" {
		t.Fatalf("task creator = %q, err=%v", creator, err)
	}
	if duplicate, created, err := create("member-1", "UMEMBER"); err != nil || created || duplicate.ID != first.ID {
		t.Fatalf("idempotent member task = %+v, created=%t, err=%v", duplicate, created, err)
	}
	if _, _, err := create("member-2", "UMEMBER"); !errors.Is(err, ErrMemberTaskRateLimit) {
		t.Fatalf("member cooldown = %v, want rate limit", err)
	}
	now = now.Add(31 * time.Second)
	if _, created, err := create("member-2", "UMEMBER"); err != nil || !created {
		t.Fatalf("second member task = created=%t, err=%v", created, err)
	}
	now = now.Add(31 * time.Second)
	if _, _, err := create("member-3", "UMEMBER"); !errors.Is(err, ErrMemberTaskCapacity) {
		t.Fatalf("member quota = %v, want capacity", err)
	}
	if _, created, err := create("other-1", "UOTHER"); err != nil || !created {
		t.Fatalf("other member task = created=%t, err=%v", created, err)
	}
}

func TestEngineeringTaskPullRequestBindingSurvivesRestart(t *testing.T) {
	ctx := context.Background()
	dir := filepath.Join(t.TempDir(), "state")
	st, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvBoundTask", "Update PR", "summary", "U123ABC",
		"COPS", "1700.3", 100, target,
	)
	if err != nil || !created || task.TaskPullRequest == nil || *task.TaskPullRequest != target {
		t.Fatalf("bound engineering task = %+v, %t, %v", task, created, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil || task.TaskPullRequest == nil || *task.TaskPullRequest != target {
		t.Fatalf("reopened engineering task binding = %+v, %v", task, err)
	}
	moved := target
	moved.HeadCommit = strings.Repeat("b", 40)
	if _, _, err := st.CreateEngineeringTask(
		ctx, "repo", "EvBoundTask", "Update PR", "summary", "U123ABC",
		"COPS", "1700.3", 100, moved,
	); !errors.Is(err, ErrConflict) {
		t.Fatalf("rebound engineering task = %v, want conflict", err)
	}
	invalid := target
	invalid.HeadCommit = ""
	if _, _, err := st.CreateEngineeringTask(
		ctx, "repo", "EvInvalidTask", "Update PR", "summary", "U123ABC",
		"COPS", "1700.4", 100, invalid,
	); err == nil {
		t.Fatal("invalid pull request binding was stored")
	}
}

func TestSlackInputsOnlySerializeActiveChannelWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{
			ID: "slack-a2", EnvelopeID: "env-a2", EventID: "event-a2",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.000002",
			UserID: "U1", Text: "second A", ReceivedAt: now.Add(time.Second),
		},
		{
			ID: "slack-a1", EnvelopeID: "env-a1", EventID: "event-a1",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.000001",
			UserID: "U1", Text: "first A", ReceivedAt: now,
		},
		{
			ID: "slack-b1", EnvelopeID: "env-b1", EventID: "event-b1",
			Kind: "message", TeamID: "T1", ChannelID: "CB", MessageTS: "1700000000.000003",
			UserID: "U1", Text: "first B", ReceivedAt: now.Add(2 * time.Second),
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-a1" {
		t.Fatalf("first lease = %+v, %v", first, err)
	}
	second, err := st.LeaseSlackInput(ctx)
	if err != nil || second.ID != "slack-b1" {
		t.Fatalf("independent channel lease = %+v, %v", second, err)
	}
	if err := st.FinishSlackInput(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackInput(
		ctx, first.ID, "long-running work was detached", time.Now().Add(time.Hour), false,
	); err != nil {
		t.Fatal(err)
	}
	third, err := st.LeaseSlackInput(ctx)
	if err != nil || third.ID != "slack-a2" {
		t.Fatalf("later channel input remained head-of-line blocked = %+v, %v", third, err)
	}
	if err := st.FinishSlackInput(ctx, third.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deferred input became due early: %v", err)
	}
}

func TestRecoverStaleSlackInputUnblocksItsChannel(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, input := range []core.SlackInput{
		{
			ID: "slack-stale", EnvelopeID: "env-stale", EventID: "event-stale",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1",
			UserID: "U1", Text: "first",
		},
		{
			ID: "slack-next", EnvelopeID: "env-next", EventID: "event-next",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "2",
			UserID: "U1", Text: "second",
		},
	} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, admitErr)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-stale" {
		t.Fatalf("first lease = %+v, %v", first, err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("channel was not serialized: %v", err)
	}
	recovered, err := st.RecoverStaleSlackInputs(ctx, time.Now().Add(time.Second))
	if err != nil || recovered != 1 {
		t.Fatalf("recover stale input = %d, %v", recovered, err)
	}
	retried, err := st.LeaseSlackInput(ctx)
	if err != nil || retried.ID != first.ID || retried.Attempts != 2 {
		t.Fatalf("recovered lease = %+v, %v", retried, err)
	}
	if err := st.FinishSlackInput(ctx, retried.ID); err != nil {
		t.Fatal(err)
	}
	next, err := st.LeaseSlackInput(ctx)
	if err != nil || next.ID != "slack-next" {
		t.Fatalf("next channel input = %+v, %v", next, err)
	}
}

func TestRecentWatchContextIsBoundedChronologicalAndTracksNewerDecisions(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for i := 1; i <= 25; i++ {
		input := core.SlackInput{
			ID:         fmt.Sprintf("slack-context-%02d", i),
			EnvelopeID: fmt.Sprintf("env-context-%02d", i),
			EventID:    fmt.Sprintf("event-context-%02d", i),
			Kind:       "message",
			TeamID:     "T1",
			ChannelID:  "CA",
			MessageTS:  fmt.Sprintf("1700000000.%06d", i),
			UserID:     fmt.Sprintf("U%d", i%3),
			Text:       fmt.Sprintf("message %02d", i),
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %d = %v, %v", i, created, err)
		}
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack-command", EnvelopeID: "env-command", EventID: "event-command",
		Kind: "slash", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.999999",
		UserID: "U1", Text: "status",
	}); err != nil || !created {
		t.Fatalf("admit command = %v, %v", created, err)
	}
	recent, err := st.ListRecentWatchMessages(ctx, "CA", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 20 || recent[0].Text != "message 06" ||
		recent[19].Text != "message 25" {
		t.Fatalf("recent context = %+v", recent)
	}
	for i := 1; i < len(recent); i++ {
		if recent[i-1].MessageTS >= recent[i].MessageTS {
			t.Fatalf("context is not chronological: %+v", recent)
		}
	}
	newer, err := st.HasNewerWatchDecision(ctx, "CA", "1700000000.000024")
	if err != nil || newer {
		t.Fatalf("decision existed before audit = %v, %v", newer, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: "slack-context-25", Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	newer, err = st.HasNewerWatchDecision(ctx, "CA", "1700000000.000024")
	if err != nil || !newer {
		t.Fatalf("newer decision = %v, %v", newer, err)
	}
}

func TestListLatestSlackInputsByKindReturnsNewestMessageRevision(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	for _, input := range []core.SlackInput{
		{
			ID: "slack-old", EnvelopeID: "env-old", EventID: "event-old", Kind: "bot_message",
			TeamID: "T1", ChannelID: "C1", MessageTS: "1700.1", UserID: "B1",
			Text: "Run Planning", ReceivedAt: now.Add(-time.Minute),
		},
		{
			ID: "slack-new", EnvelopeID: "env-new", EventID: "event-new", Kind: "bot_message",
			TeamID: "T1", ChannelID: "C1", MessageTS: "1700.1", UserID: "B1",
			Text: "Run Errored", ReceivedAt: now,
		},
		{
			ID: "slack-human", EnvelopeID: "env-human", EventID: "event-human", Kind: "message",
			TeamID: "T1", ChannelID: "C1", MessageTS: "1700.2", UserID: "U1",
			Text: "hello", ReceivedAt: now,
		},
	} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	inputs, err := st.ListLatestSlackInputsByKind(ctx, "bot_message", now.Add(-time.Hour), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(inputs) != 1 || inputs[0].ID != "slack-new" || inputs[0].Text != "Run Errored" {
		t.Fatalf("latest bot inputs = %+v", inputs)
	}
}

func TestAdmitSlackInputDeduplicatesOneVisibleMessageVersion(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first := core.SlackInput{
		ID: "slack-socket", EnvelopeID: "socket-envelope", EventID: "socket-event",
		Kind: "bot_message", TeamID: "T1", ChannelID: "C1",
		MessageTS: "1700.1", UserID: "B1", Text: "Run run-abc\nRun Errored",
	}
	created, err := st.AdmitSlackInput(ctx, first)
	if err != nil || !created {
		t.Fatalf("admit socket message = %t, %v", created, err)
	}
	duplicate := first
	duplicate.ID = "slack-reconcile"
	duplicate.EnvelopeID = "reconcile-envelope"
	duplicate.EventID = "reconcile-event"
	duplicate.Kind = "mention"
	created, err = st.AdmitSlackInput(ctx, duplicate)
	if err != nil || created {
		t.Fatalf("admit reconciled duplicate = %t, %v", created, err)
	}

	edited := duplicate
	edited.ID = "slack-applied"
	edited.Text = "Run run-abc\nRun Applied"
	created, err = st.AdmitSlackInput(ctx, edited)
	if err != nil || !created {
		t.Fatalf("admit lifecycle edit = %t, %v", created, err)
	}
}

func TestAdmitSlackInputAllowsExplicitReplay(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	original := core.SlackInput{
		ID: "slack-original", EnvelopeID: "socket-envelope", EventID: "socket-event",
		Kind: "mention", TeamID: "T1", ChannelID: "C1", MessageTS: "1700.1",
		UserID: "U1", Text: "check this run",
	}
	created, err := st.AdmitSlackInput(ctx, original)
	if err != nil || !created {
		t.Fatalf("admit original = %t, %v", created, err)
	}
	replay := original
	replay.ID = "slack-replay"
	replay.EnvelopeID = "replay:slack-replay"
	replay.EventID = replay.EnvelopeID
	created, err = st.AdmitSlackInput(ctx, replay)
	if err != nil || !created {
		t.Fatalf("admit explicit replay = %t, %v", created, err)
	}
}

func TestSlackControlsCanOvertakeRunningChannelConversation(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, input := range []core.SlackInput{
		{
			ID: "slack-message", EnvelopeID: "env-message", EventID: "event-message",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1",
			UserID: "U1", Text: "alert",
		},
		{
			ID: "slack-slash", EnvelopeID: "env-slash", EventID: "event-slash",
			Kind: "slash", TeamID: "T1", ChannelID: "CA",
			UserID: "U1", Text: "proactive off",
		},
	} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-slash" {
		t.Fatalf("priority lease = %+v, %v", first, err)
	}
	if err := st.FinishSlackInput(ctx, first.ID); err != nil {
		t.Fatal(err)
	}
	second, err := st.LeaseSlackInput(ctx)
	if err != nil || second.ID != "slack-message" {
		t.Fatalf("conversation after control = %+v, %v", second, err)
	}
}

func TestMigrationBackupRetentionIsBoundedAndScoped(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "backups")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	base := time.Now().UTC().Add(-time.Hour)
	for i := range 6 {
		path := filepath.Join(dir, fmt.Sprintf("responder-v%d-to-v13-test.db", i+1))
		if err := os.WriteFile(path, []byte("backup"), 0o600); err != nil {
			t.Fatal(err)
		}
		when := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
	}
	// Files Responder did not write. The two database-shaped ones are the point:
	// the deployed backups directory holds 47.8 MB of exactly these, hand-taken
	// before something risky, and every proposal to reclaim that space arrives
	// as "widen the glob". A stray .txt would survive that widening and prove
	// nothing, so the promise is pinned with names that would not.
	unrelated := []string{
		filepath.Join(dir, "operator-note.txt"),
		filepath.Join(dir, "manual-before-runbook-repin-20260806T202856Z.db"),
		filepath.Join(dir, "responder.db.pre-v12-20260729T044637Z.bak"),
	}
	for _, path := range unrelated {
		if err := os.WriteFile(path, []byte("retain"), 0o600); err != nil {
			t.Fatal(err)
		}
		when := base.Add(-24 * time.Hour)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
	}
	if err := pruneMigrationBackups(dir, migrationBackupRetention); err != nil {
		t.Fatal(err)
	}
	paths, err := filepath.Glob(filepath.Join(dir, "responder-v*-to-v*.db"))
	if err != nil || len(paths) != migrationBackupRetention {
		t.Fatalf("retained migration backups = %v, %v", paths, err)
	}
	for _, path := range unrelated {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("a file Responder did not create was removed: %s: %v", path, err)
		}
	}
}

func TestNewerSchemaIsRejectedWithoutMutation(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		CREATE TABLE schema_version (version INTEGER NOT NULL);
		INSERT INTO schema_version(version) VALUES (?);
		CREATE TABLE future_state (value TEXT NOT NULL);
		INSERT INTO future_state(value) VALUES ('preserve-me');
	`, currentSchemaVersion+1); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if st, err := Open(stateDir); err == nil {
		st.Close()
		t.Fatal("newer schema unexpectedly opened")
	}
	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var value string
	if err := db.QueryRow(`SELECT value FROM future_state`).Scan(&value); err != nil || value != "preserve-me" {
		t.Fatalf("future state changed: %q, %v", value, err)
	}
	var incidentsTable int
	if err := db.QueryRow(`
		SELECT count(*) FROM sqlite_master
		WHERE type = 'table' AND name = 'incidents'`).Scan(&incidentsTable); err != nil {
		t.Fatal(err)
	}
	if incidentsTable != 0 {
		t.Fatal("older binary applied its schema before rejecting future state")
	}
}

func TestOpenCurrentDoesNotCreateOrWriteDatabase(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if st, err := OpenCurrent(stateDir); err == nil {
		st.Close()
		t.Fatal("inspection unexpectedly created a database")
	}
	if _, err := os.Stat(filepath.Join(stateDir, "responder.db")); !os.IsNotExist(err) {
		t.Fatalf("inspection database stat = %v", err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = OpenCurrent(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.db.Exec(`CREATE TABLE inspection_must_not_write(value TEXT)`); err == nil {
		t.Fatal("inspection connection accepted a write")
	}
}

func TestCapacityDoesNotRollBackExistingSignalsInMixedBatch(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, first, time.Hour, 0, 1)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("first incident = %+v, %v", incidents, err)
	}
	mixed := testWebhookEvent()
	mixed.Signals[0].EventID = "event-resolved"
	mixed.Signals[0].Status = core.SignalResolved
	newSignal := mixed.Signals[0]
	newSignal.SourceID = "alert-2"
	newSignal.EventID = "event-new"
	newSignal.Status = core.SignalFiring
	newSignal.CorrelationKey = "cluster-b"
	mixed.Signals = append(mixed.Signals, newSignal)
	affected, err := st.ApplySignals(ctx, mixed, time.Hour, 0, 1)
	if !errors.Is(err, ErrCapacity) || len(affected) != 1 ||
		affected[0].ID != incidents[0].ID {
		t.Fatalf("mixed batch = %+v, %v", affected, err)
	}
	updated, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil || updated.Status != core.IncidentResolved {
		t.Fatalf("existing incident update was rolled back: %+v, %v", updated, err)
	}
	all, err := st.ListIncidents(ctx, 10)
	if err != nil || len(all) != 1 {
		t.Fatalf("capacity created an extra incident: %+v, %v", all, err)
	}
}

func TestFailedWorkCanBeInspectedAndExplicitlyRetried(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	admitted, _, err := st.AdmitWebhook(
		ctx, event.Route, event.DedupeKey, event.BodyDigest, event.Signals,
	)
	if err != nil {
		t.Fatal(err)
	}
	leasedWebhook, err := st.LeaseWebhook(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetryWebhook(ctx, leasedWebhook.ID, "route temporarily unavailable", time.Now(), true); err != nil {
		t.Fatal(err)
	}

	incident, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incident) != 1 {
		t.Fatalf("incident = %+v, %v", incident, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_failed", IncidentID: incident[0].ID, Kind: "notice",
		ChannelID: "C123ABC", Body: []byte(`{"text":"notice"}`),
	}); err != nil {
		t.Fatal(err)
	}
	leasedOutbox, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(ctx, leasedOutbox.ID, "invalid Slack payload", time.Now(), false, true); err != nil {
		t.Fatal(err)
	}

	failures, err := st.ListFailedWork(ctx, 50)
	if err != nil || len(failures) != 2 {
		t.Fatalf("failures = %+v, %v", failures, err)
	}
	retried, err := st.RetryFailedWork(ctx, "webhook", admitted.ID)
	if err != nil {
		t.Fatal(err)
	}
	if retried.LastError != "route temporarily unavailable" || retried.Attempts != 1 {
		t.Fatalf("retried snapshot = %+v", retried)
	}
	replayed, err := st.LeaseWebhook(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if replayed.ID != admitted.ID || replayed.Attempts != 1 {
		t.Fatalf("replayed webhook = %+v", replayed)
	}
	if _, err := st.RetryFailedWork(ctx, "webhook", admitted.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-failed retry = %v", err)
	}
	if _, err := st.RetryFailedWork(ctx, "outbox", leasedOutbox.ID); err != nil {
		t.Fatal(err)
	}
	uncertain, err := st.ListUncertainSlackDeliveries(ctx, 10)
	if err != nil || len(uncertain) != 1 || uncertain[0].ID != leasedOutbox.ID {
		t.Fatalf("retried outbox skipped reconciliation = %+v, %v", uncertain, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "update_failed", IncidentID: incident[0].ID,
		Operation: "update", Kind: "card", ChannelID: "C123ABC",
		MessageTS: "1700.001", Body: []byte(`{"text":"updated"}`),
	}); err != nil {
		t.Fatal(err)
	}
	leasedUpdate, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leasedUpdate.ID, "update rejected", time.Now(), false, true,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RetryFailedWork(ctx, "outbox", leasedUpdate.ID); err != nil {
		t.Fatal(err)
	}
	retriedUpdate, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || retriedUpdate.ID != leasedUpdate.ID ||
		retriedUpdate.Operation != "update" {
		t.Fatalf("legacy alias stranded Slack update = %+v, %v", retriedUpdate, err)
	}
	if _, err := st.RetryFailedWork(ctx, "unknown", admitted.ID); err == nil {
		t.Fatal("unknown work kind accepted")
	}
}

func TestTerminalCoopTurnCannotBeRetried(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incidents = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "fork-1", 1); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "slack", SourceID: "slack-1",
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx,
		leased.ID,
		"ses_1",
		0,
		incident.Repository,
		0,
		leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leased.ID, "coop_turn_1", 2, 0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, leased.ID, "failed", nil, "agent failed", 0,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}
	failures, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, failure := range failures {
		if failure.ID == queued.ID {
			found = true
			if failure.Retryable {
				t.Fatalf("terminal Coop turn shown as retryable: %+v", failure)
			}
		}
	}
	if !found {
		t.Fatal("terminal Coop turn missing from failure inspection")
	}
	if _, err := st.RetryFailedWork(ctx, "turn", queued.ID); err == nil {
		t.Fatal("terminal Coop turn was requeued")
	}
}

func testWebhookEvent() core.WebhookEvent {
	now := time.Now().UTC()
	return core.WebhookEvent{
		Route: "grafana", DedupeKey: "delivery-1", BodyDigest: "digest",
		Signals: []core.Signal{{
			Route: "grafana", SourceID: "alert-1", EventID: "event-1",
			Repository: "repo", CorrelationKey: "cluster-a", Status: core.SignalFiring,
			Title: "API latency", Severity: "critical", ReceivedAt: now,
		}},
	}
}
