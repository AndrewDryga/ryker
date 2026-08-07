package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/localstate"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack/socketmode"
)

type CoopAPI interface {
	Ready(context.Context) error
	CreateSession(context.Context, string, string, string) (coop.Session, coop.Operation, error)
	GetSession(context.Context, string) (coop.Session, error)
	PrepareSession(context.Context, string, string, int64) (coop.Session, error)
	ListSessions(context.Context, int) ([]coop.Session, error)
	SubmitTurn(context.Context, string, string, int64, string) (coop.Turn, coop.Operation, error)
	SubmitTurnWithArtifacts(context.Context, string, string, int64, string, []coop.InputArtifact) (coop.Turn, coop.Operation, error)
	GetTurn(context.Context, string, string) (coop.Turn, error)
	GetOutputArtifact(context.Context, string, string, string) (coop.OutputArtifact, error)
	Events(context.Context, string, int64, int) ([]coop.Event, error)
	Changes(context.Context, string) (coop.Changes, error)
	Review(context.Context, string, string, int64) (coop.Review, coop.Operation, error)
	Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error)
	Extend(context.Context, string, string, int64, int) (coop.Session, coop.Operation, error)
	Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error)
	PlanDiscard(context.Context, string, string, int64, bool, bool) (coop.DiscardPlan, coop.Operation, error)
	Discard(context.Context, string, string, string) (coop.Session, coop.Operation, error)
}

type PublicationAPI interface {
	Enabled() bool
	HeadBranch(core.Incident, core.Publication) (string, error)
	Publish(context.Context, publisher.Request) (publisher.Result, error)
	VerifyPublication(context.Context, core.Publication) error
}

type publicationStatusAPI interface {
	PublicationStatus(context.Context, core.Publication) (core.PublicationLifecycleStatus, error)
}

type pullRequestContextAPI interface {
	PullRequestContext(context.Context, string, int) (publisher.PullRequestContext, error)
}

// treeResolverAPI asks the publisher to resolve a commit to its tree using the
// hardened, hermetic git helper. Cleanup fails closed without it: retaining a
// fork is always safer than discarding work whose tree could not be verified.
type treeResolverAPI interface {
	ResolveTree(ctx context.Context, path, commit string) (string, error)
}

type EmisarAPI interface {
	WaitForRun(context.Context, string) (emisar.RunState, error)
}

type Socket interface {
	Events() <-chan socketmode.Event
	Ack(socketmode.Request) error
	Run(context.Context) error
	Connected() bool
	SetConnected(bool)
}

func (s *Service) SetPublisher(value PublicationAPI) {
	if value != nil {
		s.publisher = value
	}
}

func (s *Service) SetEmisar(value EmisarAPI) {
	if value != nil {
		s.emisar = value
	}
}

type Service struct {
	cfg               config.Config
	store             *store.Store
	coop              CoopAPI
	repairCoopRuntime func(context.Context) error
	slack             slackui.API
	socket            Socket
	sanitizer         *slackui.Sanitizer
	log               *slog.Logger
	publisher         PublicationAPI
	emisar            EmisarAPI

	identity    slackui.Identity
	initialized atomic.Bool
	running     atomic.Bool
	coopHealthy atomic.Bool
	heartbeats  laneHeartbeat
	clock       func() time.Time

	promptTruncation localstate.PromptTruncation

	// Process-local coordination state. See caches.go: none of it is durable
	// truth, and each piece owns its own lock.
	writeSlot    *localstate.WriteSlot
	nativeStatus *localstate.NativeStatusTracker
	historyCache *localstate.SlackHistoryCache
}

// now is the service clock. Every scheduling window, retry delay, and lease
// deadline reads it so tests can advance time instead of sleeping. It is
// nil-safe because tests construct Service literals directly.
func (s *Service) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// sanitizeMessage and sanitizeText are the only supported way to prepare model
// or operator text for Slack. They are nil-safe so tests may build a Service
// literal, and New always installs a sanitizer for the real service.
func (s *Service) sanitizeMessage(message slackui.Message) slackui.Message {
	if s.sanitizer == nil {
		return message
	}
	return s.sanitizer.Message(message)
}

func (s *Service) sanitizeText(value string) string {
	if s.sanitizer == nil {
		return value
	}
	return s.sanitizer.Text(value)
}

// SetClock replaces the service clock. It exists for tests and evaluation
// replay, which must reproduce time-dependent decisions deterministically.
func (s *Service) SetClock(clock func() time.Time) {
	if clock != nil {
		s.clock = clock
	}
}

// RecordPromptTruncation notes that a Coop prompt had to be elided. It is
// wired to the Coop client's truncation observer at startup.
func (s *Service) RecordPromptTruncation(originalBytes, cap int) {
	s.promptTruncation.Record(originalBytes)
	s.log.Warn(
		"Coop prompt truncated; the model saw an elided view of its context",
		"original_bytes", originalBytes,
		"cap", cap,
	)
}

