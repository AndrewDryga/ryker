package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/version"
	"github.com/AndrewDryga/responder/internal/webhook"
	"github.com/AndrewDryga/responder/internal/webui"
)

type Handler struct {
	cfg        config.Config
	store      *store.Store
	service    *service.Service
	identities slackIdentityReader
	secrets    map[string]string
	log        *slog.Logger

	accepted  atomic.Uint64
	duplicate atomic.Uint64
	rejected  atomic.Uint64

	statusMu    sync.Mutex
	status      serviceStatus
	statusUntil time.Time
	statusClock func() time.Time
}

type slackIdentityReader interface {
	UserNames(context.Context) (map[string]string, error)
}

// statusTTL bounds how stale a health or metrics answer may be.
//
// Every field in a status answer is read from the single writer connection that
// the scheduler, webhook admission, and Slack admission all share. These
// endpoints are unauthenticated, so without a cache any scrape interval — or a
// misconfigured one — competes directly with real work for that connection. One
// second is well inside a normal Prometheus or load-balancer interval while
// collapsing a burst into a single read.
const statusTTL = time.Second

type serviceStatus struct {
	metrics           store.Metrics
	scheduler         []service.SchedulerLaneSnapshot
	ready             bool
	reason            string
	promptTruncations uint64
	promptMaxBytes    uint64
	err               error
}

func (h *Handler) now() time.Time {
	if h.statusClock != nil {
		return h.statusClock()
	}
	return time.Now()
}

// serviceStatus returns a recent status answer, reading through at most once
// per statusTTL. Concurrent callers share one read: the lock is deliberately
// held across it so a scrape storm cannot become a storm of database queries.
func (h *Handler) serviceStatus(ctx context.Context) serviceStatus {
	h.statusMu.Lock()
	defer h.statusMu.Unlock()
	if now := h.now(); now.Before(h.statusUntil) {
		return h.status
	}
	var status serviceStatus
	status.metrics, status.err = h.store.Metrics(ctx)
	if status.err == nil {
		status.scheduler, status.err = h.service.SchedulerSnapshot(ctx)
	}
	if status.err == nil {
		status.ready, status.reason = h.service.Ready(ctx)
		status.promptTruncations, status.promptMaxBytes = h.service.PromptTruncationMetrics()
	}
	h.status = status
	h.statusUntil = h.now().Add(statusTTL)
	return status
}

func New(
	cfg config.Config,
	st *store.Store,
	svc *service.Service,
	secrets map[string]string,
	logger *slog.Logger,
) http.Handler {
	return NewWithIdentities(cfg, st, svc, nil, secrets, logger)
}

func NewWithIdentities(
	cfg config.Config,
	st *store.Store,
	svc *service.Service,
	identities slackIdentityReader,
	secrets map[string]string,
	logger *slog.Logger,
) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	handler := &Handler{
		cfg: cfg, store: st, service: svc, identities: identities, secrets: secrets, log: logger,
	}
	return securityHeaders(handler.mux())
}

// mux routes the API. It is separate from New so a test can drive a Handler it
// constructed itself without reaching back through the middleware.
func (h *Handler) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.health)
	mux.HandleFunc("GET /readyz", h.ready)
	mux.HandleFunc("GET /metrics", h.metrics)
	mux.HandleFunc("POST /v1/hooks/{route}", h.webhook)
	// The control plane, when the database can be opened for reading. A
	// dashboard that cannot start must not stop the service from answering
	// Slack, so a failure here is logged and the rest of the API serves on.
	if err := h.mountControlPlane(mux); err != nil {
		h.log.Warn("control plane unavailable", "error", err)
	}
	return mux
}

// dashboardActions gives the control plane exactly the mutations it offers, by
// calling the same store and service paths the Slack buttons call. Routed
// through here rather than the dashboard's own connection so the audit trail
// and the invariants do not depend on which surface the operator used.
type dashboardActions struct {
	store   *store.Store
	service *service.Service
	cfg     config.Config
}

// review mirrors the Slack handler exactly: the store transition AND the audit
// event. The first version called only the store method, so sixteen reviews
// made from the dashboard changed state with one legacy Slack row in
// fixture.review beside them — an action surface whose own audit trail
// promise lasted until its first real use.
func (a *dashboardActions) review(ctx context.Context, id, status, actor string) error {
	if err := a.store.ReviewFixtureCandidate(ctx, id, status, actor); err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		ID: "audit_fixture_review_cp_" + id, Kind: "fixture.review",
		ActorID: actor, ObjectID: id, Outcome: status,
	})
}

