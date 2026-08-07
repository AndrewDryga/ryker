package app

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"gopkg.in/yaml.v3"
)

type coopReadiness interface {
	Ready(context.Context) error
}

type coopSupervisor struct {
	cfg    config.Config
	output io.Writer
	log    *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	exited chan error

	processMu sync.Mutex
	process   *exec.Cmd

	stateMu       sync.Mutex
	ready         bool
	startupOutput *coopProcessOutput
}

// coopRuntimeRepairGate prevents a missing Docker daemon or broken image build
// from turning an alert burst into one expensive build attempt per message.
// Responder remains online, keeps the work queued, and retries the shared
// dependency on an exponential schedule.
type coopRuntimeRepairGate struct {
	mu       sync.Mutex
	base     time.Duration
	now      func() time.Time
	repair   func() error
	failures int
	next     time.Time
	lastErr  error
}

const coopStartupOutputLimit = 16 << 10

const coopMissingImageDiagnostic = "coop box image is not built"

func newCoopRuntimeRepairGate(base time.Duration, repair func() error) *coopRuntimeRepairGate {
	return &coopRuntimeRepairGate{base: base, now: time.Now, repair: repair}
}

func (g *coopRuntimeRepairGate) Repair(ctx context.Context) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	now := g.now()
	if now.Before(g.next) {
		return fmt.Errorf(
			"managed Coop image repair is waiting until %s after the previous failure: %w",
			g.next.UTC().Format(time.RFC3339), g.lastErr,
		)
	}
	if g.repair == nil {
		return errors.New("managed Coop image repair is unavailable")
	}
	if err := g.repair(); err != nil {
		g.failures++
		g.lastErr = err
		g.next = now.Add(coopRestartBackoff(g.base, g.failures))
		return err
	}
	g.failures = 0
	g.next = time.Time{}
	g.lastErr = nil
	return nil
}

type coopProcessOutput struct {
	mu          sync.Mutex
	destination io.Writer
	tail        []byte
}

func (w *coopProcessOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(p) >= coopStartupOutputLimit {
		w.tail = append(w.tail[:0], p[len(p)-coopStartupOutputLimit:]...)
	} else {
		overflow := len(w.tail) + len(p) - coopStartupOutputLimit
		if overflow > 0 {
			copy(w.tail, w.tail[overflow:])
			w.tail = w.tail[:len(w.tail)-overflow]
		}
		w.tail = append(w.tail, p...)
	}
	return w.destination.Write(p)
}

func (w *coopProcessOutput) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(w.tail)
}

func startCoopSupervisor(cfg config.Config, output io.Writer, logger *slog.Logger) (*coopSupervisor, error) {
	live, err := coopSocketLive(cfg.Coop.Socket)
	if err != nil {
		return nil, err
	}
	if live {
		return nil, errors.New("managed Coop cannot start because its socket is already serving")
	}
	ctx, cancel := context.WithCancel(context.Background())
	supervisor := &coopSupervisor{
		cfg: cfg, output: output, log: logger,
		ctx: ctx, cancel: cancel, done: make(chan struct{}), exited: make(chan error, 1),
	}
	command, err := supervisor.start()
	if err != nil {
		cancel()
		return nil, fmt.Errorf("start managed Coop: %w", err)
	}
	go supervisor.run(command)
	return supervisor, nil
}

func attachCoopSupervisor(
	cfg config.Config,
	output io.Writer,
	logger *slog.Logger,
	client coopReadiness,
) *coopSupervisor {
	ctx, cancel := context.WithCancel(context.Background())
	supervisor := &coopSupervisor{
		cfg: cfg, output: output, log: logger,
		ctx: ctx, cancel: cancel, done: make(chan struct{}), exited: make(chan error, 1),
		ready: true,
	}
	go supervisor.monitorAttached(client)
	return supervisor
}

func ensureManagedCoopImage(cfg config.Config, output io.Writer) error {
	missing, err := inspectManagedCoopImage(cfg)
	if err != nil {
		return err
	}
	if !missing {
		return nil
	}
	fmt.Fprintln(output, "Managed Coop box image is missing; building it now.")
	command, err := managedCoopCommand(cfg, "build")
	if err != nil {
		return err
	}
	command.Stdout = output
	command.Stderr = output
	if err := command.Run(); err != nil {
		return fmt.Errorf("build managed Coop box image: %w", err)
	}
	missing, err = inspectManagedCoopImage(cfg)
	if err != nil {
		return err
	}
	if missing {
		return errors.New("managed Coop build completed without producing its box image")
	}
	return nil
}