// PromptTruncationMetrics reports how often prompts have been elided and the
// largest prompt seen.
func (s *Service) PromptTruncationMetrics() (total uint64, maxBytes uint64) {
	return s.promptTruncation.Snapshot()
}

// SetCoopRuntimeRepairer installs the managed-runtime repair hook used when a
// turn proves that Docker removed Coop's shared execution image after startup.
func (s *Service) SetCoopRuntimeRepairer(repair func(context.Context) error) {
	s.repairCoopRuntime = repair
}

type SchedulerLaneSnapshot struct {
	Lane             string
	Pending          int
	Running          int
	Failed           int
	HeartbeatPresent bool
	HeartbeatAge     time.Duration
	OldestDueAge     time.Duration
	OldestRunningAge time.Duration
}

func New(
	cfg config.Config,
	st *store.Store,
	coopClient CoopAPI,
	slackClient slackui.API,
	socket Socket,
	sanitizer *slackui.Sanitizer,
	logger *slog.Logger,
) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	if sanitizer == nil {
		// Never fall through to unredacted output: a caller without configured
		// secrets still needs control-character stripping and size bounding.
		sanitizer = slackui.NewSanitizer(cfg.Limits.MaxAssistantBytes)
	}
	return &Service{
		cfg: cfg, store: st, coop: coopClient, slack: slackClient, socket: socket,
		sanitizer: sanitizer, log: logger,
		publisher:    publisher.New(cfg.GitHub),
		writeSlot:    localstate.NewWriteSlot(localstate.SlackWriteInterval),
		nativeStatus: localstate.NewNativeStatusTracker(),
		historyCache: localstate.NewSlackHistoryCache(),
	}
}

func (s *Service) Initialize(ctx context.Context) error {
	if err := s.store.Ping(ctx); err != nil {
		return fmt.Errorf("database: %w", err)
	}
	if err := s.coop.Ready(ctx); err != nil {
		return fmt.Errorf("Coop: %w", err)
	}
	identity, err := s.slack.Auth(ctx)
	if err != nil {
		return fmt.Errorf("Slack auth: %w", err)
	}
	if identity.TeamID != s.cfg.Slack.TeamID {
		return fmt.Errorf("Slack token belongs to team %q, expected %q", identity.TeamID, s.cfg.Slack.TeamID)
	}
	if identity.BotUserID == "" {
		return errors.New("Slack auth returned no bot user ID")
	}
	s.identity = identity
	cardRevisionChanged, err := s.store.EnsureIncidentCardRevision(
		ctx,
		slackui.IncidentCardRevision,
	)
	if err != nil {
		return fmt.Errorf("incident card revision: %w", err)
	}
	if cardRevisionChanged {
		s.log.Info(
			"scheduled Slack incident card refresh",
			"revision",
			slackui.IncidentCardRevision,
		)
	}
	if err := s.seedScheduledWork(ctx); err != nil {
		return fmt.Errorf("initialize durable scheduler: %w", err)
	}
	if err := s.catchUpSlackAppMessages(ctx); err != nil {
		return fmt.Errorf("recover missed Slack app messages: %w", err)
	}
	if err := s.seedExternalMessageReconciliations(ctx); err != nil {
		return fmt.Errorf("initialize external Slack lifecycle reconciliation: %w", err)
	}
	s.coopHealthy.Store(true)
	s.initialized.Store(true)
	return nil
}

func (s *Service) Run(ctx context.Context) error {
	if !s.initialized.Load() {
		return errors.New("service is not initialized")
	}
	if s.socket == nil {
		return errors.New("Slack Socket Mode client is unavailable")
	}
	s.running.Store(true)
	defer s.running.Store(false)

	runCtx, cancel := context.WithCancel(ctx)
	var workers sync.WaitGroup
	defer func() {
		cancel()
		workers.Wait()
	}()
	socketErrors := make(chan error, 1)
	go func() {
		socketErrors <- s.socket.Run(runCtx)
	}()
	go s.consumeSocket(runCtx)
	s.startScheduler(runCtx, &workers)
	if s.cfg.Coop.PrewarmSessions > 0 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			s.prewarmConversationSessions(runCtx)
		}()
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-socketErrors:
			if ctx.Err() != nil {
				return nil
			}
			if err == nil {
				return errors.New("Slack Socket Mode stopped")
			}
			return fmt.Errorf("Slack Socket Mode: %w", err)
		}
	}
}

