package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/httpapi"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

var errProcessLocked = errors.New("another Responder process owns this state directory")

// shutdownGrace bounds the whole ordered shutdown: drain HTTP, then drain the
// service workers before the deferred store and Coop teardown runs.
const shutdownGrace = 15 * time.Second

func Run(args []string, stdout, stderr io.Writer, buildVersion string) error {
	if len(args) == 0 {
		printHelp(stdout)
		return nil
	}
	switch args[0] {
	case "serve":
		return runServe(args[1:], stdout, stderr)
	case "doctor":
		return runDoctor(args[1:], stdout, stderr)
	case "bootstrap-coop":
		return runBootstrap(args[1:], stdout, stderr)
	case "status":
		return runStatus(args[1:], stdout, stderr)
	case "failures":
		return runFailures(args[1:], stdout, stderr)
	case "retry":
		return runRetry(args[1:], stdout, stderr)
	case "replay":
		return runReplay(args[1:], stdout, stderr)
	case "eval":
		return runEval(args[1:], stdout, stderr)
	case "version", "--version", "-version":
		fmt.Fprintln(stdout, buildVersion)
		return nil
	case "help", "--help", "-h":
		printHelp(stdout)
		return nil
	default:
		return fmt.Errorf("unknown command %q (run responder help)", args[0])
	}
}

func runServe(args []string, stdout, stderr io.Writer) (resultErr error) {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("serve accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	logger := newLogger(stderr, cfg.LogLevel)
	// Serve verifies the bootstrap files only when it supervises Coop, because
	// that is the only case in which it is the one projecting them.
	pre := newPreflight(cfg)
	var bootstrapChecks []preflightCheck
	if cfg.Coop.Supervise {
		bootstrapChecks = append(bootstrapChecks, pre.coopBootstrapCheck())
	}
	if err := pre.run(context.Background(), bootstrapChecks...); err != nil {
		return err
	}
	secrets := pre.secrets
	botToken, appToken, emisarToken := pre.botToken, pre.appToken, pre.emisarToken
	redactions, emisarHTTP := pre.redactions, pre.emisarHTTP()
	githubPublisher := pre.publisher()
	lock, err := acquireProcessLock(cfg.StateDir)
	if err != nil {
		return err
	}
	defer releaseProcessLock(lock)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.RecoverInterrupted(context.Background()); err != nil {
		return err
	}
	if adopted, err := st.AdoptLegacyFeedback(context.Background(), cfg.StateDir); err != nil {
		return err
	} else if adopted > 0 {
		logger.Info("adopted feedback from the standalone database", "items", adopted)
	}
	coopClient := coop.New(cfg.Coop.Socket, cfg.Coop.RequestTimeout.Duration)
	supervisor, err := startManagedCoop(cfg, stderr, logger, coopClient)
	if err != nil {
		return err
	}
	defer func() {
		if stopErr := stopManagedCoop(supervisor, shutdownGrace); resultErr == nil && stopErr != nil {
			resultErr = stopErr
		}
	}()
	slackClient := slackui.New(botToken, appToken)
	svc := service.New(
		cfg, st, coopClient, slackClient, slackClient,
		slackui.NewSanitizer(cfg.Limits.MaxAssistantBytes, redactions...), logger,
	)
	coopClient.SetTruncationObserver(svc.RecordPromptTruncation)
	svc.SetPublisher(githubPublisher)
	svc.SetEmisar(emisar.New(emisarHTTP, cfg.Coop.EmisarURL, emisarToken))
	if cfg.Coop.Supervise {
		repair := newCoopRuntimeRepairGate(cfg.Coop.RestartDelay.Duration, func() error {
			return ensureManagedCoopImage(cfg, stderr)
		})
		svc.SetCoopRuntimeRepairer(repair.Repair)
	}
	startupCtx, startupCancel := context.WithTimeout(context.Background(), cfg.Coop.RequestTimeout.Duration)
	err = svc.Initialize(startupCtx)
	startupCancel()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.Listen, err)
	}
	defer listener.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	server := &http.Server{
		Handler:           httpapi.New(cfg, st, svc, secrets, logger),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	// Separate channels so shutdown can wait for the service workers
	// specifically. They own the store and the Coop connection, so returning
	// before they drain would close both underneath in-flight work.
	serviceStopped := make(chan error, 1)
	serverStopped := make(chan error, 1)
	go func() { serviceStopped <- svc.Run(ctx) }()
	go func() { serverStopped <- server.Serve(listener) }()
	fmt.Fprintf(stdout, "Responder listening on http://%s\n", listener.Addr())

	select {
	case <-ctx.Done():
	case runErr := <-serviceStopped:
		if runErr != nil {
			err = runErr
		}
		cancel()
		serviceStopped = nil
	case runErr := <-serverStopped:
		if runErr != nil && !errors.Is(runErr, http.ErrServerClosed) {
			err = runErr
		}
		cancel()
	}
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer shutdownCancel()
	if shutdownErr := server.Shutdown(shutdownCtx); shutdownErr != nil && err == nil {
		err = shutdownErr
	}
	if serviceStopped != nil {
		select {
		case runErr := <-serviceStopped:
			if runErr != nil && err == nil {
				err = runErr
			}
		case <-shutdownCtx.Done():
			logger.Error(
				"service workers did not drain before the shutdown deadline",
				"grace", shutdownGrace,
			)
			if err == nil {
				err = errors.New("service workers did not drain before shutdown")
			}
		}
	}
	return err
}

