package slackui

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func homeContent(message Message) string {
	parts := append([]string{message.Text}, message.Sections...)
	for _, row := range message.Rows {
		parts = append(parts, row.Text)
	}
	for _, field := range message.Fields {
		parts = append(parts, field.Label+" "+field.Value)
	}
	return strings.Join(parts, "\n")
}

// A failed run is not a promise owed to the team. Listing failures under "what
// Emisar owes the team" put a Coop idempotency conflict — an internal transport
// error the retry machinery owns — in front of an operator as a task, six times
// over, each with "Needs operator attention / Review the blocker or retry".
func TestWaitingOnYouExcludesFailuresAndBoilerplate(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{
			{
				Title: "Deploy the website", State: core.CommitmentBlocked,
				Status: "The apply is waiting on a workspace lock", NextAction: "Force-unlock va1-apps",
			},
			{
				Title:  "<https://grafana.example.com/alerting/grafana/va1-reaper/view?orgId=1|[VA1 FIRING:1] Reaper missed its cycle> *FIRING*",
				State:  core.CommitmentBlocked,
				Status: "Coop API idempotency_conflict (409): idempotency key is bound to another request",
			},
			{
				Title: "Answer Slack request", State: core.CommitmentBlocked,
				Status: "Needs operator attention", NextAction: "Review the blocker or retry",
			},
		},
		nil, nil, nil, nil,
	)
	content := homeContent(message)

	if !strings.Contains(content, "Deploy the website") {
		t.Errorf("real blocked work is missing:\n%s", content)
	}
	// The store no longer projects failed episodes into commitments at all, so
	// this asserts the surviving half: an internal error that does reach a row
	// must not be shown as prose an operator is expected to act on.
	if strings.Contains(content, "idempotency key is bound") {
		t.Errorf("an internal transport failure is shown as operator prose:\n%s", content)
	}
	// The boilerplate pair says only what the Blocked label already said.
	if strings.Contains(content, "Needs operator attention") ||
		strings.Contains(content, "Review the blocker or retry") {
		t.Errorf("boilerplate status survived:\n%s", content)
	}
	// A raw alert URL is three unreadable lines; the link text is the alert.
	if strings.Contains(content, "https://grafana.example.com") {
		t.Errorf("a raw URL is being used as a title:\n%s", content)
	}
}

func TestCommitmentHeadlineKeepsTheAlertNotTheURL(t *testing.T) {
	got := commitmentHeadline(
		"<https://grafana.example.com/alerting/grafana/va1-reaper/view?orgId=1|[VA1 FIRING:1] WARNING | Reaper missed its cycle> *FIRING - 1 alert*",
	)
	if strings.Contains(got, "http") {
		t.Errorf("headline still carries a URL: %q", got)
	}
	if !strings.Contains(got, "Reaper missed its cycle") {
		t.Errorf("headline lost the alert name: %q", got)
	}
}

// "Context retained; no current summary" is a placeholder dressed as content.
// Three of them made a section that told the reader nothing.
func TestChannelSituationsWithoutASummaryAreOmitted(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil,
		[]core.ChannelMemory{
			{ChannelID: "CQUIET", UpdatedAt: time.Now()},
			{ChannelID: "CBUSY", UpdatedAt: time.Now(), State: core.AgentMemory{
				SituationSummary: "Rollout verified; drift backlog still open",
			}},
		},
		nil, nil, nil,
	)
	content := homeContent(message)
	if strings.Contains(content, "no current summary") {
		t.Errorf("placeholder summary rendered:\n%s", content)
	}
	if strings.Contains(content, "CQUIET") {
		t.Errorf("a channel with nothing to report was listed:\n%s", content)
	}
	if !strings.Contains(content, "drift backlog still open") {
		t.Errorf("the channel that had something to say is missing:\n%s", content)
	}
}