func (a *dashboardActions) KeepCorrection(ctx context.Context, id, actor string) error {
	return a.review(ctx, id, "approved", actor)
}

func (a *dashboardActions) DiscardCorrection(ctx context.Context, id, actor string) error {
	return a.review(ctx, id, "rejected", actor)
}

// RetryFailure puts a terminally failed run back in the pending queue through
// the kernel's own requeue-and-reopen transition, so the ordinary workers pick
// it up with a fresh Coop idempotency key. The store refuses anything that is
// not the episode's latest attempt, and that refusal reaches the operator
// verbatim — a superseded run must say why it is history, not shrug.
func (a *dashboardActions) RetryFailure(ctx context.Context, runID, actor string) error {
	if err := a.store.RequeueFailedAgentRun(ctx, runID,
		"operator retried this run from the control plane"); err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "failure.retry", ActorID: actor, ObjectID: runID, Outcome: "requeued",
	})
}

// PublishRetainedWork and DiscardRetainedWork go through the service, not the
// store: the Coop review, the verified discard plan, and the cleanup schedule
// live behind clients only the service holds, and the service handler is the
// same one the Slack button calls — audit record, Slack outcome notice and
// all. A store-side reimplementation would be a second copy of the safety
// rules, which is how a surface grows a button that skips the dirty-tree
// check.
func (a *dashboardActions) PublishRetainedWork(ctx context.Context, incidentID, actor string) error {
	return a.service.ControlPlaneAct(ctx, "publish", incidentID, actor)
}

func (a *dashboardActions) DiscardRetainedWork(ctx context.Context, incidentID, actor string) error {
	return a.service.ControlPlaneAct(ctx, "discard", incidentID, actor)
}

// DiscardWorkspace reclaims a fork that belongs to no work record. Separate
// from DiscardRetainedWork because the identifier is different in kind — a
// Coop session rather than an incident — and routing both through one method
// would mean guessing which one a caller meant from the shape of a string.
func (a *dashboardActions) DiscardWorkspace(ctx context.Context, sessionID, actor string) error {
	return a.service.ControlPlaneDiscardSession(ctx, sessionID, actor)
}

// RerunCleanup sends one blocked workspace back through the janitor's checks.
// The transition and the audit row land in the same act: the dashboard once
// shipped an action that changed state with no audit trail, and sixteen
// unattributed reviews later that is a rule rather than a preference.
func (a *dashboardActions) RerunCleanup(ctx context.Context, sessionID, actor string) error {
	if err := a.store.RequeueBlockedCleanup(ctx, sessionID); err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "cleanup.retry", ActorID: actor, ObjectID: sessionID, Outcome: "requeued",
		Detail: "operator sent a blocked workspace back through the janitor's checks",
	})
}

// ResolveEpisodeOvertaken closes blocked or waiting work whose moment has
// passed. The transition is an episode_cancelled event through the kernel's
// own reducer — the same validation every host transition passes — so an
// episode that has moved on since the page rendered refuses it there rather
// than being forced. Nothing is deleted; the event and the audit row are the
// record of who decided.
func (a *dashboardActions) ResolveEpisodeOvertaken(ctx context.Context, episodeID, actor string) error {
	episode, err := a.store.GetWorkEpisode(ctx, episodeID)
	if err != nil {
		return err
	}
	switch episode.State {
	case core.EpisodeBlocked, core.EpisodeWaitingOperator,
		core.EpisodeWaitingApproval, core.EpisodeWaitingExternal:
	default:
		return fmt.Errorf(
			"episode is %s; only blocked or waiting work can be resolved as overtaken",
			episode.State,
		)
	}
	payload, err := episodepkg.Encode(episodepkg.Transition{
		State: core.EpisodeCancelled, Phase: "finished",
		Status: "Resolved by the operator: overtaken by events",
	})
	if err != nil {
		return err
	}
	// A fresh key per act, not per episode: the key exists to deduplicate
	// replays of one logical act, and a resolve after a reopen is a new act
	// that a fixed key would silently swallow.
	actID, err := core.NewID("cpresolve")
	if err != nil {
		return err
	}
	if _, err := a.store.AppendEpisodeEvent(ctx, episodeID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventEpisodeCancelled, Actor: actor,
		IdempotencyKey: "control-plane:overtaken:" + actID,
		Payload:        payload,
	}); err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "episode.resolve", ActorID: actor, ObjectID: episodeID,
		Outcome: "overtaken_by_events",
		Detail:  "resolved from the control plane while " + string(episode.State),
	})
}

