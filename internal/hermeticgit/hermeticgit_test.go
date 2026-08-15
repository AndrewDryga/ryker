package hermeticgit

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These three moved here with the runner they cover. They were written for the
// publication checkout, which holds the only GitHub push credential Responder
// has; internal/repomirror now fetches with the same credential through the
// same runner, so the rules have two callers and one place that proves them.

// Nothing from the service environment may reach a git subprocess.
func TestGitEnvWithholdsTheServiceEnvironment(t *testing.T) {
	t.Setenv("SLACK_BOT_TOKEN", "xoxb-not-for-git")
	t.Setenv("RESPONDER_WEBHOOK_SECRET", "hook-secret-not-for-git")
	t.Setenv("PATH", os.Getenv("PATH"))

	env := Env("/tmp/work")
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

// An operator's global gitconfig must not reach the checkout: a core.hooksPath
// or init.templateDir there would otherwise run code inside it.
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
	if _, err := Run(ctx, work, "", nil, nil, "init", "--quiet"); err != nil {
		t.Fatal(err)
	}
	// `git config --get` exits non-zero when the key is absent, which is the
	// result we want: the operator's global config was not read.
	if output, err := Run(ctx, work, "", nil, nil, "config", "--get", "user.name"); err == nil {
		t.Fatalf("global gitconfig leaked into the checkout: user.name = %q", strings.TrimSpace(output))
	}
	if output, err := Run(ctx, work, "", nil, nil, "config", "--get", "core.hooksPath"); err == nil {
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

// A managed clone hands git a HOME outside the work tree, because Responder
// promises never to dirty a repository Coop is about to fork from. Passing the
// work tree as HOME — the throwaway-checkout default — would let anything git
// writes to a dotfile land in `git status`.
func TestRunGitAcceptsAHomeOutsideTheWorkTree(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(root, "clone")
	if err := os.Mkdir(work, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := Run(ctx, work, root, nil, nil, "init", "--quiet"); err != nil {
		t.Fatal(err)
	}
	env := Env(root)
	if !strings.Contains(strings.Join(env, "\n"), "HOME="+root) {
		t.Fatalf("HOME was not the directory above the work tree:\n%s", strings.Join(env, "\n"))
	}
}

// A token reaches git as a per-invocation header, never as an argument or a
// file. Anything else would put the one credential the agent box must not have
// into the process table or onto disk.
func TestAuthEnvCarriesTheTokenWithoutTouchingDisk(t *testing.T) {
	env := AuthEnv("ghp_example_token_value")
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "ghp_example_token_value") {
		t.Fatalf("token appears verbatim in the environment:\n%s", joined)
	}
	if !strings.Contains(joined, "AUTHORIZATION: basic ") {
		t.Fatalf("token was not injected as an HTTP header:\n%s", joined)
	}
	if !strings.Contains(joined, "GIT_TERMINAL_PROMPT=0") {
		t.Fatalf("an authenticated invocation may still prompt:\n%s", joined)
	}
	for _, name := range []string{"credential.helper", "GIT_ASKPASS", "GIT_CONFIG_KEY_1"} {
		if strings.Contains(joined, name) {
			t.Fatalf("authenticated environment carried %s:\n%s", name, joined)
		}
	}
}
