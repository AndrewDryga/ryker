package slackui

import (
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

func TestSanitizerRedactsSecretsMentionsANSIAndBounds(t *testing.T) {
	sanitizer := NewSanitizer(120, "super-secret-token")
	input := "\x1b[31mfailed\x1b[0m <@U123> <!channel> xoxb-1234567890-secret super-secret-token " + strings.Repeat("x", 200)
	got := sanitizer.Text(input)
	for _, forbidden := range []string{"\x1b", "xoxb-", "super-secret-token", "<@U123>", "<!channel>"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("sanitized output contains %q: %q", forbidden, got)
		}
	}
	if len(got) > 150 || !strings.Contains(got, "truncated") {
		t.Fatalf("bound output = %q (%d)", got, len(got))
	}
}

func TestSanitizerCoversEveryUntrustedMessageSurface(t *testing.T) {
	sanitizer := NewSanitizer(500, "super-secret-token")
	message := sanitizer.Message(Message{
		Text: "<!channel>", Header: "super-secret-token",
		Sections: []string{"<@U123>"}, Fields: []Field{{Label: "xoxb-1234567890-secret", Value: "\x1b[31mvalue"}},
		Context: []string{"<!here>"},
	})
	data, err := Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"<!channel>", "<@U123>", "<!here>", "super-secret-token", "xoxb-", "\x1b"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("message contains %q: %s", forbidden, data)
		}
	}
}

func TestIncidentCardHasVisibleStateAndDeterministicControls(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API readiness failed", Severity: "critical",
		Status: core.IncidentActive, Workflow: core.WorkflowInvestigating,
		FiringCount: 2, SignalCount: 3, ActiveTurnID: "turn_1",
		RootTS: "1700.001", CoopSessionID: "ses_1", CoopForkName: "incident-api",
		CreatedAt: time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC),
		UpdatedAt: time.Date(2026, 7, 27, 1, 0, 0, 0, time.UTC),
	}
	card := IncidentCard(incident, "Infrastructure", []core.Signal{{
		Status: core.SignalFiring, Summary: "Checkout requests are timing out.",
		SourceURL: "https://grafana.example.test/alerting/1",
	}}, true)
	if card.Header != "CRITICAL | "+incident.Title || len(card.Actions) != 2 {
		t.Fatalf("card = %+v", card)
	}
	if !strings.Contains(card.Text, "Severity critical") ||
		!strings.Contains(card.Text, "Responder Investigating") ||
		!strings.Contains(card.Text, "2 of 3 signals firing") {
		t.Fatalf("fallback omits incident state: %q", card.Text)
	}
	if len(card.Sections) != 2 || !strings.Contains(card.Sections[1], "Checkout requests") ||
		!slices.Contains(card.Context, "Alert source: <https://grafana.example.test/alerting/1|Open grafana.example.test>") {
		t.Fatalf("card omits alert evidence: %+v", card)
	}
	var actionBlocks int
	for _, action := range card.Actions {
		if action.ID == ActionUpdate || action.ID == ActionReview || action.ID == ActionResolve {
			t.Fatalf("active card exposes unavailable action: %+v", action)
		}
	}
	for _, block := range card.Blocks() {
		if actionBlock, ok := block.(*slack.ActionBlock); ok {
			actionBlocks++
			if len(actionBlock.Elements.ElementSet) > 4 {
				t.Fatalf("action row has %d elements", len(actionBlock.Elements.ElementSet))
			}
		}
	}
	if actionBlocks != 1 || card.Actions[0].ID != ActionStop ||
		card.Actions[0].Label != "Stop current run" ||
		card.Actions[0].Style != "danger" || card.Actions[0].Confirm == "" {
		t.Fatalf("card lacks compact safe stop action: %+v", card.Actions)
	}
}