func (s *Service) prewarmConversationSessions(ctx context.Context) {
	recent, err := s.store.ListRecentConversationChannels(
		ctx,
		s.cfg.Coop.PrewarmSessions,
	)
	if err != nil && ctx.Err() == nil {
		s.log.Warn("could not list recent conversation sessions for prewarming", "error", err)
	}
	configured := append(
		append([]string(nil), s.cfg.Slack.WatchChannels...),
		s.cfg.Slack.SummonChannels...,
	)
	slices.Sort(configured)
	channelIDs := make([]string, 0, len(recent)+len(configured))
	seen := make(map[string]struct{}, len(recent)+len(configured))
	for _, channelID := range append(recent, configured...) {
		channelID = strings.TrimSpace(channelID)
		if channelID == "" {
			continue
		}
		if _, ok := seen[channelID]; ok {
			continue
		}
		seen[channelID] = struct{}{}
		channelIDs = append(channelIDs, channelID)
	}
	prewarmed := 0
	for _, channelID := range channelIDs {
		if prewarmed >= s.cfg.Coop.PrewarmSessions {
			return
		}
		if ctx.Err() != nil {
			return
		}
		repositoryKey, err := s.effectiveRepository(
			ctx,
			channelID,
			"",
			s.cfg.Slack.DefaultRepository,
		)
		if err != nil {
			s.log.Warn(
				"could not resolve conversation session for prewarming",
				"channel", channelID,
				"error", err,
			)
			continue
		}
		repository, ok := s.cfg.RepositoryContext(repositoryKey)
		if !ok || strings.TrimSpace(repository.ConversationPolicy) == "" {
			continue
		}
		memory, session, err := s.ensureConversationSession(
			ctx,
			channelID,
			repositoryKey,
			repository.ConversationPolicy,
		)
		if err == nil {
			_, err = s.coop.PrepareSession(
				ctx,
				fmt.Sprintf("responder:conversation-prepare:%s:%d", channelID, session.Revision),
				session.ID,
				session.Revision,
			)
		}
		if isCoopSessionPolicyConflict(err) {
			oldSessionID := memory.SessionID
			_, detachErr := s.store.DetachConversationSession(
				ctx,
				channelID,
				oldSessionID,
			)
			if detachErr == nil {
				detachErr = s.store.ScheduleCleanup(
					ctx,
					oldSessionID,
					"",
					"conversation policy changed",
					false,
					s.now().UTC(),
				)
			}
			if detachErr == nil {
				memory, session, err = s.ensureConversationSessionAtGeneration(
					ctx,
					channelID,
					repositoryKey,
					repository.ConversationPolicy,
					memory.Generation+1,
				)
			}
			if detachErr != nil {
				err = errors.Join(err, detachErr)
			} else if err == nil {
				_, err = s.coop.PrepareSession(
					ctx,
					fmt.Sprintf(
						"responder:conversation-prepare:%s:%d",
						channelID,
						memory.SessionRevision,
					),
					session.ID,
					session.Revision,
				)
			}
		}
		if err != nil && ctx.Err() == nil {
			s.log.Warn(
				"could not prewarm conversation session",
				"channel", channelID,
				"repository", repositoryKey,
				"error", err,
			)
			continue
		}
		s.log.Info(
			"prewarmed conversation session and execution environment",
			"channel", channelID,
			"repository", repositoryKey,
		)
		prewarmed++
	}
}

func isCoopSessionPolicyConflict(err error) bool {
	var apiErr *coop.APIError
	return errors.As(err, &apiErr) &&
		apiErr.Code == "invalid_session_state" &&
		strings.Contains(strings.ToLower(apiErr.Detail), "policy")
}

func (s *Service) Ready(ctx context.Context) (bool, string) {
	switch {
	case !s.initialized.Load():
		return false, "initializing"
	case !s.running.Load():
		return false, "worker stopped"
	case !s.coopHealthy.Load():
		return false, "Coop unavailable"
	case s.socket == nil || !s.socket.Connected():
		return false, "Slack disconnected"
	}
	if err := s.store.Ping(ctx); err != nil {
		return false, "database unavailable"
	}
	stallAfter := s.cfg.Limits.WorkerStallAfter.Duration
	snapshot, err := s.SchedulerSnapshot(ctx)
	if err != nil {
		return false, "scheduler unavailable"
	}
	for _, lane := range snapshot {
		if !lane.HeartbeatPresent || lane.HeartbeatAge > stallAfter {
			return false, lane.Lane + " worker stalled"
		}
		if lane.OldestDueAge > stallAfter {
			return false, lane.Lane + " queue stalled"
		}
		if lane.OldestRunningAge > stallAfter {
			return false, lane.Lane + " work stalled"
		}
	}
	return true, "ready"
}