func runDoctor(args []string, stdout, stderr io.Writer) (resultErr error) {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	jsonOutput := flags.Bool("json", false, "print JSON")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("doctor accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	checks := map[string]string{"config": "ok"}
	// Doctor verifies the bootstrap files whether or not Responder supervises
	// Coop, and proves a box can actually start. Serve does neither: it repairs
	// a missing image on demand instead of refusing to start over it.
	pre := newPreflight(cfg)
	if err := pre.run(
		context.Background(),
		pre.coopBootstrapCheck(),
		pre.managedCoopImageCheck(),
	); err != nil {
		return err
	}
	botToken, appToken, emisarReport := pre.botToken, pre.appToken, pre.emisarReport
	logger := newLogger(stderr, cfg.LogLevel)
	lock, lockErr := acquireProcessLock(cfg.StateDir)
	var st *store.Store
	responderStatus := "not running (configuration checks only)"
	switch {
	case lockErr == nil:
		st, err = store.Open(cfg.StateDir)
	case errors.Is(lockErr, errProcessLocked):
		st, err = store.OpenCurrent(cfg.StateDir)
		readyCtx, readyCancel := context.WithTimeout(context.Background(), 3*time.Second)
		readyErr := probeResponderReady(readyCtx, cfg.Listen)
		readyCancel()
		if readyErr != nil {
			return fmt.Errorf(
				"Responder owns the state directory but is not serving on %s: %w",
				cfg.Listen,
				readyErr,
			)
		}
		responderStatus = "serving"
	default:
		err = lockErr
	}
	if err != nil {
		releaseProcessLock(lock)
		return err
	}
	defer st.Close()
	if err := st.Check(context.Background()); err != nil {
		releaseProcessLock(lock)
		return err
	}
	releaseProcessLock(lock)
	checks["database"] = "ok"
	checks["responder"] = responderStatus
	coopClient := coop.New(cfg.Coop.Socket, cfg.Coop.RequestTimeout.Duration)
	supervisor, supervision, err := startDoctorCoop(
		cfg, stderr, logger, coopClient,
	)
	if err != nil {
		return err
	}
	defer func() {
		if stopErr := stopManagedCoop(supervisor, shutdownGrace); resultErr == nil && stopErr != nil {
			resultErr = stopErr
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), cfg.Coop.RequestTimeout.Duration)
	defer cancel()
	if err := coopClient.Ready(ctx); err != nil {
		return fmt.Errorf("Coop: %w", err)
	}
	checks["coop"] = "ok"
	checks["coop_supervision"] = supervision
	slackReport, err := slackui.New(botToken, appToken).Preflight(
		ctx, cfg.Slack.TeamID, cfg.Slack.Operators,
		cfg.Slack.InviteUsers, cfg.Slack.SummonChannels, cfg.Slack.WatchChannels,
	)
	if err != nil {
		return fmt.Errorf("Slack: %w", err)
	}
	checks["slack"] = "ok"
	checks["slack_socket_mode"] = "ok"
	checks["slack_operators"] = fmt.Sprintf("%d", slackReport.OperatorCount)
	checks["slack_invite_users"] = fmt.Sprintf("%d", slackReport.InviteCount)
	checks["slack_summon_channels"] = fmt.Sprintf("%d", slackReport.SummonChannels)
	checks["slack_watch_channels"] = fmt.Sprintf("%d", slackReport.WatchChannels)
	checks["emisar_mcp"] = fmt.Sprintf(
		"authenticated; %d tools; protocol %s",
		emisarReport.ToolCount,
		emisarReport.ProtocolVersion,
	)
	checks["coop_config"] = "private"
	if cfg.GitHub.Enabled {
		checks["github_publisher"] = "draft PR credentials ready"
	} else {
		checks["github_publisher"] = "disabled"
	}
	if *jsonOutput {
		return json.NewEncoder(stdout).Encode(map[string]any{"healthy": true, "checks": checks})
	}
	fmt.Fprintln(stdout, "config          ok")
	fmt.Fprintln(stdout, "database        ok")
	fmt.Fprintf(stdout, "Responder       %s\n", responderStatus)
	fmt.Fprintf(stdout, "Coop            ready (%s)\n", checks["coop_supervision"])
	fmt.Fprintln(stdout, "Slack           authenticated; scopes and Socket Mode ready")
	fmt.Fprintf(stdout, "Operators       %d full workspace members\n", slackReport.OperatorCount)
	fmt.Fprintf(stdout, "Invite users    %d full workspace members\n", slackReport.InviteCount)
	fmt.Fprintf(stdout, "Summon channels %d accessible\n", slackReport.SummonChannels)
	fmt.Fprintf(stdout, "Watch channels  %d accessible\n", slackReport.WatchChannels)
	fmt.Fprintf(
		stdout,
		"Emisar MCP      authenticated; %d tools; required operational tools ready\n",
		emisarReport.ToolCount,
	)
	fmt.Fprintln(stdout, "Coop config     private")
	fmt.Fprintf(stdout, "GitHub          %s\n", checks["github_publisher"])
	return nil
}

func probeResponderReady(ctx context.Context, listen string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+listen+"/readyz", nil)
	if err != nil {
		return err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("ready endpoint returned %s", response.Status)
	}
	return nil
}

