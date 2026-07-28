package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
)

func runBootstrap(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("bootstrap-coop", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("bootstrap-coop accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	token, err := cfg.Secret(cfg.Coop.EmisarTokenEnv)
	if err != nil {
		return err
	}
	live, err := coopSocketLive(cfg.Coop.Socket)
	if err != nil {
		return err
	}
	if live {
		return errors.New("stop Coop before running bootstrap-coop")
	}
	if err := ensurePrivateDirectory(cfg.Coop.BootstrapDir); err != nil {
		return err
	}
	files, err := bootstrapFiles(cfg, token)
	if err != nil {
		return err
	}
	for name, data := range files {
		if err := atomicPrivateWrite(filepath.Join(cfg.Coop.BootstrapDir, name), data); err != nil {
			return err
		}
	}
	fmt.Fprintf(stdout, "Wrote private Coop session configuration to %s\n", cfg.Coop.BootstrapDir)
	fmt.Fprintf(stdout, "Start Coop with COOP_CONFIG_DIR=%s\n", cfg.Coop.BootstrapDir)
	return nil
}

func coopSocketLive(path string) (bool, error) {
	connection, err := net.DialTimeout("unix", path, 500*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		return true, nil
	}
	if _, statErr := os.Lstat(path); os.IsNotExist(statErr) {
		return false, nil
	} else if statErr != nil {
		return false, fmt.Errorf("inspect Coop socket: %w", statErr)
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return false, nil
	}
	return false, fmt.Errorf("check Coop socket: %w", err)
}

func bootstrapFiles(cfg config.Config, token string) (map[string][]byte, error) {
	if strings.ContainsAny(token, "\r\n\x00") {
		return nil, fmt.Errorf("%s cannot contain a newline or NUL", cfg.Coop.EmisarTokenEnv)
	}
	mcpData, err := bootstrapMCPConfig(cfg)
	if err != nil {
		return nil, err
	}
	environment, err := bootstrapEnvironment(cfg, token)
	if err != nil {
		return nil, err
	}
	return map[string][]byte{
		"mcp.json":        append(mcpData, '\n'),
		"env":             environment,
		"INSTRUCTIONS.md": []byte(service.CoopInstructions(cfg.Coop.Instructions) + "\n"),
	}, nil
}

type mcpDocument struct {
	Servers map[string]json.RawMessage `json:"mcpServers"`
}

var mcpServerNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
var projectedEnvNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func bootstrapMCPConfig(cfg config.Config) ([]byte, error) {
	document := mcpDocument{Servers: make(map[string]json.RawMessage)}
	if cfg.Coop.AdditionalMCP != "" {
		data, err := readPrivateBootstrapSource(cfg.Coop.AdditionalMCP, "additional MCP")
		if err != nil {
			return nil, err
		}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&document); err != nil {
			return nil, fmt.Errorf("decode additional MCP file: %w", err)
		}
		if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
			if err == nil {
				return nil, errors.New("decode additional MCP file: multiple JSON values")
			}
			return nil, fmt.Errorf("decode additional MCP file: %w", err)
		}
		if document.Servers == nil {
			document.Servers = make(map[string]json.RawMessage)
		}
	}
	if _, exists := document.Servers["emisar"]; exists {
		return nil, errors.New(`additional MCP file must not define reserved server "emisar"`)
	}
	for name, raw := range document.Servers {
		if !mcpServerNamePattern.MatchString(name) {
			return nil, fmt.Errorf("additional MCP server name %q is invalid", name)
		}
		var definition map[string]json.RawMessage
		if err := json.Unmarshal(raw, &definition); err != nil || definition == nil {
			return nil, fmt.Errorf("additional MCP server %q must be a JSON object", name)
		}
	}
	emisar, err := json.Marshal(struct {
		Type              string `json:"type"`
		URL               string `json:"url"`
		BearerTokenEnvVar string `json:"bearer_token_env_var"`
	}{
		Type: "http", URL: cfg.Coop.EmisarURL,
		BearerTokenEnvVar: cfg.Coop.EmisarTokenEnv,
	})
	if err != nil {
		return nil, err
	}
	document.Servers["emisar"] = emisar
	return json.MarshalIndent(document, "", "  ")
}

func bootstrapEnvironment(cfg config.Config, token string) ([]byte, error) {
	values, err := additionalEnvironmentValues(cfg)
	if err != nil {
		return nil, err
	}
	values[cfg.Coop.EmisarTokenEnv] = token
	values["EMISAR_CLIENT"] = "responder"
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	var environment strings.Builder
	for _, name := range names {
		fmt.Fprintf(&environment, "%s=%s\n", name, values[name])
	}
	return []byte(environment.String()), nil
}

