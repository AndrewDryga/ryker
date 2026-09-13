package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/ryker/internal/branching"
	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/localstate"
	"github.com/AndrewDryga/ryker/internal/publisher"
	"github.com/AndrewDryga/ryker/internal/replaycontrol"
	"github.com/AndrewDryga/ryker/internal/repomirror"
	"github.com/AndrewDryga/ryker/internal/resultcontract"
	"github.com/AndrewDryga/ryker/internal/retrydelay"
	"github.com/AndrewDryga/ryker/internal/serviceport"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskpr"
	"github.com/AndrewDryga/ryker/internal/taskpublication"
)

type PublicationAPI = serviceport.Publication

func (s *Service) taskPullRequestResolver(inspector taskpr.Inspector) taskpr.IncidentResolver {
	return taskpr.IncidentResolver{
		Repositories: s.cfg.Repositories, Inspector: inspector,
		LoadSource: s.store.SlackInputs.GetByEventID,
		LoadRun:    s.store.GetAgentRunBySource, Bind: s.store.Incidents.BindTaskPullRequest,
	}
}

// treeResolverAPI asks the publisher to resolve a commit to its tree using the
// hardened, hermetic git helper. Cleanup fails closed without it: retaining a
// fork is always safer than discarding work whose tree could not be verified.
type treeResolverAPI interface {
	ResolveTree(ctx context.Context, path, commit string) (string, error)
}