func checkManagedCoopImage(cfg config.Config) error {
	missing, err := inspectManagedCoopImage(cfg)
	if err != nil {
		return err
	}
	if !missing {
		return nil
	}
	return fmt.Errorf(
		"managed Coop box image is missing; Responder cannot execute agent turns; run:\n  cd %s && COOP_CONFIG_DIR=%s %s build\nthen retry Responder",
		shellWord(managedCoopRepository(cfg)),
		shellWord(cfg.Coop.BootstrapDir),
		shellWord(cfg.Coop.Binary),
	)
}

func inspectManagedCoopImage(cfg config.Config) (bool, error) {
	// Coop doctor intentionally probes a self-contained fixture, so it can only
	// prove that the shared base image exists. A repository may select its own
	// image through .agent/Dockerfile or COOP_IMAGE. Exercise the same repository
	// resolution and box startup path as a real turn instead.
	command, err := managedCoopCommand(cfg, "run", "--", "true")
	if err != nil {
		return false, err
	}
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		detail := strings.TrimSpace(output.String())
		if managedCoopImageMissingDiagnostic(detail) {
			return true, nil
		}
		return false, fmt.Errorf("preflight managed Coop execution image: %w: %s", err, detail)
	}
	return false, nil
}

func managedCoopImageMissingDiagnostic(detail string) bool {
	detail = strings.ToLower(strings.TrimSpace(detail))
	if strings.Contains(detail, coopMissingImageDiagnostic) {
		return true
	}
	// Coop 7.2 reports the resolved project image name instead of the generic
	// box diagnostic. Require the remediation command as well as "not built"
	// so unrelated build failures still surface as real preflight errors.
	return strings.Contains(detail, "image ") && strings.Contains(detail, "not built") &&
		strings.Contains(detail, "coop build")
}

func managedCoopCommand(cfg config.Config, args ...string) (*exec.Cmd, error) {
	repository := managedCoopRepository(cfg)
	if repository == "" {
		return nil, fmt.Errorf("default repository %q has no path for managed Coop runtime preflight", cfg.Slack.DefaultRepository)
	}
	command := exec.Command(cfg.Coop.Binary, args...)
	command.Dir = repository
	command.Env = append(coopEnvironment(cfg), "COOP_REPO="+repository)
	return command, nil
}

func managedCoopRepository(cfg config.Config) string {
	repository, ok := cfg.RepositoryContext(cfg.Slack.DefaultRepository)
	if !ok {
		return ""
	}
	return strings.TrimSpace(repository.Path)
}

func startManagedCoop(
	cfg config.Config,
	output io.Writer,
	logger *slog.Logger,
	client coopReadiness,
) (*coopSupervisor, error) {
	if !cfg.Coop.Supervise {
		return nil, nil
	}
	readyCtx, readyCancel := context.WithTimeout(
		context.Background(),
		cfg.Coop.RequestTimeout.Duration,
	)
	readyErr := client.Ready(readyCtx)
	readyCancel()
	if readyErr == nil {
		logger.Info("attached to existing managed Coop", "socket", cfg.Coop.Socket)
		return attachCoopSupervisor(cfg, output, logger, client), nil
	}
	supervisor, err := startCoopSupervisor(cfg, output, logger)
	if err != nil {
		return nil, err
	}
	readyCtx, cancel := context.WithTimeout(context.Background(), cfg.Coop.RequestTimeout.Duration)
	defer cancel()
	if err := supervisor.WaitReady(readyCtx, client); err != nil {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), cfg.Coop.RequestTimeout.Duration)
		defer stopCancel()
		return nil, errors.Join(err, supervisor.Close(stopCtx))
	}
	return supervisor, nil
}