func runStatus(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("status", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	jsonOutput := flags.Bool("json", false, "print JSON")
	limit := flags.Int("limit", 50, "maximum incidents")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("status accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()
	incidents, err := st.ListIncidents(context.Background(), *limit)
	if err != nil {
		return err
	}
	metrics, err := st.Metrics(context.Background())
	if err != nil {
		return err
	}
	if *jsonOutput {
		if incidents == nil {
			incidents = []core.Incident{}
		}
		return json.NewEncoder(stdout).Encode(struct {
			Metrics   store.Metrics   `json:"metrics"`
			Incidents []core.Incident `json:"incidents"`
		}{
			Metrics:   metrics,
			Incidents: incidents,
		})
	}
	fmt.Fprintf(
		stdout,
		"Lifecycle: %d draft PRs, %d cleanup queued, %d cleanup blocked\n",
		metrics.PublishedPRs, metrics.CleanupPending, metrics.CleanupBlocked,
	)
	if len(incidents) == 0 {
		fmt.Fprintln(stdout, "No incidents.")
		return nil
	}
	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "INCIDENT\tSTATUS\tWORKFLOW\tSIGNALS\tCHANNEL\tTITLE\tERROR")
	for _, incident := range incidents {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%d/%d\t%s\t%s\t%s\n",
			slackui.ShortID(incident.ID), incident.Status, incident.Workflow,
			incident.FiringCount, incident.SignalCount,
			displayOr(incident.ChannelName, "-"), incident.Title,
			displayOr(incident.LastError, "-"))
	}
	return writer.Flush()
}

