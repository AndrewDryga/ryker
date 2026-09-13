package slackui

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
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
	// Superseded: the stat line used to sit between the summary and the diff,
	// which is the one position a reader scrolling four hundred changed lines
	// passes without reading. It now leads the body — the renderer emits
	// Markdown before every context block, so first-line-of-Markdown is as
	// early as this fact can be placed — and "page" became "part", because the
	// window is a byte range and calling it a page invited the reading that
	// file 3 of 4 was on it. The offsets and the navigation values are
	// untouched, so routing is unchanged.
	//
	// This page carries no shape: the patch was fetched a page at a time, and
	// "N files" counted from bytes 7001-14000 would read exactly like "N files"
	// counted from the whole change.
	if !strings.HasPrefix(
		message.Markdown,
		"part 2 of 4 · bytes 7001-14000 of 25000 · snapshot `aaaaaaaaaaaa`\n\n",
	) ||
		strings.Contains(message.Markdown, "Patch page") ||
		strings.Contains(message.Markdown, "files ·") ||
		strings.Index(message.Markdown, "part 2 of 4") > strings.Index(message.Markdown, "```diff") ||
		!strings.Contains(message.Markdown, "+changed line") ||
		strings.Contains(message.Markdown, "The patch exceeded") ||
		len(message.Actions) != 4 ||
		message.Actions[0].ID != ActionChangesPrevious ||
		message.Actions[1].ID != ActionChangesNext ||
		message.Actions[2].ID != ActionChangesRefresh ||
		message.Actions[3].ID != ActionCloseDiff {
		t.Fatalf("large diff page = %+v", message)
	}

	// A diff fetched whole leads with what the change amounts to, which is the
	// question it was opened to answer. One page, so no part counter.
	incident.ChangesStat = "3 files · +48 −12"
	whole := ChangesMessage(incident, "*Committed (3)*", []byte("+one\n"), ChangesNavigation{
		Page: 1, Pages: 1, FirstByte: 0, LastByte: 5, TotalBytes: 5,
		RefreshValue: "refresh",
	})
	if !strings.HasPrefix(whole.Markdown, "*3 files · +48 −12* · bytes 1-5 of 5\n\n") {
		t.Fatalf("whole diff = %q", whole.Markdown)
	}
	// Close diff is on every page, because the way out should not depend on
	// which page you stopped reading.
	if last := whole.Actions[len(whole.Actions)-1]; last.ID != ActionCloseDiff ||
		last.Value != incident.ID || last.Label != "Close diff" {
		t.Fatalf("close control = %+v", last)
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
	// The header is the incident's name and the glyph. The "CRITICAL | "
	// prefix it used to carry moved into the state line, where severity sits
	// beside the signal count it qualifies instead of competing with the title.
	if card.Header != "🔴 "+incident.Title || len(card.Actions) != 2 {
		t.Fatalf("card = %+v", card)
	}
	if card.Stripe != StripeFailed {
		t.Fatalf("firing critical incident is not red: %q", card.Stripe)
	}
	if !strings.HasPrefix(card.Text, "Firing — ") {
		t.Fatalf("fallback does not lead with the state word: %q", card.Text)
	}
	if !strings.Contains(card.Text, "Severity critical") ||
		!strings.Contains(card.Text, "Ryker Investigating") ||
		!strings.Contains(card.Text, "2 of 3 signals firing") {
		t.Fatalf("fallback omits incident state: %q", card.Text)
	}
	if !strings.Contains(card.Sections[0], "Critical") ||
		!strings.Contains(card.Sections[0], "2 of 3 signals firing") {
		t.Fatalf("state line omits severity or signal count: %q", card.Sections[0])
	}
	if len(card.Sections) != 2 || !strings.Contains(card.Sections[1], "Checkout requests") ||
		!slices.Contains(card.Context, "Alert source: <https://grafana.example.test/alerting/1|Open grafana.example.test>") {
		t.Fatalf("card omits alert evidence: %+v", card)
	}
	// The fields grid stated a count and never the names. The strip states
	// which signal, which is the question the count stood in front of.
	if len(card.Ledger) != 1 || card.Ledger[0].Glyph != "●" || len(card.Fields) != 0 {
		t.Fatalf("signal strip did not replace the fields grid: %+v", card)
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
	// One action block owns both the card controls and its single overflow menu.
	// Work record opens a second-level directory for the four durable reads, so
	// the primary card never presents two indistinguishable ellipses.
	//
	// Stop is neutral now. It preserves the fork and the queued work, so it
	// destroys nothing, and red is reserved for the controls that do — a red
	// button on every running card is how red stops meaning anything.
	if actionBlocks != 1 || len(card.Overflow) == 0 ||
		card.Overflow[0].ID != ActionRecordDirectory ||
		card.Overflow[0].Label != "Work record" ||
		card.Actions[0].ID != ActionStop ||
		card.Actions[0].Label != "Stop current run" ||
		card.Actions[0].Style != "" || card.Actions[0].Confirm == "" {
		t.Fatalf("card lacks compact safe stop action: %+v", card.Actions)
	}
}

func TestIncidentWorkspacePreparationRemainsRykerOwned(t *testing.T) {
	incident := core.Incident{
		ID: "incident_preparing", Title: "Scrape target down", Severity: "critical",
		Status: core.IncidentActive, Workflow: core.WorkflowHolding,
		SignalCount: 1, FiringCount: 1,
		LastError: "branch session lacks read-only repository authority; no model turn started",
		CreatedAt: time.Now().Add(-time.Minute),
	}
	card := IncidentCardWithPublication(
		incident, "blitz-core", nil, false, true,
		core.Publication{}, core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	body, err := Encode(card)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, want := range []string{"Workspace preparation", "nothing needed from you", "Ryker will retry automatically"} {
		if !strings.Contains(text, want) {
			t.Fatalf("preparation card lost %q: %s", want, text)
		}
	}
	for _, forbidden := range []string{"Action needed", "Needs you", "reply here"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("preparation card assigned operator work via %q: %s", forbidden, text)
		}
	}
}

func TestReadOnlyWorkspaceNoticeNamesItsAutomaticRetryTime(t *testing.T) {
	retryAt := time.Date(2026, 8, 18, 16, 5, 0, 0, time.UTC)
	message := ReadOnlyWorkspaceBlocked("blitz-core", retryAt)
	body, err := Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	if !strings.Contains(text, "Ryker will retry automatically at 16:05 UTC") ||
		strings.Contains(text, "circuit breaker") {
		t.Fatalf("read-only preparation notice = %s", text)
	}
}

func TestHistoricalWorkspaceNoticeNamesItsAutomaticRetryTime(t *testing.T) {
	retryAt := time.Date(2026, 8, 18, 16, 5, 0, 0, time.UTC)
	message := WorkspacePreparationBlocked("blitz-core", retryAt)
	body, err := Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, want := range []string{"finish workspace preparation", "Ryker will retry automatically at 16:05 UTC"} {
		if !strings.Contains(text, want) {
			t.Fatalf("historical preparation notice lost %q: %s", want, text)
		}
	}
	if strings.Contains(text, "refreshing") {
		t.Fatalf("historical key exhaustion was called a refresh: %s", text)
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
			Confirm: "Ask Ryker to inspect current evidence and post a concise update?",
		},
		{ID: ActionChanges, Label: "View diff", Value: incident.ID},
		{
			ID: ActionReview, Label: "Run readiness check", Value: incident.ID,
			Confirm: "Compare the isolated changes with the current repository, rebase state, validation, and policy gates?",
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
		message.Actions[0].Confirm != "Create a dedicated incident room and isolated investigation workspace from this message?" ||
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
	content := cardText(card)
	// "*Engineering task: Open | Ryker: Waiting for input*" and the full
	// "Requested change" dump are both gone. The fallback leads with the state
	// word, and the ask is a two-line quote with a way to read the rest —
	// the request is reference material and was the tallest block on the card.
	if !strings.HasPrefix(card.Text, "Parked — ") ||
		!strings.Contains(content, "Update infra/ with required packs.") ||
		strings.Contains(content, "alert signals") ||
		strings.Contains(content, "Severity") ||
		len(card.Actions) == 0 ||
		card.Actions[len(card.Actions)-1].Label != "Close task" {
		t.Fatalf("engineering task card = %+v", card)
	}
	// The whole request leads the card; Slack may fold that section without
	// hiding the progress instrument below it.
	if len(card.Sections) == 0 || !strings.HasPrefix(card.Sections[0], "*The request*") {
		t.Fatalf("the request is not first: %+v", card.Sections)
	}
	if !strings.Contains(offer.Actions[0].Confirm, "isolated") {
		t.Fatalf("engineering task thread copy = offer:%+v", offer)
	}
	// The "*Delivery state*\nThe isolated task has no code changes…" paragraph
	// is superseded by the ledger: an unstarted step states the same fact as a
	// position instead of as a paragraph the reader has to place in a sequence.
	if position, steps := ledgerMarker(card.Ledger); position != 2 || steps != 6 {
		t.Fatalf("zero-change task ledger = step %d of %d: %+v", position, steps, card.Ledger)
	}
	task.Workflow = core.WorkflowBlocked
	blocked := IncidentCard(task, "Emisar", nil, false)
	blockedContent := blocked.Header + "\n" + blocked.Text + "\n" + blocked.Markdown + "\n" +
		strings.Join(blocked.Sections, "\n") + "\n" + strings.Join(blocked.Context, "\n")
	// "Needs teammate action" existed to avoid the incident card's "Needs
	// operator action" authority copy. Both are replaced by one custody word
	// that names neither role, so neither can be the wrong one.
	if !strings.Contains(blockedContent, "Needs you") ||
		strings.Contains(blockedContent, "Needs operator action") ||
		blocked.Stripe != StripeNeedsYou {
		t.Fatalf("blocked engineering task uses incident authority copy: %+v", blocked)
	}
	task.Workflow = core.WorkflowParked
	changed := IncidentCardWithPublication(
		task, "Emisar", nil, true, true, core.Publication{},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if !slices.ContainsFunc(changed.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR && action.Label == "Create draft PR"
	}) {
		t.Fatalf("changed task lacks publication action: %+v", changed.Actions)
	}
	published := IncidentCardWithPublication(
		task, "Emisar", nil, true, true, core.Publication{
			State: "published", PRNumber: 42, PRURL: "https://github.example/pull/42",
		},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	// The "*PR ready*\n<link>. The reviewed task tree is now durable…"
	// paragraph is superseded by the state word and the ledger's Draft PR step.
	if !slices.ContainsFunc(published.Actions, func(action Action) bool {
		return action.ID == ActionViewPR && action.URL == "https://github.example/pull/42"
	}) || !strings.HasPrefix(published.Text, "PR open — ") ||
		!strings.Contains(ledgerText(published.Ledger), "#42") {
		t.Fatalf("published task lacks durable PR state: %+v", published)
	}
	mergedTask := task
	mergedTask.LatestUpdate = "The follow-up apply exposed one more hostname to stage."
	mergedPublication := core.Publication{
		State: core.PublicationPublished, PRNumber: 529,
		PRURL: "https://github.example/pull/529",
	}
	mergedFollowup := core.PublicationFollowup{
		PRState: "merged", ChecksState: "passing", MergeSHA: "b3b6bb4e50119ba6",
	}
	merged := IncidentCardWithPublication(
		mergedTask, "Emisar", nil, true, true, mergedPublication, mergedFollowup,
		core.PublicationLifecycleEvent{
			ID: "delivery-1", Kind: "terraform", State: "failed",
			Summary: "Terraform apply failed for the next staged hostname.",
		},
	)
	mergedText := merged.Text + "\n" + strings.Join(merged.Sections, "\n")
	if !strings.Contains(mergedText, "PR merged") ||
		!strings.Contains(mergedText, "b3b6bb4e501") ||
		!strings.Contains(mergedText, mergedTask.LatestUpdate) ||
		!strings.Contains(mergedText, "Terraform apply failed") {
		t.Fatalf("merged task card lost durable or work state: %+v", merged)
	}
	if slices.ContainsFunc(merged.Actions, func(action Action) bool {
		return action.ID == ActionReview || action.ID == ActionPublishPR || action.ID == ActionUpdate
	}) || !slices.ContainsFunc(merged.Actions, func(action Action) bool {
		return action.ID == ActionViewPR
	}) || !slices.ContainsFunc(merged.Actions, func(action Action) bool {
		return action.ID == ActionChanges
	}) {
		t.Fatalf("merged task actions = %+v", merged.Actions)
	}
	mergedReply := WithEngineeringTaskDelivery(
		ConversationResponse("I staged the next hostname.", NewSanitizer(12000)),
		mergedTask, true, mergedPublication, mergedFollowup,
	)
	// Superseded: this used to assert a context paragraph explaining that the
	// PR was already merged and a new task was needed. WithEngineeringTaskDelivery
	// no longer writes paragraphs — on the task-card path taskcard.Update keeps
	// only a message's words and drops its buttons, so the paragraph was the
	// half that survived and the controls were the half that mattered. The task
	// card states the merged state on its own ledger; this decorator now
	// contributes controls and nothing else, and offers no publish control into
	// a PR that can no longer be published into.
	if slices.ContainsFunc(mergedReply.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR || action.ID == ActionReview
	}) || len(mergedReply.Context) != 0 ||
		!slices.ContainsFunc(mergedReply.Actions, func(action Action) bool {
			return action.ID == ActionChanges
		}) {
		t.Fatalf("merged task follow-up delivery = %+v", mergedReply)
	}
	for _, state := range []struct {
		name     string
		session  string
		activeID string
	}{
		{name: "starting"},
		{name: "active", session: "ses_1", activeID: "turn_1"},
	} {
		stateTask := task
		stateTask.CoopSessionID = state.session
		stateTask.ActiveTurnID = state.activeID
		stateCard := IncidentCardWithPublication(
			stateTask, "Emisar", nil, false, false, core.Publication{
				State: core.PublicationPublished, PRNumber: 42,
				PRURL: "https://github.example/pull/42",
			},
			core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
		)
		if !slices.ContainsFunc(stateCard.Actions, func(action Action) bool {
			return action.ID == ActionViewPR
		}) {
			t.Fatalf("%s existing-PR task lost Open PR: %+v", state.name, stateCard.Actions)
		}
	}
	stalePublication := core.Publication{
		State: "stale", PRNumber: 42, PRURL: "https://github.example/pull/42",
	}
	stale := IncidentCardWithPublication(
		task, "Emisar", nil, true, true, stalePublication,
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if slices.ContainsFunc(stale.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR
	}) || !slices.ContainsFunc(stale.Actions, func(action Action) bool {
		return action.ID == ActionViewPR && action.URL == stalePublication.PRURL
	}) || !strings.Contains(ledgerText(stale.Ledger), "needs update") ||
		!strings.HasPrefix(stale.Text, "Updating PR — ") {
		// "*PR needs an update*\nThe task changed after…" is now the Draft PR
		// step's detail: the same fact, on the step it is about.
		t.Fatalf("stale task lacks update state: %+v", stale)
	}
	delivery := WithEngineeringTaskDelivery(
		ConversationResponse("Done.", NewSanitizer(12000)), task, true, stalePublication,
		core.PublicationFollowup{},
	)
	if slices.ContainsFunc(delivery.Actions, func(action Action) bool {
		return action.ID == ActionPublishPR
	}) || len(delivery.Context) != 0 {
		t.Fatalf("stale task delivery required a manual PR update: %+v", delivery)
	}
	for _, progress := range []struct {
		state string
		text  string
		prURL string
	}{
		// Publication progress used to be a paragraph per state. It is now a
		// detail on the ledger step it belongs to, so the reader sees which
		// step is running instead of an adjective they have to place.
		{state: "reviewing", text: "working"},
		{state: "publishing", text: "publishing", prURL: "https://github.example/pull/42"},
		{state: "retrying", text: "retrying"},
	} {
		card := IncidentCardWithPublication(
			task, "Emisar", nil, false, false, core.Publication{
				State: core.PublicationState(progress.state), PRNumber: 42, PRURL: progress.prURL,
				LastError: "temporary Coop error",
			},
			core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
		)
		if !strings.Contains(ledgerText(card.Ledger), progress.text) {
			t.Fatalf("%s card lacks progress: %+v", progress.state, card)
		}
		if !strings.HasPrefix(card.Text, "Working — ") || card.Stripe != StripeWorking {
			t.Fatalf("%s card does not read as Emisar's turn: %q %q",
				progress.state, card.Text, card.Stripe)
		}
		for _, action := range card.Actions {
			if slices.Contains([]string{
				ActionUpdate, ActionReview, ActionPublishPR, ActionResolve,
			}, action.ID) {
				t.Fatalf("%s card retained conflicting action %+v", progress.state, action)
			}
		}
		if !slices.ContainsFunc(card.Actions, func(action Action) bool {
			return action.ID == ActionChanges
		}) {
			t.Fatalf("%s card removed read-only diff: %+v", progress.state, card.Actions)
		}
		if progress.prURL != "" && !slices.ContainsFunc(card.Actions, func(action Action) bool {
			return action.ID == ActionViewPR && action.URL == progress.prURL
		}) {
			t.Fatalf("%s card removed existing PR: %+v", progress.state, card.Actions)
		}
	}
	existingProgress := IncidentCardWithPublication(
		task, "Emisar", nil, false, false, core.Publication{
			State: core.PublicationReviewing, PRNumber: 42,
			PRURL: "https://github.example/pull/42",
		},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if strings.Contains(existingProgress.Text, "Draft PR") ||
		!strings.Contains(existingProgress.Text, "PR update readiness review") {
		t.Fatalf("existing PR fallback copy = %q", existingProgress.Text)
	}
	for _, state := range []struct {
		name     string
		workflow core.WorkflowState
	}{
		{name: "queued", workflow: core.WorkflowInvestigating},
		{name: "parked", workflow: core.WorkflowParked},
	} {
		stateTask := task
		stateTask.Workflow = state.workflow
		stateTask.ActiveTurnID = ""
		card := IncidentCardWithPublication(
			stateTask, "Emisar", nil, false, true, core.Publication{
				PRNumber: 42, PRURL: "https://github.example/pull/42",
			},
			core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
		)
		if !slices.ContainsFunc(card.Actions, func(action Action) bool {
			return action.ID == ActionViewPR
		}) {
			t.Fatalf("%s no-change task lost Open PR: %+v", state.name, card.Actions)
		}
	}
	failed := IncidentCardWithPublication(
		task, "Emisar", nil, false, false, core.Publication{
			State: "failed", LastError: "GitHub rejected the branch update",
			PRNumber: 42, PRURL: "https://github.example/pull/42",
		},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if !strings.Contains(ledgerText(failed.Ledger), "failed") ||
		!strings.Contains(strings.Join(failed.Sections, "\n"), "Retry PR update") ||
		!slices.ContainsFunc(failed.Actions, func(action Action) bool {
			return action.ID == ActionPublishPR && action.Label == "Retry PR update" &&
				strings.Contains(action.Confirm, "update PR #42")
		}) || !slices.ContainsFunc(failed.Actions, func(action Action) bool {
		return action.ID == ActionViewPR && action.URL == "https://github.example/pull/42"
	}) {
		t.Fatalf("failed task lacks recovery state: %+v", failed)
	}
	emptyFailure := IncidentCardWithPublication(
		task, "Emisar", nil, false, true, core.Publication{
			State:     core.PublicationFailed,
			LastError: "The isolated task has no code changes to publish.",
		},
		core.PublicationFollowup{}, core.PublicationLifecycleEvent{},
	)
	if !strings.Contains(strings.Join(emptyFailure.Sections, "\n"), "Add or restore") ||
		slices.ContainsFunc(emptyFailure.Actions, func(action Action) bool {
			return action.ID == ActionPublishPR || action.ID == ActionChanges
		}) {
		t.Fatalf("confirmed empty publication offered impossible retry: %+v", emptyFailure)
	}
}

func TestScheduleAndEngineeringTaskOffersComposeWithoutOverwriting(t *testing.T) {
	task := core.ScheduledTask{
		Title: "Daily deep health review", Prompt: "Check current infrastructure health.",
		Repository: "blitz-infra",
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
		"Blitz infrastructure (`blitz-infra`)",
	)
	// Supersedes the flat-Actions form: the schedule's confirmation now sits on
	// the proposal row it confirms, and the task offer keeps the card's own
	// button, so composition means both survive in their own place.
	if len(message.Rows) != 1 || len(message.Rows[0].Actions) != 1 ||
		message.Rows[0].Actions[0].ID != ActionRememberSchedule ||
		!strings.Contains(message.Rows[0].Text, "Daily deep health review") {
		t.Fatalf("schedule proposal row = %+v", message)
	}
	if len(message.Actions) != 1 || message.Actions[0].ID != ActionStartTask ||
		len(message.Sections) != 1 ||
		!strings.Contains(message.Sections[0], "Create a reusable deep health runbook") ||
		len(message.Context) != 1 {
		t.Fatalf("compound offers = %+v", message)
	}
}

func TestIncidentAndSuggestedFixOffersCompose(t *testing.T) {
	message := ConciseEvidenceResponse(
		"The API is degraded and the decoder failure is bounded.",
		nil, nil, NewSanitizer(12000),
	)
	message = WithIncidentOffer(message, "slack-source-diagnosis")
	message = WithSuggestedEngineeringTaskOffer(
		message,
		"Make rank decoding forward-compatible",
		"slack-source-diagnosis",
		"Blitz platform (`blitz-platform`)",
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
	// Superseded: the header was "PR ready" over a section that said the PR was
	// ready. A receipt states its one fact once, in the section, and keeps no
	// header — the same rule the memory and preference receipts already follow.
	if message.Header != "" ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "Draft PR #42") ||
		message.Stripe != StripeDone ||
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
	if message.Header != "" ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "Draft PR #43") ||
		!strings.Contains(context, "Validation warning") ||
		!strings.Contains(context, "GitHub checks") ||
		!slices.ContainsFunc(message.Actions, func(action Action) bool {
			return action.ID == ActionViewPR && action.Label == "Open PR"
		}) {
		t.Fatalf("incomplete validation publication message = %+v", message)
	}
}

func TestTurnFailureAndManualHandoffPreserveTheNextStep(t *testing.T) {
	failure := TurnFailureMessage(core.Incident{}, "failed", "MCP request timed out.")
	// Superseded: what to do next moved out of the section that says what
	// survived and into the context line, so the three slots every failure card
	// now has — what stopped, what survived, what to do — are three separate
	// things a reader can find rather than two sentences sharing a paragraph.
	if failure.Header != "🛑 Investigation could not finish" ||
		failure.Stripe != StripeFailed ||
		!strings.Contains(strings.Join(failure.Sections, "\n"), "preserved") ||
		!strings.Contains(strings.Join(failure.Context, "\n"), "continue") {
		t.Fatalf("failure message = %+v", failure)
	}
	// Cancelling is not a failure. It is grey, and it says who did it.
	cancelled := TurnFailureMessage(core.Incident{}, "cancelled", "operator stopped the turn")
	if cancelled.Stripe != StripeIdle || cancelled.Header != "⏸ Stopped — you asked me to." {
		t.Fatalf("cancelled turn = %+v", cancelled)
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

func TestHelpExplainsTheNextMoveWithoutAControlLegend(t *testing.T) {
	message := HelpMessage(core.Incident{ID: "inc_1234567890abcdef"})
	content := helpSurface(t, message)
	for _, required := range []string{
		"no `@mention` needed",
		"work card above",
		"plain language",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("help lacks %q: %+v", required, message)
		}
	}
	for _, unwanted := range []string{
		"stop · diff · publish · close",
		"timeline · evidence · handoff",
		"never merge, sign, or deploy",
		"lease-protected branch",
	} {
		if strings.Contains(content, unwanted) {
			t.Fatalf("help still carries %q: %+v", unwanted, message)
		}
	}
}

// Help names the card, in every variant, because the card is what is there.
//
// It used to print four slash commands to the channel variant and the card to
// the thread variant, on the grounds that those commands resolved through
// FindIncidentByChannel — which filters work_scope = 'room', so typing one at a
// task thread could never select that task. The commands are gone now, so both
// variants say the same true thing.
func TestHelpNamesTheCardRatherThanACommand(t *testing.T) {
	message := HelpMessage(core.Incident{
		ID: "inc_1234567890abcdef", WorkKind: core.WorkKindEngineeringTask,
		WorkScope: core.WorkScopeThread,
	})
	content := helpSurface(t, message)
	for _, required := range []string{
		"*Just reply in this thread*",
		"work card above",
		"plain language",
	} {
		if !strings.Contains(content, required) {
			t.Fatalf("thread help lacks %q: %+v", required, message)
		}
	}
	if strings.Contains(content, "/responder") {
		t.Errorf("thread help advertises a slash command it cannot honour:\n%s", content)
	}
}

// Help is read in a hurry, so it says how to continue and points at the work
// card instead of encoding the card's current controls into a second legend.
func TestHelpIsOneClearInstructionAndOneDismissButton(t *testing.T) {
	for _, variant := range []struct {
		name     string
		incident core.Incident
		lead     string
	}{
		{
			name:     "incident room",
			incident: core.Incident{ID: "inc_1234567890abcdef"},
			lead:     "*Just reply in this channel*",
		},
		{
			name: "thread-scoped task",
			incident: core.Incident{
				ID: "inc_1234567890abcdef", WorkKind: core.WorkKindEngineeringTask,
				WorkScope: core.WorkScopeThread,
			},
			lead: "*Just reply in this thread*",
		},
	} {
		t.Run(variant.name, func(t *testing.T) {
			message := HelpMessage(variant.incident)
			if message.Header != "" {
				t.Errorf("help still opens with a header block: %q", message.Header)
			}
			if message.Stripe != StripeIdle {
				t.Errorf("help stripe = %q, want the idle colour %q", message.Stripe, StripeIdle)
			}
			if len(message.Sections) != 1 || !strings.Contains(message.Sections[0], variant.lead) {
				t.Fatalf("help prose = %+v, want %q", message.Sections, variant.lead)
			}
			if len(message.Ledger) != 0 {
				t.Errorf("help still renders the ambiguous control strip: %+v", message.Ledger)
			}
			if len(message.Context) != 0 {
				t.Errorf("help still renders a disclaimer: %+v", message.Context)
			}
			if len(message.Actions) != 0 || len(message.Fields) != 0 {
				t.Errorf("help grew controls or tiles: %+v %+v", message.Actions, message.Fields)
			}
			if !strings.HasPrefix(message.Text, "Help — ") {
				t.Errorf("fallback text = %q, want a one-sentence \"Help — …\"", message.Text)
			}

			// Three blocks: one instruction, then the standard temporary-card
			// divider and Dismiss row.
			blocks := message.Blocks()
			if len(blocks) != 3 {
				t.Fatalf("help renders %d blocks, want 3:\n%s", len(blocks), helpBlockTypes(blocks))
			}
			if types := helpBlockTypes(blocks); types != "section divider actions" {
				t.Errorf("help block order = %q, want the temporary-card exit last", types)
			}

			// The six sections are gone, and so is the second spelling the
			// paragraph advertised.
			content := helpSurface(t, message)
			for _, dead := range []string{
				"Lifecycle controls", "Automatic capacity", "Thread scope",
				"Read-only inspection", "Channel behavior", "!respond",
				"turn-limit", "How to work with Ryker",
			} {
				if strings.Contains(content, dead) {
					t.Errorf("the wall grew back — help still says %q:\n%s", dead, content)
				}
			}
			assertOnlyRealSubcommands(t, "help", content)
		})
	}
}

// helpSurface is everything the operator can read on the card: the prose, the
// rendered strip, and the boundary line.
func helpSurface(t *testing.T, message Message) string {
	t.Helper()
	parts := append([]string{}, message.Sections...)
	parts = append(parts, monospaceStrips(t, message)...)
	parts = append(parts, message.Context...)
	return strings.Join(parts, "\n")
}

func helpBlockTypes(blocks []slack.Block) string {
	types := make([]string, 0, len(blocks))
	for _, block := range blocks {
		types = append(types, string(block.BlockType()))
	}
	return strings.Join(types, " ")
}

func TestEvidenceResponseRendersCoverageAndCitations(t *testing.T) {
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
		NewSanitizer(30000),
	)
	for _, required := range []string{
		"## Coverage",
		"| scheduler | unhealthy | emisar status |",
		"## Evidence",
		"Allocation is terminal",
		"https://emisar.dev/operations/op-1",
	} {
		if !strings.Contains(message.Markdown, required) {
			t.Fatalf("evidence response lacks %q: %s", required, message.Markdown)
		}
	}
	if strings.Contains(message.Markdown, "token=secret") {
		t.Fatalf("evidence URL leaked query: %s", message.Markdown)
	}
	// An evidence reply carries no controls of its own. It offered Slack
	// approval buttons for a proposed operational action until that path was
	// deleted; Emisar owns approval, and its card adds its own link.
	if len(message.Actions) != 0 {
		t.Fatalf("evidence response controls = %+v", message.Actions)
	}
	// One Markdown block carrying the whole ledger, and no action block: the
	// three blocks this used to produce were the ledger plus the approve and
	// reject controls.
	blocks := message.Blocks()
	if len(blocks) != 1 {
		t.Fatalf("evidence response Block Kit = %+v", blocks)
	}
}

func TestEmisarApprovalCardLinksToAuthoritativeConsole(t *testing.T) {
	message := WithEmisarApproval(
		IncidentEvidenceResponse(
			"Emisar paused the requested restart for policy approval.",
			nil,
			nil,
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
	// Superseded: the header was "Approval required in Emisar" — a category —
	// and the action id was repeated in a section below it. The header names
	// the action now, which is safe because an action id is a typed identifier
	// Emisar assigned rather than model prose, and the section it displaced
	// stated the expiry in UTC. The expiry moved to a date token in context so
	// it renders in the reader's own timezone; see the token assertion below.
	if message.Header != "✋ Approval needed: nomad.alloc_restart" ||
		message.Stripe != StripeNeedsYou ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "Review the exact target") ||
		!strings.Contains(strings.Join(message.Context, "\n"), "2026-07-28 06:30 UTC") ||
		strings.Contains(strings.Join(message.Context, "\n"), "Approval happens only") {
		t.Fatalf("approval card copy = %+v", message)
	}
	// The decorator adds one section. The reply it decorates keeps its own —
	// the agent's account of why it wants this is the one sentence on the card
	// this package could not have written.
	if !strings.Contains(message.Markdown, "Emisar paused the requested restart for policy approval") {
		t.Fatalf("approval card clobbered the model reply: %+v", message)
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
	// Superseded on the date token: this used to assert no `<!date^` survived
	// rendering, which was true only because no card used slackDate yet. The
	// sanitizer preserves exactly the shape slackDate emits and neuters every
	// other bang form, and Slack resolves it client-side — so the token is now
	// the correct thing to find here, and its absence would mean the approval
	// expiry had gone back to asking its reader to convert from UTC.
	if strings.Contains(strings.Join(renderedMessage.Sections, "\n"), "**") {
		t.Fatalf("approval Block Kit contains incompatible Slack markup: %s", rendered)
	}
	// Asserted on the sanitized context rather than the marshalled blocks:
	// encoding/json escapes the token's angle bracket to \u003c, so a substring
	// search over the payload would answer no to a token that is present and
	// correct.
	if !strings.Contains(strings.Join(renderedMessage.Context, "\n"), "<!date^") ||
		!strings.Contains(string(rendered), "date_short_pretty") {
		t.Fatalf("approval Block Kit lost the client-local expiry: %s", rendered)
	}
}

func TestEmisarApprovalCardSupportsCurrentConversationWithoutIncident(t *testing.T) {
	message := WithEmisarApproval(
		ConciseEvidenceResponse(
			"Emisar paused the requested change for approval.", nil, nil,
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
	// The card keeps only the typed request identity and the approval link.
	content := cardText(message)
	if !strings.Contains(strings.Join(message.Context, "\n"), "Run `run_shared`") ||
		strings.Contains(content, "automatically") || len(message.Actions) != 1 ||
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
	// Superseded: the header gained its glyph, because colour never travels
	// alone and a notification strips the stripe.
	if running.Header != "⚙️ Emisar is running the approved action" ||
		!strings.Contains(strings.Join(running.Sections, "\n"), "keep using Slack") ||
		len(running.Actions) != 1 || running.Actions[0].Label != "Open run in Emisar" {
		t.Fatalf("running approval state = %+v", running)
	}
	approval.Status = "success"
	completed := EmisarApprovalStateMessage(approval, true)
	if completed.Header != "✅ Emisar action completed" ||
		!strings.Contains(strings.Join(completed.Sections, "\n"), "concise follow-up") ||
		!strings.Contains(strings.Join(completed.Context, "\n"), "Run `run_state`") {
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
		NewSanitizer(12000),
	)
	if strings.Contains(message.Markdown, "## Evidence") ||
		strings.Contains(message.Markdown, "## Coverage") ||
		strings.Contains(message.Markdown, "Nine declared packs are live") {
		t.Fatalf("routine reply dumped evidence ledger: %+v", message)
	}
	if len(message.Context) != 1 ||
		message.Context[0] != "Details saved: 1 evidence record and 1 system area." {
		t.Fatalf("routine reply evidence summary = %+v", message.Context)
	}
}

func TestConciseEvidenceResponseCountsMemoryChangesBesideEvidence(t *testing.T) {
	message := ConciseEvidenceResponse(
		"The correction is saved.",
		[]core.Evidence{{}, {}, {}},
		[]core.Coverage{{}},
		NewSanitizer(12000),
		2,
	)
	if len(message.Context) != 1 || message.Context[0] !=
		"Details saved: 3 evidence records, 1 system area, and 2 memory changes." {
		t.Fatalf("memory-aware details = %+v", message.Context)
	}
}

func TestBlockedAssessmentExplainsWhatStoppedAndHowToContinue(t *testing.T) {
	message := WithBlockedAssessment(
		ConciseEvidenceResponse(
			"Core infrastructure is available, but customer impact is not verified.",
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

// What the answer does not yet know reaches Slack, in one line, or it does not
// reach the operator at all.
//
// On 2026-08-16 a Traefik reply whose own ledger said cause_status "bounded",
// "no Go heap profile was captured ... unresolved" and "capture a Go heap
// profile at high RSS to settle whether growth beyond the connection count is a
// real leak" arrived in the channel as "Memory tracks load ... raise the cap and
// roll the job." Every one of those fields was typed and stored; none of them
// was rendered, because only a blocked completion had a context line. The
// operator read certainty the answer did not have.
func TestOpenQuestionsRenderAsOneContextLine(t *testing.T) {
	base := ConciseEvidenceResponse(
		"Memory tracks load; raise the cap and roll the job.", nil, nil, NewSanitizer(12000),
	)
	message := WithOpenQuestions(
		base,
		"bounded",
		"Traefik's working set scales with in-flight connection state, and the 4,096 MiB cap is now the binding constraint.",
		[]string{
			"No Go heap profile was captured, so the split between load-driven growth and a genuine leak is unresolved.",
		},
		[]string{
			"The va1-nomad-oom-risk alert cleared without any allocation recovering",
			"nomad-hvn04 has no reclaimable file cache left",
			"a third thing nobody has room to read",
		},
		"scheduled follow-up at 16:30 UTC",
		NewSanitizer(12000),
	)
	if len(message.Context) != len(base.Context)+1 {
		t.Fatalf("open questions are not one context line: %+v", message.Context)
	}
	line := message.Context[len(message.Context)-1]
	for _, want := range []string{
		"Still unknown: No Go heap profile was captured",
		"Next: scheduled follow-up at 16:30 UTC",
		" · ",
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("the open-questions line lacks %q: %q", want, line)
		}
	}
	// One, not the whole ledger. A context line an operator scrolls past is the
	// same as no context line, and every finding is still on the episode.
	if strings.Contains(line, "va1-nomad-oom-risk") ||
		strings.Contains(line, "nomad-hvn04") {
		t.Fatalf("findings repeated beside the more direct material gap: %q", line)
	}
	if strings.Contains(line, "a third thing nobody has room to read") {
		t.Fatalf("a third unexplained finding reached the reply: %q", line)
	}
	if len(message.Sections) != len(base.Sections) {
		t.Fatalf("open questions leaked into sections: %+v", message.Sections)
	}

	// An identified cause with a material gap still says the gap plainly.
	identified := WithOpenQuestions(
		base, "identified", "the 4,096 MiB cap", []string{"peak-hour request rate per node"},
		nil, "", NewSanitizer(12000),
	)
	if got := identified.Context[len(identified.Context)-1]; !strings.HasPrefix(got, "Still unknown: ") {
		t.Fatalf("an identified cause with a gap did not render plainly: %q", got)
	}

	// Nothing to say, nothing said. A reply that knows what it knows must not
	// grow an empty caveat line.
	quiet := WithOpenQuestions(base, "identified", "the cap", nil, nil, "", NewSanitizer(12000))
	if len(quiet.Context) != len(base.Context) {
		t.Fatalf("an answer with no open question grew a context line: %+v", quiet.Context)
	}

	// Bounded by the same 700 bytes every other context line is bounded by: the
	// gaps are model-authored prose and Slack renders the whole of it.
	long := WithOpenQuestions(
		base, "bounded", strings.Repeat("cause ", 400),
		[]string{strings.Repeat("gap ", 400)}, []string{strings.Repeat("finding ", 400)},
		strings.Repeat("check ", 400), NewSanitizer(12000),
	)
	if got := len(long.Context[len(long.Context)-1]); got > 700 {
		t.Fatalf("the open-questions line is %d bytes, over the 700-byte bound", got)
	}
}

func TestDecisionReadyFindingIsLabeledAsStillUnknown(t *testing.T) {
	message := WithOpenQuestions(
		Message{}, "", "", nil,
		[]string{"Rate limiting, protocol drift, and stale sessions remain possible."},
		"Run one paced-account canary.", NewSanitizer(12000),
	)
	if len(message.Context) != 1 ||
		!strings.Contains(message.Context[0], "Still unknown: Rate limiting") {
		t.Fatalf("decision-ready uncertainty is mislabeled: %+v", message.Context)
	}
}

// The Valorant reply ended with a second, machine-shaped conclusion beginning
// "Cause bounded, not identified" and repeating the finding under "Remaining
// uncertainty". The typed ledger already preserves those classifications; the
// Slack line should read like one teammate naming the remaining question.
func TestOpenQuestionContextUsesPlainHumanWording(t *testing.T) {
	message := WithOpenQuestions(
		Message{}, "bounded", "The failure is inside an unidentified client path.", nil,
		[]string{"The failed Flutter URL and affected build are still unknown."},
		"Inspect the Flutter HTTP wrapper and current fingerprint events.",
		NewSanitizer(12000),
	)
	if len(message.Context) != 1 {
		t.Fatalf("open question context = %+v", message.Context)
	}
	line := message.Context[0]
	if !strings.Contains(line, "Still unknown: The failed Flutter URL") ||
		!strings.Contains(line, "Next: Inspect the Flutter HTTP wrapper") {
		t.Fatalf("open question is not direct human wording: %q", line)
	}
	for _, label := range []string{"Cause bounded", "Remaining uncertainty", "Next check"} {
		if strings.Contains(line, label) {
			t.Fatalf("open question retained internal label %q: %q", label, line)
		}
	}
}

func TestEvidenceSummaryUsesNaturalCoveragePlural(t *testing.T) {
	message := ConciseEvidenceResponse(
		"Summary",
		[]core.Evidence{{Claim: "one"}, {Claim: "two"}},
		[]core.Coverage{{Layer: "host"}, {Layer: "runtime"}, {Layer: "application"}},
		NewSanitizer(12000),
	)
	if len(message.Context) != 1 ||
		message.Context[0] != "Details saved: 2 evidence records and 3 system areas." {
		t.Fatalf("evidence summary = %+v", message.Context)
	}
}

// What an operator sees when Ryker could not read its own model's result.
//
// The rule this pins: a person waiting on an incident is never shown an
// internal error or internal vocabulary. They did not ask about a JSON envelope
// and cannot act on one. They need to know what survived, that nothing changed,
// and what to do next.
//
// This replaced a test that required the phrases "Coop completed the agent
// turn" and "Result needs a clean summary" — both of which describe Ryker's
// plumbing rather than the operator's situation.
func TestAgentReportFailureSpeaksToTheOperatorNotAboutTheParser(t *testing.T) {
	message := AgentReportFailureMessage(core.Incident{})
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
		"workspace are preserved",
	} {
		if !strings.Contains(content, required) {
			t.Errorf("failure message does not tell the operator %q:\n%s", required, content)
		}
	}

	// It takes no detail argument at all now. The parameter existed "for
	// callers with something operator-facing to add", and the only thing any
	// caller ever had was the parse error.
}

func TestTriageFailureMessageDoesNotAcceptOrExposeRawErrors(t *testing.T) {
	message := TriageFailureMessage(false)
	// Superseded: the fallback led with "I couldn't finish this request", and
	// what to do next was a section. The fallback now leads with the header and
	// what stopped — the two things a notification has room for — and the next
	// step is the context line every failure card carries it in.
	if !strings.Contains(message.Text, "Request needs a retry") ||
		!strings.Contains(strings.Join(message.Context, " "), "Reply in this thread") {
		t.Fatalf("terminal triage failure = %+v", message)
	}
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
	if !strings.Contains(strings.Join(timeline.Sections, "\n"), "Live state checked") ||
		!strings.Contains(strings.Join(timeline.Sections, "\n"), "Emisar run succeeded") ||
		!strings.Contains(handoff.Markdown, "Shift handoff") ||
		!strings.Contains(handoff.Markdown, "## Evidence") ||
		!strings.Contains(postmortem.Markdown, "Post-incident draft") ||
		!strings.Contains(postmortem.Markdown, "2026-07-27 21:00 UTC") ||
		!strings.Contains(postmortem.Markdown, "service.restart") ||
		!strings.Contains(postmortem.Markdown, "Confirm root cause") {
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
		"",
		"channel",
		"30 days",
	)
	// Supersedes the "Proposed operational memory" heading: the proposal is the
	// row, quoted, so a label restating that it is a proposal is one line of
	// card spent saying nothing the reader cannot see.
	content := cardText(message)
	for _, expected := range []string{
		"old portal", "alias_of", "service:portal",
		"Saved memory guides investigations", "current evidence decides health",
	} {
		if !strings.Contains(content, expected) {
			t.Fatalf("memory offer missing %q: %+v", expected, message)
		}
	}
	actions := cardActions(message)
	if len(actions) != 1 || actions[0].ID != ActionRememberMemory ||
		actions[0].Confirm != "Save this channel memory for 30 days?" {
		t.Fatalf("memory offer action = %+v", actions)
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
	directoryActions := cardActions(directory)
	if len(directoryActions) != 1 ||
		directoryActions[0].ID != ActionForgetMemory ||
		!strings.Contains(cardText(directory), "COPS") {
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
	offerActions := cardActions(offer)
	if len(offerActions) != 1 || offerActions[0].ID != ActionRememberSchedule ||
		!strings.Contains(strings.Join(offer.Context, " "), "current policy") {
		t.Fatalf("schedule offer = %+v", offer)
	}
	// Every control still reaches the row it belongs to; two of them now sit in
	// that row's ⋯ rather than in a pile of four buttons per schedule.
	directory := ScheduleDirectoryMessage([]core.ScheduledTask{task})
	ids := cardActionIDs(directory)
	for _, want := range []string{ActionToggleSchedule, ActionRunSchedule, ActionEditSchedule, ActionDeleteSchedule} {
		if !slices.Contains(ids, want) {
			t.Fatalf("schedule directory actions = %v, missing %s", ids, want)
		}
	}
	completed := task
	completed.Enabled = false
	completed.NextRunAt = time.Time{}
	completedDirectory := ScheduleDirectoryMessage([]core.ScheduledTask{completed})
	if slices.Contains(cardActionIDs(completedDirectory), ActionToggleSchedule) {
		t.Fatalf("completed one-shot schedule can be resumed: %+v", completedDirectory.Rows)
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
	content := cardText(message)
	actions := cardActions(message)
	if len(actions) != 1 || actions[0].ID != ActionRememberSchedule {
		t.Fatalf("schedule confirmation action = %+v", actions)
	}
	if !strings.Contains(content, "Confirm the schedule below") ||
		strings.Contains(content, "I’ll recheck") ||
		message.Text == "I’ll recheck cms-web in 24 hours and report here." {
		t.Fatalf("schedule offer retained an unconditional commitment: %+v", message)
	}

	unavailable := ScheduleOfferUnavailable(message)
	// cardActions rather than Actions: the proposal it is replacing carries its
	// confirmation on a row now, so clearing only the bottom pile would have
	// deleted the sentence and left the button that agreed to it.
	if len(cardActions(unavailable)) != 0 || unavailable.Stripe != StripeIdle ||
		!strings.Contains(unavailable.Text, "Schedule could not be prepared") {
		t.Fatalf("invalid schedule offer = %+v", unavailable)
	}

	diagnosis := WithScheduleOffer(
		ConversationResponse("The rollout is healthy among the checked routes.", NewSanitizer(12000)),
		task, `{"version":1}`, "Once on Aug 3, 2026 at 19:18 UTC",
	)
	if !strings.Contains(cardText(diagnosis), "The rollout is healthy among the checked routes") {
		t.Fatalf("schedule offer discarded the answer it followed: %+v", diagnosis)
	}
}

func TestSeveralScheduleOffersUseOneAtomicConfirmation(t *testing.T) {
	now := time.Now().UTC().Add(24 * time.Hour)
	tasks := []core.ScheduledTask{
		{ChannelID: "COPS", ThreadTS: "100.1", Repository: "repo", Title: "Check Zot tomorrow", Prompt: "Check Zot logs for the fixed authentication error.", NextRunAt: now, Timezone: "UTC"},
		{ChannelID: "COPS", ThreadTS: "100.1", Repository: "repo", Title: "Check Zot in three days", Prompt: "Check Zot logs for the fixed authentication error.", NextRunAt: now.Add(48 * time.Hour), Timezone: "UTC"},
	}
	message := WithScheduleOffers(
		ConversationResponse("I can check both.", NewSanitizer(12000)), tasks,
		`{"version":3,"proposal_ids":["one","two"]}`,
		[]string{"Tomorrow at 15:00 CDT", "In three days at 15:00 CDT"},
	)
	content := cardText(message)
	actions := cardActions(message)
	if len(actions) != 1 || actions[0].Label != "Schedule all 2" ||
		!strings.Contains(actions[0].Confirm, "all 2") ||
		!strings.Contains(content, "Check Zot tomorrow") ||
		!strings.Contains(content, "Check Zot in three days") ||
		!strings.Contains(actions[0].Confirm, "as one set") {
		t.Fatalf("schedule batch card = %+v", message)
	}
	// One confirmation, and it is on the first proposal rather than repeated
	// down the card: the second row is a thing being agreed to, not a thing to
	// agree to separately.
	if len(message.Rows) != 2 || len(message.Rows[0].Actions) != 1 ||
		len(message.Rows[1].Actions) != 0 {
		t.Fatalf("batch confirmation is not attached to the first proposal: %+v", message.Rows)
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
		`{"version":1,"forever":true}`,
		"workspace",
		"90 days",
	)
	content := cardText(message)
	actions := cardActions(message)
	for _, expected := range []string{
		"Start with a simple summary", "only you, across this workspace",
		"Saved guidance shapes replies", "Remember this",
	} {
		if !strings.Contains(content+"\n"+actions[0].Label, expected) {
			t.Fatalf("guidance offer missing %q: %+v", expected, message)
		}
	}
	// Two buttons: the offer as proposed, and the same guidance with no expiry.
	// The second one is the whole answer to "I don't want a deadline" — an
	// operator who wants permanence should not have to talk the model into
	// re-proposing it. Both sit on the proposal row now.
	if strings.Contains(content, "**") || len(actions) != 2 ||
		actions[0].ID != ActionRememberMemory ||
		actions[1].ID != ActionRememberMemory ||
		actions[1].Label != "Remember permanently" ||
		actions[1].Value != `{"version":1,"forever":true}` {
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
	surface := cardText(saved) + "\n" + cardText(directory)
	// Supersedes the "Guidance remembered" header: the receipt is one line that
	// leads with the verb, so the header said it a second time.
	for _, expected := range []string{
		"I'll remember", "Remembered.", "Guidance: fix explanation style",
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
	// Superseded: the header gained its glyph and the card gained its stripe.
	// Salmon rather than red — a readiness check that says no has not failed,
	// it has answered, and the change it is about is intact behind it.
	if message.Header != "✋ Not ready for review" || message.Stripe != StripeNeedsYou ||
		len(message.Actions) != 0 {
		t.Fatalf("failed review recovery = %+v", message)
	}
	if len(message.Context) != 1 ||
		!strings.Contains(message.Context[0], "Correct the blocker on the task card") {
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
	// The review nudge leads the card and carries its own button; the health
	// counters became the context line under the header, where counters belong.
	if len(health.Rows) < 2 || len(health.Rows[0].Actions) != 1 ||
		health.Rows[0].Actions[0].ID != ActionReviewMemory ||
		!strings.Contains(strings.Join(health.Context, "\n"), "last consolidation") {
		t.Fatalf("health = %+v", health)
	}
	review := MemoryReviewMessage(core.MemoryReviewItem{
		ID: "review_1", Kind: "stale", Reason: "Not recently recalled.",
	}, []core.MemoryEntry{entry})
	if len(review.Actions) != 2 || review.Actions[0].ID != ActionKeepMemoryReview ||
		review.Actions[1].ID != ActionForgetMemoryReview || len(review.Context) != 0 {
		t.Fatalf("review = %+v", review)
	}
}

func TestBehaviorOfferCardsAndDirectoriesExplainScopeAndSafety(t *testing.T) {
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	preference := core.RykerPreference{
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
	preferenceContent := cardText(preferenceMessage)
	for _, expected := range []string{
		"Health-check depth", "deep", "You (operator preference)",
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
	locationContent := cardText(locationMessage)
	for _, expected := range []string{
		"Reply in threads", "relevant thread", "Use this reply style",
	} {
		if !strings.Contains(locationContent+"\n"+cardActions(locationMessage)[0].Label, expected) {
			t.Fatalf("location preference lacks %q: %+v", expected, locationMessage)
		}
	}
	if strings.Contains(preferenceContent, "**") ||
		strings.Contains(preferenceContent, preference.ScopeKey) ||
		!strings.Contains(preferenceContent, "You (operator preference)") {
		t.Fatalf("preference offer has invalid Slack formatting or scope: %s", preferenceContent)
	}
	preferenceActions := cardActions(preferenceMessage)
	if len(preferenceActions) != 1 ||
		preferenceActions[0].ID != ActionRememberPreference {
		t.Fatalf("preference offer action = %+v", preferenceActions)
	}
	preferenceDirectory := PreferenceDirectoryMessage(
		[]core.RykerPreference{preference},
	)
	preferenceSaved := PreferenceSavedMessage(preference, false)
	preferenceSurface := cardText(preferenceDirectory) + "\n" + cardText(preferenceSaved)
	// Supersedes the flat-Actions order: each preference's three controls sit
	// under the preference they act on, so the assertion is per row.
	if len(preferenceDirectory.Rows) != 1 ||
		len(preferenceDirectory.Rows[0].Actions) != 3 ||
		preferenceDirectory.Rows[0].Actions[0].ID != ActionTogglePreference ||
		preferenceDirectory.Rows[0].Actions[1].ID != ActionEditPreference ||
		preferenceDirectory.Rows[0].Actions[2].ID != ActionDeletePreference ||
		strings.Contains(preferenceSurface, "**") ||
		strings.Contains(preferenceSurface, preference.ScopeKey) ||
		!strings.Contains(preferenceSurface, "highest precedence") {
		t.Fatalf("preference controls = %+v", preferenceDirectory.Rows)
	}

	rule := core.StandingRule{
		ID: "rule_1", ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "app", Enabled: true, TriggerCount: 2,
		ActedCount: 1, QuietCount: 1, ExpiresAt: now,
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
	ruleContent := cardText(ruleMessage)
	for _, expected := range []string{
		"Review Terraform plans", "saved plan", "red flags",
		"This channel",
	} {
		if !strings.Contains(ruleContent, expected) {
			t.Fatalf("rule offer lacks %q: %+v", expected, ruleMessage)
		}
	}
	if strings.Contains(ruleContent, "**") ||
		strings.Contains(ruleContent, rule.ChannelID) ||
		!strings.Contains(ruleContent, "This channel") {
		t.Fatalf("rule offer has invalid Slack formatting or scope: %s", ruleContent)
	}
	ruleOfferActions := cardActions(ruleMessage)
	if len(ruleOfferActions) != 1 ||
		ruleOfferActions[0].ID != ActionRememberRule {
		t.Fatalf("rule offer action = %+v", ruleOfferActions)
	}
	ruleDirectory := RuleDirectoryMessage([]core.StandingRule{rule})
	ruleSaved := RuleSavedMessage(rule, false)
	ruleSurface := cardText(ruleDirectory) + "\n" + cardText(ruleSaved)
	// Supersedes the flat-Actions order: a rule's controls sit under the rule,
	// and the worth sentence stays on the row that names it.
	if len(ruleDirectory.Rows) != 1 ||
		len(ruleDirectory.Rows[0].Actions) != 3 ||
		ruleDirectory.Rows[0].Actions[0].ID != ActionToggleRule ||
		ruleDirectory.Rows[0].Actions[1].ID != ActionEditRule ||
		ruleDirectory.Rows[0].Actions[2].ID != ActionDeleteRule ||
		!strings.Contains(ruleDirectory.Rows[0].Text, "Fired 2 times") ||
		!strings.Contains(ruleDirectory.Rows[0].Text, "acted 1, did nothing 1") ||
		strings.Contains(ruleSurface, "**") {
		t.Fatalf("rule directory = %+v", ruleDirectory)
	}
}

// A rule's directory entry has to answer "should I keep this", and the fire
// count alone never could: emisar's Terraform rule had fired 64 times and every
// outcome anyone kept was 'ignore', which reads exactly like a rule earning its
// keep. The three shapes below are the three honest answers, and the one that
// matters most is the middle one — fires, no actions, say so.
func TestStandingRuleWorthSeparatesFiresFromWhatTheyProduced(t *testing.T) {
	acted := time.Date(2026, 8, 8, 9, 0, 0, 0, time.UTC)
	for _, testCase := range []struct {
		name     string
		rule     core.StandingRule
		contains []string
		absent   []string
	}{
		{
			name: "nothing recorded yet cannot be judged",
			rule: core.StandingRule{TriggerCount: 41},
			contains: []string{
				"Fired 41 times", "no outcome recorded yet",
			},
			absent: []string{"acted"},
		},
		{
			name: "fires that produced nothing say so",
			rule: core.StandingRule{TriggerCount: 64, QuietCount: 12},
			contains: []string{
				"Fired 64 times", "acted 0, did nothing 12",
				"of the 12 fires with a recorded outcome",
				"it has never done anything",
			},
		},
		{
			name: "a working rule reports when it last worked",
			rule: core.StandingRule{
				TriggerCount: 10, ActedCount: 7, QuietCount: 3, LastActed: acted,
			},
			contains: []string{"Fired 10 times", "acted 7, did nothing 3", "last acted 2026-08-08"},
			// Ten fires, ten recorded: nothing is unaccounted for, so the
			// caveat must not appear and imply that something is.
			absent: []string{"with a recorded outcome"},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			worth := StandingRuleWorth(testCase.rule)
			for _, expected := range testCase.contains {
				if !strings.Contains(worth, expected) {
					t.Fatalf("worth %q lacks %q", worth, expected)
				}
			}
			for _, unwanted := range testCase.absent {
				if strings.Contains(worth, unwanted) {
					t.Fatalf("worth %q should not claim %q", worth, unwanted)
				}
			}
		})
	}
}

// The overdue card says which of the two silences it is actually looking at.
//
// Both ages are facts it holds, and conflating them is what sent an operator
// after a stall that had not happened: on 2026-08-13 a turn that was making
// tool calls the whole time was reported as having made no progress for half an
// hour. A turn last seen working seven minutes ago is not stalled; one that has
// recorded nothing since before its deadline is, and the card is allowed to say
// so because it can now point at both clocks.
func TestOverdueCardDistinguishesAStallFromAQuietTurn(t *testing.T) {
	episode := core.WorkEpisode{
		ID: "ep_1", Objective: "Verify the rollout",
		Status: "Working", NextAction: "Investigating",
	}
	for _, testCase := range []struct {
		name          string
		overdueBy     time.Duration
		sinceActivity time.Duration
		contains      []string
		absent        []string
	}{
		{
			// Nothing recorded either way — an episode from before the stream
			// existed, or a turn that narrated nothing. It says what the
			// progress clock knows and invents no activity it never saw.
			name:      "a turn that recorded nothing keeps the progress-only copy",
			overdueBy: 33 * time.Minute,
			contains: []string{
				"Still working on Verify the rollout",
				"*No progress for 33 minutes.*",
			},
			absent: []string{"last activity", "nothing recorded", "Stalled"},
		},
		{
			name:          "a turn that was working recently is not called stalled",
			overdueBy:     33 * time.Minute,
			sinceActivity: 7 * time.Minute,
			contains: []string{
				"Still working on Verify the rollout: no update for 33 minutes",
				"quiet for the last 7 minutes",
				"*No progress note for 33 minutes, and last activity 7 minutes ago.*",
			},
			absent: []string{"Stalled"},
		},
		{
			name:          "nothing since before the deadline is a stall, and both ages are cited",
			overdueBy:     33 * time.Minute,
			sinceActivity: 40 * time.Minute,
			contains: []string{
				"Stalled on Verify the rollout",
				"*Stalled for 33 minutes.*",
				"nothing recorded for 40 minutes",
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			message := CommitmentOverdueMessage(episode, testCase.overdueBy, testCase.sinceActivity)
			spoken := message.Text + "\n" + strings.Join(message.Sections, "\n") + "\n" +
				strings.Join(message.Context, "\n")
			for _, expected := range testCase.contains {
				if !strings.Contains(spoken, expected) {
					t.Fatalf("overdue card lacks %q:\n%s", expected, spoken)
				}
			}
			for _, unwanted := range testCase.absent {
				if strings.Contains(spoken, unwanted) {
					t.Fatalf("overdue card claims %q:\n%s", unwanted, spoken)
				}
			}
			// Whichever reading it is, the card still states where the work
			// stands and what the operator can do, and still apologises for
			// nothing.
			if !strings.Contains(message.Sections[1], "*Next action:* Investigating") {
				t.Fatalf("overdue card dropped the next action: %+v", message)
			}
			if !strings.Contains(strings.ToLower(spoken), "ask me to retry") {
				t.Fatalf("overdue card stopped saying what the operator can do:\n%s", spoken)
			}
			if strings.Contains(strings.ToLower(spoken), "sorry") {
				t.Fatalf("overdue card started grovelling:\n%s", spoken)
			}
		})
	}
}

// Six identical engineering-task offers reached one Slack channel on
// 2026-08-16, none of them accepted, each one a fresh button beside a button
// that still worked. A second control for work already on offer is not a second
// choice; it is the same choice, and the operator has to decide which of the
// two is real.
//
// The pointer is a context line rather than a section because it is not part of
// the answer: the answer is what the alert means now, and where the offer went
// is a footnote for whoever wants to press it.
func TestExistingTaskOfferPointsAtTheOpenOfferInsteadOfRepeatingIt(t *testing.T) {
	message := WithExistingTaskOfferPointer(
		ConversationResponse("Memory is still over the cap on all five allocations.", NewSanitizer(12000)),
		"Raise the Traefik memory cap and roll the job",
		"Blitz infrastructure (`blitz-infra`)",
		"https://app.slack.com/client/T1/C1/thread/C1-1700.100",
		NewSanitizer(12000),
	)
	if len(message.Actions) != 0 {
		t.Fatalf("the pointer rendered a second button: %+v", message.Actions)
	}
	pointer := strings.Join(message.Context, "\n")
	if !strings.Contains(pointer, "Already offered") ||
		!strings.Contains(pointer, "Raise the Traefik memory cap") ||
		!strings.Contains(pointer, "Blitz infrastructure") {
		t.Fatalf("the pointer does not say what is already on offer: %q", pointer)
	}
	if !strings.Contains(pointer, "https://app.slack.com/client/T1/C1/thread/C1-1700.100") {
		t.Fatalf("the pointer does not link to the offer it points at: %q", pointer)
	}
	// Without a link there is still an instruction: an operator who cannot be
	// sent to the message has to be told the button is on an earlier one, or
	// the line reads as a refusal.
	unlinked := WithExistingTaskOfferPointer(
		ConversationResponse("Still over the cap.", NewSanitizer(12000)),
		"Raise the Traefik memory cap and roll the job",
		"Blitz infrastructure (`blitz-infra`)",
		"",
		NewSanitizer(12000),
	)
	if line := strings.Join(unlinked.Context, "\n"); !strings.Contains(
		line, "use the Start button on that message",
	) {
		t.Fatalf("an unlinkable pointer leaves the operator nowhere: %q", line)
	}
	// A pointer with nothing to point at changes nothing.
	plain := ConversationResponse("Still over the cap.", NewSanitizer(12000))
	if empty := WithExistingTaskOfferPointer(
		plain, "", "Blitz infrastructure (`blitz-infra`)", "", NewSanitizer(12000),
	); len(empty.Context) != len(plain.Context) {
		t.Fatalf("a titleless pointer added a line: %+v", empty.Context)
	}
}

// Sanitizing a copy of a Message must not rewrite the caller's own slices.