func (a *dashboardActions) CancelSlackReplay(ctx context.Context, replayID, expectedRunKey, actor string) error {
	return service.CancelSlackReplay(ctx, a.service, replayID, expectedRunKey, actor)
}

// ResolveIncident closes an open room through the same service handler the
// Slack close control calls: cleanup scheduling, audit, timeline and the
// closing notice included.
func (a *dashboardActions) RerunEpisode(ctx context.Context, episodeID, actor string) error {
	return a.service.ControlPlaneAct(ctx, "rerun", episodeID, actor)
}

// SetSchedulePaused stops a schedule firing, or starts it again.
//
// The store refuses to resume one that has no future run left — a "once"
// schedule that already fired, or any schedule past its expiry — and that
// refusal reaches the operator as a sentence rather than as a row count,
// because "nothing happened" on a control they just pressed is the failure
// mode this whole page exists to avoid.
func (a *dashboardActions) SetSchedulePaused(
	ctx context.Context, id string, paused bool, actor string,
) error {
	task, err := a.store.Schedules.SetScheduledTaskEnabled(ctx, id, !paused)
	if err != nil {
		if paused {
			return fmt.Errorf("this schedule could not be paused; it may already be deleted or expired: %w", err)
		}
		return fmt.Errorf(
			"this schedule cannot be resumed: it has no future run left, which happens to a one-off that already fired and to any schedule past its expiry. Ask Responder in Slack for a replacement: %w",
			err,
		)
	}
	outcome, detail := "resumed", "enabled"
	if paused {
		outcome, detail = "paused", "disabled"
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "schedule." + outcome, ActorID: actor, ObjectID: task.ID,
		Outcome: detail, Detail: task.Title,
	})
}

// DeleteSchedule removes a schedule for good.
//
// The executions it already produced are not touched: they are the record of
// work that really ran, and the episodes they point at are reached from
// Episodes whether or not the schedule that started them still exists.
func (a *dashboardActions) DeleteSchedule(ctx context.Context, id, actor string) error {
	task, err := a.store.Schedules.DeleteScheduledTask(ctx, id)
	if err != nil {
		return fmt.Errorf("this schedule could not be deleted; it may already be gone: %w", err)
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "schedule.deleted", ActorID: actor, ObjectID: task.ID,
		Outcome: "deleted", Detail: task.Title,
	})
}

func (a *dashboardActions) ResolveIncident(ctx context.Context, incidentID, actor string) error {
	return a.service.ControlPlaneAct(ctx, "close", incidentID, actor)
}

// ForgetMemory mirrors the Slack forget handler: the same delete, the same
// memory.forget audit kind with the same scope-and-predicate detail, so the
// log reads identically whichever surface removed the entry. The Slack
// handler's channel-visibility dance is not mirrored because it is about
// which Slack context may see an entry; the loopback operator is the person
// those rules protect the entry for.
func (a *dashboardActions) SetChannelSetting(ctx context.Context, channelID, name, value, actor string) error {
	if err := a.service.ControlPlaneChannelSetting(ctx, channelID, name, value, actor); err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		ID:   "audit_channel_setting_" + channelID + "_" + name + "_" + value,
		Kind: "channel.configure", ActorID: actor, ObjectID: channelID,
		Outcome: name + "=" + value,
	})
}

func (a *dashboardActions) ForgetMemory(ctx context.Context, entryID, actor string) error {
	entry, err := a.store.Memory.DeleteMemoryEntry(ctx, entryID)
	if errors.Is(err, store.ErrNotFound) {
		return errors.New("this memory entry was already removed or expired")
	}
	if err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "memory.forget", ActorID: actor, ObjectID: entry.ID, Outcome: "deleted",
		Detail: "scope=" + entry.ScopeKind + " predicate=" + entry.Predicate,
	})
}

