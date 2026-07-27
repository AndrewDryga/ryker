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
	"strings"
	"syscall"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
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
	mcp := struct {
		Servers map[string]struct {
			Type              string `json:"type"`
			URL               string `json:"url"`
			BearerTokenEnvVar string `json:"bearer_token_env_var"`
		} `json:"mcpServers"`
	}{
		Servers: map[string]struct {
			Type              string `json:"type"`
			URL               string `json:"url"`
			BearerTokenEnvVar string `json:"bearer_token_env_var"`
		}{
			"emisar": {
				Type: "http", URL: cfg.Coop.EmisarURL,
				BearerTokenEnvVar: cfg.Coop.EmisarTokenEnv,
			},
		},
	}
	mcpData, err := json.MarshalIndent(mcp, "", "  ")
	if err != nil {
		return nil, err
	}
	environment := fmt.Sprintf(
		"%s=%s\nEMISAR_CLIENT=responder\n",
		cfg.Coop.EmisarTokenEnv,
		token,
	)
	return map[string][]byte{
		"mcp.json":        append(mcpData, '\n'),
		"env":             []byte(environment),
		"INSTRUCTIONS.md": []byte(strings.TrimSpace(cfg.Coop.Instructions) + "\n"),
	}, nil
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
