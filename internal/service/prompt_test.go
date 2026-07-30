package service

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

func TestCoopInstructionsRequireClaimBasedCrossSourceEvidence(t *testing.T) {
	instructions := CoopInstructions("Keep the response concise.")
	for _, required := range []string{
		"Choose evidence sources by the claim being answered",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Inspect and use other available MCP servers and tools",
		"Never equate or count runner records, hosts, VMs, nodes, allocations, containers, or services",
		"When sources disagree, do not silently pick one",
		"does not prove runner, fleet, workload, or infrastructure health",
		"only after an Emisar MCP tool call fails in the current turn",
		"Emisar is the only authority for operational actions",
		"directly and explicitly asks for that exact operational change",
		"If Emisar returns pending_approval, stop the turn",
		"Do not keep polling while a human decision is pending",
		"continue the same run through its returned wait_for_run continuation",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"fenced code blocks with a language",
		"task lists, dividers, tables",
		"Responder owns interactive controls",
	} {
		if !strings.Contains(instructions, required) {
			t.Fatalf("Coop instructions do not contain %q:\n%s", required, instructions)
		}
	}
	if strings.Contains(instructions, "call the Emisar MCP tools before using shell commands") {
		t.Fatalf("Coop instructions still impose the old fixed tool order:\n%s", instructions)
	}
}

func TestWatchPromptCarriesMandatoryCrossSourceEvidencePolicy(t *testing.T) {
	prompt := watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC",
			MessageTS: "1700.001",
			UserID:    "U123ABC",
			Text:      "How is the health of our infrastructure?",
		},
		"U999BOT",
		nil,
	)
	for _, required := range []string{
		"Consider the full set of repository, MCP, and other tools available in the turn",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Use the MCP tools directly, not curl against the MCP endpoint",
		"treat its results only as runner identities and connection state",
		"Do not ignore a relevant configured tool merely because Emisar is available",
		"Reconcile declared topology with observed runtime entities",
		"Never say Emisar is unavailable merely because a local CLI",
		"This evidence policy is mandatory for current operational questions",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"task lists, dividers, tables",
		"outer JSON is only the transport envelope",
		"do not send them outside Slack",
		"task_title",
		"task_repository",
		"Configured repository bindings",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("watch prompt does not contain %q:\n%s", required, prompt)
		}
	}
	if strings.Contains(prompt, "call the Emisar MCP tools before using shell commands") {
		t.Fatalf("watch prompt still imposes the old fixed tool order:\n%s", prompt)
	}
}

func TestRepositorySetPromptExplainsPinnedReadOnlyCompanions(t *testing.T) {
	prompt := repositorySetPrompt(coop.Session{
		BaseCommit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Companions: []coop.CompanionRepository{{
			Name:       "control-plane",
			Path:       "/coop/repositories/control-plane",
			BaseCommit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		}},
	})
	for _, required := range []string{
		"Primary working copy",
		"only repository whose changes can be reviewed or published",
		"Read-only companion `control-plane`",
		"`/coop/repositories/control-plane`",
		"pinned at `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`",
		"Reconcile across repositories",
		"never try to edit them",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("repository-set prompt lacks %q:\n%s", required, prompt)
		}
	}
}

func TestEngineeringTaskPromptAllowsOnlyForkScopedRepositoryWork(t *testing.T) {
	task := core.Incident{
		ID: "inc_task", Route: "manual", SourceIncidentID: "task:EvTask",
		Repository: "emisar", Title: "Audit infrastructure packs",
		Status: core.IncidentActive,
	}
	prompt, err := initialPrompt("Use evidence.", task, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		`"kind":"engineering_task"`,
		"Complete this operator-approved engineering task",
		"make the smallest justified repository changes",
		"File edits, tests, and commits are allowed",
		"Do not merge, push, deploy, sign, or mutate infrastructure",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("engineering prompt lacks %q:\n%s", required, prompt)
		}
	}
}
