// Package hermeticgit runs git subprocesses that can see nothing they were not
// handed.
//
// It was extracted from internal/publisher, which held the only GitHub push
// credential Responder has and therefore grew the discipline first: the service
// environment is withheld, global and system gitconfig are pinned at /dev/null
// so an operator's core.hooksPath cannot inject code, output is bounded while
// the process runs rather than inspected afterwards, and a token reaches git as
// a per-invocation HTTP header instead of anything written to disk.
//
// It lives in its own package because there is now a second caller.
// internal/repomirror fetches Responder-managed clones with the same credential,
// and a second copy of an env scrub is a second place for one of these rules to
// quietly stop applying — which is the whole failure mode the scrub exists to
// prevent.
package hermeticgit

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// MaxOutput bounds what one git invocation may return.
const MaxOutput = 1 << 20

// passthroughEnv names the only ambient variables a hermetic git invocation
// inherits. Everything else is withheld so a git subprocess cannot see Slack,
// Coop, Emisar, GitHub, or webhook secrets from the service environment.
var passthroughEnv = []string{
	"PATH",
	"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
	"http_proxy", "https_proxy", "no_proxy",
	"SSL_CERT_FILE", "SSL_CERT_DIR",
	"GIT_SSL_CAINFO", "GIT_SSL_CAPATH",
}

// Env builds a hermetic environment for git. Global and system gitconfig are
// pinned to /dev/null so an operator's `core.hooksPath` or `init.templateDir`
// cannot inject code into the checkout, and HOME points at a directory
// Responder owns so nothing resolves a real dotfile.
func Env(home string, extra ...string) []string {
	env := make([]string, 0, len(passthroughEnv)+len(extra)+6)
	for _, name := range passthroughEnv {
		if value, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+value)
		}
	}
	env = append(env,
		"HOME="+home,
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0",
		"LC_ALL=C",
	)
	return append(env, extra...)
}

// AuthEnv carries a GitHub token to one git invocation as an HTTP header.
//
// Through the environment rather than the URL or a credential helper: an
// argument is visible in the process table and a helper is a file on disk,
// and this token is the one credential the agent box must never be able to
// reach.
func AuthEnv(token string) []string {
	value := base64.StdEncoding.EncodeToString([]byte("x-access-token:" + token))
	return []string{
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http.https://github.com/.extraheader",
		"GIT_CONFIG_VALUE_0=AUTHORIZATION: basic " + value,
		"GIT_TERMINAL_PROMPT=0",
	}
}

// boundedBuffer stops accumulating past limit so a runaway subprocess cannot
// grow the buffer without bound. Checking the size after the process exits
// would already have paid the memory cost.
type boundedBuffer struct {
	buf      bytes.Buffer
	limit    int
	overflow bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if remaining := b.limit - b.buf.Len(); remaining > 0 {
		if len(p) > remaining {
			b.buf.Write(p[:remaining])
			b.overflow = true
		} else {
			b.buf.Write(p)
		}
	} else if len(p) > 0 {
		b.overflow = true
	}
	// Report a full write so git is never signalled a broken pipe.
	return len(p), nil
}

func (b *boundedBuffer) String() string { return b.buf.String() }

// Run executes `git -C dir args...` hermetically and returns its combined
// output.
//
// home is the HOME the subprocess sees. Pass "" to use dir, which is what a
// throwaway checkout wants; a managed clone passes the directory above it so
// nothing git might write lands inside a work tree Responder promises never to
// dirty.
func Run(
	ctx context.Context,
	dir string,
	home string,
	extraEnv []string,
	input []byte,
	args ...string,
) (string, error) {
	if len(args) == 0 {
		return "", errors.New("hermetic git invocation has no arguments")
	}
	if home == "" {
		home = dir
	}
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	command.Env = Env(home, extraEnv...)
	if input != nil {
		command.Stdin = bytes.NewReader(input)
	}
	output := &boundedBuffer{limit: MaxOutput}
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	if output.overflow {
		return "", errors.New("git output exceeded 1 MiB")
	}
	if err != nil {
		return "", fmt.Errorf("git %s: %s", args[0], strings.TrimSpace(output.String()))
	}
	return output.String(), nil
}