func TestIncidentCardControlsFollowLifecycle(t *testing.T) {
	base := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed", Status: core.IncidentActive,
		RootTS: "1700.001", CoopSessionID: "ses_1", CoopForkName: "incident-api",
		UpdatedAt: time.Now(),
	}
	tests := []struct {
		name     string
		incident core.Incident
		want     []string
	}{
		{
			name: "provisioning",
			incident: core.Incident{
				ID: base.ID, Title: base.Title, Status: core.IncidentActive,
				Workflow: core.WorkflowProvisioningSession, RootTS: base.RootTS,
			},
			want: []string{ActionResolve},
		},
		{
			name: "active turn",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowInvestigating
				value.ActiveTurnID = "turn_1"
				return value
			}(),
			want: []string{ActionStop, ActionChanges},
		},
		{
			name: "parked",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowParked
				return value
			}(),
			want: []string{ActionUpdate, ActionChanges, ActionReview, ActionResolve},
		},
		{
			name: "budget blocked",
			incident: func() core.Incident {
				value := base
				value.Workflow = core.WorkflowBlocked
				return value
			}(),
			want: []string{ActionChanges, ActionReview, ActionResolve},
		},
		{
			name: "closed",
			incident: func() core.Incident {
				value := base
				value.Status = core.IncidentClosed
				value.Workflow = core.WorkflowClosed
				return value
			}(),
			want: []string{ActionChanges},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			card := IncidentCard(test.incident, "Repository", nil, true)
			got := make([]string, 0, len(card.Actions))
			for _, action := range card.Actions {
				got = append(got, action.ID)
			}
			if !slices.Equal(got, test.want) {
				t.Fatalf("actions = %v, want %v", got, test.want)
			}
		})
	}
}

func TestIncidentCardHidesChangeControlsWithoutCodeChanges(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Read-only inspection",
		Status: core.IncidentActive, Workflow: core.WorkflowParked,
		RootTS: "1700.001", CoopSessionID: "ses_1", CoopForkName: "incident-read-only",
		UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", nil, false)
	got := make([]string, 0, len(card.Actions))
	for _, action := range card.Actions {
		got = append(got, action.ID)
	}
	if !slices.Equal(got, []string{ActionUpdate, ActionResolve}) {
		t.Fatalf("unchanged parked incident controls = %v", got)
	}
	incident.Status = core.IncidentClosed
	incident.Workflow = core.WorkflowClosed
	card = IncidentCard(incident, "Repository", nil, false)
	if len(card.Actions) != 0 {
		t.Fatalf("unchanged closed incident exposes controls: %+v", card.Actions)
	}
}

func TestIncidentCardControlsExplainTheirEffects(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed", Status: core.IncidentActive,
		Workflow: core.WorkflowParked, RootTS: "1700.001",
		CoopSessionID: "ses_1", CoopForkName: "incident-api", UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", nil, true)
	want := []Action{
		{
			ID: ActionUpdate, Label: "Ask agent for update", Value: incident.ID,
			Style:   "primary",
			Confirm: "Ask Responder to inspect current evidence and post a concise update?",
		},
		{ID: ActionChanges, Label: "View diff", Value: incident.ID},
		{
			ID: ActionReview, Label: "Run readiness check", Value: incident.ID,
			Confirm: "Compare the isolated changes with the current repository state, check rebase and configured validation and policy gates, and report whether the fix is ready for external review. This does not merge, push, sign, or deploy.",
		},
	}
	if len(card.Actions) != 4 || !slices.Equal(card.Actions[:3], want) {
		t.Fatalf("controls = %+v, want effects made explicit", card.Actions)
	}

	incident.Workflow = core.WorkflowBlocked
	card = IncidentCard(incident, "Repository", nil, true)
	got := make([]string, 0, len(card.Actions))
	for _, action := range card.Actions {
		got = append(got, action.ID)
	}
	if !slices.Equal(
		got, []string{ActionChanges, ActionReview, ActionResolve},
	) {
		t.Fatalf("blocked controls = %v", got)
	}
}

func TestInitialIncidentCardHasNoControlsUntilRootIsBound(t *testing.T) {
	card := IncidentCard(core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed",
		Status: core.IncidentActive, Workflow: core.WorkflowProvisioningChannel,
		UpdatedAt: time.Now(),
	}, "Repository", nil, false)
	if len(card.Actions) != 0 {
		t.Fatalf("unbound root exposes stale controls: %+v", card.Actions)
	}
}

