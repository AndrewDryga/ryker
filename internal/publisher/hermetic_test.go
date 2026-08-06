package publisher

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The publication checkout holds the only GitHub push credential Responder
// has. Nothing else from the service environment may reach a git subprocess.
func TestGitEnvWithholdsTheServiceEnvironment(t *testing.T) {
	t.Setenv("SLACK_BOT_TOKEN", "xoxb-not-for-git")
	t.Setenv("RESPONDER_WEBHOOK_SECRET", "hook-secret-not-for-git")
	t.Setenv("PATH", os.Getenv("PATH"))

	env := gitEnv("/tmp/work")
	joined := strings.Join(env, "\n")
	for _, secret := range []string{"xoxb-not-for-git", "hook-secret-not-for-git"} {
		if strings.Contains(joined, secret) {
			t.Fatalf("git environment leaked %q:\n%s", secret, joined)
		}
	}
	for _, name := range []string{"SLACK_BOT_TOKEN=", "RESPONDER_WEBHOOK_SECRET="} {
		if strings.Contains(joined, name) {
			t.Fatalf("git environment carried %s:\n%s", name, joined)
		}
	}
	for _, required := range []string{
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_TERMINAL_PROMPT=0",
		"HOME=/tmp/work",
	} {
		if !strings.Contains(joined, required) {
			t.Fatalf("git environment missing %s:\n%s", required, joined)
		}
	}
	if !strings.Contains(joined, "PATH=") {
		t.Fatal("git environment has no PATH")
	}
}

// An operator's global gitconfig must not reach the isolated checkout: a
// core.hooksPath or init.templateDir there would otherwise run code inside it.
func TestRunGitIgnoresOperatorGlobalConfig(t *testing.T) {
	home := t.TempDir()
	hooks := filepath.Join(home, "poisoned-hooks")
	if err := os.WriteFile(
		filepath.Join(home, ".gitconfig"),
		[]byte("[user]\n\tname = POISONED\n[core]\n\thooksPath = "+hooks+"\n"),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	work := t.TempDir()
	ctx := context.Background()
	if _, err := runGit(ctx, work, nil, nil, "init", "--quiet"); err != nil {
		t.Fatal(err)
	}
	// `git config --get` exits non-zero when the key is absent, which is the
	// result we want: the operator's global config was not read.
	if output, err := runGit(ctx, work, nil, nil, "config", "--get", "user.name"); err == nil {
		t.Fatalf("global gitconfig leaked into the checkout: user.name = %q", strings.TrimSpace(output))
	}
	if output, err := runGit(ctx, work, nil, nil, "config", "--get", "core.hooksPath"); err == nil {
		t.Fatalf("global hooksPath leaked into the checkout: %q", strings.TrimSpace(output))
	}
}

// Command output is bounded while git runs, not inspected afterwards.
func TestRunGitBoundsOutputWhileTheProcessRuns(t *testing.T) {
	buffer := &boundedBuffer{limit: 64}
	for range 100 {
		n, err := buffer.Write([]byte(strings.Repeat("x", 32)))
		if err != nil || n != 32 {
			t.Fatalf("write = %d, %v", n, err)
		}
	}
	if !buffer.overflow {
		t.Fatal("overflow was not recorded")
	}
	if got := len(buffer.String()); got != 64 {
		t.Fatalf("buffered %d bytes, want the 64-byte limit", got)
	}
}
