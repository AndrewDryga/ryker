package slackui

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/slack-go/slack"
)

func TestChangesMessageRendersExplicitPatchPageAndNavigation(t *testing.T) {
	incident := core.Incident{
		ID: "incident_large_diff", WorkKind: core.WorkKindEngineeringTask,
		CoopForkName: "remote-large",
	}
	patch := []byte(strings.Repeat("+changed line\n", 400))
	message := ChangesMessage(
		incident,
		"*Committed (24)*\n`first.go` M\n_…and 23 more committed files._",
		patch,
		ChangesNavigation{
			Page: 2, Pages: 4, FirstByte: 7000, LastByte: 14000,
			TotalBytes:    25000,
			Digest:        strings.Repeat("a", 64),
			PreviousValue: "previous", NextValue: "next", RefreshValue: "refresh",
		},
	)
	if !strings.Contains(message.Markdown, "Patch page 2 of 4") ||
		!strings.Contains(message.Markdown, "bytes 7001-14000 of 25000") ||
		!strings.Contains(message.Markdown, "snapshot `aaaaaaaaaaaa`") ||
		!strings.Contains(message.Markdown, "+changed line") ||
		strings.Contains(message.Markdown, "The patch exceeded") ||
		len(message.Actions) != 3 ||
		message.Actions[0].ID != ActionChangesPrevious ||
		message.Actions[1].ID != ActionChangesNext ||
		message.Actions[2].ID != ActionChangesRefresh {
		t.Fatalf("large diff page = %+v", message)
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

func TestPullRequestReviewActionIsExplicitAndReadOnly(t *testing.T) {
	message := WithPullRequestReview(
		ConversationResponse("MinIO looks reasonable here.", NewSanitizer(12000)),
		"source-input",
	)
	if len(message.Actions) != 1 {
		t.Fatalf("actions = %+v", message.Actions)
	}
	action := message.Actions[0]
	if action.ID != ActionReviewPullRequest || action.Label != "Review PR" ||
		action.Value != "source-input" || action.Style != "" ||
		!strings.Contains(action.Confirm, "exact PR diff") ||
		!strings.Contains(action.Confirm, "read-only") {
		t.Fatalf("PR review action = %+v", action)
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

func TestFileBlocksReplaceUnsupportedMarkdownAndKeepActions(t *testing.T) {
	message := Message{
		Text:     "Fallback",
		Header:   "CPU report",
		Markdown: strings.Repeat("The chart uses `fresh` data.\n", 150),
		Sections: []string{"No saturation was found."},
		Fields:   []Field{{Label: "Window", Value: "7 days"}},
		Context:  []string{"1 finding saved"},
		Actions:  []Action{{ID: "review", Label: "Review", Value: "x"}},
	}
	blocks := message.FileBlocks()
	var sections int
	var actions int
	for _, block := range blocks {
		switch typed := block.(type) {
		case *slack.MarkdownBlock:
			t.Fatalf("file blocks contain unsupported markdown block: %+v", typed)
		case *slack.SectionBlock:
			sections++
			if typed.Text != nil && len(typed.Text.Text) > 2900 {
				t.Fatalf("file section exceeds Slack bound: %d", len(typed.Text.Text))
			}
		case *slack.ActionBlock:
			actions++
		}
	}
	if sections < 3 || actions != 1 {
		t.Fatalf("file blocks lost content or controls: sections=%d actions=%d", sections, actions)
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
		len(message.Context) != 0 {
		t.Fatalf("incident offer = %+v", message)
	}

	evidenceOffer := EvidenceResponseWithIncidentOffer(
		"Production is degraded.",
		[]core.Evidence{{Claim: "Errors are elevated."}},
		[]core.Coverage{{Layer: "application", Status: "degraded"}},
		"slack-source-2",
		NewSanitizer(12000),
	)
	if len(evidenceOffer.Context) != 0 || len(evidenceOffer.Actions) != 1 {
		t.Fatalf("evidence incident offer has redundant footer: %+v", evidenceOffer)
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
		offer.Actions[0].Label != "Start task" ||
		!strings.Contains(offer.Actions[0].Confirm, "edit, test, and commit") ||
		!strings.Contains(offer.Actions[0].Confirm, "Emisar (`emisar`)") ||
		len(offer.Context) != 0 {
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
	if !strings.Contains(offer.Actions[0].Confirm, "isolated") ||
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
	stalePublication := core.Publication{
		State: "stale", PRNumber: 42, PRURL: "https://github.example/pull/42",
	}
	stale := IncidentCardWithPublication(task, "Emisar", nil, true, stalePublication)
	if !slices.ContainsFunc(stale.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR && action.Label == "Update draft PR"
	}) || !slices.ContainsFunc(stale.Actions, func(action Action) bool {
		return action.ID == ActionViewPR && action.URL == stalePublication.PRURL
	}) || !strings.Contains(strings.Join(stale.Sections, "\n"), "needs an update") {
		t.Fatalf("stale task lacks update state: %+v", stale)
	}
	delivery := WithEngineeringTaskDelivery(
		ConversationResponse("Done.", NewSanitizer(12000)), task, true, stalePublication,
	)
	if !slices.ContainsFunc(delivery.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR && action.Label == "Update draft PR"
	}) || strings.Contains(strings.Join(delivery.Context, "\n"), "create a draft PR") {
		t.Fatalf("stale task delivery offered a new PR: %+v", delivery)
	}
}

func TestScheduleAndEngineeringTaskOffersComposeWithoutOverwriting(t *testing.T) {
	task := core.ScheduledTask{
		Title: "Daily deep health review", Prompt: "Check current infrastructure health.",
		Repository: "tenant-infra",
	}
	message := WithScheduleOffer(
		ConversationResponse("I can set up both parts.", NewSanitizer(12000)),
		task,
		`{"version":1}`,
		"Every day at 09:00 America/Merida",
	)
	message = WithEngineeringTaskOffer(
		message,
		"Create a reusable deep health runbook",
		"slack-source-compound",
		"Tenant infrastructure (`tenant-infra`)",
	)
	if len(message.Actions) != 2 ||
		message.Actions[0].ID != ActionRememberSchedule ||
		message.Actions[1].ID != ActionStartTask ||
		len(message.Sections) != 2 ||
		!strings.Contains(message.Sections[0], "Daily deep health review") ||
		!strings.Contains(message.Sections[1], "Create a reusable deep health runbook") ||
		len(message.Context) != 1 {
		t.Fatalf("compound offers = %+v", message)
	}
}

func TestIncidentAndSuggestedFixOffersCompose(t *testing.T) {
	message := ConciseEvidenceResponse(
		"The API is degraded and the decoder failure is bounded.",
		nil, nil, nil, NewSanitizer(12000),
	)
	message = WithIncidentOffer(message, "slack-source-diagnosis")
	message = WithSuggestedEngineeringTaskOffer(
		message,
		"Make rank decoding forward-compatible",
		"slack-source-diagnosis",
		"Tenant platform (`tenant-platform`)",
	)
	if len(message.Actions) != 2 ||
		message.Actions[0].ID != ActionOpenIncident ||
		message.Actions[1].ID != ActionStartTask ||
		message.Actions[1].Label != "Prepare code fix" ||
		len(message.Context) != 0 {
		t.Fatalf("combined diagnosis actions = %+v", message)
	}
	content := message.Text + "\n" + message.Markdown + "\n" + strings.Join(message.Sections, "\n")
	if strings.Contains(content, "Confirm the engineering task below") ||
		strings.Contains(content, "No code change has been made") ||
		!strings.Contains(content, "Make rank decoding forward-compatible") {
		t.Fatalf("combined diagnosis copy = %+v", message)
	}
}

func TestPublicationGateRecommendationIsAdvisory(t *testing.T) {
	message := WithRepositoryGateRecommendation(PublicationMessage(core.Publication{
		PRNumber: 42,
		PRURL:    "https://github.example/owner/repository/pull/42",
	}, false))
	if message.Header != "Draft PR ready" ||
		!strings.Contains(strings.Join(message.Context, "\n"), "add `gate:`") ||
		!slices.ContainsFunc(message.Actions, func(action Action) bool {
			return action.ID == ActionCheckDelivery && action.Label == "Check delivery"
		}) {
		t.Fatalf("ungated publication message = %+v", message)
	}
}

func TestIncompleteValidationWarningKeepsDraftPublicationActionable(t *testing.T) {
	message := WithIncompleteValidationWarning(PublicationMessage(core.Publication{
		PRNumber: 43,
		PRURL:    "https://github.example/owner/repository/pull/43",
	}, false))
	context := strings.Join(message.Context, "\n")
	if message.Header != "Draft PR ready" ||
		!strings.Contains(context, "Validation warning") ||
		!strings.Contains(context, "GitHub checks") ||
		!slices.ContainsFunc(message.Actions, func(action Action) bool {
			return action.ID == ActionViewPR && action.Label == "Open PR"
		}) {
		t.Fatalf("incomplete validation publication message = %+v", message)
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
		!strings.Contains(strings.Join(message.Sections, "\n"), "paused `nomad.alloc_restart` before it ran") ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "2026-07-28 06:30 UTC") ||
		!strings.Contains(strings.Join(message.Context, "\n"), "Approval happens only in Emisar") {
		t.Fatalf("approval card copy = %+v", message)
	}
	if len(message.Fields) != 0 {
		t.Fatalf("approval metadata must use a full-width layout: %+v", message.Fields)
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
	renderedMessage := NewSanitizer(30000).Message(message)
	rendered, err := json.Marshal(renderedMessage.Blocks())
	if err != nil {
		t.Fatalf("marshal approval Block Kit: %v", err)
	}
	if strings.Contains(strings.Join(renderedMessage.Sections, "\n"), "**") ||
		strings.Contains(string(rendered), "<!date^") {
		t.Fatalf("approval Block Kit contains incompatible Slack markup: %s", rendered)
	}
}

func TestEmisarApprovalCardSupportsCurrentConversationWithoutIncident(t *testing.T) {
	message := WithEmisarApproval(
		ConciseEvidenceResponse(
			"Emisar paused the requested change for approval.", nil, nil, nil,
			NewSanitizer(30000),
		),
		core.EmisarApproval{
			RequestID: "apr_shared", RunID: "run_shared", OperationID: "op_shared",
			ActionID: "bunny.pull_zone.update", PackRef: "bunny@1#sha256:abc",
			RunnerRef: "prod~abc", Status: "pending_approval",
			ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_shared",
			ExpiresAt:   time.Date(2099, 8, 1, 0, 0, 0, 0, time.UTC),
		},
	)
	sections := strings.Join(message.Sections, "\n")
	if !strings.Contains(sections, "update this card automatically") ||
		strings.Contains(sections, "pinned card") || len(message.Actions) != 1 ||
		message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_shared" {
		t.Fatalf("shared approval card = %+v", message)
	}
}

func TestEmisarApprovalStateMessagesExplainProgressAndCompletion(t *testing.T) {
	approval := core.EmisarApproval{
		RequestID: "apr_state", RunID: "run_state", ActionID: "service.enable",
		RunnerRef: "prod~abc", Status: "running",
		RunURL: "https://emisar.dev/app/acme/runs/run_state",
	}
	running := EmisarApprovalStateMessage(approval, false)
	if running.Header != "Emisar is running the approved action" ||
		!strings.Contains(strings.Join(running.Sections, "\n"), "keep using Slack") ||
		len(running.Actions) != 1 || running.Actions[0].Label != "Open run in Emisar" {
		t.Fatalf("running approval state = %+v", running)
	}
	approval.Status = "success"
	completed := EmisarApprovalStateMessage(approval, true)
	if completed.Header != "Emisar action completed" ||
		!strings.Contains(strings.Join(completed.Sections, "\n"), "concise follow-up") ||
		!strings.Contains(strings.Join(completed.Context, "\n"), "authoritative") {
		t.Fatalf("completed approval state = %+v", completed)
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
		message.Context[0] != "Details saved: 1 finding and 1 system area checked." {
		t.Fatalf("routine reply evidence summary = %+v", message.Context)
	}
}

func TestBlockedAssessmentExplainsWhatStoppedAndHowToContinue(t *testing.T) {
	message := WithBlockedAssessment(
		ConciseEvidenceResponse(
			"Core infrastructure is available, but customer impact is not verified.",
			nil,
			nil,
			nil,
			NewSanitizer(12000),
		),
		"The configured SLO source could not be read.",
		[]string{"Current availability and error-budget consumption"},
		[]string{"Queried the configured monitoring connector; access was denied"},
		"Grant the monitoring account read access, then retry the assessment",
		NewSanitizer(12000),
	)
	context := strings.Join(message.Context, "\n")
	for _, want := range []string{
		"Blocked:",
		"Next:",
		"Grant the monitoring account read access",
	} {
		if !strings.Contains(context, want) {
			t.Fatalf("blocked assessment lacks %q: %+v", want, message)
		}
	}
	if len(message.Sections) != 0 {
		t.Fatalf("blocked assessment repeated its typed ledger in sections: %+v", message)
	}
}

func TestEvidenceSummaryUsesNaturalCoveragePlural(t *testing.T) {
	message := ConciseEvidenceResponse(
		"Summary",
		[]core.Evidence{{Claim: "one"}, {Claim: "two"}},
		[]core.Coverage{{Layer: "host"}, {Layer: "runtime"}, {Layer: "application"}},
		nil,
		NewSanitizer(12000),
	)
	if len(message.Context) != 1 ||
		message.Context[0] != "Details saved: 2 findings and 3 system areas checked." {
		t.Fatalf("evidence summary = %+v", message.Context)
	}
}

// What an operator sees when Responder could not read its own model's result.
//
// The rule this pins: a person waiting on an incident is never shown an
// internal error or internal vocabulary. They did not ask about a JSON envelope
// and cannot act on one. They need to know what survived, that nothing changed,
// and what to do next.
//
// This replaced a test that required the phrases "Coop completed the agent
// turn" and "Result needs a clean summary" — both of which describe Responder's
// plumbing rather than the operator's situation.
func TestAgentReportFailureSpeaksToTheOperatorNotAboutTheParser(t *testing.T) {
	message := AgentReportFailureMessage()
	content := message.Text + "\n" + message.Header + "\n" +
		strings.Join(message.Sections, "\n") + "\n" + strings.Join(message.Context, "\n")

	for _, leak := range []string{
		"json:", "unmarshal", "unknown field", "parse", "schema", "envelope",
		"structured report format", "Coop completed", "nil", "error:",
	} {
		if strings.Contains(strings.ToLower(content), strings.ToLower(leak)) {
			t.Errorf("operator-facing failure message contains internal detail %q:\n%s", leak, content)
		}
	}

	for _, required := range []string{
		"preserved", // what survived
		"Reply",     // what to do
		"nothing was lost",
	} {
		if !strings.Contains(content, required) {
			t.Errorf("failure message does not tell the operator %q:\n%s", required, content)
		}
	}

	// The safety statement stays: no merge, push, signing or deployment, and no
	// raw transcript. That is the one piece of plumbing an operator does care
	// about, because it bounds what could have happened while they were away.
	if !strings.Contains(content, "No merge, push, signing, or deployment occurred") {
		t.Error("failure message dropped the statement bounding what happened")
	}

	// It takes no detail argument at all now. The parameter existed "for
	// callers with something operator-facing to add", and the only thing any
	// caller ever had was the parse error.
}

func TestTimelineHandoffAndPostmortemRemainEvidenceGrounded(t *testing.T) {
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Checkout latency",
		Status: core.IncidentActive, Workflow: core.WorkflowParked,
		FiringCount: 1, SignalCount: 2, Severity: "high",
		CreatedAt: time.Date(2026, 7, 27, 19, 0, 0, 0, time.UTC),
		ClosedAt:  time.Date(2026, 7, 27, 21, 0, 0, 0, time.UTC),
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
	record := core.RemediationRecord{
		Incident: incident, Events: events, Evidence: evidence, Coverage: coverage,
		Approvals: []core.EmisarApproval{{
			RunID: "run_1", ActionID: "service.restart", RunnerRef: "runner_1",
			Status: "succeeded", CreatedAt: time.Date(2026, 7, 27, 20, 5, 0, 0, time.UTC),
			TerminalAt: time.Date(2026, 7, 27, 20, 10, 0, 0, time.UTC),
		}},
	}
	timeline := TimelineMessage(record)
	handoff := HandoffMessage(record)
	postmortem := PostmortemDraft(record)
	if !strings.Contains(timeline.Markdown, "Live state checked") ||
		!strings.Contains(timeline.Markdown, "Emisar run succeeded") ||
		!strings.Contains(handoff.Markdown, "Shift handoff") ||
		!strings.Contains(handoff.Markdown, "## Evidence") ||
		!strings.Contains(postmortem.Markdown, "Post-incident draft") ||
		!strings.Contains(postmortem.Markdown, "2026-07-27 21:00 UTC") ||
		!strings.Contains(postmortem.Markdown, "service.restart") ||
		!strings.Contains(postmortem.Markdown, "Confirm root cause") ||
		!strings.Contains(
			strings.Join(postmortem.Context, "\n"),
			"does not invent impact, root cause, owners, or actions",
		) {
		t.Fatalf(
			"timeline=%+v\nhandoff=%+v\npostmortem=%+v",
			timeline, handoff, postmortem,
		)
	}
}

func TestOperationsHomeSummarizesWorkWithoutMarketingCopy(t *testing.T) {
	message := OperationsHome(1, 3, 1, 2, 1, 2, 1, 0, 0, 0, 2, 1, []core.Incident{{
		ID: "inc_1", Title: "API unavailable", Status: core.IncidentActive,
		Workflow: core.WorkflowInvestigating, ChannelID: "CINCIDENT",
		ChannelName: "ems-api", FiringCount: 1, SignalCount: 1,
	}}, []core.Commitment{{
		Title: "Verify rollout", State: core.CommitmentWorking,
		Status: "Checking live state", NextAction: "Deliver the result",
		ChannelID: "CINCIDENT",
	}}, nil, nil, nil, nil)
	content := message.Text + "\n" + message.Markdown + "\n" +
		strings.Join(message.Sections, "\n") + "\n" +
		strings.Join(message.Context, "\n")
	for _, row := range message.Rows {
		content += "\n" + row.Text
	}
	for _, required := range []string{
		// The heading answers "is anything waiting for me?" rather than saying
		// "Needs attention" above a page the reader then has to search.
		"needs you",
		"API unavailable",
		"Verify rollout",
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
	if strings.Contains(content, "**") {
		t.Fatalf("memory offer uses non-Slack bold markup: %s", content)
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

func TestScheduleOfferAndDirectoryExplainExecutionBoundary(t *testing.T) {
	now := time.Now().UTC().Add(time.Hour)
	task := core.ScheduledTask{
		ID: "schedule_1", ChannelID: "COPS", ThreadTS: "100.1",
		Repository: "repo", Title: "Morning health report",
		Prompt:     "Check production health and summarize material changes.",
		Recurrence: "daily", LocalTime: "09:00", Timezone: "UTC",
		NextRunAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour), Enabled: true,
	}
	offer := WithScheduleOffer(ConversationResponse("I can do that.", NewSanitizer(12000)), task, `{"version":1}`, "Every day at 09:00 UTC")
	if len(offer.Actions) != 1 || offer.Actions[0].ID != ActionRememberSchedule ||
		!strings.Contains(strings.Join(offer.Context, " "), "cannot reuse an old approval") {
		t.Fatalf("schedule offer = %+v", offer)
	}
	directory := ScheduleDirectoryMessage([]core.ScheduledTask{task})
	ids := make([]string, 0, len(directory.Actions))
	for _, action := range directory.Actions {
		ids = append(ids, action.ID)
	}
	for _, want := range []string{ActionToggleSchedule, ActionRunSchedule, ActionEditSchedule, ActionDeleteSchedule} {
		if !slices.Contains(ids, want) {
			t.Fatalf("schedule directory actions = %v, missing %s", ids, want)
		}
	}
	completed := task
	completed.Enabled = false
	completed.NextRunAt = time.Time{}
	completedDirectory := ScheduleDirectoryMessage([]core.ScheduledTask{completed})
	for _, action := range completedDirectory.Actions {
		if action.ID == ActionToggleSchedule {
			t.Fatalf("completed one-shot schedule can be resumed: %+v", completedDirectory.Actions)
		}
	}
}

func TestScheduleOfferMakesFutureCommitmentConditional(t *testing.T) {
	task := core.ScheduledTask{
		ChannelID: "COPS", ThreadTS: "100.1", Repository: "repo",
		Title:  "Recheck cms-web after 24 hours",
		Prompt: "Run a fresh cms-web health check and report the result.",
	}
	message := WithScheduleOffer(
		ConversationResponse(
			"I’ll recheck cms-web in 24 hours and report here.",
			NewSanitizer(12000),
		),
		task,
		`{"version":1}`,
		"Once on Aug 3, 2026 at 19:18 UTC",
	)
	content := message.Text + "\n" + message.Markdown + "\n" +
		strings.Join(message.Sections, "\n") + "\n" +
		strings.Join(message.Context, "\n")
	for _, row := range message.Rows {
		content += "\n" + row.Text
	}
	if len(message.Actions) != 1 || message.Actions[0].ID != ActionRememberSchedule {
		t.Fatalf("schedule confirmation action = %+v", message.Actions)
	}
	if !strings.Contains(content, "Confirm the schedule below") ||
		!strings.Contains(content, "Nothing is scheduled yet") ||
		message.Text == "I’ll recheck cms-web in 24 hours and report here." {
		t.Fatalf("schedule offer retained an unconditional commitment: %+v", message)
	}

	unavailable := ScheduleOfferUnavailable(message)
	if len(unavailable.Actions) != 0 ||
		!strings.Contains(unavailable.Text, "nothing was scheduled") {
		t.Fatalf("invalid schedule offer = %+v", unavailable)
	}
}

func TestGuidanceMemoryUsesNaturalConfirmationAndManagementCopy(t *testing.T) {
	offer := core.MemoryOffer{
		Scope: "workspace", Subject: "fix_explanation_style", Predicate: "guidance",
		Value:      "Start with a simple summary before technical details.",
		Visibility: "operator", ExpiresIn: "90d",
	}
	message := WithMemoryOffer(
		ConversationResponse("Got it. I can remember that.", NewSanitizer(12000)),
		offer,
		`{"version":1}`,
		"workspace",
		"90 days",
	)
	content := strings.Join(message.Sections, "\n") + "\n" +
		strings.Join(message.Context, "\n")
	for _, expected := range []string{
		"Proposed guidance", "Start with a simple summary", "only you, across this workspace",
		"cannot start work", "Remember this",
	} {
		if !strings.Contains(content+"\n"+message.Actions[0].Label, expected) {
			t.Fatalf("guidance offer missing %q: %+v", expected, message)
		}
	}
	if strings.Contains(content, "**") || len(message.Actions) != 1 ||
		message.Actions[0].ID != ActionRememberMemory {
		t.Fatalf("guidance offer formatting/actions = %+v", message)
	}
	entry := core.MemoryEntry{
		ID: "mem_guidance", ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		SubjectKey: "fix_explanation_style", Predicate: "guidance",
		Value:          "Start with a simple summary before technical details.",
		VisibilityKind: "operator", VisibilityID: "UOPERATOR",
		ExpiresAt: time.Date(2026, 10, 30, 12, 0, 0, 0, time.UTC),
	}
	saved := MemorySavedMessage(entry, false)
	directory := MemoryDirectoryMessage([]core.MemoryEntry{entry})
	surface := saved.Text + "\n" + saved.Header + "\n" +
		strings.Join(saved.Sections, "\n") + "\n" +
		strings.Join(directory.Sections, "\n")
	for _, expected := range []string{
		"I'll remember", "Guidance remembered", "Guidance: fix explanation style",
	} {
		if !strings.Contains(surface, expected) {
			t.Fatalf("guidance management missing %q: %s", expected, surface)
		}
	}
}

func TestFailedEngineeringReviewOffersSameTaskRecovery(t *testing.T) {
	incident := core.Incident{
		ID: "task_123", WorkKind: core.WorkKindEngineeringTask,
	}
	message := ReviewMessage(
		incident,
		"*Readiness checks*\n• Repository gate: failed",
		false,
	)
	if message.Header != "Not ready for review" || len(message.Actions) != 2 ||
		message.Actions[0].ID != ActionPublishPR ||
		message.Actions[0].Value != incident.ID ||
		message.Actions[0].Label != "Retry draft PR" ||
		message.Actions[1].ID != ActionRepairReview ||
		message.Actions[1].Label != "Fix blocker" {
		t.Fatalf("failed review recovery = %+v", message)
	}
	if len(message.Context) != 1 ||
		!strings.Contains(message.Context[0], "Retry") {
		t.Fatalf("failed review context = %+v", message.Context)
	}
}

func TestMemoryHealthAndReviewCardsAreExplicit(t *testing.T) {
	now := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	entry := core.MemoryEntry{
		ID: "mem_1", ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
		SubjectKey: "plain_language", Predicate: "guidance",
		Value: "Start with plain language.", VisibilityKind: "workspace",
		VisibilityID: "TWORKSPACE", ExpiresAt: now.Add(30 * 24 * time.Hour),
	}
	health := MemoryHealthMessage([]core.MemoryEntry{entry}, []core.MemoryRollup{{
		ID: "dream_1", ScopeKind: "repository", ScopeKey: "repo",
		PeriodStart: now.Add(-7 * 24 * time.Hour), PeriodEnd: now,
		SourceCount: 3, State: core.AgentMemory{SituationSummary: "Prior deployment context."},
	}}, core.MemoryHealth{
		ExplicitActive: 1, ConversationSummaries: 12, Rollups: 4,
		PendingReviews: 1, LastDreamedAt: now,
	})
	if len(health.Actions) < 3 || health.Actions[0].ID != ActionReviewMemory ||
		!strings.Contains(strings.Join(health.Sections, "\n"), "Last consolidation") {
		t.Fatalf("health = %+v", health)
	}
	review := MemoryReviewMessage(core.MemoryReviewItem{
		ID: "review_1", Kind: "stale", Reason: "Not recently recalled.",
	}, []core.MemoryEntry{entry})
	if len(review.Actions) != 2 || review.Actions[0].ID != ActionKeepMemoryReview ||
		review.Actions[1].ID != ActionForgetMemoryReview ||
		!strings.Contains(strings.Join(review.Context, "\n"), "never changes memory") {
		t.Fatalf("review = %+v", review)
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
		"Proposed preference", "Health-check depth", "deep",
		"Nothing is saved yet", "cannot establish health",
	} {
		if !strings.Contains(preferenceContent, expected) {
			t.Fatalf("preference offer lacks %q: %+v", expected, preferenceMessage)
		}
	}
	location := preference
	location.Name = "response_location"
	location.Value = "prefer_thread"
	locationMessage := WithPreferenceOffer(
		ConversationResponse("Got it.", NewSanitizer(12000)),
		core.PreferenceOffer{
			Scope: "operator", Name: location.Name, Value: location.Value,
		},
		location,
		`{"version":1}`,
		"90 days",
	)
	locationContent := strings.Join(locationMessage.Sections, "\n") + "\n" +
		strings.Join(locationMessage.Context, "\n")
	for _, expected := range []string{
		"Reply location", "Prefer threads", "future Slack replies", "Remember this",
	} {
		if !strings.Contains(locationContent+"\n"+locationMessage.Actions[0].Label, expected) {
			t.Fatalf("location preference lacks %q: %+v", expected, locationMessage)
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

// Sanitizing a copy of a Message must not rewrite the caller's own slices.