// reviewMemory mirrors handleMemoryReview for the two verdicts the dashboard
// offers: the same ResolveMemoryReview call, the same memory.review audit
// kind carrying the item's kind.
func (a *dashboardActions) reviewMemory(ctx context.Context, reviewID, action, actor string) error {
	items, err := a.store.Memory.ListPendingMemoryReviews(ctx, 100)
	if err != nil {
		return err
	}
	kind := ""
	for _, item := range items {
		if item.ID == reviewID {
			kind = item.Kind
		}
	}
	if kind == "" {
		return errors.New("that memory review is already complete")
	}
	if _, err := a.store.Memory.ResolveMemoryReview(ctx, reviewID, action, actor); err != nil {
		if errors.Is(err, store.ErrConflict) || errors.Is(err, store.ErrNotFound) {
			return errors.New("that memory review is already complete")
		}
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "memory.review", ActorID: actor, ObjectID: reviewID, Outcome: action,
		Detail: "kind=" + kind,
	})
}

func (a *dashboardActions) KeepMemoryReview(ctx context.Context, reviewID, actor string) error {
	return a.reviewMemory(ctx, reviewID, "keep", actor)
}

func (a *dashboardActions) DismissMemoryReview(ctx context.Context, reviewID, actor string) error {
	return a.reviewMemory(ctx, reviewID, "dismiss", actor)
}

// DismissFeedback mirrors handleDismissFeedback: dismissing is a real
// outcome, because the alternative is a queue that only grows and teaches
// everyone to ignore it.
func (a *dashboardActions) DismissFeedback(ctx context.Context, feedbackID, actor string) error {
	err := a.store.ResolveFeedback(ctx, feedbackID, "dismissed", actor)
	if errors.Is(err, store.ErrFeedbackNotOpen) {
		return errors.New("that feedback was already resolved")
	}
	if err != nil {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "feedback.dismiss", ActorID: actor, ObjectID: feedbackID, Outcome: "dismissed",
	})
}

// ConvertFeedback mirrors handleConvertFeedback field for field: the summary
// becomes workspace-scoped guidance with the feedback item as its source, the
// item resolves as converted, and the feedback.convert audit row names the
// memory it became. The same refusals apply — multiline or credential-like
// text cannot become guidance — because a second door with fewer checks is
// how a rule stops being one.
func (a *dashboardActions) ConvertFeedback(ctx context.Context, feedbackID, actor string) error {
	item, err := a.store.GetFeedback(ctx, feedbackID)
	if err != nil {
		return err
	}
	if item.Status != "open" {
		return errors.New("that feedback was already resolved")
	}
	entry := core.MemoryEntry{
		ScopeKind: "workspace", ScopeKey: a.cfg.Slack.TeamID,
		SubjectKey:     memorypkg.NormalizeGuidanceSubject(item.Category),
		Predicate:      "guidance",
		Value:          core.BoundedText(item.Summary, 1000),
		VisibilityKind: "workspace", VisibilityID: a.cfg.Slack.TeamID,
		ExpiresAt: time.Now().UTC().Add(memorypkg.DefaultTTL),
		SourceRef: "feedback:" + item.ID,
		ActorID:   actor,
	}
	if entry.SubjectKey == "" || entry.Value == "" ||
		strings.ContainsAny(entry.SubjectKey+entry.Value, "\r\n\t") ||
		memorypkg.ContainsSecretLikeValue(entry.SubjectKey) ||
		memorypkg.ContainsSecretLikeValue(entry.Value) {
		return errors.New("this feedback cannot become guidance as written: memory holds " +
			"one line and never credential-like values")
	}
	saved, _, err := a.store.Memory.UpsertMemoryEntry(
		ctx, entry, a.cfg.Limits.MaxMemoryEntries, a.cfg.Limits.MaxMemoryEntriesPerScope,
	)
	if err != nil {
		return err
	}
	if err := a.store.ResolveFeedback(ctx, item.ID, "converted", actor); err != nil &&
		!errors.Is(err, store.ErrFeedbackNotOpen) {
		return err
	}
	return a.store.Audit(ctx, core.AuditEvent{
		Kind: "feedback.convert", ActorID: actor, ObjectID: item.ID, Outcome: "converted",
		Detail: "memory=" + saved.ID,
	})
}

