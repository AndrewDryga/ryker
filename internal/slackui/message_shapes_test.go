package slackui

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Memory, preferences, rules and schedules are four subjects in five
// situations, and the tests below assert the situation rather than the subject:
// every receipt is checked as a receipt, every directory as a directory. A
// twenty-sixth constructor that grows its own private answer to "what does a
// save look like" fails here rather than in review.

func shapeMemoryEntry(index int) core.MemoryEntry {
	return core.MemoryEntry{
		ID:             "mem_" + string(rune('a'+index)),
		ScopeKind:      "channel",
		ScopeKey:       "COPS",
		SubjectKey:     "old_portal",
		Predicate:      "alias_of",
		Value:          "service:portal",
		VisibilityKind: "channel",
		VisibilityID:   "COPS",
		ExpiresAt:      time.Now().Add(720 * time.Hour),
		CreatedAt:      time.Now().Add(-240 * time.Hour),
	}
}

func shapeGuidanceEntry() core.MemoryEntry {
	entry := shapeMemoryEntry(0)
	entry.Predicate = "guidance"
	entry.SubjectKey = "fix_explanation_style"
	entry.Value = "Start with a simple summary before technical details."
	entry.LastRecalledAt = time.Now().Add(-72 * time.Hour)
	entry.RecallCount = 4
	return entry
}

func shapePreference(index int) core.ResponderPreference {
	return core.ResponderPreference{
		ID: "pref_" + string(rune('a'+index)), ScopeKind: "operator",
		ScopeKey: "UOPERATOR", Name: "health_check_depth", Value: "deep",
		Enabled: true, ExpiresAt: time.Now().Add(720 * time.Hour),
	}
}

func shapeRule(index int) core.StandingRule {
	return core.StandingRule{
		ID: "rule_" + string(rune('a'+index)), ChannelID: "COPS", Repository: "repo",
		Trigger: "terraform_plan", Action: "review_terraform_plan",
		SourceKind: "app", Enabled: true, TriggerCount: 2, ActedCount: 1,
		QuietCount: 1, ExpiresAt: time.Now().Add(720 * time.Hour),
	}
}

func shapeTask(index int) core.ScheduledTask {
	return core.ScheduledTask{
		ID: "sched_" + string(rune('a'+index)), ChannelID: "COPS", ThreadTS: "100.1",
		Repository: "repo", Title: "Morning health report",
		Prompt:    "Check production health and summarize material changes.",
		Timezone:  "UTC",
		NextRunAt: time.Now().Add(time.Hour), Enabled: true,
		ExpiresAt: time.Now().Add(720 * time.Hour),
	}
}

func shapeCommitment(index int) core.Commitment {
	return core.Commitment{
		ID: "commit_" + string(rune('a'+index)), ChannelID: "COPS", ThreadTS: "100.1",
		Title: "Verify the rollout", State: core.CommitmentBlocked,
		Status: "Waiting on a lock", NextAction: "Read the run holding the lock.",
	}
}

func repeat[T any](count int, build func(int) T) []T {
	items := make([]T, 0, count)
	for index := range count {
		items = append(items, build(index))
	}
	return items
}

