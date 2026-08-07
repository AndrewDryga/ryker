package publisher

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

func fakeGitHub(t *testing.T, handler http.HandlerFunc) (*GitHub, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	t.Setenv("TEST_GITHUB_TOKEN", "ghp_testtokenvaluelongenough")
	return New(config.GitHubConfig{
		Enabled:      true,
		APIURL:       server.URL,
		TokenEnv:     "TEST_GITHUB_TOKEN",
		BranchPrefix: "responder",
		CommitName:   "Responder",
		CommitEmail:  "responder@example.test",
	}), server
}

// Ready is the startup check that decides whether Responder will accept
// publication work at all. Accepting work it cannot finish is worse than
// refusing it, so a bad credential has to fail at startup, not at push time.
func TestReadyRejectsABadCredential(t *testing.T) {
	var authorization string
	github, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		if r.URL.Path != "/user" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"login":"responder-bot"}`)
	})
	if err := github.Ready(context.Background()); err != nil {
		t.Fatalf("a working credential was rejected: %v", err)
	}
	if !strings.Contains(authorization, "ghp_testtokenvaluelongenough") {
		t.Fatalf("the token did not reach GitHub: %q", authorization)
	}

	unauthorized, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"message":"Bad credentials"}`)
	})
	if err := unauthorized.Ready(context.Background()); err == nil {
		t.Fatal("a rejected credential passed the startup check")
	}

	// An identity with no login means the response is not what we think it is.
	anonymous, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{}`)
	})
	if err := anonymous.Ready(context.Background()); err == nil {
		t.Fatal("an identity with no login was accepted")
	}
}

// A publication branch is Responder-owned. Adopting one it did not create, or
// one that moved underneath it, would overwrite work nobody asked it to touch.
func TestVerifyPublicationRefusesAMovedBranch(t *testing.T) {
	publication := core.Publication{
		IncidentID: "inc_1", HeadBranch: "responder/inc-1",
		RemoteSHA: strings.Repeat("a", 40), PRNumber: 7,
	}
	github, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "/pulls/"):
			fmt.Fprintf(w, `{"number":7,"state":"open","draft":true,
			  "head":{"ref":"responder/inc-1","sha":%q}}`, strings.Repeat("b", 40))
		default:
			fmt.Fprint(w, `{}`)
		}
	})
	if err := github.VerifyPublication(context.Background(), publication); err == nil {
		t.Fatal("a branch that moved outside Responder was accepted as current")
	}
}

// ResolveTree is the only supported way to ask git a question outside the
// publication flow, so it must refuse anything that is not a full object ID
// before that value reaches a command line.
func TestResolveTreeValidatesItsInput(t *testing.T) {
	github := New(config.GitHubConfig{Enabled: true})
	ctx := context.Background()
	for _, invalid := range []string{
		"", "HEAD", "--help", "main", "abc", strings.Repeat("z", 40),
	} {
		if _, err := github.ResolveTree(ctx, "/tmp", invalid); err == nil {
			t.Errorf("ResolveTree accepted %q as an object ID", invalid)
		}
	}
	if _, err := github.ResolveTree(ctx, "", strings.Repeat("a", 40)); err == nil {
		t.Error("ResolveTree accepted an empty repository path")
	}
}