// monitorAttached adopts a healthy Coop process left behind by an interrupted
// Responder restart. If that process later disappears, this Responder starts a
// replacement and resumes ordinary child-process supervision.
func (s *coopSupervisor) monitorAttached(client coopReadiness) {
	delay := s.cfg.Coop.RestartDelay.Duration
	if delay <= 0 || delay > time.Second {
		delay = time.Second
	}
	ticker := time.NewTicker(delay)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			close(s.done)
			return
		case <-ticker.C:
		}

		probeCtx, probeCancel := context.WithTimeout(
			s.ctx,
			s.cfg.Coop.RequestTimeout.Duration,
		)
		err := client.Ready(probeCtx)
		probeCancel()
		if err == nil {
			continue
		}
		live, liveErr := coopSocketLive(s.cfg.Coop.Socket)
		if liveErr != nil || live {
			continue
		}

		command, startErr := s.start()
		if startErr != nil {
			s.log.Error("managed Coop takeover failed", "error", startErr)
			continue
		}
		s.log.Info("managed Coop takeover started", "pid", command.Process.Pid)
		s.run(command)
		return
	}
}

func validateConversationPrewarmPolicies(cfg config.Config) error {
	if cfg.Coop.PrewarmSessions <= 0 {
		return nil
	}
	if strings.TrimSpace(cfg.Coop.Policies) == "" {
		return errors.New(
			"prewarm_conversation_sessions requires a readable Coop policies file",
		)
	}
	data, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		return fmt.Errorf("read Coop policies for conversation prewarming: %w", err)
	}
	var policyFile struct {
		Policies map[string]struct {
			WarmIdleTimeout string `yaml:"warm_idle_timeout"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(data, &policyFile); err != nil {
		return fmt.Errorf("parse Coop policies for conversation prewarming: %w", err)
	}
	seen := make(map[string]struct{})
	for _, repositoryKey := range cfg.RepositoryContextKeys() {
		repository, ok := cfg.RepositoryContext(repositoryKey)
		if !ok {
			continue
		}
		policyName := strings.TrimSpace(repository.ConversationPolicy)
		if policyName == "" {
			continue
		}
		if _, ok := seen[policyName]; ok {
			continue
		}
		seen[policyName] = struct{}{}
		policy, ok := policyFile.Policies[policyName]
		if !ok {
			return fmt.Errorf(
				"conversation prewarming requires Coop policy %q, but it is not defined in %s",
				policyName, cfg.Coop.Policies,
			)
		}
		idle, parseErr := time.ParseDuration(strings.TrimSpace(policy.WarmIdleTimeout))
		if parseErr != nil || idle <= 0 {
			return fmt.Errorf(
				"conversation prewarming requires Coop policy %q to set a positive warm_idle_timeout (for example, warm_idle_timeout: 15m)",
				policyName,
			)
		}
	}
	return nil
}

func startDoctorCoop(
	cfg config.Config,
	output io.Writer,
	logger *slog.Logger,
	client coopReadiness,
) (*coopSupervisor, string, error) {
	if !cfg.Coop.Supervise {
		return nil, "external", nil
	}
	readyCtx, readyCancel := context.WithTimeout(
		context.Background(),
		cfg.Coop.RequestTimeout.Duration,
	)
	readyErr := client.Ready(readyCtx)
	readyCancel()
	if readyErr == nil {
		return nil, "managed; already running", nil
	}
	live, err := coopSocketLive(cfg.Coop.Socket)
	if err != nil {
		return nil, "", err
	}
	if live {
		return nil, "", fmt.Errorf(
			"existing managed Coop socket is serving but not ready: %w",
			readyErr,
		)
	}
	supervisor, err := startManagedCoop(cfg, output, logger, client)
	if err != nil {
		return nil, "", err
	}
	return supervisor, "managed; temporary", nil
}

func stopManagedCoop(supervisor *coopSupervisor, timeout time.Duration) error {
	if supervisor == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return supervisor.Close(ctx)
}

func (s *coopSupervisor) WaitReady(ctx context.Context, client coopReadiness) error {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	var lastErr error
	for {
		s.stateMu.Lock()
		err := client.Ready(ctx)
		if err == nil {
			s.ready = true
		}
		s.stateMu.Unlock()
		if err == nil {
			s.log.Info("managed Coop is ready", "socket", s.cfg.Coop.Socket)
			return nil
		}
		lastErr = err
		select {
		case exitErr := <-s.exited:
			if exitErr == nil {
				exitErr = errors.New("process exited successfully")
			}
			s.stateMu.Lock()
			output := s.startupOutput
			s.stateMu.Unlock()
			if output != nil {
				if remediation := coopAuthenticationRemediation(s.cfg, output.String()); remediation != "" {
					return fmt.Errorf("%s: %w", remediation, exitErr)
				}
			}
			return fmt.Errorf("managed Coop exited before becoming ready: %w", exitErr)
		case <-ctx.Done():
			return fmt.Errorf("wait for managed Coop readiness: %w", errors.Join(ctx.Err(), lastErr))
		case <-ticker.C:
		}
	}
}

func (s *coopSupervisor) Close(ctx context.Context) error {
	s.cancel()
	s.signal(syscall.SIGTERM)
	select {
	case <-s.done:
		return nil
	case <-ctx.Done():
		s.signal(syscall.SIGKILL)
		select {
		case <-s.done:
		case <-time.After(time.Second):
		}
		return fmt.Errorf("stop managed Coop: %w", ctx.Err())
	}
}

func (s *coopSupervisor) run(command *exec.Cmd) {
	defer close(s.done)
	startedAt := time.Now()
	shortLivedFailures := 0
	for {
		waitErr := command.Wait()
		uptime := time.Since(startedAt)
		s.clearProcess(command)
		if s.ctx.Err() != nil {
			return
		}

		s.stateMu.Lock()
		ready := s.ready
		s.stateMu.Unlock()
		if !ready {
			select {
			case s.exited <- waitErr:
			default:
			}
			return
		}

		if uptime >= 5*time.Minute {
			shortLivedFailures = 0
		}
		shortLivedFailures++
		delay := coopRestartBackoff(s.cfg.Coop.RestartDelay.Duration, shortLivedFailures)
		s.log.Error(
			"managed Coop exited; restarting",
			"error", processResult(waitErr), "uptime", uptime, "retry_in", delay,
		)
		if !sleepContext(s.ctx, delay) {
			return
		}
		for {
			next, err := s.start()
			if err == nil {
				s.log.Info("managed Coop restarted", "pid", next.Process.Pid)
				command = next
				startedAt = time.Now()
				break
			}
			if s.ctx.Err() != nil {
				return
			}
			s.log.Error("managed Coop restart failed", "error", err)
			shortLivedFailures++
			delay = coopRestartBackoff(s.cfg.Coop.RestartDelay.Duration, shortLivedFailures)
			if !sleepContext(s.ctx, delay) {
				return
			}
		}
	}
}

func coopRestartBackoff(base time.Duration, failures int) time.Duration {
	if base <= 0 {
		base = time.Second
	}
	if failures < 1 {
		failures = 1
	}
	delay := base
	for attempt := 1; attempt < failures && delay < 5*time.Minute; attempt++ {
		if delay > 5*time.Minute/2 {
			return 5 * time.Minute
		}
		delay *= 2
	}
	if delay > 5*time.Minute {
		return 5 * time.Minute
	}
	return delay
}

func (s *coopSupervisor) start() (*exec.Cmd, error) {
	coop := s.cfg.Coop
	command := exec.Command(
		coop.Binary,
		"sessions", "serve",
		"--state", coop.StateDir,
		"--policies", coop.Policies,
		"--socket", coop.Socket,
	)
	command.Env = coopEnvironment(s.cfg)
	processOutput := &coopProcessOutput{destination: s.output}
	command.Stdout = processOutput
	command.Stderr = processOutput
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	s.stateMu.Lock()
	s.startupOutput = processOutput
	s.stateMu.Unlock()
	if err := command.Start(); err != nil {
		return nil, err
	}
	s.processMu.Lock()
	s.process = command
	s.processMu.Unlock()
	if s.ctx.Err() != nil {
		s.signal(syscall.SIGTERM)
	}
	return command, nil
}

func (s *coopSupervisor) clearProcess(command *exec.Cmd) {
	s.processMu.Lock()
	if s.process == command {
		s.process = nil
	}
	s.processMu.Unlock()
}

func (s *coopSupervisor) signal(signal syscall.Signal) {
	s.processMu.Lock()
	command := s.process
	s.processMu.Unlock()
	if command == nil || command.Process == nil {
		return
	}
	_ = syscall.Kill(-command.Process.Pid, signal)
}

func coopEnvironment(cfg config.Config) []string {
	blocked := map[string]bool{
		"COOP_CONFIG_DIR": true,
		"COOP_REPO":       true,
		"COOP_SPINNER":    true,
		"NO_COLOR":        true,
		"TERM":            true,
	}
	for name := range reservedServiceEnvironment(cfg) {
		blocked[name] = true
	}
	environment := make([]string, 0, len(os.Environ())+4)
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if !blocked[name] {
			environment = append(environment, entry)
		}
	}
	return append(environment,
		"COOP_CONFIG_DIR="+cfg.Coop.BootstrapDir,
		"COOP_SPINNER=0",
		"NO_COLOR=1",
		"TERM=dumb",
	)
}

func sleepContext(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func processResult(err error) string {
	if err == nil {
		return "process exited successfully"
	}
	return err.Error()
}

func coopAuthenticationRemediation(cfg config.Config, output string) string {
	// Coop names the rung as `target` or `target[i]` and calls the account a
	// credential, so match on the credential clause rather than a fixed label.
	const accountPrefix = `credential "`
	const accountSuffix = `" is not authenticated`
	accountStart := strings.LastIndex(output, accountPrefix)
	if accountStart < 0 {
		return ""
	}
	accountStart += len(accountPrefix)
	accountEnd := strings.Index(output[accountStart:], accountSuffix)
	if accountEnd < 0 {
		return ""
	}
	account := output[accountStart : accountStart+accountEnd]

	const policyPrefix = `policy "`
	const policySuffix = `": target`
	policyStart := strings.LastIndex(output[:accountStart], policyPrefix)
	if policyStart < 0 {
		return ""
	}
	policyStart += len(policyPrefix)
	policyEnd := strings.Index(output[policyStart:], policySuffix)
	if policyEnd < 0 {
		return ""
	}
	policyName := output[policyStart : policyStart+policyEnd]

	data, err := os.ReadFile(cfg.Coop.Policies)
	if err != nil {
		return ""
	}
	var policyFile struct {
		Policies map[string]struct {
			Target yaml.Node `yaml:"target"`
		} `yaml:"policies"`
	}
	if err := yaml.Unmarshal(data, &policyFile); err != nil {
		return ""
	}
	policy, ok := policyFile.Policies[policyName]
	if !ok {
		return ""
	}
	// A target may be a fallback ladder. Decoding it as a plain string fails on
	// a list, which would silently drop the remediation and leave the operator
	// with Coop's bare "not authenticated" — the diagnostic this exists to
	// replace.
	rungs, err := policyTargetRungs(&policy.Target)
	if err != nil || len(rungs) == 0 {
		return ""
	}
	// The credential Coop named says which rung is broken. A rung that pins no
	// credential runs on the provider's default, so the first rung stays the
	// answer when nothing matches by name.
	provider := ""
	for _, rung := range rungs {
		if rungProvider, rungAccount := splitTargetRung(rung); rungAccount == account {
			provider = rungProvider
			break
		}
	}
	if provider == "" {
		provider, _ = splitTargetRung(rungs[0])
	}
	if provider == "" || account == "" {
		return ""
	}
	loginTarget := provider + "@" + account
	return fmt.Sprintf(
		"managed Coop target %s is not authenticated; run:\n  COOP_CONFIG_DIR=%s %s login %s\nthen retry Responder",
		loginTarget,
		shellWord(cfg.Coop.BootstrapDir),
		shellWord(cfg.Coop.Binary),
		shellWord(loginTarget),
	)
}

// splitTargetRung separates one target's provider from its pinned credential.
func splitTargetRung(rung string) (provider, account string) {
	provider = strings.TrimSpace(rung)
	if at := strings.IndexByte(provider, '@'); at >= 0 {
		provider, account = provider[:at], provider[at+1:]
	}
	if separator := strings.IndexAny(provider, ":/"); separator >= 0 {
		provider = provider[:separator]
	}
	return provider, account
}

func shellWord(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}