// The page answers one question, so the numbers it is not about are demoted —
// counted lines in the footer and on the shelf, not a grid of tiles competing
// with the work. Nine tiles, most of them zero or restating the heading, were
// most of what made the page read as a mess.
//
// Every command this page prints must exist. `/responder failures` and
// `/responder sessions` were printed here for months and neither has ever been
// a subcommand — an operator who followed the page's own advice got "Unknown
// `/responder` subcommand" — so this test now guards their absence as
// deliberately as it used to assert their presence.
func TestSecondaryNumbersAreOneLineNotAGridOfTiles(t *testing.T) {
	message := OperationsHome(0, 0, 0, 100, 3, 0, 30, 0, 0, 0, 1, 0, nil, nil, nil, nil, nil, nil)

	if len(message.Fields) != 0 {
		t.Errorf("the page still renders a tile block: %+v", message.Fields)
	}
	context := strings.Join(message.Context, "\n")
	for _, expected := range []string{
		"100 failed", "30 retained workspaces", "3 draft PRs", "/responder status",
	} {
		if !strings.Contains(context, expected) {
			t.Errorf("context is missing %q:\n%s", expected, context)
		}
	}
	// A schedule count is a shelf entry, beside the command that opens it.
	shelf := strings.Join(message.Sections, "\n")
	for _, expected := range []string{"1 scheduled task", "/responder schedules"} {
		if !strings.Contains(shelf, expected) {
			t.Errorf("the shelf is missing %q:\n%s", expected, shelf)
		}
	}
	for _, invented := range []string{"/responder failures", "/responder sessions"} {
		if strings.Contains(homeContent(message)+context, invented) {
			t.Errorf("the page advertises %q, which is not a subcommand", invented)
		}
	}

	// An idle system says so in the one place the reader looks first, which is
	// now the header itself rather than a line beneath it.
	idle := OperationsHome(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil)
	if idle.Header != "Nothing needs you" {
		t.Errorf("an idle system should say so plainly: %q", idle.Header)
	}
	if strings.Contains(strings.Join(idle.Context, "\n"), "retained workspaces") {
		t.Errorf("an idle system should not list chores it does not have: %+v", idle.Context)
	}
}

// Every command any Home surface prints has to be one the slash router accepts.
//
// This is the guard for the class of defect above rather than for the two
// instances of it: the page's whole secondary layer is now "a count and the
// command that opens it", so a command that does not exist is the one way that
// layer can lie, and it lies silently — the operator types it and is told the
// subcommand is unknown, which reads as their mistake.
func TestEveryCommandTheHomeNamesIsARealSubcommand(t *testing.T) {
	// From the switch in internal/service/slash.go processSlashInput.
	real := map[string]bool{
		"help": true, "status": true, "settings": true, "config": true,
		"incidents": true, "work": true, "commitments": true, "feedback": true,
		"memory": true, "preferences": true, "preference": true, "rules": true,
		"rule": true, "schedules": true, "schedule": true, "reminders": true,
		"proactive": true, "watch": true, "shadow": true, "turn-limit": true,
		"turns": true, "timeline": true, "evidence": true, "handoff": true,
		"postmortem": true, "update": true, "changes": true, "review": true,
		"publish": true, "stop": true, "extend": true, "close": true,
	}
	message := busiestHome()
	surface := homeContent(message) + "\n" + strings.Join(message.Context, "\n")
	for _, match := range slashCommandPattern.FindAllStringSubmatch(surface, -1) {
		if !real[match[1]] {
			t.Errorf("the Home names `/responder %s`, which the slash router refuses", match[1])
		}
	}
}

var slashCommandPattern = regexp.MustCompile(`/responder ([a-z-]+)`)