// An offer's confirmation belongs on the thing it confirms.
//
// It used to sit in the pile at the bottom of the card, which is survivable
// with one proposal and wrong with two: a card offering a preference and a
// standing rule showed two primary buttons under both, and neither said which
// was which.
func TestOffersAttachTheConfirmToTheProposal(t *testing.T) {
	lede := func() Message {
		return ConversationResponse("I can do that.", NewSanitizer(12000))
	}
	for name, message := range map[string]Message{
		"memory guidance": WithMemoryOffer(lede(), core.MemoryOffer{
			Scope: "workspace", Subject: "fix_explanation_style", Predicate: "guidance",
			Value: "Start with a simple summary.", Visibility: "operator", ExpiresIn: "90d",
		}, `{"v":1}`, `{"v":1,"forever":true}`, "workspace", "90 days"),
		"memory mapping": WithMemoryOffer(lede(), core.MemoryOffer{
			Scope: "channel", Subject: "old portal", Predicate: "alias_of",
			Value: "service:portal", Visibility: "channel", ExpiresIn: "30d",
		}, `{"v":1}`, "", "channel", "30 days"),
		"preference": WithPreferenceOffer(lede(), core.PreferenceOffer{
			Scope: "operator", Name: "health_check_depth", Value: "deep", ExpiresIn: "30d",
		}, shapePreference(0), `{"v":1}`, "30 days"),
		"rule": WithRuleOffer(lede(), core.RuleOffer{
			Scope: "channel", Repository: "repo", Trigger: "terraform_plan",
			Action: "review_terraform_plan", SourceKind: "app", ExpiresIn: "30d",
		}, shapeRule(0), `{"v":1}`, "30 days"),
		"schedule": WithScheduleOffer(
			lede(), shapeTask(0), `{"v":1}`, "Every day at 09:00 UTC",
		),
		"schedules": WithScheduleOffers(
			lede(), []core.ScheduledTask{shapeTask(0), shapeTask(1)}, `{"v":3}`,
			[]string{"Tomorrow at 15:00 UTC", "In three days at 15:00 UTC"},
		),
	} {
		t.Run(name, func(t *testing.T) {
			if len(message.Actions) != 0 {
				t.Errorf("offer left a control at the bottom of the card: %+v", message.Actions)
			}
			if len(message.Rows) == 0 {
				t.Fatalf("offer proposed nothing: %+v", message)
			}
			confirm := message.Rows[0].Actions
			if len(confirm) == 0 || confirm[0].Style != "primary" {
				t.Fatalf("proposal row has no primary confirmation: %+v", message.Rows[0])
			}
			for _, action := range confirm {
				if action.Confirm == "" {
					t.Errorf("offer control %q asks for no confirmation", action.Label)
				}
			}
			// Only the first proposal carries the button: one confirmation
			// saves the batch, and repeating it would read as a choice.
			for index, row := range message.Rows[1:] {
				if len(row.Actions) != 0 {
					t.Errorf("proposal %d repeated the confirmation: %+v", index+2, row.Actions)
				}
			}
			if !strings.HasPrefix(message.Rows[0].Text, "> ") {
				t.Errorf("proposal is not quoted: %q", message.Rows[0].Text)
			}
			if len(message.Context) > 1 {
				t.Errorf("offer has %d context lines, want at most one: %+v", len(message.Context), message.Context)
			}
		})
	}
}