// deploymentName walks the state path up past the dot-directory. The naive
// Base(TrimSuffix(path, "/state")) stopped one level short, and every header
// on the dashboard introduced the deployment as ".responder" — the name of the
// convention, not the name of anything.
func deploymentName(stateDir string) string {
	path := strings.TrimSuffix(strings.TrimSuffix(stateDir, "/"), "/state")
	for _, step := range []int{0, 1} {
		_ = step
		if base := filepath.Base(path); base != "" && base != "." && base != "/" &&
			!strings.HasPrefix(base, ".") {
			return base
		}
		path = filepath.Dir(path)
	}
	return "responder"
}

func (h *Handler) mountControlPlane(mux *http.ServeMux) error {
	reader, err := webui.OpenReader(filepath.Join(h.cfg.StateDir, "responder.db"))
	if err != nil {
		return err
	}
	if h.identities != nil {
		identityCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		labels, identityErr := h.identities.UserNames(identityCtx)
		cancel()
		reader.SetSlackIdentities(labels)
		if identityErr != nil {
			h.log.Warn("dashboard Slack identity snapshot failed", "error", identityErr)
		}
	}
	// Coop's own session store, so the workspaces page can show what is held
	// rather than only what is queued for reclamation.
	reader.OpenCoopSessions(filepath.Join(h.cfg.Coop.StateDir, "session.sqlite"))
	// Read from the database rather than a constant, so the page reports the
	// schema actually in use rather than the one this binary expects. Those
	// differ exactly when something is wrong.
	dashboard, err := webui.NewHandler(
		reader,
		deploymentName(h.cfg.StateDir),
		reader.Schema(context.Background()),
		version.Version,
		func() bool { ready, _ := h.service.Ready(context.Background()); return ready },
		h.cfg.Pricing,
		h.cfg.Repositories,
		&dashboardActions{store: h.store, service: h.service, cfg: h.cfg},
	)
	if err != nil {
		return err
	}
	dashboard.Register(mux)
	return nil
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Ping(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"healthy": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"healthy": true})
}

func (h *Handler) ready(w http.ResponseWriter, r *http.Request) {
	status := h.serviceStatus(r.Context())
	if status.err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"ready": false, "reason": "status unavailable",
		})
		return
	}
	code := http.StatusOK
	if !status.ready {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]any{"ready": status.ready, "reason": status.reason})
}