func TestIncidentCardFallbackIncludesActionableErrorAndRejectsUnsafeSource(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed <!channel>", Severity: "high",
		Status: core.IncidentActive, Workflow: core.WorkflowBlocked,
		FiringCount: 1, SignalCount: 1, LastError: "Turn budget exhausted; notify <@U123>.",
		UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", []core.Signal{{
		Status: core.SignalFiring, Summary: "See <https://evil.example|details>.",
		SourceURL: "javascript:alert(1)",
	}}, false)
	if !strings.Contains(card.Text, "Action needed: Turn budget exhausted") ||
		strings.Contains(card.Text, "<!channel>") || strings.Contains(card.Text, "<@U123>") ||
		len(card.Sections) < 3 || strings.Contains(card.Sections[2], "<https://evil.example") {
		t.Fatalf("fallback = %q", card.Text)
	}
	for _, context := range card.Context {
		if strings.Contains(context, "javascript:") {
			t.Fatalf("unsafe source rendered: %q", context)
		}
	}
}

func TestIncidentCardSourceLinkNamesHostAndDropsCredentials(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API failed", Status: core.IncidentActive,
		Workflow: core.WorkflowInvestigating, UpdatedAt: time.Now(),
	}
	card := IncidentCard(incident, "Repository", []core.Signal{{
		Status:    core.SignalFiring,
		SourceURL: "https://alerts.example.test/path/to/alert?token=super-secret&signature=abc#details",
	}}, false)
	want := "Alert source: <https://alerts.example.test/path/to/alert|Open alerts.example.test>"
	if !slices.Contains(card.Context, want) {
		t.Fatalf("sanitized source link = %+v, want %q", card.Context, want)
	}
	for _, context := range card.Context {
		if strings.Contains(context, "super-secret") || strings.Contains(context, "signature=") {
			t.Fatalf("source credentials leaked into Slack: %q", context)
		}
	}
	concealed := IncidentCard(incident, "Repository", []core.Signal{{
		Status: core.SignalFiring, SourceURL: "https://trusted.example@evil.example/phish",
	}}, false)
	for _, context := range concealed.Context {
		if strings.Contains(context, "evil.example") {
			t.Fatalf("credential-style concealed host rendered: %q", context)
		}
	}
}

func TestChannelNameIsSlackSafeAndDeterministic(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "API / Checkout: 5xx above 20%",
		CreatedAt: time.Date(2026, 7, 27, 1, 0, 0, 0, time.UTC),
	}
	name := ChannelName("ems", incident)
	if name != ChannelName("ems", incident) || !strings.HasPrefix(name, "ems-0727-") {
		t.Fatalf("channel name is not deterministic: %q", name)
	}
	if len(name) > 80 || !strings.HasSuffix(name, "-1234567890") {
		t.Fatalf("channel name = %q", name)
	}
	for _, char := range name {
		if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '-' && char != '_' {
			t.Fatalf("unsafe channel character %q in %q", char, name)
		}
	}
}

func TestLongAssistantResponseShowsTruncation(t *testing.T) {
	message := AssistantResponse(strings.Repeat("paragraph\n", 5000), NewSanitizer(30000))
	if len(message.Markdown) > 12000 ||
		!strings.Contains(message.Markdown, "truncated") ||
		message.Header != "Investigation update" ||
		!strings.HasPrefix(message.Text, "Investigation update:") {
		t.Fatalf("long response was not visibly bounded: %+v", message)
	}
}

func TestConversationResponseLooksLikeOrdinarySlackSpeech(t *testing.T) {
	message := ConversationResponse("I checked the deploy. It is healthy.", NewSanitizer(12000))
	if message.Text != "I checked the deploy. It is healthy." ||
		message.Markdown != "I checked the deploy. It is healthy." ||
		len(message.Sections) != 0 ||
		message.Header != "" || len(message.Context) != 0 {
		t.Fatalf("conversation response = %+v", message)
	}
}

func TestConversationResponseUsesSlackMarkdownBlock(t *testing.T) {
	text := "## Health\n\n**Degraded**\n\n| Layer | State |\n| --- | --- |\n| Nomad | Healthy |\n\n- [x] Hosts checked\n\n```hcl\ncount = 2\n```"
	message := ConversationResponse(text, NewSanitizer(12000))
	blocks := message.Blocks()
	if len(blocks) != 1 {
		t.Fatalf("conversation blocks = %+v", blocks)
	}
	markdown, ok := blocks[0].(*slack.MarkdownBlock)
	if !ok || markdown.Type != slack.MBTMarkdown || markdown.Text != text {
		t.Fatalf("conversation markdown block = %#v", blocks[0])
	}
}