func runFailures(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("failures", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	jsonOutput := flags.Bool("json", false, "print JSON")
	limit := flags.Int("limit", 50, "maximum failed work items")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("failures accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()
	items, err := st.ListFailedWork(context.Background(), *limit)
	if err != nil {
		return err
	}
	if *jsonOutput {
		return json.NewEncoder(stdout).Encode(items)
	}
	if len(items) == 0 {
		fmt.Fprintln(stdout, "No failed work.")
		return nil
	}
	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "KIND\tID\tRETRYABLE\tATTEMPTS\tREFERENCE\tUPDATED\tERROR")
	for _, item := range items {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%d\t%s\t%s\t%s\n",
			item.Kind, item.ID, yesNo(item.Retryable), item.Attempts, displayOr(item.Reference, "-"),
			item.UpdatedAt.Local().Format(time.RFC3339), displayOr(item.LastError, "-"))
	}
	return writer.Flush()
}

func runRetry(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("retry", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 2 {
		return errors.New(
			"usage: responder retry [--config path] " +
				"<webhook|slack|delivery|agent_run> <id>",
		)
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if err := ensurePrivateDirectory(cfg.StateDir); err != nil {
		return err
	}
	lock, err := acquireProcessLock(cfg.StateDir)
	if err != nil {
		return fmt.Errorf("stop Responder before retrying work: %w", err)
	}
	defer releaseProcessLock(lock)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()
	kind, id := flags.Arg(0), flags.Arg(1)
	_, err = st.RetryFailedWork(context.Background(), kind, id)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Requeued %s %s with its original durable payload and idempotency identity.\n", kind, id)
	return nil
}

func runtimeSecrets(cfg config.Config) (map[string]string, string, string, error) {
	botToken, err := cfg.Secret(cfg.Slack.BotTokenEnv)
	if err != nil {
		return nil, "", "", err
	}
	appToken, err := cfg.Secret(cfg.Slack.AppTokenEnv)
	if err != nil {
		return nil, "", "", err
	}
	secrets := make(map[string]string, len(cfg.Webhooks))
	for name, route := range cfg.Webhooks {
		secret, err := cfg.Secret(route.SecretEnv)
		if err != nil {
			return nil, "", "", err
		}
		secrets[name] = secret
	}
	return secrets, botToken, appToken, nil
}

func acquireProcessLock(stateDir string) (*os.File, error) {
	path := filepath.Join(stateDir, "responder.lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open process lock: %w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return nil, fmt.Errorf("protect process lock: %w", err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errProcessLocked
	}
	return file, nil
}

func releaseProcessLock(file *os.File) {
	if file == nil {
		return
	}
	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	_ = file.Close()
}

func defaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "responder.yaml"
	}
	return filepath.Join(home, ".config", "responder", "responder.yaml")
}

func newLogger(output io.Writer, level string) *slog.Logger {
	var configured slog.Level
	_ = configured.UnmarshalText([]byte(level))
	return slog.New(slog.NewJSONHandler(output, &slog.HandlerOptions{Level: configured}))
}

func displayOr(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func printHelp(output io.Writer) {
	fmt.Fprintln(output, `Responder turns authenticated alert webhooks into isolated Coop investigations and focused Slack incident channels.

Usage:
  responder serve          Run webhook, Slack, and Coop reconciliation
  responder doctor         Verify local state, Coop, Slack, and the Emisar MCP tool catalog
  responder bootstrap-coop Write private Coop MCP, environment, and instruction files
  responder status         List durable incidents
  responder failures       List terminal durable work
  responder retry          Requeue one failed work item while Responder is stopped
  responder replay slack   Privately reprocess a saved Slack message; --publish sends the result
  responder eval           Run the real configured model against the evaluation corpus
  responder version        Print the build version

Every command accepts --help. The default config is ~/.config/responder/responder.yaml.`)
}
