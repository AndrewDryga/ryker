package service

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
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

// The policy text below must survive every edit to the prompt. Some of it is
// conditional now, so this builds the turn that enables everything — an
// operator's scheduled occurrence — and asserts the wording is intact.
// TestPromptSectionsAppearOnlyWhenTheyApply owns the separate question of which
// blocks reach which turn.
func TestWatchPromptCarriesMandatoryCrossSourceEvidencePolicy(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, _ := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC",
			MessageTS: "1700.001",
			UserID:    cfg.Slack.Operators[0],
			Kind:      "scheduled",
			Text:      "How is the health of our infrastructure?",
		},
		"U999BOT",
		false,
		nil,
		core.AgentMemory{},
		nil,
		nil,
		decisionpkg.OperationalMemoryContext{},
		"",
		nil,
		watchPromptBudget(0),
	)
	for _, required := range []string{
		"Consider the full set of repository, MCP, and other tools available in the turn",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Use the MCP tools directly, not curl against the MCP endpoint",
		// The policy said this twice; this pin was on the copy. Anchored to the
		// survivor so deleting the duplicate is not mistaken for losing the rule.
		"Treat runner-list results only as runner identities and connection state",
		// Also pinned on the deleted copy. Both rules were stated twice, and both
		// pins anchored the second statement rather than the first.
		"relevant configured tool merely because Emisar is available",
		"search Emisar find_actions",
		"list_packs with availability=all",
		"completion.capability_gaps recommendation",
		"without inventing one",
		"Reconcile declared topology with observed runtime entities",
		"Use the investigation contract's conclusion kind",
		"say Emisar is unavailable merely because a local CLI",
		"This evidence policy is mandatory for current operational questions",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"Default to natural, plain English",
		"Use common words, contractions",
		// The soft version of this ("a simple explanation should usually be a few
		// sentences") let a nine-word question draw a 350-word answer, because the
		// only hard length bound lived in the alert-reply block. Pin the number.
		"a one-line question gets one to three sentences",
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
		"preferred reproducible route rather than the requested outcome",
		"read-only semantic replacement or equivalent authorized checks",
		"do not replace the runbook action with an engineering task",
		"preferred named runbook or reusable workflow is unavailable",
		"missing reusable workflow is a maintenance gap",
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
		// The incident room used to get plain language and humor and nothing
		// about how a Slack message is rendered, so twenty runs guessed. It
		// carries the whole reply contract now.
		"standard Markdown for Slack's Block Kit `markdown` block",
		"a one-line question gets one to three sentences",
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
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil, decisionpkg.OperationalMemoryContext{}, "repo",
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
	// This prompt told the model to write mrkdwn in the same breath as the
	// formatting policy told it to write Markdown, and the delivery path — a
	// Block Kit `markdown` block, see slackui.Message.Blocks — renders the
	// second. Only one of them can be in here.
	if strings.Contains(prompt, "mrkdwn") {
		t.Fatalf("the bounded conversation prompt still asks for mrkdwn:\n%s", prompt)
	}
	if !strings.Contains(prompt, "standard Markdown for Slack's Block Kit `markdown` block") {
		t.Fatalf("the bounded conversation prompt lost the real format contract:\n%s", prompt)
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

// staticWatchPromptBytes is the size of the instruction block on the turn that
// enables every conditional section — the largest the static prompt gets.
//
// It is pinned because the number is a budget, not a curiosity. The transport
// caps a prompt at coop.MaxPromptBytes and elides the middle of anything over,
// which cuts through the structured context. Every byte of instruction is a
// byte of conversation the model does not get to see, and instructions grow by
// accretion: nobody adds a paragraph believing it is the one that pushes a
// real thread out of the window.
//
// Measured in production on 2026-08-07: assembled prompts ran a median 3.2 KiB
// over the cap across 89 truncations in a day. Freeing 4 KiB of instruction
// would have prevented 91% of them; 8 KiB, all of them.
// Raised by 6 on 2026-08-09 to teach the feedback contract the word
// "positive". Its vocabulary was negative, suggestion and mixed, so the model
// had no way to record that an answer was right — nine days of traffic left
// the feedback table empty at zero rows, and every example of the target
// behaviour had to be inferred from complaints that never came. Nine bytes for
// the new value, three back from rewording the sibling field.
const staticWatchPromptBytes = 48195

// The static prompt must not grow without someone deciding it should.
//
// This is a two-sided bound on purpose. Over the pin means the instructions
// grew and something has to give. Under it means a compression landed and the
// pin should come down to lock the win in — a ratchet that only ever loosens
// is not a ratchet.
func TestStaticWatchPromptSizeIsPinned(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, _ := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: cfg.Slack.Operators[0], Kind: "scheduled",
			Text: "How is the health of our infrastructure?",
		},
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "", nil, watchPromptBudget(0),
	)
	switch {
	case len(prompt) > staticWatchPromptBytes:
		t.Fatalf(
			"static watch prompt grew to %d bytes, over its pin of %d.\n"+
				"Every byte here is a byte of conversation the model cannot see. "+
				"Compress something else out, or raise the pin deliberately.",
			len(prompt), staticWatchPromptBytes,
		)
	case len(prompt) < staticWatchPromptBytes:
		t.Fatalf(
			"static watch prompt is %d bytes, under its pin of %d — "+
				"lower staticWatchPromptBytes to %d to keep the saving.",
			len(prompt), staticWatchPromptBytes, len(prompt),
		)
	}
	// The pin is only meaningful if the prompt actually leaves room for a
	// conversation. This is the number that matters to answer quality.
	if room := coop.MaxPromptBytes - len(prompt); room < 8<<10 {
		t.Fatalf(
			"instructions leave only %d bytes for conversation and evidence",
			room,
		)
	}
}