func (h *Handler) metrics(w http.ResponseWriter, r *http.Request) {
	status := h.serviceStatus(r.Context())
	if status.err != nil {
		http.Error(w, "metrics unavailable", http.StatusServiceUnavailable)
		return
	}
	snapshot, scheduler := status.metrics, status.scheduler
	readyValue := 0
	if status.ready {
		readyValue = 1
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprintf(w, "# HELP responder_ready Whether Slack, Coop, and workers are ready.\n")
	fmt.Fprintf(w, "# TYPE responder_ready gauge\nresponder_ready %d\n", readyValue)
	metrics := []struct {
		name  string
		help  string
		value int
	}{
		{"responder_incidents_open", "Open incidents.", snapshot.IncidentsOpen},
		{"responder_incidents_total", "All durable incidents.", snapshot.IncidentsTotal},
		{"responder_coop_sessions_open", "Open Coop sessions.", snapshot.SessionsOpen},
		{"responder_draft_prs_published", "Responder-managed draft pull requests.", snapshot.PublishedPRs},
		{"responder_cleanup_pending", "Owned Coop sessions awaiting cleanup.", snapshot.CleanupPending},
		{"responder_cleanup_blocked", "Owned Coop sessions retained for operator action.", snapshot.CleanupBlocked},
		{"responder_memory_entries_active", "Active operator-confirmed memory entries.", snapshot.MemoryActive},
		{"responder_memory_entries_expired", "Expired memory entries awaiting maintenance pruning.", snapshot.MemoryExpired},
		{"responder_memory_rollups", "Active synthesized conversation continuity rollups.", snapshot.MemoryRollups},
		{"responder_memory_reviews_pending", "Operator-confirmed memory items awaiting review.", snapshot.MemoryReviewsPending},
		{"responder_conversation_memories", "Recent per-conversation summaries retained before consolidation.", snapshot.ConversationMemories},
		{"responder_preferences_active", "Enabled operator-confirmed Responder preferences.", snapshot.PreferencesActive},
		{"responder_preferences_disabled", "Disabled unexpired Responder preferences.", snapshot.PreferencesDisabled},
		{"responder_standing_rules_active", "Enabled operator-confirmed standing rules.", snapshot.RulesActive},
		{"responder_standing_rules_disabled", "Disabled unexpired standing rules.", snapshot.RulesDisabled},
		{"responder_scheduled_tasks_active", "Enabled unexpired operator-confirmed scheduled tasks.", snapshot.SchedulesActive},
		{"responder_scheduled_tasks_paused", "Paused unexpired scheduled tasks.", snapshot.SchedulesPaused},
		{"responder_scheduled_task_runs_active", "Scheduled task occurrences currently queued or running.", snapshot.ScheduleRunsActive},
		{"responder_webhook_work_pending", "Webhook events awaiting completion.", snapshot.WebhooksPending},
		{"responder_slack_input_pending", "Slack inputs awaiting completion.", snapshot.SlackPending},
		{"responder_slack_deliveries_pending", "Slack writes awaiting confirmed delivery.", snapshot.SlackDeliveriesPending},
		{"responder_agent_runs_pending", "Agent runs awaiting terminal completion.", snapshot.AgentRunsPending},
		{"responder_work_failed", "Durable work items in a terminal failure state.", snapshot.WorkFailed},
		{"responder_episodes_overdue", "Accepted work past its progress deadline.", snapshot.EpisodesOverdue},
		{"responder_corrections_awaiting_review", "Corrections the product made about itself that nobody has judged yet.", snapshot.CorrectionsAwaitingReview},
		{"responder_corrections_lapsing_soon", "Pending corrections that expire within three days.", snapshot.CorrectionsLapsingSoon},
	}
	for _, metric := range metrics {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n",
			metric.name, metric.help, metric.name, metric.name, metric.value)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_pending Durable scheduled work awaiting a lease.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_pending gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_pending{lane=%q} %d\n",
			lane.Lane,
			lane.Pending,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_running Durable scheduled work with an active lease.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_running gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_running{lane=%q} %d\n",
			lane.Lane,
			lane.Running,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_work_failed Durable scheduler records in terminal failure.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_work_failed gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_work_failed{lane=%q} %d\n",
			lane.Lane,
			lane.Failed,
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_oldest_due_seconds Age of the oldest due scheduler item.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_oldest_due_seconds gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_oldest_due_seconds{lane=%q} %.3f\n",
			lane.Lane,
			lane.OldestDueAge.Seconds(),
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_oldest_running_seconds Age of the oldest running scheduler item.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_oldest_running_seconds gauge")
	for _, lane := range scheduler {
		fmt.Fprintf(
			w,
			"responder_scheduler_oldest_running_seconds{lane=%q} %.3f\n",
			lane.Lane,
			lane.OldestRunningAge.Seconds(),
		)
	}
	fmt.Fprintln(w, "# HELP responder_scheduler_heartbeat_age_seconds Age of the last worker heartbeat, or -1 before startup.")
	fmt.Fprintln(w, "# TYPE responder_scheduler_heartbeat_age_seconds gauge")
	for _, lane := range scheduler {
		age := -1.0
		if lane.HeartbeatPresent {
			age = lane.HeartbeatAge.Seconds()
		}
		fmt.Fprintf(
			w,
			"responder_scheduler_heartbeat_age_seconds{lane=%q} %.3f\n",
			lane.Lane,
			age,
		)
	}
	fmt.Fprintln(w, "# HELP responder_coop_prompt_truncations_total Prompts the Coop transport had to elide.")
	fmt.Fprintf(w, "# TYPE responder_coop_prompt_truncations_total counter\nresponder_coop_prompt_truncations_total %d\n", status.promptTruncations)
	fmt.Fprintln(w, "# HELP responder_coop_prompt_max_bytes Largest prompt composed, before any elision.")
	fmt.Fprintf(w, "# TYPE responder_coop_prompt_max_bytes gauge\nresponder_coop_prompt_max_bytes %d\n", status.promptMaxBytes)
	fmt.Fprintf(w, "# TYPE responder_webhooks_accepted_total counter\nresponder_webhooks_accepted_total %d\n", h.accepted.Load())
	fmt.Fprintf(w, "# TYPE responder_webhooks_duplicate_total counter\nresponder_webhooks_duplicate_total %d\n", h.duplicate.Load())
	fmt.Fprintf(w, "# TYPE responder_webhooks_rejected_total counter\nresponder_webhooks_rejected_total %d\n", h.rejected.Load())
}

func (h *Handler) webhook(w http.ResponseWriter, r *http.Request) {
	routeName := r.PathValue("route")
	route, ok := h.cfg.Webhooks[routeName]
	if !ok || strings.Contains(routeName, "/") {
		h.rejected.Add(1)
		writeError(w, http.StatusNotFound, "unknown webhook route")
		return
	}
	if r.URL.RawQuery != "" {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "query parameters are not accepted")
		return
	}
	contentTypes := r.Header.Values("Content-Type")
	mediaType := ""
	var err error
	if len(contentTypes) == 1 {
		mediaType, _, err = mime.ParseMediaType(contentTypes[0])
	}
	if len(contentTypes) != 1 || err != nil || mediaType != "application/json" {
		h.rejected.Add(1)
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, int64(h.cfg.Limits.MaxWebhookBytes)))
	if err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusRequestEntityTooLarge, "webhook body exceeds the configured limit")
		return
	}
	if err := webhook.Verify(route, r.Header, body, h.secrets[routeName], time.Now()); err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusUnauthorized, "webhook authentication failed")
		return
	}
	signals, err := webhook.Normalize(route, body, time.Now())
	if err != nil {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	digestBytes := sha256.Sum256(body)
	digest := hex.EncodeToString(digestBytes[:])
	deliveryIDs := r.Header.Values("X-Responder-Event-ID")
	if len(deliveryIDs) > 1 {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "at most one X-Responder-Event-ID is accepted")
		return
	}
	dedupeKey := ""
	if len(deliveryIDs) == 1 {
		dedupeKey = strings.TrimSpace(deliveryIDs[0])
	}
	if dedupeKey == "" {
		dedupeKey = digest
	}
	if len(dedupeKey) > 500 || strings.ContainsRune(dedupeKey, '\x00') {
		h.rejected.Add(1)
		writeError(w, http.StatusBadRequest, "X-Responder-Event-ID is invalid")
		return
	}
	event, created, err := h.store.AdmitWebhook(r.Context(), routeName, dedupeKey, digest, signals)
	if err != nil {
		h.log.Error("persist webhook", "route", routeName, "error", err)
		writeError(w, http.StatusServiceUnavailable, "webhook could not be persisted")
		return
	}
	if !created && event.BodyDigest != digest {
		h.rejected.Add(1)
		writeError(w, http.StatusConflict, "event ID was already used for different content")
		return
	}
	if created {
		h.accepted.Add(1)
	} else {
		h.duplicate.Add(1)
	}
	writeJSON(w, http.StatusAccepted, map[string]any{
		"accepted": true, "duplicate": !created, "event_id": event.ID,
	})
}