func TestConversationIncidentOfferExplainsAndConfirmsCreation(t *testing.T) {
	message := ConversationResponseWithIncidentOffer(
		"Two production runners are disconnected.",
		"slack-source-1",
		NewSanitizer(12000),
	)
	if message.Text != "Two production runners are disconnected." ||
		len(message.Actions) != 1 ||
		message.Actions[0].ID != ActionOpenIncident ||
		message.Actions[0].Value != "slack-source-1" ||
		message.Actions[0].Label != "Open incident room" ||
		message.Actions[0].Style != "primary" ||
		!strings.Contains(message.Actions[0].Confirm, "No merge, push, deployment") ||
		len(message.Context) != 1 ||
		!strings.Contains(message.Context[0], "No incident has been created") {
		t.Fatalf("incident offer = %+v", message)
	}
}

func TestEngineeringTaskOfferAndCardDoNotMislabelWorkAsIncident(t *testing.T) {
	offer := EvidenceResponseWithTaskOffer(
		"I can audit and update `infra/` in an isolated working copy.",
		nil,
		nil,
		"slack-source-task",
		"Emisar (`emisar`)",
		NewSanitizer(12000),
	)
	if len(offer.Actions) != 1 ||
		offer.Actions[0].ID != ActionStartTask ||
		offer.Actions[0].Label != "Start engineering task" ||
		!strings.Contains(offer.Actions[0].Confirm, "edit, test, and commit") ||
		!strings.Contains(offer.Actions[0].Confirm, "Emisar (`emisar`)") ||
		!strings.Contains(offer.Context[0], "No engineering task has been created") {
		t.Fatalf("engineering task offer = %+v", offer)
	}

	task := core.Incident{
		ID: "inc_1234567890abcdef", Route: "manual", SourceIncidentID: "task:EvTask",
		WorkKind: core.WorkKindEngineeringTask, WorkScope: core.WorkScopeThread,
		OriginChannelID: "COPS", OriginThreadTS: "1700.0",
		Title: "Audit infrastructure packs", Status: core.IncidentActive,
		Workflow: core.WorkflowParked, RootTS: "1700.1", CoopSessionID: "ses_1",
		CoopForkName: "remote-task", CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	card := IncidentCard(task, "Emisar", []core.Signal{{
		Status: core.SignalFiring, Summary: "Update infra/ with required packs.",
	}}, false)
	content := card.Text + "\n" + strings.Join(card.Sections, "\n")
	if !strings.Contains(content, "Engineering task") ||
		!strings.Contains(content, "Requested change") ||
		strings.Contains(content, "alert signals") ||
		strings.Contains(content, "Severity") ||
		len(card.Actions) == 0 ||
		card.Actions[len(card.Actions)-1].Label != "Close task" {
		t.Fatalf("engineering task card = %+v", card)
	}
	if !strings.Contains(offer.Context[0], "this Slack thread") ||
		!strings.Contains(offer.Actions[0].Confirm, "in this thread") ||
		!strings.Contains(card.Context[0], "same isolated task session") {
		t.Fatalf("engineering task thread copy = offer:%+v card:%+v", offer, card)
	}
	if !strings.Contains(content, "nothing to inspect, review, or publish") {
		t.Fatalf("zero-change task does not explain delivery state: %+v", card)
	}
	changed := IncidentCardWithPublication(
		task, "Emisar", nil, true, core.Publication{},
	)
	if !slices.ContainsFunc(changed.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR && action.Label == "Create draft PR"
	}) {
		t.Fatalf("changed task lacks publication action: %+v", changed.Actions)
	}
	published := IncidentCardWithPublication(
		task, "Emisar", nil, true, core.Publication{
			State: "published", PRNumber: 42, PRURL: "https://github.example/pull/42",
		},
	)
	if !slices.ContainsFunc(published.Actions, func(action Action) bool {
		return action.ID == ActionViewPR && action.URL == "https://github.example/pull/42"
	}) || !strings.Contains(strings.Join(published.Sections, "\n"), "Draft PR ready") {
		t.Fatalf("published task lacks durable PR state: %+v", published)
	}
}