// Headings must keep their items. Rendering every row after every section put
// "Responder preferences", "Standing rules" and "Corrections worth keeping?"
// in a stack with all of their rows below all three, so no heading described
// what followed it.
func TestHomeHeadingsKeepTheirRows(t *testing.T) {
	expires := time.Now().Add(720 * time.Hour)
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, nil, nil, nil, nil,
		[]core.ResponderPreference{{
			ID: "pref_1", Name: "response_location", Value: "prefer_thread",
			ScopeKind: "channel", ScopeKey: "CBACKEND", Enabled: true, ExpiresAt: expires,
		}},
		[]core.StandingRule{{
			ID: "rule_1", Trigger: "operational_alert", Action: "triage_alert",
			ChannelID: "CBACKEND", Enabled: true, ExpiresAt: expires,
		}},
	)
	message = AppendFixtureReview(message, []FixtureCandidateSummary{
		{ID: "cand_1", Correction: "a correction to judge"},
	})

	var order []string
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type string `json:"type"`
			Text struct {
				Text string `json:"text"`
			} `json:"text"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		if probe.Type == "section" && probe.Text.Text != "" {
			order = append(order, probe.Text.Text)
		}
	}

	// Each heading must be immediately followed by its own item.
	for _, pair := range [][2]string{
		{"*Settings*", "response_location"},
		{"*Standing rules*", "operational_alert"},
		{"*Improve Responder*", "correction to judge"},
	} {
		found := false
		for index, text := range order {
			if !strings.Contains(text, pair[0]) {
				continue
			}
			if index+1 >= len(order) || !strings.Contains(order[index+1], pair[1]) {
				t.Errorf("%q is not followed by its row; order was:\n%s",
					pair[0], strings.Join(order, "\n"))
			}
			found = true
			break
		}
		if !found {
			t.Errorf("heading %q missing; order was:\n%s", pair[0], strings.Join(order, "\n"))
		}
	}
}

// The same alert firing twice made two identical rows with nothing to tell
// them apart, which reads as a rendering fault rather than two events.
func TestRepeatedAlertsCollapseWithACount(t *testing.T) {
	title := "<https://grafana.example.com/a|[VA1 FIRING:1] CRITICAL | Reaper overdue for 24h> *FIRING*"
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, nil,
		[]core.Commitment{
			{Title: title, State: core.CommitmentBlocked},
			{Title: title, State: core.CommitmentBlocked},
		},
		nil, nil, nil, nil,
	)
	content := homeContent(message)
	if strings.Count(content, "Reaper overdue") != 1 {
		t.Errorf("the repeated alert was listed more than once:\n%s", content)
	}
	if !strings.Contains(content, "×2") {
		t.Errorf("the repeat count is missing:\n%s", content)
	}
	// Emphasis from the source message must not leak into the headline.
	if strings.Contains(content, "*FIRING*") {
		t.Errorf("source markup leaked into the headline:\n%s", content)
	}
}

// A correction reads as the rule that was broken, not as the same machinery
// prefix five times over. Four of the five on the page opened with "the
// structured Slack response is invalid:", which pushed the part that differs
// to the right of a colon the reader had to scan past every time.
func TestCorrectionsLeadWithWhatWasWrong(t *testing.T) {
	message := AppendFixtureReview(Message{}, []FixtureCandidateSummary{
		{ID: "c1", Correction: "the structured Slack response is invalid: decision-ready completion cannot contain material gaps"},
		{ID: "c2", Correction: "the deep work episode found active degradation but has no diagnostic closure"},
	})
	var rows []string
	for _, row := range message.Rows {
		rows = append(rows, row.Text)
	}
	content := strings.Join(rows, "\n")

	if strings.Contains(content, "structured Slack response is invalid") {
		t.Errorf("the machinery prefix survived:\n%s", content)
	}
	if !strings.Contains(content, "Decision-ready completion cannot contain material gaps") {
		t.Errorf("the rule that was broken is missing:\n%s", content)
	}
	// A correction that never had the prefix is left alone apart from its case.
	if !strings.Contains(content, "The deep work episode found active degradation") {
		t.Errorf("an unprefixed correction was mangled:\n%s", content)
	}
}

// Active work outranks a standing chore. Thirty retained workspaces is cleanup
// that has waited days; a blocked question has somebody waiting on the answer,
// and the chore used to sit above it in a paragraph of its own.
func TestTheChoreDoesNotOutrankTheWork(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{{
			Title: "Deploy the website", State: core.CommitmentBlocked,
			Status: "Waiting on a workspace lock", NextAction: "Force-unlock va1-apps",
		}},
		nil, nil, nil, nil,
	)
	visible := homeContent(message)
	if !strings.Contains(visible, "Deploy the website") {
		t.Fatalf("the blocked work is missing:\n%s", visible)
	}
	// The chore is a line of context, not a section competing with the work.
	if strings.Contains(strings.Join(message.Sections, "\n"), "retained workspace") {
		t.Errorf("the cleanup chore is still a section:\n%s", visible)
	}
	if !strings.Contains(strings.Join(message.Context, "\n"), "30 retained workspaces") {
		t.Errorf("the chore should still be reachable: %+v", message.Context)
	}
}

// A page headed "needs a decision from you" that offers no way to reach the
// conversation is a list of homework. Every item gets a button to the thread.
func TestEachItemNeedingYouCanBeOpened(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{{
			ID: "commitment_1", Title: "Deploy the website", State: core.CommitmentBlocked,
			ChannelID: "CBACKEND", ThreadTS: "1786198712.282779",
			NextAction: "Force-unlock va1-apps and queue a fresh run",
		}},
		nil, nil, nil, nil,
	)

	var opened *Action
	for _, row := range message.Rows {
		for index, action := range row.Actions {
			if action.ID == ActionOpenWorkThread {
				opened = &row.Actions[index]
			}
		}
	}
	if opened == nil {
		t.Fatalf("no way to reach the work from the page: %+v", message.Rows)
	}
	for _, expected := range []string{"CBACKEND", "1786198712.282779"} {
		if !strings.Contains(opened.URL, expected) {
			t.Errorf("open link does not reach the message: %q", opened.URL)
		}
	}
	if !strings.HasPrefix(opened.URL, "https://") {
		t.Errorf("open link is not an ordinary web link: %q", opened.URL)
	}
}

// The next action arrives as a paragraph with the instruction first and the
// caveats after. On a list, the instruction is the part that has to fit.
func TestNextActionIsTrimmedToTheInstruction(t *testing.T) {
	got := shortInstruction(
		"Open the workspace's run list in Terraform Cloud and read the run holding the lock: " +
			"if it is stuck in Applying with a dead executor, force-unlock and queue a fresh run " +
			"for the current commit; if it is genuinely applying, wait. Say which workspace and I can carry the rest.",
	)
	if len([]rune(got)) > 165 {
		t.Errorf("instruction is still a paragraph (%d chars): %q", len([]rune(got)), got)
	}
	if !strings.Contains(got, "Terraform Cloud") {
		t.Errorf("instruction lost its subject: %q", got)
	}
	if strings.Contains(got, "carry the rest") {
		t.Errorf("the trailing caveats survived: %q", got)
	}
}

// homeBlockTexts flattens a rendered surface to one readable string per block,
// so a test can assert what comes before what by scanning it.
func homeBlockTexts(message Message) []string {
	out := make([]string, 0, 48)
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			out = append(out, "unmarshalable block")
			continue
		}
		var probe struct {
			Type string `json:"type"`
			Text struct {
				Text string `json:"text"`
			} `json:"text"`
			Elements []struct {
				Type string          `json:"type"`
				Text json.RawMessage `json:"text"`
			} `json:"elements"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			out = append(out, "unreadable block")
			continue
		}
		parts := []string{probe.Type}
		if probe.Text.Text != "" {
			parts = append(parts, probe.Text.Text)
		}
		// A button's text is an object; a context element's text is a string.
		for _, element := range probe.Elements {
			var nested struct {
				Text string `json:"text"`
			}
			if err := json.Unmarshal(element.Text, &nested); err == nil {
				if nested.Text != "" {
					parts = append(parts, nested.Text)
				}
				continue
			}
			var plain string
			if err := json.Unmarshal(element.Text, &plain); err == nil && plain != "" {
				parts = append(parts, plain)
			}
		}
		out = append(out, strings.Join(parts, " | "))
	}
	return out
}