// securityHeaders keeps the JSON API at default-src 'none' and gives the
// control plane the narrowest policy that lets it render.
//
// One policy for both did not work: 'none' blocked the dashboard's own
// stylesheet, so every page served as unstyled HTML while returning 200. The
// browser reported it and the server could not — a failure visible only to
// whoever opened the page.
//
// The dashboard policy still forbids scripts, frames, form posts and any
// external origin. It permits exactly same-origin styles and images, which is
// what a server-rendered page with one vendored stylesheet needs.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", contentSecurityPolicy(r.URL.Path))
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

// apiOnlyPaths are the machine endpoints. Everything else on this server is the
// control plane, so a new dashboard route cannot accidentally inherit a policy
// that stops it rendering.
var apiOnlyPaths = []string{"/healthz", "/readyz", "/metrics", "/v1/"}

func contentSecurityPolicy(path string) string {
	for _, prefix := range apiOnlyPaths {
		if path == prefix || strings.HasPrefix(path, prefix) {
			return "default-src 'none'; frame-ancestors 'none'"
		}
	}
	return "default-src 'none'; style-src 'self'; img-src 'self' data:; " +
		"form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
}

func writeError(w http.ResponseWriter, status int, detail string) {
	writeJSON(w, status, map[string]any{"error": detail})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "response encoding failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(append(data, '\n'))
}