func TestTurnFailureAndManualHandoffPreserveTheNextStep(t *testing.T) {
	failure := TurnFailureMessage("failed", "MCP request timed out.")
	if failure.Header != "Investigation could not finish" ||
		!strings.Contains(strings.Join(failure.Sections, "\n"), "preserved") ||
		!strings.Contains(strings.Join(failure.Sections, "\n"), "continue") {
		t.Fatalf("failure message = %+v", failure)
	}
	handoff := ManualHandoff("C123INCIDENT")
	if handoff.Header != "Incident room ready" ||
		!strings.Contains(handoff.Text, "<#C123INCIDENT>") ||
		!strings.Contains(handoff.Sections[0], "<#C123INCIDENT>") {
		t.Fatalf("handoff = %+v", handoff)
	}
}

func TestIncidentStatusExplainsStateAndNextAction(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Status: core.IncidentActive,
		Workflow: core.WorkflowParked, FiringCount: 1, SignalCount: 2,
	}
	message := IncidentStatusMessage(incident)
	content := message.Text + "\n" + strings.Join(message.Sections, "\n")
	for _, required := range []string{
		"Waiting for input",
		"No agent turn is running",
		"Reply normally in this incident channel",
		"1 of 2 alert signals are firing",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("incident status lacks %q: %+v", required, message)
		}
	}
	if strings.Contains(content, "parked") {
		t.Fatalf("incident status exposes internal workflow: %+v", message)
	}
}

func TestHelpExplainsControlEffectsAndSafety(t *testing.T) {
	message := HelpMessage(core.Incident{ID: "inc_1234567890abcdef"})
	content := strings.Join(message.Sections, "\n") + "\n" + strings.Join(message.Context, "\n")
	for _, required := range []string{
		"an `@mention` is not required",
		"`/responder changes` shows",
		"`/responder stop` cancels",
		"does not disable conversation in an attached incident room",
		"never merge, sign, or deploy",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("help lacks %q: %+v", required, message)
		}
	}
}

func TestEvidenceResponseRendersCoverageCitationsAndGovernedActions(t *testing.T) {
	observed := time.Date(2026, 7, 27, 20, 0, 0, 0, time.UTC)
	message := EvidenceResponse(
		"**Assessment:** one scheduler allocation is unhealthy.",
		[]core.Evidence{{
			ID: "ev_1", Claim: "Allocation is terminal",
			Observation: "Nomad reported client status failed",
			SourceName:  "emisar status", SourceType: "emisar",
			SourceURL:  "https://emisar.dev/operations/op-1?token=secret",
			ObservedAt: observed,
		}},
		[]core.Coverage{{
			Layer: "scheduler", Status: "unhealthy", Source: "emisar status",
		}},
		[]core.ActionProposal{{
			ID: "act_1", ActionName: "restart_allocation",
			Title: "Restart failed allocation", Target: "alloc-123",
			Summary: "No healthy replacement exists.", Risk: "medium", Required: 2,
			BlastRadius: "One allocation", Rollback: "Restore the prior version",
			Verification: "Replacement reaches healthy",
		}},
		NewSanitizer(30000),
	)
	for _, required := range []string{
		"## Coverage",
		"| scheduler | unhealthy | emisar status |",
		"## Evidence",
		"Allocation is terminal",
		"https://emisar.dev/operations/op-1",
		"## Proposed action: Restart failed allocation",
		"No action runs until",
	} {
		if !strings.Contains(message.Markdown, required) {
			t.Fatalf("evidence response lacks %q: %s", required, message.Markdown)
		}
	}
	if strings.Contains(message.Markdown, "token=secret") {
		t.Fatalf("evidence URL leaked query: %s", message.Markdown)
	}
	if len(message.Actions) != 2 ||
		message.Actions[0].ID != ActionApproveProposal ||
		message.Actions[0].Value != "act_1" ||
		!strings.Contains(message.Actions[0].Confirm, "Required approvals: 2") ||
		message.Actions[1].ID != ActionRejectProposal ||
		!strings.Contains(message.Actions[1].Confirm, "No operational action") {
		t.Fatalf("proposal controls = %+v", message.Actions)
	}
	blocks := message.Blocks()
	if len(blocks) < 3 {
		t.Fatalf("evidence response Block Kit = %+v", blocks)
	}
}

