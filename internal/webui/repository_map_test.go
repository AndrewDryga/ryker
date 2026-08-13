package webui

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// The repository map is the one page an operator can act on by noticing an
// absence, so a repository nothing has described has to appear as a row rather
// than be left out of the list. The whole reason the map moved out of a
// hand-written document is that a missing entry looked exactly like a
// repository that did not exist.
func TestMemoryPageShowsDescribedAndUndescribedRepositories(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := live.Memory.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "repository", ScopeKey: "described-repo",
		SubjectKey: core.RepositoryContentsSubject, Predicate: "guidance",
		Value:          "Rust realtime gateway for live data sharing.",
		VisibilityKind: "workspace", VisibilityID: "T123ABC",
		ExpiresAt: core.PermanentExpiry,
		SourceRef: "run:run_1", ActorID: "responder",
	}, 1000, 100); err != nil {
		t.Fatal(err)
	}
	// A companion an agent described without any repositories: entry for it.
	if _, _, err := live.Memory.UpsertMemoryEntry(ctx, core.MemoryEntry{
		ScopeKind: "repository", ScopeKey: "unconfigured-companion",
		SubjectKey: core.RepositoryContentsSubject, Predicate: "guidance",
		Value:          "Session and turn supervisor for agent runs.",
		VisibilityKind: "workspace", VisibilityID: "T123ABC",
		ExpiresAt: core.PermanentExpiry,
		SourceRef: "run:run_2", ActorID: "responder",
	}, 1000, 100); err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(dir + "/responder.db")
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	repositories := map[string]config.Repository{
		"described-repo":   {DisplayName: "Described", Description: "Configuration guessed this."},
		"configured-only":  {DisplayName: "Configured", Description: "Astro marketing site."},
		"undescribed-repo": {DisplayName: "Undescribed"},
	}
	handler, err := NewHandler(
		reader, "test", "47", "responder-abc", nil, config.Pricing{}, repositories, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/memory", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET /memory = %d: %s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	for _, required := range []string{
		"Repository map",
		// What an agent wrote wins over what configuration guessed.
		"Rust realtime gateway for live data sharing.",
		// A companion no repositories: entry configures is still in the map.
		"unconfigured-companion",
		"Session and turn supervisor for agent runs.",
		// Configuration fills the gap until an agent reads the repository.
		"Astro marketing site.",
		// And a repository with neither says so instead of vanishing.
		"undescribed-repo",
		"Not described yet",
		"1 still undescribed",
	} {
		if !strings.Contains(body, required) {
			t.Errorf("memory page lacks %q", required)
		}
	}
	if strings.Contains(body, "Configuration guessed this.") {
		t.Error("the configured sentence outranked what an agent actually read")
	}
	// The descriptions must not also appear in the operational-memory table,
	// where the page's own advice — prune what nothing recalls — is wrong for
	// them.
	if strings.Contains(body, core.RepositoryContentsSubject) {
		t.Error("repository descriptions leaked into the operational memory table")
	}
	// An undescribed repository sorts above described ones: it is the only row
	// here anyone can act on.
	mapSection := body[strings.Index(body, "Repository map"):]
	if strings.Index(mapSection, "undescribed-repo") > strings.Index(mapSection, "described-repo") {
		t.Error("undescribed repositories are not listed first")
	}
}