// A receipt is one line, green, with one way back out.
//
// No red: a Forget button styled as destruction, one second after somebody
// confirmed they wanted the thing, asks them to re-litigate a decision they
// just made. Undo is neutral and unconfirmed — the regret arrives immediately
// or not at all, and a dialog on the way out is a toll on the wrong person.
func TestReceiptsShareOneShape(t *testing.T) {
	for name, testCase := range map[string]struct {
		message  Message
		wantUndo string
	}{
		"memory guidance": {MemorySavedMessage(shapeGuidanceEntry(), false), ActionForgetMemory},
		"memory updated":  {MemorySavedMessage(shapeGuidanceEntry(), true), ActionForgetMemory},
		"memory mapping":  {MemorySavedMessage(shapeMemoryEntry(0), false), ActionForgetMemory},
		"preference":      {PreferenceSavedMessage(shapePreference(0), false), ActionDeletePreference},
		"rule":            {RuleSavedMessage(shapeRule(0), false), ActionDeleteRule},
		"schedule":        {ScheduleSavedMessage(shapeTask(0)), ActionDeleteSchedule},
		// handleDeleteSchedule takes one id, so an "Undo all" here would
		// remove one of the batch while claiming the batch.
		"schedules": {SchedulesSavedMessage([]core.ScheduledTask{shapeTask(0), shapeTask(1)}), ""},
	} {
		t.Run(name, func(t *testing.T) {
			message := testCase.message
			if message.Stripe != StripeDone {
				t.Errorf("receipt stripe = %q, want done", message.Stripe)
			}
			if message.Header != "" {
				t.Errorf("receipt header restates its own section: %q", message.Header)
			}
			if len(message.Sections) != 1 {
				t.Errorf("receipt = %d sections, want 1: %+v", len(message.Sections), message.Sections)
			}
			if !strings.HasPrefix(message.Sections[0], "*") {
				t.Errorf("receipt does not lead with the verb: %q", message.Sections[0])
			}
			if strings.TrimSpace(message.Text) == "" {
				t.Error("receipt has no fallback text")
			}
			for _, action := range cardActions(message) {
				if action.Style == "danger" {
					t.Errorf("receipt offers destruction: %+v", action)
				}
				if action.Confirm != "" {
					t.Errorf("undo asks for confirmation: %+v", action)
				}
			}
			if testCase.wantUndo == "" {
				if len(cardActions(message)) != 0 {
					t.Errorf("receipt offered a control it cannot honour: %+v", cardActions(message))
				}
				return
			}
			actions := cardActions(message)
			if len(actions) != 1 || actions[0].ID != testCase.wantUndo ||
				actions[0].Label != "Undo" || actions[0].Value == "" {
				t.Errorf("receipt undo = %+v, want one neutral Undo on %s", actions, testCase.wantUndo)
			}
		})
	}
}

// A state change says what is true now and offers the way back — unless there
// is nothing left to act on, in which case it offers nothing at all.
func TestStateChangesOfferTheInverse(t *testing.T) {
	pausedTask := shapeTask(0)
	pausedTask.Enabled = false
	disabledPreference := shapePreference(0)
	disabledPreference.Enabled = false
	disabledRule := shapeRule(0)
	disabledRule.Enabled = false

	for name, testCase := range map[string]struct {
		message Message
		want    []string
	}{
		"preference enabled":  {PreferenceStateMessage(shapePreference(0)), []string{ActionTogglePreference}},
		"preference disabled": {PreferenceStateMessage(disabledPreference), []string{ActionTogglePreference}},
		"rule enabled":        {RuleStateMessage(shapeRule(0)), []string{ActionToggleRule}},
		"rule disabled":       {RuleStateMessage(disabledRule), []string{ActionToggleRule}},
		"schedule active": {
			ScheduleStateMessage(shapeTask(0)),
			[]string{ActionToggleSchedule, ActionRunSchedule},
		},
		"schedule paused": {
			ScheduleStateMessage(pausedTask),
			[]string{ActionToggleSchedule, ActionRunSchedule},
		},
		"preference deleted": {PreferenceDeletedMessage(), nil},
		"rule deleted":       {RuleDeletedMessage(), nil},
		"schedule deleted":   {ScheduleDeletedMessage(), nil},
		"memory forgotten":   {MemoryForgottenMessage(), nil},
		"rollup forgotten":   {MemoryRollupForgottenMessage(), nil},
		"review finished":    {MemoryReviewCompleteMessage("forget", 0), nil},
		"review continues":   {MemoryReviewCompleteMessage("keep", 3), []string{ActionReviewMemory}},
	} {
		t.Run(name, func(t *testing.T) {
			message := testCase.message
			if message.Stripe != StripeIdle {
				t.Errorf("state change stripe = %q, want idle", message.Stripe)
			}
			if message.Header != "" {
				t.Errorf("state change header restates its own section: %q", message.Header)
			}
			if len(message.Sections) != 1 {
				t.Errorf("state change = %d sections, want 1: %+v", len(message.Sections), message.Sections)
			}
			if len(message.Context) > 1 {
				t.Errorf("state change = %d context lines, want at most 1: %+v",
					len(message.Context), message.Context)
			}
			// The fallback leads with the outcome word: a notification and the
			// sidebar get the text and neither gets the stripe.
			if word := strings.SplitN(message.Text, " ", 2)[0]; !strings.HasSuffix(word, ".") {
				t.Errorf("fallback text does not lead with the outcome: %q", message.Text)
			}
			ids := cardActionIDs(message)
			for _, action := range cardActions(message) {
				if action.Style == "danger" {
					t.Errorf("state change offers destruction: %+v", action)
				}
			}
			if len(ids) != len(testCase.want) {
				t.Fatalf("state change controls = %v, want %v", ids, testCase.want)
			}
			for index, want := range testCase.want {
				if ids[index] != want {
					t.Errorf("control %d = %q, want %q", index, ids[index], want)
				}
			}
		})
	}
}