func TestEmisarApprovalCardLinksToAuthoritativeConsole(t *testing.T) {
	message := WithEmisarApproval(
		IncidentEvidenceResponse(
			"Emisar paused the requested restart for policy approval.",
			nil,
			nil,
			[]core.ActionProposal{{ID: "legacy", Title: "Legacy approval"}},
			NewSanitizer(30000),
		),
		core.EmisarApproval{
			RequestID: "apr_123", RunID: "run_123", OperationID: "op_123",
			ActionID: "nomad.alloc_restart", PackRef: "nomad@1.2.3#sha256:abc",
			RunnerRef: "prod-1~abc123", Status: "pending_approval",
			ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_123",
			ExpiresAt:   time.Date(2026, 7, 28, 6, 30, 0, 0, time.UTC),
		},
	)
	if message.Header != "Approval required in Emisar" ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "paused this operational request") ||
		!strings.Contains(strings.Join(message.Context, "\n"), "Slack cannot approve") {
		t.Fatalf("approval card copy = %+v", message)
	}
	if len(message.Actions) != 1 ||
		message.Actions[0].ID != ActionOpenApproval ||
		message.Actions[0].Value != "apr_123" ||
		message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_123" ||
		message.Actions[0].Label != "Review approval in Emisar" {
		t.Fatalf("approval control = %+v", message.Actions)
	}
	blocks := message.Blocks()
	var linked bool
	for _, block := range blocks {
		actionBlock, ok := block.(*slack.ActionBlock)
		if !ok {
			continue
		}
		for _, element := range actionBlock.Elements.ElementSet {
			button, ok := element.(*slack.ButtonBlockElement)
			if ok && button.URL == message.Actions[0].URL {
				linked = true
			}
		}
	}
	if !linked {
		t.Fatalf("Block Kit did not retain approval URL: %+v", blocks)
	}
}

func TestConciseEvidenceResponseKeepsLedgerOutOfRoutineSlackReply(t *testing.T) {
	message := ConciseEvidenceResponse(
		"**Audit complete:** no repository change was needed.",
		[]core.Evidence{{
			Claim: "Packs match", Observation: "Nine declared packs are live",
			SourceType: "emisar", SourceName: "list_packs",
		}},
		[]core.Coverage{{Layer: "runtime", Status: "healthy"}},
		nil,
		NewSanitizer(12000),
	)
	if strings.Contains(message.Markdown, "## Evidence") ||
		strings.Contains(message.Markdown, "## Coverage") ||
		strings.Contains(message.Markdown, "Nine declared packs are live") {
		t.Fatalf("routine reply dumped evidence ledger: %+v", message)
	}
	if len(message.Context) != 1 ||
		message.Context[0] != "1 evidence record and 1 coverage assessment saved." {
		t.Fatalf("routine reply evidence summary = %+v", message.Context)
	}
}

func TestAgentReportFailureDoesNotRenderRawTranscript(t *testing.T) {
	message := AgentReportFailureMessage("json: unknown field `tool_output`")
	content := message.Text + strings.Join(message.Sections, "\n") +
		strings.Join(message.Context, "\n")
	for _, required := range []string{
		"Result needs a clean summary",
		"Coop completed the agent turn",
		"isolated working copy",
		"Raw agent transcripts",
	} {
		if !strings.Contains(content+message.Header, required) {
			t.Fatalf("report failure lacks %q: %+v", required, message)
		}
	}
	if strings.Contains(content, "tool output here") {
		t.Fatalf("report failure leaked transcript: %+v", message)
	}
}

func TestTimelineHandoffAndPostmortemRemainEvidenceGrounded(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Checkout latency",
		Status: core.IncidentActive, Workflow: core.WorkflowParked,
		FiringCount: 1, SignalCount: 2, Severity: "high",
		CreatedAt: time.Date(2026, 7, 27, 19, 0, 0, 0, time.UTC),
	}
	events := []core.TimelineEvent{{
		Title: "Live state checked", Detail: "One allocation was terminal.",
		CreatedAt: time.Date(2026, 7, 27, 20, 0, 0, 0, time.UTC),
	}}
	evidence := []core.Evidence{{
		Claim: "One allocation was terminal", Observation: "Nomad reported failed",
		SourceType: "emisar", SourceName: "status",
	}}
	coverage := []core.Coverage{{
		Layer: "application", Status: "unknown",
		Detail: "No user-facing SLO source was available",
	}}
	timeline := TimelineMessage(incident, events)
	handoff := HandoffMessage(incident, events, evidence, coverage)
	postmortem := PostmortemDraft(incident, events, evidence, coverage)
	if !strings.Contains(timeline.Markdown, "Live state checked") ||
		!strings.Contains(handoff.Markdown, "Shift handoff") ||
		!strings.Contains(handoff.Markdown, "## Evidence") ||
		!strings.Contains(postmortem.Markdown, "Post-incident draft") ||
		!strings.Contains(postmortem.Markdown, "Confirm root cause") ||
		!strings.Contains(
			strings.Join(postmortem.Context, "\n"),
			"does not invent impact, root cause, owners",
		) {
		t.Fatalf(
			"timeline=%+v\nhandoff=%+v\npostmortem=%+v",
			timeline, handoff, postmortem,
		)
	}
}

