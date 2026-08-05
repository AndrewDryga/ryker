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
		"directly and explicitly asks for the exact operational change",
		"A dedicated incident or task is not required",
		"If Emisar returns pending_approval, stop the turn",
		"Do not keep polling while a human decision is pending",
		"Responder monitors an exact pending run outside the model turn",
		"never call run_action or create a replacement run",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"Default to natural, plain English",
		"Use common words, contractions",
		"Answer the user's actual question first",
		"one main idea per sentence",
		"Keep exact technical terms",
		"Strict controlled English is only for a user who explicitly asks for it",
		"Do not repeat repository or live-system checks",
		"Use humor like a trusted teammate",
		"never force a joke",
		"Stay straightforward during active incidents",
		"Most messages need none; use at most one",
		"Prefer a reaction over a written reply",
		"Personality may change phrasing, never facts",
		"Evidence, memory, incident and task titles",
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
		"search Emisar find_actions",
		"list_packs with availability=all",
		"completion.capability_gaps recommendation",
		"without inventing one",
		"Reconcile declared topology with observed runtime entities",
		"Use the investigation contract's conclusion kind",
		"Never say Emisar is unavailable merely because a local CLI",
		"This evidence policy is mandatory for current operational questions",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"Default to natural, plain English",
		"Use common words, contractions",
		"a simple explanation should usually be a few sentences",
		"Translate evidence into meaning",
		"Use humor like a trusted teammate",
		"make light of customer impact",
		"When a user asks for a chart, image, or meme",
		"do not send unsolicited visual noise",
		"Creative images and memes",
		"task lists, dividers, tables",
		"outer JSON is only the transport envelope",
		"do not send them outside Slack",
		"task_title",
		"task_repository",
		"inspect the most likely configured source repository",
		"even if the broader operational assessment remains blocked by that exact defect",
		"Do not merely describe the patch",
		"omit task_prompt rather than guessing",
		"Configured repository bindings",
		"target_is_configured_operator must be true",
		"A dedicated incident is not required",
		"include the exact pending_approval object",
		"Create, inspect, validate, publish, and execute Emisar runbooks",
		"An Emisar runbook is control-plane data, not a repository artifact",
		"complete the runbook-management steps first",
		"do not replace the runbook action with an engineering task",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("watch prompt does not contain %q:\n%s", required, prompt)
		}
	}
	if strings.Contains(prompt, "call the Emisar MCP tools before using shell commands") {
		t.Fatalf("watch prompt still imposes the old fixed tool order:\n%s", prompt)
	}
}

func TestConversationPromptReusesKnownResultForSimpleExplanation(t *testing.T) {
	prompt := conversationPrompt(
		"U123ABC",
		"Can you explain the fix in simple terms?",
		true,
	)
	for _, required := range []string{
		"answer from the existing conversation in natural plain language",
		"Do not rerun tools or repeat the investigation",
		"unless the user asks for a fresh check",
		"Default to natural, plain English",
		"Use common words, contractions",
		"Stay straightforward during active incidents",
		"Most messages need none; use at most one",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("conversation prompt does not contain %q:\n%s", required, prompt)
		}
	}
	if !simpleExplanationRequest("Can you explain me the fix in simple terms?") {
		t.Fatal("simple explanation request was not recognized")
	}
	if simpleExplanationRequest("Please check whether the fix is live now.") {
		t.Fatal("fresh verification request was mistaken for a simple explanation")
	}
	if got := progressMilestones("is explaining the earlier answer..."); len(got) != 2 || got[0] != "Reading the earlier answer" ||
		got[1] != "Writing a simpler explanation" {
		t.Fatalf("explanation progress = %v", got)
	}
}

func TestBoundedConversationUsesTheSameHumanVoicePolicy(t *testing.T) {
	prompt := (&Service{}).conversationPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: "U123ABC", Text: "Did the formatting check finally pass?",
		},
		"U999BOT", false, nil, core.AgentMemory{}, nil, "repo",
	)
	for _, required := range []string{
		"not a report generator, policy engine, or technical manual",
		"Use common words, contractions",
		"Do not force headings or bullets onto a short answer",
		"Strict controlled English is only for a user who explicitly asks for it",
		"Use humor like a trusted teammate",
		"Use emoji like a teammate, not decoration",
		"Prefer a reaction over a written reply",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("bounded conversation prompt lacks %q:\n%s", required, prompt)
		}
	}
}

func TestProgressCopyUsesPlainOperatorLanguage(t *testing.T) {
	for _, progress := range append(watchProgressSteps(), progressMilestones("investigating")...) {
		for _, jargon := range []string{"topology", "reconciling", "entities", "coverage"} {
			if strings.Contains(strings.ToLower(progress), jargon) {
				t.Fatalf("progress %q contains internal term %q", progress, jargon)
			}
		}
	}
	if got := progressMilestones("reviewing change"); len(got) != 4 || got[0] != "Reading the code changes" || got[3] != "Writing the review" {
		t.Fatalf("review progress = %v", got)
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
