package repositorycapability

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
)

func TestBuildDistinguishesPinnedReadOnlyAndConfiguredRepositories(t *testing.T) {
	cfg := config.Config{
		Repositories: map[string]config.Repository{
			"tenant-core":    {DisplayName: "Tenant Core"},
			"tenant-flutter": {DisplayName: "Tenant Flutter"},
			"tenant-infra":   {DisplayName: "Tenant Infrastructure"},
		},
		RepositorySets: map[string]config.RepositorySet{
			"tenant-platform": {Primary: "tenant-infra"},
		},
	}
	manifest := Build(cfg, "tenant-platform", coop.Session{
		BaseCommit: "infra-commit",
		Companions: []coop.CompanionRepository{{
			Name: "tenant-core", BaseCommit: "core-commit",
		}},
	}, PinnedReadOnly)
	if manifest.PrimaryRepository != "tenant-infra" || len(manifest.Repositories) != 3 {
		t.Fatalf("manifest = %+v", manifest)
	}
	want := map[string]Repository{
		"tenant-core": {
			Key: "tenant-core", DisplayName: "Tenant Core", Role: "companion",
			AccessMode: PinnedReadOnly, PinnedCommit: "core-commit",
		},
		"tenant-flutter": {
			Key: "tenant-flutter", DisplayName: "Tenant Flutter", Role: "unbound",
			AccessMode: Configured,
		},
		"tenant-infra": {
			Key: "tenant-infra", DisplayName: "Tenant Infrastructure", Role: "primary",
			AccessMode: PinnedReadOnly, PinnedCommit: "infra-commit",
		},
	}
	for _, repository := range manifest.Repositories {
		if repository != want[repository.Key] {
			t.Errorf("repository %q = %+v, want %+v", repository.Key, repository, want[repository.Key])
		}
		if repository.CanPublish {
			t.Errorf("repository %q unexpectedly grants publication", repository.Key)
		}
	}
}

func TestPromptMakesAccessAndDenialSemanticsExplicit(t *testing.T) {
	prompt := Prompt(Manifest{Repositories: []Repository{{
		Key: "tenant-core", Role: "companion", AccessMode: PinnedReadOnly,
		PinnedCommit: "core-commit",
	}}})
	for _, required := range []string{
		"<trusted-responder-repository-capabilities>",
		`"key":"tenant-core"`,
		`"access_mode":"pinned_read_only"`,
		"has verified read access",
		"configured repositories as unverified",
		"absent from the manifest is not configured",
		"No access mode grants publication",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("prompt lacks %q:\n%s", required, prompt)
		}
	}
}

func TestBuildKeepsCompanionsReadOnlyWhenPrimaryIsWritable(t *testing.T) {
	cfg := config.Config{Repositories: map[string]config.Repository{
		"primary": {}, "companion": {},
	}}
	manifest := Build(cfg, "primary", coop.Session{
		BaseCommit: "primary-commit",
		Companions: []coop.CompanionRepository{{
			Name: "companion", BaseCommit: "companion-commit",
		}},
	}, IsolatedWrite)
	if manifest.Repositories[1].AccessMode != IsolatedWrite {
		t.Fatalf("primary access = %q", manifest.Repositories[1].AccessMode)
	}
	if manifest.Repositories[0].AccessMode != PinnedReadOnly {
		t.Fatalf("companion access = %q", manifest.Repositories[0].AccessMode)
	}
	for _, repository := range manifest.Repositories {
		if repository.CanPublish {
			t.Fatalf("repository %q unexpectedly grants publication", repository.Key)
		}
	}
}

func TestAccessQuestionRecognizesRepositoryCapabilityRequests(t *testing.T) {
	for _, message := range []string{
		"do you have access to the tenant-core repo?",
		"Do you have access to tenant-core?",
		"Can you access tenant-overlay?",
		"Can you read that repository?",
		"Check repository permissions now.",
	} {
		if !AccessQuestion(message) {
			t.Errorf("AccessQuestion(%q) = false", message)
		}
	}
	for _, message := range []string{
		"Who owns tenant-core?",
		"Can you read the incident?",
		"Explain repository sets.",
	} {
		if AccessQuestion(message) {
			t.Errorf("AccessQuestion(%q) = true", message)
		}
	}
}