func TestOperationsHomeSummarizesWorkWithoutMarketingCopy(t *testing.T) {
	message := OperationsHome(1, 3, 1, 2, 1, 2, 1, 0, 0, 0, 1, []core.Incident{{
		ID: "inc_1", Title: "API unavailable", Status: core.IncidentActive,
		Workflow: core.WorkflowInvestigating, ChannelID: "CINCIDENT",
		ChannelName: "ems-api", FiringCount: 1, SignalCount: 1,
	}}, []core.Commitment{{
		Title: "Verify rollout", State: core.CommitmentWorking,
		Status: "Checking live state", NextAction: "Deliver the result",
		ChannelID: "CINCIDENT",
	}}, nil, nil, nil, nil)
	content := message.Text + "\n" + message.Markdown + "\n" +
		strings.Join(message.Sections, "\n")
	for _, field := range message.Fields {
		content += "\n" + field.Label + "\n" + field.Value
	}
	for _, required := range []string{
		"Needs attention",
		"Open work",
		"Failed work",
		"API unavailable",
		"Verify rollout",
		"What Emisar owes the team",
		"<#CINCIDENT>",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("operations home lacks %q: %+v", required, message)
		}
	}
	if message.Markdown != "" {
		t.Fatalf("operations home uses message-only markdown block: %+v", message)
	}
}

func TestMemoryOfferAndDirectoryExplainExactOperatorAction(t *testing.T) {
	offer := core.MemoryOffer{
		Scope: "channel", Subject: "old portal", Predicate: "alias_of",
		Value: "service:portal", Visibility: "channel", ExpiresIn: "30d",
	}
	message := WithMemoryOffer(
		ConversationResponse("I can remember that mapping.", NewSanitizer(12000)),
		offer,
		`{"version":1}`,
		"channel",
		"30 days",
	)
	content := strings.Join(message.Sections, "\n") + "\n" +
		strings.Join(message.Context, "\n")
	for _, expected := range []string{
		"Proposed operational memory", "old portal", "alias_of", "service:portal",
		"Nothing is saved yet", "not live evidence",
	} {
		if !strings.Contains(content, expected) {
			t.Fatalf("memory offer missing %q: %+v", expected, message)
		}
	}
	if len(message.Actions) != 1 ||
		message.Actions[0].ID != ActionRememberMemory ||
		!strings.Contains(message.Actions[0].Confirm, "cannot establish current health") {
		t.Fatalf("memory offer action = %+v", message.Actions)
	}
	entry := core.MemoryEntry{
		ID: "mem_1", ScopeKind: "channel", ScopeKey: "COPS",
		SubjectKey: "old portal", Predicate: "alias_of", Value: "service:portal",
		ExpiresAt: time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC),
	}
	directory := MemoryDirectoryMessage([]core.MemoryEntry{entry})
	if len(directory.Actions) != 1 ||
		directory.Actions[0].ID != ActionForgetMemory ||
		!strings.Contains(directory.Sections[0], "COPS") {
		t.Fatalf("memory directory = %+v", directory)
	}
}

