package app

import (
	"context"
	"fmt"
	"net/http"
	"os"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/publisher"
)

// preflight is the set of readiness checks serve, doctor and eval run before
// accepting work.
//
// They used to be written inline in each of those three, which is how doctor
// drifted from what serve actually requires — and doctor exists precisely to
// tell an operator why serve will not start. One definition of each check, with
// the differences between callers stated where the callers are, is the only
// version of that which stays true.
//
// Each check is a method taking no arguments beyond a context, so it can be
// exercised on its own against a config fixture.
type preflight struct {
	cfg config.Config

	// Populated by earlier checks and read by later ones and by the callers.
	secrets              map[string]string
	projectedEnvironment map[string]string
	botToken             string
	appToken             string
	emisarToken          string
	// redactions is every secret value in scope, assembled once so that no
	// error surfaced by a later check — or by the running service — can print
	// one. Building it in two places is how one of them ends up incomplete.
	redactions   []string
	emisarReport emisarMCPReport
	httpClient   *http.Client
}

// preflightCheck is one named step. The name is operator-facing: it prefixes
// the error, so a failure reads as "Emisar MCP: ..." rather than as a bare
// transport error with no indication of which dependency produced it.
type preflightCheck struct {
	name string
	run  func(context.Context) error
}

func newPreflight(cfg config.Config) *preflight {
	return &preflight{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: cfg.Coop.RequestTimeout.Duration,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// checks returns the sequence every caller runs. Callers with additional
// requirements append them; see runDoctor and runServe.
func (p *preflight) checks() []preflightCheck {
	return []preflightCheck{
		{"conversation prewarm policies", p.checkPrewarmPolicies},
		{"runtime secrets", p.checkRuntimeSecrets},
		{"Emisar MCP", p.checkEmisarMCP},
		{"GitHub publisher", p.checkGitHubPublisher},
		{"state directory", p.checkStateDirectory},
	}
}

// run executes checks in order and stops at the first failure, because later
// checks depend on earlier ones having succeeded — nothing can reach Emisar
// before the secrets that authenticate to it have loaded.
func (p *preflight) run(ctx context.Context, checks ...preflightCheck) error {
	for _, check := range append(p.checks(), checks...) {
		if err := check.run(ctx); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
	}
	return nil
}

// checkPrewarmPolicies rejects a prewarm configuration naming a policy that
// does not exist, which would otherwise fail only when a channel first spoke.
func (p *preflight) checkPrewarmPolicies(context.Context) error {
	return validateConversationPrewarmPolicies(p.cfg)
}

// checkRuntimeSecrets loads every credential the process needs. It fails closed:
// a missing or too-short secret stops startup rather than surfacing later as an
// authentication error nobody can attribute to a configuration mistake.
func (p *preflight) checkRuntimeSecrets(context.Context) error {
	secrets, botToken, appToken, err := runtimeSecrets(p.cfg)
	if err != nil {
		return err
	}
	projected, err := additionalEnvironmentValues(p.cfg)
	if err != nil {
		return err
	}
	emisarToken, err := p.cfg.Secret(p.cfg.Coop.EmisarTokenEnv)
	if err != nil {
		return err
	}
	p.secrets, p.projectedEnvironment = secrets, projected
	p.botToken, p.appToken, p.emisarToken = botToken, appToken, emisarToken

	p.redactions = []string{botToken, appToken, emisarToken}
	if p.cfg.GitHub.TokenEnv != "" {
		if token := os.Getenv(p.cfg.GitHub.TokenEnv); token != "" {
			p.redactions = append(p.redactions, token)
		}
	}
	for _, secret := range secrets {
		p.redactions = append(p.redactions, secret)
	}
	for _, secret := range projected {
		p.redactions = append(p.redactions, secret)
	}
	return nil
}

// checkEmisarMCP proves the configured Emisar identity authenticates and
// exposes the tool catalog investigations depend on.
func (p *preflight) checkEmisarMCP(ctx context.Context) error {
	checkCtx, cancel := context.WithTimeout(ctx, p.cfg.Coop.RequestTimeout.Duration)
	defer cancel()
	report, err := preflightEmisarMCP(checkCtx, p.httpClient, p.cfg.Coop.EmisarURL, p.emisarToken)
	if err != nil {
		return err
	}
	p.emisarReport = report
	return nil
}

// checkGitHubPublisher proves the push credential works before any work is
// accepted that would need it. Accepting work Responder cannot finish is worse
// than refusing it up front.
func (p *preflight) checkGitHubPublisher(ctx context.Context) error {
	return p.publisher().Ready(ctx)
}

// checkStateDirectory ensures the durable state directory exists and is private
// to this user: it holds credential-adjacent operational history.
func (p *preflight) checkStateDirectory(context.Context) error {
	return ensurePrivateDirectory(p.cfg.StateDir)
}

// coopBootstrapCheck verifies the owner-private files projected into the agent
// box match what this configuration expects. Serve requires this only when it
// supervises Coop; doctor and eval verify it either way, since a mismatch an
// external supervisor is serving is exactly the kind of thing an operator runs
// doctor to find out about.
func (p *preflight) coopBootstrapCheck() preflightCheck {
	return preflightCheck{"Coop bootstrap files", func(context.Context) error {
		expected, err := bootstrapFiles(p.cfg, p.emisarToken)
		if err != nil {
			return err
		}
		return checkPrivateCoopConfig(p.cfg.Coop.BootstrapDir, expected)
	}}
}

// managedCoopImageCheck proves a real turn can start a box. Doctor runs it;
// serve deliberately does not, because serve repairs a missing image on demand
// rather than refusing to start over something it can fix itself.
func (p *preflight) managedCoopImageCheck() preflightCheck {
	return preflightCheck{"managed Coop image", func(context.Context) error {
		return checkManagedCoopImage(p.cfg)
	}}
}

// publisher returns the GitHub publisher with every known secret registered
// for redaction, so a push failure quoting a URL cannot leak a token into Slack.
func (p *preflight) publisher() *publisher.GitHub {
	return publisher.New(p.cfg.GitHub, p.redactions...)
}

// emisarHTTP is the client used to reach Emisar, shared with the service so
// preflight proves the same transport the running process will use.
func (p *preflight) emisarHTTP() *http.Client { return p.httpClient }
