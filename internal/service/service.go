package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack/socketmode"
)

type CoopAPI interface {
	Ready(context.Context) error
	CreateSession(context.Context, string, string, string) (coop.Session, coop.Operation, error)
	GetSession(context.Context, string) (coop.Session, error)
	ListSessions(context.Context, int) ([]coop.Session, error)
	SubmitTurn(context.Context, string, string, int64, string) (coop.Turn, coop.Operation, error)
	GetTurn(context.Context, string, string) (coop.Turn, error)
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

type Service struct {
	cfg       config.Config
	store     *store.Store
	coop      CoopAPI
	slack     slackui.API
	socket    Socket
	sanitizer *slackui.Sanitizer
	log       *slog.Logger
	publisher PublicationAPI

	identity     slackui.Identity
	initialized  atomic.Bool
	running      atomic.Bool
	coopHealthy  atomic.Bool
	postMu       sync.Mutex
	lastPost     time.Time
	statusMu     sync.Mutex
	nativeStatus map[string]nativeStatusState

	retryMu sync.Mutex
	retries map[string]retryState
}

type retryState struct {
	at       time.Time
	attempts int
}

type nativeStatusState struct {
	text string
	at   time.Time
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
	return &Service{
		cfg: cfg, store: st, coop: coopClient, slack: slackClient, socket: socket,
		sanitizer: sanitizer, log: logger,
		publisher:    publisher.New(cfg.GitHub),
		nativeStatus: make(map[string]nativeStatusState),
		retries:      make(map[string]retryState),
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
	s.identity = identity
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
	s.startPeriodicWorker(
		runCtx,
		&workers,
		s.cfg.Limits.WorkerInterval.Duration,
		s.runControlWork,
	)
	s.startPeriodicWorker(
		runCtx,
		&workers,
		s.cfg.Limits.WorkerInterval.Duration,
		s.runBackgroundWork,
	)
	s.startPeriodicWorker(
		runCtx,
		&workers,
		s.cfg.Coop.PollInterval.Duration,
		func(workerCtx context.Context) {
			s.pollAgentRuns(workerCtx)
			s.pollCoop(workerCtx)
		},
	)
	s.startPeriodicWorker(
		runCtx,
		&workers,
		s.cfg.Retention.MaintenanceInterval.Duration,
		s.runMaintenance,
	)

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

func (s *Service) startPeriodicWorker(
	ctx context.Context,
	group *sync.WaitGroup,
	interval time.Duration,
	run func(context.Context),
) {
	group.Add(1)
	go func() {
		defer group.Done()
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			run(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
}

func (s *Service) Ready() (bool, string) {
	switch {
	case !s.initialized.Load():
		return false, "initializing"
	case !s.running.Load():
		return false, "worker stopped"
	case !s.coopHealthy.Load():
		return false, "Coop unavailable"
	case s.socket == nil || !s.socket.Connected():
		return false, "Slack disconnected"
	default:
		return true, "ready"
	}
}

func (s *Service) Identity() slackui.Identity {
	return s.identity
}

func (s *Service) runControlWork(ctx context.Context) {
	s.runSteps(ctx, []workerStep{
		{"Slack input", s.processSlackInput},
		{"Slack delivery reconciliation", s.reconcileSlackDelivery},
		{"Slack write", s.processSlackWrite},
	})
}

func (s *Service) runBackgroundWork(ctx context.Context) {
	s.runSteps(ctx, []workerStep{
		{"webhook", s.processWebhook},
		{"channel", s.processChannel},
		{"session", s.processSession},
		{"agent run", s.processAgentRun},
		{"agent result", s.processAgentRunFinalization},
	})
}

type workerStep struct {
	name string
	run  func(context.Context) error
}

func (s *Service) runSteps(ctx context.Context, steps []workerStep) {
	for _, step := range steps {
		if err := step.run(ctx); err != nil && !errors.Is(err, store.ErrNotFound) && ctx.Err() == nil {
			s.log.Error("worker step failed", "step", step.name, "error", err)
		}
	}
}

func (s *Service) runMaintenance(ctx context.Context) {
	if _, err := s.store.ResolveDueIncidents(ctx, time.Now()); err != nil && ctx.Err() == nil {
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
		ctx, incident.ChannelID, state, time.Now().UTC(),
	)
	if err != nil {
		return err
	}
	if incident.ChannelState != state {
		for _, item := range updated {
			_ = s.store.Audit(ctx, core.AuditEvent{
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

func (s *Service) canRetry(key string) bool {
	s.retryMu.Lock()
	defer s.retryMu.Unlock()
	return !time.Now().Before(s.retries[key].at)
}

func (s *Service) retryLater(key string) {
	s.retryMu.Lock()
	defer s.retryMu.Unlock()
	state := s.retries[key]
	state.attempts++
	seconds := math.Min(300, math.Pow(2, float64(min(state.attempts, 8))))
	state.at = time.Now().Add(time.Duration(seconds) * time.Second)
	s.retries[key] = state
}

func (s *Service) retryDone(key string) {
	s.retryMu.Lock()
	delete(s.retries, key)
	s.retryMu.Unlock()
}

func queueDelay(attempt int) time.Time {
	seconds := math.Min(300, math.Pow(2, float64(min(max(attempt, 1), 8))))
	return time.Now().Add(time.Duration(seconds) * time.Second)
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