func TestBehaviorOfferCardsAndDirectoriesExplainScopeAndSafety(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	preference := core.ResponderPreference{
		ID: "pref_1", ScopeKind: "operator", ScopeKey: "UOPERATOR",
		Name: "health_check_depth", Value: "deep", Enabled: true,
		ExpiresAt: now,
	}
	preferenceOffer := core.PreferenceOffer{
		Scope: "operator", Name: preference.Name, Value: preference.Value,
		ExpiresIn: "30d",
	}
	preferenceMessage := WithPreferenceOffer(
		ConversationResponse("I can make that your default.", NewSanitizer(12000)),
		preferenceOffer,
		preference,
		`{"version":1}`,
		"30 days",
	)
	preferenceContent := strings.Join(preferenceMessage.Sections, "\n") + "\n" +
		strings.Join(preferenceMessage.Context, "\n")
	for _, expected := range []string{
		"Proposed Responder preference", "health_check_depth", "deep",
		"Nothing is saved yet", "cannot establish health",
	} {
		if !strings.Contains(preferenceContent, expected) {
			t.Fatalf("preference offer lacks %q: %+v", expected, preferenceMessage)
		}
	}
	if strings.Contains(preferenceContent, "**") ||
		strings.Contains(preferenceContent, preference.ScopeKey) ||
		!strings.Contains(preferenceContent, "You (operator preference)") {
		t.Fatalf("preference offer has invalid Slack formatting or scope: %s", preferenceContent)
	}
	if len(preferenceMessage.Actions) != 1 ||
		preferenceMessage.Actions[0].ID != ActionRememberPreference {
		t.Fatalf("preference offer action = %+v", preferenceMessage.Actions)
	}
	preferenceDirectory := PreferenceDirectoryMessage(
		[]core.ResponderPreference{preference},
	)
	preferenceSaved := PreferenceSavedMessage(preference, false)
	preferenceSurface := strings.Join(preferenceDirectory.Sections, "\n") + "\n" +
		strings.Join(preferenceSaved.Sections, "\n") + "\n" +
		strings.Join(preferenceSaved.Context, "\n")
	if len(preferenceDirectory.Actions) != 3 ||
		preferenceDirectory.Actions[0].ID != ActionTogglePreference ||
		preferenceDirectory.Actions[1].ID != ActionEditPreference ||
		preferenceDirectory.Actions[2].ID != ActionDeletePreference ||
		strings.Contains(preferenceSurface, "**") ||
		strings.Contains(preferenceSurface, preference.ScopeKey) ||
		!strings.Contains(preferenceSurface, "highest precedence") {
		t.Fatalf("preference controls = %+v", preferenceDirectory.Actions)
	}

	rule := core.StandingRule{
		ID: "rule_1", ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "app", Enabled: true, TriggerCount: 2,
		ExpiresAt: now,
	}
	ruleOffer := core.RuleOffer{
		Scope: "channel", Repository: rule.Repository,
		Trigger: rule.Trigger, Action: rule.Action,
		SourceKind: rule.SourceKind, ExpiresIn: "30d",
	}
	ruleMessage := WithRuleOffer(
		ConversationResponse("I can watch those plans.", NewSanitizer(12000)),
		ruleOffer,
		rule,
		`{"version":1}`,
		"30 days",
	)
	ruleContent := strings.Join(ruleMessage.Sections, "\n") + "\n" +
		strings.Join(ruleMessage.Context, "\n")
	for _, expected := range []string{
		"Proposed standing rule", "terraform_plan", "review_terraform_plan",
		"read-only", "proactive triage is off", "Nothing is saved yet",
	} {
		if !strings.Contains(ruleContent, expected) {
			t.Fatalf("rule offer lacks %q: %+v", expected, ruleMessage)
		}
	}
	if strings.Contains(ruleContent, "**") ||
		strings.Contains(ruleContent, rule.ChannelID) ||
		!strings.Contains(ruleContent, "Scope: This channel") {
		t.Fatalf("rule offer has invalid Slack formatting or scope: %s", ruleContent)
	}
	if len(ruleMessage.Actions) != 1 ||
		ruleMessage.Actions[0].ID != ActionRememberRule {
		t.Fatalf("rule offer action = %+v", ruleMessage.Actions)
	}
	ruleDirectory := RuleDirectoryMessage([]core.StandingRule{rule})
	ruleSaved := RuleSavedMessage(rule, false)
	ruleSurface := strings.Join(ruleDirectory.Sections, "\n") + "\n" +
		strings.Join(ruleSaved.Sections, "\n")
	if len(ruleDirectory.Actions) != 3 ||
		ruleDirectory.Actions[0].ID != ActionToggleRule ||
		ruleDirectory.Actions[1].ID != ActionEditRule ||
		ruleDirectory.Actions[2].ID != ActionDeleteRule ||
		!strings.Contains(ruleDirectory.Sections[0], "Runs: 2") ||
		strings.Contains(ruleSurface, "**") {
		t.Fatalf("rule directory = %+v", ruleDirectory)
	}
}