// busiestHome is the worst page a real deployment can produce: every list at
// the cap the caller loads it at, with a coverage gap on top.
func busiestHome() Message {
	now := time.Now()
	expires := now.Add(720 * time.Hour)

	incidents := make([]core.Incident, 0, 8)
	for index := 0; index < 8; index++ {
		incidents = append(incidents, core.Incident{
			ID:        "inc_" + string(rune('a'+index)),
			Title:     "VA1: prevent reload-driven Traefik OOM recurrence",
			Status:    core.IncidentActive,
			Workflow:  core.WorkflowInvestigating,
			ChannelID: "CROOM1",
			CreatedAt: now.Add(-time.Duration(index+1) * 17 * time.Minute),
		})
	}
	commitments := make([]core.Commitment, 0, 5)
	for index := 0; index < 5; index++ {
		commitments = append(commitments, core.Commitment{
			ID:         "commitment_" + string(rune('a'+index)),
			Title:      "Deploy the website " + string(rune('a'+index)),
			State:      core.CommitmentBlocked,
			ChannelID:  "CBACKEND",
			ThreadTS:   "1786198712.28277",
			NextAction: "Force-unlock va1-apps and queue a fresh run for the current commit.",
		})
	}
	situations := make([]core.ChannelMemory, 0, 3)
	for index := 0; index < 3; index++ {
		situations = append(situations, core.ChannelMemory{
			ChannelID: "CSIT" + string(rune('a'+index)),
			UpdatedAt: now,
			State: core.AgentMemory{
				SituationSummary: "Rollout verified; drift backlog still open",
				OpenLoops:        []string{"drift"},
			},
		})
	}
	memories := make([]core.MemoryEntry, 0, 6)
	for index := 0; index < 6; index++ {
		memories = append(memories, core.MemoryEntry{
			ID: "mem_" + string(rune('a'+index)), SubjectKey: "va1-apps",
			Predicate: "runbook", Value: "restart traefik first",
			ScopeKind: "workspace", ExpiresAt: expires,
		})
	}
	preferences := make([]core.ResponderPreference, 0, 3)
	for index := 0; index < 3; index++ {
		preferences = append(preferences, core.ResponderPreference{
			ID: "pref_" + string(rune('a'+index)), Name: "response_location",
			Value: "prefer_thread", ScopeKind: "channel", ScopeKey: "CBACKEND",
			Enabled: true, ExpiresAt: expires,
		})
	}
	rules := make([]core.StandingRule, 0, 3)
	for index := 0; index < 3; index++ {
		rules = append(rules, core.StandingRule{
			ID: "rule_" + string(rune('a'+index)), Trigger: "operational_alert",
			Action: "triage_alert", ChannelID: "CBACKEND", Enabled: true, ExpiresAt: expires,
		})
	}
	feedback := make([]FeedbackSummary, 0, 5)
	for index := 0; index < 5; index++ {
		feedback = append(feedback, FeedbackSummary{
			ID: "fb_" + string(rune('a'+index)), Category: "tone",
			Sentiment: "negative", Summary: "Replies are too long for an alert channel",
		})
	}
	fixtures := make([]FixtureCandidateSummary, 0, 3)
	for index := 0; index < 3; index++ {
		fixtures = append(fixtures, FixtureCandidateSummary{
			ID: "cand_" + string(rune('a'+index)), Capability: "slack_reply",
			Correction: "Decision-ready completion cannot contain material gaps",
		})
	}

	message := OperationsHome(
		8, 24, 6, 100, 3, 4, 30, 12, 4, 2, 3, 5,
		incidents, commitments, situations, memories, preferences, rules,
	)
	// The order the service publishes them in, which is what decides the page.
	message = AppendCoverageGaps(message, []string{"CGAP1", "CGAP2"})
	message = AppendFeedbackDigest(message, feedback)
	message = AppendFixtureReview(message, fixtures)
	return message
}