var numberedLabel = regexp.MustCompile(`\d`)

// A directory names its buttons instead of numbering them.
//
// "Forget memory 3" and "Run now #2" existed because the buttons were pooled at
// the bottom of the card and had to point back up at a list. The row carries
// its own controls now, so the number is noise — and the list is bounded,
// because a row costs two blocks and Slack refuses a message over fifty.
func TestDirectoriesNeverNumberTheirButtons(t *testing.T) {
	health := core.MemoryHealth{
		ExplicitActive: 12, ExplicitRecalled: 6, ConversationSummaries: 12,
		Rollups: 4, PendingReviews: 2, LastDreamedAt: time.Now().Add(-24 * time.Hour),
	}
	rollups := repeat(4, func(index int) core.MemoryRollup {
		return core.MemoryRollup{
			ID: "roll_" + string(rune('a'+index)), ScopeKind: "repository", ScopeKey: "repo",
			PeriodStart: time.Now().Add(-168 * time.Hour), PeriodEnd: time.Now(),
			SourceCount: 3, State: core.AgentMemory{SituationSummary: "Prior deployment context."},
		}
	})
	for name, testCase := range map[string]struct {
		message Message
		maxRows int
	}{
		"memory": {MemoryDirectoryMessage(repeat(12, shapeMemoryEntry)), directoryRowLimit},
		"memory health": {
			MemoryHealthMessage(repeat(12, shapeMemoryEntry), rollups, health),
			directoryRowLimit + 1 + len(rollups),
		},
		"preferences": {PreferenceDirectoryMessage(repeat(12, shapePreference)), directoryRowLimit},
		"rules":       {RuleDirectoryMessage(repeat(12, shapeRule)), directoryRowLimit},
		"schedules":   {ScheduleDirectoryMessage(repeat(12, shapeTask)), directoryRowLimit},
		"commitments": {CommitmentDirectoryMessage(repeat(12, shapeCommitment)), directoryRowLimit},
	} {
		t.Run(name, func(t *testing.T) {
			message := testCase.message
			if len(message.Rows) > testCase.maxRows {
				t.Errorf("directory rendered %d rows, want at most %d",
					len(message.Rows), testCase.maxRows)
			}
			if len(message.Actions) != 0 {
				t.Errorf("directory pooled controls at the bottom: %+v", message.Actions)
			}
			if message.Header == "" {
				t.Error("directory has no header")
			}
			for _, action := range cardActions(message) {
				if numberedLabel.MatchString(action.Label) {
					t.Errorf("directory numbered a button: %q", action.Label)
				}
				if action.Style == "danger" && action.Confirm == "" {
					t.Errorf("destructive control has no confirmation: %+v", action)
				}
			}
			for _, row := range message.Rows {
				// Block Kit confirms the menu, not the option, so a confirmable
				// behind ⋯ would guard every option including the harmless ones.
				for _, action := range row.Overflow {
					if action.Confirm != "" {
						t.Errorf("overflow holds a confirmable control: %+v", action)
					}
				}
				if len(row.Overflow) > 5 {
					t.Errorf("overflow holds %d options, Slack accepts 5", len(row.Overflow))
				}
			}
			// The listing is bounded, and a bounded listing that does not say so
			// is a wrong listing.
			if !strings.Contains(strings.Join(message.Context, "\n"), "and 2 more") {
				t.Errorf("directory hid the entries it dropped: %+v", message.Context)
			}
			if blocks := len(message.Blocks()); blocks >= 50 {
				t.Errorf("directory renders %d blocks; Slack refuses the message over 50", blocks)
			}
		})
	}
}