func additionalEnvironmentValues(cfg config.Config) (map[string]string, error) {
	values := make(map[string]string)
	if cfg.Coop.AdditionalEnv != "" {
		data, err := readPrivateBootstrapSource(cfg.Coop.AdditionalEnv, "additional environment")
		if err != nil {
			return nil, err
		}
		if bytes.IndexByte(data, 0) >= 0 || bytes.IndexByte(data, '\r') >= 0 {
			return nil, errors.New("additional environment file cannot contain CR or NUL")
		}
		blocked := reservedServiceEnvironment(cfg)
		for lineNumber, line := range strings.Split(string(data), "\n") {
			trimmed := strings.TrimSpace(line)
			if trimmed == "" || strings.HasPrefix(trimmed, "#") {
				continue
			}
			name, value, ok := strings.Cut(line, "=")
			name = strings.TrimSpace(name)
			if !ok || !projectedEnvNamePattern.MatchString(name) {
				return nil, fmt.Errorf(
					"additional environment line %d must be NAME=value",
					lineNumber+1,
				)
			}
			if blocked[name] {
				return nil, fmt.Errorf(
					"additional environment variable %s is reserved or service-only",
					name,
				)
			}
			if _, exists := values[name]; exists {
				return nil, fmt.Errorf("additional environment variable %s is duplicated", name)
			}
			if len(value) < 8 {
				return nil, fmt.Errorf(
					"additional environment variable %s must contain at least 8 bytes",
					name,
				)
			}
			values[name] = value
		}
	}
	return values, nil
}

func reservedServiceEnvironment(cfg config.Config) map[string]bool {
	blocked := make(map[string]bool)
	for _, name := range []string{
		cfg.Slack.BotTokenEnv,
		cfg.Slack.AppTokenEnv,
		cfg.Coop.EmisarTokenEnv,
		cfg.GitHub.TokenEnv,
		"EMISAR_CLIENT",
	} {
		if name != "" {
			blocked[name] = true
		}
	}
	for _, route := range cfg.Webhooks {
		if route.SecretEnv != "" {
			blocked[route.SecretEnv] = true
		}
	}
	return blocked
}

func readPrivateBootstrapSource(path, label string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect %s file: %w", label, err)
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("%s file must be a regular file", label)
	}
	owner, mode, err := store.FileOwner(path)
	if err != nil {
		return nil, fmt.Errorf("inspect %s file ownership: %w", label, err)
	}
	if owner != uint32(os.Getuid()) || mode&0o077 != 0 || mode&0o400 == 0 {
		return nil, fmt.Errorf(
			"%s file must be owned by uid %d, owner-readable, and inaccessible to group or other",
			label, os.Getuid(),
		)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s file: %w", label, err)
	}
	return data, nil
}

func ensurePrivateDirectory(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("private directory must be an absolute clean path")
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("private path must be a real directory")
		}
	} else if !os.IsNotExist(err) {
		return err
	} else if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	return os.Chmod(path, 0o700)
}

func checkPrivateCoopConfig(path string, expected map[string][]byte) error {
	owner, mode, err := store.FileOwner(path)
	if err != nil {
		return fmt.Errorf("inspect Coop bootstrap directory: %w", err)
	}
	if owner != uint32(os.Getuid()) || mode != 0o700 {
		return fmt.Errorf("Coop bootstrap directory must be owned by uid %d with mode 0700", os.Getuid())
	}
	for _, name := range []string{"env", "mcp.json", "INSTRUCTIONS.md"} {
		filePath := filepath.Join(path, name)
		info, err := os.Lstat(filePath)
		if err != nil {
			return fmt.Errorf("inspect Coop %s: %w", name, err)
		}
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("Coop %s must be a regular file", name)
		}
		owner, mode, err := store.FileOwner(filePath)
		if err != nil {
			return err
		}
		if owner != uint32(os.Getuid()) || mode != 0o600 {
			return fmt.Errorf("Coop %s must be owned by uid %d with mode 0600", name, os.Getuid())
		}
		if expected != nil {
			actual, err := os.ReadFile(filePath)
			if err != nil {
				return fmt.Errorf("read Coop %s: %w", name, err)
			}
			if !bytes.Equal(actual, expected[name]) {
				return fmt.Errorf("Coop %s is stale; rerun responder bootstrap-coop", name)
			}
		}
	}
	return nil
}

func atomicPrivateWrite(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temp, path); err != nil {
		return err
	}
	return nil
}