// Slack rejects a view over 100 blocks outright, and views.publish reports that
// by publishing nothing — the operator opens the tab and sees an empty page
// with no error anywhere. Every inline list this page used to render in full
// pushed it toward that, which is why the memory list became a shelf entry.
func TestTheBusiestHomeStaysUnderTheBlockCeiling(t *testing.T) {
	blocks := busiestHome().Blocks()
	if len(blocks) >= 100 {
		t.Fatalf("the busiest App Home renders %d blocks; Slack rejects the view at 100", len(blocks))
	}
	t.Logf("busiest App Home renders %d blocks", len(blocks))
}

// Answer-first, and provably so. The ask comes before the configuration
// warning, which comes before the work in flight, which comes before the
// standing context, which comes before the shelf of things this page is not
// about. Reading order is the design; a section that drifts up the page takes
// somebody's decision with it.
func TestTheHomeAnswersWhatNeedsMeBeforeAnythingElse(t *testing.T) {
	texts := homeBlockTexts(busiestHome())

	indexOf := func(needle string) int {
		for index, text := range texts {
			if strings.Contains(text, needle) {
				return index
			}
		}
		return -1
	}
	positions := []struct {
		name   string
		needle string
	}{
		{"header stating the count", "things need you"},
		{"the first thing needing you", "Deploy the website a"},
		{"the coverage-gap warning", "Configured but not joined"},
		{"work in flight", "*In flight*"},
		{"channel situations", "*Channel situations*"},
		{"the shelf", "*Everything else*"},
	}
	previous := -1
	for _, position := range positions {
		at := indexOf(position.needle)
		if at < 0 {
			t.Fatalf("%s is missing from the page:\n%s", position.name, strings.Join(texts, "\n"))
		}
		if at <= previous {
			t.Errorf("%s renders at block %d, after something that should follow it:\n%s",
				position.name, at, strings.Join(texts, "\n"))
		}
		previous = at
	}
	// The glyph is earned. It appears when something is waiting and not before.
	if !strings.Contains(texts[0], "✋") {
		t.Errorf("the header does not carry the needs-you glyph: %q", texts[0])
	}
	idle := OperationsHome(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil)
	if strings.Contains(idle.Header, "✋") {
		t.Errorf("an idle page raises a hand for nothing: %q", idle.Header)
	}
}