func (s *Service) SchedulerSnapshot(ctx context.Context) ([]SchedulerLaneSnapshot, error) {
	now := s.now().UTC()
	lanes := []string{
		store.WorkLaneControl,
		store.WorkLaneBackground,
		store.WorkLaneMaintenance,
	}
	result := make([]SchedulerLaneSnapshot, 0, len(lanes))
	for _, lane := range lanes {
		metrics, err := s.store.WorkMetrics(ctx, lane)
		if err != nil {
			return nil, err
		}
		heartbeat := s.heartbeats.time(lane)
		item := SchedulerLaneSnapshot{
			Lane: lane, Pending: metrics.Pending, Running: metrics.Running,
			Failed: metrics.Failed, OldestDueAge: metrics.OldestDueAge,
			OldestRunningAge: metrics.OldestRunning,
			HeartbeatPresent: !heartbeat.IsZero(),
		}
		if !heartbeat.IsZero() {
			item.HeartbeatAge = max(now.Sub(heartbeat), 0)
		}
		result = append(result, item)
	}
	return result, nil
}

func (s *Service) runMaintenance(ctx context.Context) {
	if _, err := s.store.ResolveDueIncidents(ctx, s.now()); err != nil && ctx.Err() == nil {
		s.log.Error("incident resolution reconciliation failed", "error", err)
	}
	if err := s.reconcileIncidentChannel(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) && ctx.Err() == nil {
		s.log.Warn("incident Slack room reconciliation failed", "error", err)
	}
	if err := s.coop.Ready(ctx); err != nil {
		s.coopHealthy.Store(false)
		if ctx.Err() == nil {
			s.log.Warn("Coop readiness check failed", "error", err)
		}
	} else {
		s.coopHealthy.Store(true)
	}
	s.maintainLifecycle(ctx)
}

func (s *Service) reconcileIncidentChannel(ctx context.Context) error {
	incidents, err := s.store.ListChannelReconciliationWork(ctx, 1)
	if err != nil {
		return err
	}
	if len(incidents) == 0 {
		return store.ErrNotFound
	}
	incident := incidents[0]
	state := core.ChannelActive
	channel, err := s.slack.GetChannel(ctx, incident.ChannelID)
	switch {
	case err == nil && channel.Archived:
		state = core.ChannelArchived
	case err == nil:
	case errors.Is(err, slackui.ErrNotFound):
		state = core.ChannelUnreachable
	default:
		return err
	}
	updated, err := s.store.SetIncidentChannelState(
		ctx, incident.ChannelID, state, s.now().UTC(),
	)
	if err != nil {
		return err
	}
	if incident.ChannelState != state {
		for _, item := range updated {
			s.audit(ctx, core.AuditEvent{
				IncidentID: item.ID,
				Kind:       "slack.channel.reconciled",
				ObjectID:   item.ChannelID,
				Outcome:    "observed",
				Detail:     string(state),
			})
		}
	}
	return nil
}

func (s *Service) queueDelay(attempt int) time.Time {
	return s.now().Add(queueDelayDuration(attempt))
}

func queueDelayDuration(attempt int) time.Duration {
	seconds := math.Min(300, math.Pow(2, float64(min(max(attempt, 1), 8))))
	return time.Duration(seconds) * time.Second
}

func terminalAttempt(attempt, maximum int) bool {
	return attempt >= maximum
}

func trimError(err error) string {
	if err == nil {
		return ""
	}
	return strings.TrimSpace(err.Error())
}

// audit records a durable audit fact. Audit coverage of denials, approvals,
// and privileged actions is a stated guarantee, so a failed write is logged
// rather than discarded — but it never fails the caller's operation, because
// losing the audit trail is strictly better than losing the work it describes.
func (s *Service) audit(ctx context.Context, event core.AuditEvent) {
	if err := s.store.Audit(ctx, event); err != nil && ctx.Err() == nil {
		s.log.Error(
			"record audit event",
			"kind", event.Kind,
			"actor", event.ActorID,
			"object", event.ObjectID,
			"outcome", event.Outcome,
			"error", err,
		)
	}
}

// recordTimeline appends a best-effort incident timeline entry. The timeline is
// presentation, so a failure is logged and the caller continues.
func (s *Service) recordTimeline(ctx context.Context, event core.TimelineEvent) {
	if err := s.store.RecordTimeline(ctx, event); err != nil && ctx.Err() == nil {
		s.log.Warn(
			"record incident timeline event",
			"incident", event.IncidentID,
			"kind", event.Kind,
			"error", err,
		)
	}
}

// setIncidentError records why an incident is blocked. Losing it would leave
// the incident card claiming progress it is not making.
func (s *Service) setIncidentError(
	ctx context.Context,
	id string,
	workflow core.WorkflowState,
	detail string,
) {
	if err := s.store.SetIncidentError(ctx, id, workflow, detail); err != nil && ctx.Err() == nil {
		s.log.Error(
			"record incident failure state",
			"incident", id,
			"workflow", workflow,
			"error", err,
		)
	}
}
