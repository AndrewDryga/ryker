package repositorycapability

import (
	"encoding/json"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
)

type AccessMode string

const (
	Configured     AccessMode = "configured"
	PinnedReadOnly AccessMode = "pinned_read_only"
	IsolatedWrite  AccessMode = "isolated_write"
)

type Repository struct {
	Key          string     `json:"key"`
	DisplayName  string     `json:"display_name"`
	Role         string     `json:"role"`
	AccessMode   AccessMode `json:"access_mode"`
	PinnedCommit string     `json:"pinned_commit,omitempty"`
	CanPublish   bool       `json:"can_publish"`
}

type Manifest struct {
	CurrentContext    string       `json:"current_context"`
	PrimaryRepository string       `json:"primary_repository,omitempty"`
	Repositories      []Repository `json:"repositories"`
}

func Build(
	cfg config.Config,
	active string,
	bound coop.Session,
	primaryAccess AccessMode,
) Manifest {
	primary := active
	if set, ok := cfg.RepositorySets[active]; ok {
		primary = set.Primary
	}
	companions := make(map[string]coop.CompanionRepository, len(bound.Companions))
	for _, companion := range bound.Companions {
		companions[companion.Name] = companion
	}
	keys := make([]string, 0, len(cfg.Repositories))
	for key := range cfg.Repositories {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	manifest := Manifest{CurrentContext: active, PrimaryRepository: primary}
	for _, key := range keys {
		configured := cfg.Repositories[key]
		displayName := strings.TrimSpace(configured.DisplayName)
		if displayName == "" {
			displayName = key
		}
		repository := Repository{
			Key: key, DisplayName: displayName, Role: "unbound",
			AccessMode: Configured,
		}
		switch {
		case key == primary && bound.BaseCommit != "":
			repository.Role = "primary"
			repository.AccessMode = primaryAccess
			repository.PinnedCommit = bound.BaseCommit
		case companions[key].BaseCommit != "":
			repository.Role = "companion"
			repository.AccessMode = PinnedReadOnly
			repository.PinnedCommit = companions[key].BaseCommit
		}
		manifest.Repositories = append(manifest.Repositories, repository)
	}
	return manifest
}

func Prompt(manifest Manifest) string {
	payload, _ := json.Marshal(manifest)
	return `Trusted repository capabilities for this turn:
- configured: registered by Responder, but not proof that this Coop session can read it.
- pinned_read_only: this Coop session has an immutable checkout and may read it; it may not edit or publish it.
- isolated_write: only an approved engineering task's primary checkout may be edited, tested, and committed; it may not be published.
- No access mode grants publication. Publication requires a separate host-verified workflow.

For repository-access questions, use this manifest instead of nearby conversation evidence. A pinned_read_only repository has verified read access. Treat configured repositories as unverified and use the tool-enabled investigation lane before claiming access. A repository absent from the manifest is not configured; do not claim that an absent repository was tested or denied.
<trusted-responder-repository-capabilities>
` + string(payload) + `
</trusted-responder-repository-capabilities>`
}

func AccessQuestion(message string) bool {
	normalized := strings.ToLower(message)
	if strings.Contains(normalized, "do you have access") ||
		strings.Contains(normalized, "can you access") ||
		strings.Contains(normalized, "check if you have access") {
		return true
	}
	repositoryNamed := strings.Contains(normalized, "repo") ||
		strings.Contains(normalized, "repository")
	accessAsked := strings.Contains(normalized, "access") ||
		strings.Contains(normalized, "permission") ||
		strings.Contains(normalized, "can you read")
	return repositoryNamed && accessAsked
}