// No control on this page is numbered.
//
// A number in a label existed only to point back at a list, because the buttons
// were pooled at the foot of the page: "Keep 1" through "Discard 5" mixed in
// with "Forget memory 3" and a preference toggle, nineteen of them, none of them
// beside what it acted on. Every control sits on its own row now, so a number is
// either noise or a ranking the page does not mean.
func TestNoHomeControlCarriesANumberedLabel(t *testing.T) {
	numbered := regexp.MustCompile(`(\s\d+|#\d+)$`)
	for _, action := range cardActions(busiestHome()) {
		if numbered.MatchString(strings.TrimSpace(action.Label)) {
			t.Errorf("control %q carries a numbered label", action.Label)
		}
	}
}

// Every button the busiest page can render is one the service answers.
//
// The App Home is the surface where an unrouted button costs the most: a click
// that reaches no handler is retried until it gives up, and the operator gets
// no reply and no error either time. This is also the guard on the shelf — it
// carries commands as text precisely because a navigation button here would
// route nowhere, and this test is what fails if one is added without a handler.
func TestEveryHomeControlIsRouted(t *testing.T) {
	for _, action := range cardActions(busiestHome()) {
		if !routedActionIDs[action.ID] {
			t.Errorf("the App Home offers %q, which no handler answers", action.ID)
		}
	}
}

// The restricted page is a refusal, and a refusal is short: what is withheld,
// and who can grant it. It carries no controls, because there is nothing here
// the reader is permitted to do.
func TestRestrictedHomeIsOneRefusalAndOneRemedy(t *testing.T) {
	message := OperationsHomeRestricted()

	if message.HasControls() {
		t.Errorf("the restricted page offers controls to someone with no access: %+v", message)
	}
	if len(message.Rows) != 0 || len(message.Fields) != 0 {
		t.Errorf("the restricted page renders a list: %+v", message)
	}
	if len(message.Sections) != 1 {
		t.Errorf("sections = %d, want one refusal:\n%s",
			len(message.Sections), strings.Join(message.Sections, "\n---\n"))
	}
	if len(message.Context) != 1 {
		t.Errorf("context lines = %d, want the one remedy: %+v", len(message.Context), message.Context)
	}
	if !strings.Contains(strings.Join(message.Context, " "), "slack.operators") {
		t.Errorf("the page does not say how access is granted: %+v", message.Context)
	}
	if blocks := len(message.Blocks()); blocks > 3 {
		t.Errorf("a refusal renders %d blocks: %+v", blocks, message)
	}
}

// A title is escaped exactly once on its way to the page.
//
// commitmentHeadline escapes what it returns, so a caller that escapes the
// result again sends "&amp;" to the reader in place of "&" — the kind of defect
// that looks like a corrupted title and is invisible until a real alert name
// contains an ampersand.
func TestHomeTitlesAreEscapedExactlyOnce(t *testing.T) {
	message := OperationsHome(
		1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
		[]core.Incident{{
			ID: "inc_1", Title: "Traefik & Nomad reload storm",
			Status: core.IncidentActive, Workflow: core.WorkflowInvestigating,
			ChannelID: "CROOM1", CreatedAt: time.Now().Add(-9 * time.Minute),
		}},
		[]core.Commitment{{
			ID: "commitment_1", Title: "Drain & restart va1-apps",
			State: core.CommitmentBlocked, ChannelID: "CBACKEND",
			NextAction: "Force-unlock the workspace first.",
		}},
		nil, nil, nil, nil,
	)
	content := homeContent(message)
	if strings.Contains(content, "&amp;amp;") {
		t.Errorf("a title was escaped twice:\n%s", content)
	}
	for _, expected := range []string{"Traefik &amp; Nomad", "Drain &amp; restart"} {
		if !strings.Contains(content, expected) {
			t.Errorf("expected %q in:\n%s", expected, content)
		}
	}
}