type EmisarAPI = serviceport.Emisar
type FixturePromotion = serviceport.FixturePromotion
type Socket = serviceport.Socket

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
	cfg config.Config
	// store is concrete on purpose: tests run against a real database so they
	// exercise the schema, not a mock of it. See docs/testing.md for when that
	// trade would be worth revisiting.
	store             *store.Store
	branches          *branching.Runner
	coop              serviceport.Coop
	repairCoopRuntime func(context.Context) error
	coopRepairHealth  func() (int, error)
	slack             slackui.API
	socket            Socket
	sanitizer         *slackui.Sanitizer
	log               *slog.Logger
	publisher         PublicationAPI
	emisar            EmisarAPI

	// Mirrors keeps repositories declared by slug current, and is exported for
	// the same reason store.Memory is a field rather than a delegating method:
	// an extracted area is reached through the thing that owns it, and a
	// passthrough method here would make the extraction invisible to the
	// architecture budget while costing the same slot in it. /metrics reads the
	// fetch-failure gauge from here.
	//
	// One per state directory, which the process lock already guarantees: two
	// managers over one root would be two things cloning and swapping the same
	// directories.
	Mirrors *repomirror.Manager

	// FixturePromotion drains the corrections an operator kept into the
	// regression corpus, and is nil on every deployment that has no checkout of
	// the repository the corpus lives in.
	//
	// A field for the same reason Mirrors is one, and assigned after New for the
	// same reason the publisher is: building the drain needs a store that is
	// open and a corpus that exists, which is knowledge the process start-up
	// already has and 191 callers of New should not have to supply.
	FixturePromotion FixturePromotion

	identity    slackui.Identity
	initialized atomic.Bool
	running     atomic.Bool
	coopHealthy atomic.Bool
	heartbeats  laneHeartbeat
	clock       func() time.Time

	promptTruncation localstate.PromptTruncation

	// Process-local coordination state. See caches.go: none of it is durable
	// truth, and each piece owns its own lock.
	channelWrites *localstate.ChannelWriteSlots
	nativeStatus  *localstate.NativeStatusTracker
	cardActivity  *localstate.CardRefreshThrottle
	historyCache  *localstate.SlackHistoryCache
	runCancels    *localstate.RunCancellations
	replayControl replaycontrol.Controller

	// coverageGaps remembers the configured-but-unjoined channels last
	// reported, so a standing gap is stated when it appears and when it
	// changes rather than once a minute forever. Reconciliation is
	// single-threaded through the work lane; the mutex is here because
	// nothing else guarantees that stays true.
	coverageGapsMu       sync.Mutex
	reportedCoverageGaps string
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
// turn proves that Docker removed Coop's shared execution image after startup,
// and the gate's failure-streak reader so readiness can name an image that
// repeatedly fails to rebuild instead of reporting the process fine around it.
// One setter for both because they are two views of the same gate; health may
// be nil where no gate exists.
func (s *Service) SetCoopRuntimeRepairer(
	repair func(context.Context) error,
	health func() (int, error),
) {
	s.repairCoopRuntime = repair
	s.coopRepairHealth = health
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
	coopClient serviceport.RuntimeCoop,
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
	svc := &Service{
		cfg: cfg, store: st, coop: resultcontract.InstallOn(coopClient), socket: socket,
		sanitizer: sanitizer, log: logger,
		publisher:     publisher.New(cfg.GitHub),
		channelWrites: localstate.NewChannelWriteSlots(localstate.SlackWriteInterval),
		nativeStatus:  localstate.NewNativeStatusTracker(),
		cardActivity:  localstate.NewCardRefreshThrottle(localstate.CardActivityInterval),
		historyCache:  localstate.NewSlackHistoryCache(),
		runCancels:    localstate.NewRunCancellations(),
	}
	// Built here rather than injected, the way the publisher is: the manager
	// needs the state directory and the same GitHub credential the publisher
	// reads, both of which are already in cfg, and 191 callers of New should
	// not have to pass a repository manager to get a service.
	svc.Mirrors = repomirror.New(cfg, logger, repomirror.WithToken(
		func(ctx context.Context) (string, error) {
			return publisher.Token(ctx, cfg.GitHub)
		},
	))
	// The service holds a paced Slack client, so every write is visible to the
	// pacer rather than only the queued ones. See localstate.PaceChannelWrites;
	// the alternative was remembering to record at twenty scattered call sites.
	// svc.now is a method value, so it follows a clock installed later by
	// SetClock.
	svc.slack = localstate.PaceChannelWrites(slackClient, svc.channelWrites, svc.now)
	svc.branches = branching.New(st, coopClient, cfg, svc.now, logger)
	svc.replayControl = replaycontrol.Controller{
		CancelReplay: func(ctx context.Context, id, runKey, detail string) (core.AgentRun, bool, bool, error) {
			return store.CancelSlackReplay(ctx, st, id, runKey, detail)
		},
		Audit: st.Audit, Coop: coopClient, Active: svc.runCancels,
		Complete: st.ReplayCancellations.Complete, Retry: st.ReplayCancellations.Retry,
		Log: logger,
	}
	return svc
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
	if err := taskpublication.RecoverLegacyDirtyFailures(ctx, s.store, s.coop,
		taskpublication.RecoveryPolicy{
			TeamID: s.cfg.Slack.TeamID, InputKind: inputTaskPublication, Now: s.now,
			Warn: func(message, incidentID string, err error) {
				s.log.Warn(message, "incident", incidentID, "error", trimError(err))
			},
		}); err != nil {
		return fmt.Errorf("recover committed draft PR updates: %w", err)
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

// prewarmConversationSessions warms a model session for the channels most
// likely to be spoken to next, so the first question of the day does not wait
// for a cold start.
//
// It reads three sources, and the third is the one that was missing. Recent
// conversation lanes come from conversation_sessions; the static watch and
// summon lists come from YAML; and the channels an operator configured come
// from channel_configurations, the database control plane. A deployment that
// onboards channels by inviting the bot — which is the supported path, and the
// one blitz uses for all eight of its channels — has an empty YAML and, until
// someone has spoken, an empty conversation_sessions. Both of the old sources
// were therefore empty, the loop iterated nothing, and the function returned
// without warming anything and without saying it had not.
//
// That silence is fixed here too. Every exit reports what it decided: how many
// channels were considered, how many were warmed, and why any were skipped. A
// prewarm that does nothing is a fact worth one line, and its absence is what
// let thirty-five restarts pass with no warm session and no warning.
func (s *Service) prewarmConversationSessions(ctx context.Context) {
	budget := s.cfg.Coop.PrewarmSessions
	recent, err := s.store.ListRecentConversationChannels(ctx, budget)
	if err != nil && ctx.Err() == nil {
		s.log.Warn("could not list recent conversation sessions for prewarming", "error", err)
	}
	operatorConfigured, err := s.store.ListConfiguredChannelIDs(ctx, budget)
	if err != nil && ctx.Err() == nil {
		s.log.Warn("could not list configured channels for prewarming", "error", err)
	}
	configured := append(
		append([]string(nil), s.cfg.Slack.WatchChannels...),
		s.cfg.Slack.SummonChannels...,
	)
	slices.Sort(configured)
	candidates := len(recent) + len(operatorConfigured) + len(configured)
	channelIDs := make([]string, 0, candidates)
	seen := make(map[string]struct{}, candidates)
	for _, channelID := range slices.Concat(recent, operatorConfigured, configured) {
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
	skipped := 0
	// Every exit reports, including the one that considered nothing at all.
	// An empty candidate list is the exact state blitz was in for a week, and
	// it used to return here in silence.
	defer func() {
		if ctx.Err() != nil {
			return
		}
		record, outcome := s.log.Info, "finished prewarming conversation sessions"
		if prewarmed == 0 {
			record, outcome = s.log.Warn, "prewarmed no conversation sessions"
		}
		record(outcome,
			"prewarmed", prewarmed, "considered", len(channelIDs),
			"skipped", skipped, "budget", budget,
		)
	}()
	for _, channelID := range channelIDs {
		if prewarmed >= budget {
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
			skipped++
			s.log.Warn(
				"could not resolve conversation session for prewarming",
				"channel", channelID,
				"error", err,
			)
			continue
		}
		// A channel whose repository declares no conversation policy has
		// nothing to warm. That is a legitimate configuration, but it used to
		// be indistinguishable from a channel that was warmed, because both
		// produced no output at all.
		repository, ok := s.cfg.RepositoryContext(repositoryKey)
		if !ok || strings.TrimSpace(repository.ConversationPolicy) == "" {
			skipped++
			reason := "its repository declares no conversation policy"
			if !ok {
				reason = "its repository is not configured"
			}
			s.log.Info(
				"skipped prewarming a channel: "+reason,
				"channel", channelID,
				"repository", repositoryKey,
			)
			continue
		}
		// Whether the channel has a bounded lane at all is conversation_policy's
		// answer, above; which policy that lane runs under is the chat profile's.
		// Prewarming under a different policy than the lane asks for would build
		// a session the first message rotates away.
		conversationPolicy := repository.SessionProfilePolicy(config.ProfileChat, repository.ConversationPolicy)
		memory, session, err := s.ensureConversationSession(
			ctx,
			channelID,
			repositoryKey,
			conversationPolicy,
		)
		if err == nil {
			_, err = s.coop.PrepareSession(
				ctx,
				fmt.Sprintf("ryker:conversation-prepare:%s:%d", channelID, session.Revision),
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
					conversationPolicy,
					memory.Generation+1,
				)
			}
			if detachErr != nil {
				err = errors.Join(err, detachErr)
			} else if err == nil {
				_, err = s.coop.PrepareSession(
					ctx,
					fmt.Sprintf(
						"ryker:conversation-prepare:%s:%d",
						channelID,
						memory.SessionRevision,
					),
					session.ID,
					session.Revision,
				)
			}
		}
		if err != nil && ctx.Err() == nil {
			skipped++
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

// coopImageUnbuildableAfter is how many consecutive managed-image repair
// failures readiness tolerates before naming the condition. The gate's own
// prune-and-rebuild self-heal triggers at two, so by the third failure the
// self-heal has been tried and lost and the machine needs a person — the
// 2026-08-13 corruption outage ran 75 minutes with /readyz green throughout.
const coopImageUnbuildableAfter = 3

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
	if s.coopRepairHealth != nil {
		if failures, _ := s.coopRepairHealth(); failures >= coopImageUnbuildableAfter {
			// The exact token the watchdog's ready_reason() forwards; detail
			// stays in the supervisor log where the failing build wrote it.
			return false, "coop_image_unbuildable"
		}
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
	s.warnAboutLapsingCorrections(ctx)
	s.maintainLifecycle(ctx)
}

// warnAboutLapsingCorrections logs when the product's own corrections are about
// to be forgotten.
//
// A fixture candidate is a correction Ryker made about itself, and it is
// only actionable while it is pending. Until this existed the only place a
// pending correction appeared was App Home, so the loop could stall for a
// fortnight and then lose the evidence with nothing said anywhere.
//
// A log line rather than a Slack message, deliberately. The count is already on
// /metrics, and this deployment alerts from Grafana — so the alertable signal
// exists, and a proactive Slack notice would mean new plumbing whose failure
// mode is pestering operators about a queue they may be working through
// deliberately. The log is the second signal, not the primary one.
func (s *Service) warnAboutLapsingCorrections(ctx context.Context) {
	metrics, err := s.store.Metrics(ctx)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn("read correction review backlog", "error", err)
		}
		return
	}
	if metrics.CorrectionsLapsingSoon == 0 {
		return
	}
	s.log.Warn(
		"corrections are about to lapse unreviewed; they will not be learned from",
		"lapsing_within_3_days", metrics.CorrectionsLapsingSoon,
		"awaiting_review", metrics.CorrectionsAwaitingReview,
	)
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

func (s *Service) queueDelay(attempt int) time.Time { return s.now().Add(retrydelay.Duration(attempt)) }

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
	if err := s.store.Intelligence.RecordTimeline(ctx, event); err != nil && ctx.Err() == nil {
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