// The busiest card in the family still fits in one message.
func TestBusiestDirectoryStaysUnderTheBlockCeiling(t *testing.T) {
	message := MemoryHealthMessage(
		repeat(20, shapeMemoryEntry),
		repeat(4, func(index int) core.MemoryRollup {
			return core.MemoryRollup{
				ID: "roll_" + string(rune('a'+index)), ScopeKind: "repository", ScopeKey: "repo",
				PeriodStart: time.Now().Add(-168 * time.Hour), PeriodEnd: time.Now(),
				SourceCount: 3, State: core.AgentMemory{SituationSummary: "Prior context."},
			}
		}),
		core.MemoryHealth{ExplicitActive: 20, PendingReviews: 3, Rollups: 4},
	)
	// Uncapped, the same twenty entries render 53 blocks and Slack rejects the
	// message whole.
	if blocks := len(message.Blocks()); blocks >= 50 {
		t.Fatalf("memory health renders %d blocks, over Slack's 50-block ceiling", blocks)
	}
}

// The review shows the entry first, then says why it is asking.
//
// It used to open with "This saved memory has not been used recently", which is
// the recall fact rewritten as prose, above an entry that states it precisely.
func TestReviewLeadsWithTheEntry(t *testing.T) {
	entry := shapeGuidanceEntry()
	for name, testCase := range map[string]struct {
		kind   string
		header string
		want   []string
	}{
		"stale": {
			"stale", "Still true?",
			[]string{ActionKeepMemoryReview, ActionForgetMemoryReview},
		},
		"duplicate": {
			"duplicate", "Same memory twice?",
			[]string{ActionMergeMemoryReview, ActionDismissMemoryReview},
		},
	} {
		t.Run(name, func(t *testing.T) {
			message := MemoryReviewMessage(core.MemoryReviewItem{
				ID: "review_1", Kind: testCase.kind, Reason: "Not recently recalled.",
			}, []core.MemoryEntry{entry})
			if message.Stripe != StripeNeedsYou {
				t.Errorf("review stripe = %q, want needs-you", message.Stripe)
			}
			if message.Header != testCase.header {
				t.Errorf("review header = %q, want %q", message.Header, testCase.header)
			}
			if len(message.Sections) < 2 {
				t.Fatalf("review = %+v", message.Sections)
			}
			if !strings.HasPrefix(message.Sections[0], "> ") ||
				!strings.Contains(message.Sections[0], entry.Value) {
				t.Errorf("review does not lead with the entry: %q", message.Sections[0])
			}
			// The facts line states recall directly rather than describing it.
			for _, want := range []string{"saved ", "used 4×", "fix explanation style"} {
				if !strings.Contains(message.Sections[0], want) {
					t.Errorf("entry facts missing %q: %q", want, message.Sections[0])
				}
			}
			if strings.Contains(cardText(message), "has not been used recently") {
				t.Error("review still narrates the fact its own entry states")
			}
			if len(message.Context) != 0 {
				t.Errorf("review added a redundant disclaimer: %+v", message.Context)
			}
			ids := cardActionIDs(message)
			if len(ids) != 2 || ids[0] != testCase.want[0] || ids[1] != testCase.want[1] {
				t.Fatalf("review controls = %v, want %v", ids, testCase.want)
			}
			if message.Actions[0].Style != "primary" {
				t.Errorf("review has no primary: %+v", message.Actions[0])
			}
		})
	}
}
