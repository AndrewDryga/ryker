package slackui

import (
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

type ChangesNavigation struct {
	Page          int
	Pages         int
	FirstByte     int64
	LastByte      int64
	TotalBytes    int64
	Digest        string
	PreviousValue string
	NextValue     string
	RefreshValue  string
}

// engineeringTaskCard renders one state as one layout.
//
// What it replaces was a switch that appended a section per condition, so a
// task that was blocked, had changes, had a stale PR and a delivery update
// rendered four paragraphs of prose and left the reader to work out which of
// them was the current one. The rebuild resolves the state once and lets every
// other part of the card read that answer: the stripe, the glyph, the state
// line's closing clause, whether a primary button exists at all, and which
// ledger step carries the marker.
//
// The run itself moved out of prose and into the ledger. "Reviewing changes"
// was a workflow adjective a reader had to place in a sequence they could not
// see; `▸ Readiness review` is the same fact stated as a position.
func engineeringTaskCard(
	task core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
	followup core.PublicationFollowup,
	lifecycle core.PublicationLifecycleEvent,
) Message {
	now := time.Now()
	state := taskCardState(task, hasCodeChanges, codeChangesKnown, publication, followup)
	ask := taskAsk(state, task, hasCodeChanges, codeChangesKnown, publication)
	ledger := taskLedger(task, state, hasCodeChanges, publication, now)
	actions, overflow := taskActions(
		task, state, hasCodeChanges, codeChangesKnown, publication, followup,
	)
	message := Message{
		Text: truncateUTF8(taskFallback(
			task, state, repositoryName, ask, ledger, publication, followup,
		), 4000),
		Header: state.Header(task.Title),
		Stripe: state.Stripe,
		Sections: []string{state.stateLine(
			escapeSlackText(repositoryName), cardAge(task.CreatedAt, now), ask,
		)},
		Ledger:   ledger,
		Context:  []string{taskFooter(task)},
		Actions:  actions,
		Overflow: overflow,
	}
	// Position two, directly under the state line, because it is the reason
	// the card is salmon and the only thing on it the operator can act on.
	if blocker := taskBlocker(task, codeChangesKnown, hasCodeChanges, publication); blocker != "" {
		message.Sections = append(message.Sections, blocker)
	}
	// The ask is reference material: it is what was wanted, not what is
	// happening, and it was the tallest block on every card that carried it.
	// Two lines and a way to read the rest.
	if signal, ok := primarySignal(signals); ok && strings.TrimSpace(signal.Summary) != "" {
		message = AppendRow(
			message,
			"> "+truncateUTF8(escapeSlackText(singleLine(signal.Summary)), 180),
			[]Action{{ID: ActionFullRequest, Label: "Full request", Value: task.ID}},
		)
	}
	// The model's own summary of its turn. Between activity windows it is the
	// only account of what actually happened, so it keeps its own section.
	if strings.TrimSpace(task.LatestUpdate) != "" {
		message.Sections = append(
			message.Sections,
			"*Latest*\n"+truncateUTF8(task.LatestUpdate, 1500),
		)
	}
	// Delivery news outlives the PR: a Terraform apply that fails after a merge
	// is the most important thing on a card whose ledger is already complete.
	if lifecycle.ID != "" && lifecycle.Kind != "merged" && lifecycle.Kind != "closed" {
		message.Sections = append(
			message.Sections,
			"*Delivery update*\n"+truncateUTF8(escapeSlackText(lifecycle.Summary), 1200),
		)
	}
	if outcome := taskOutcome(state, publication, followup); outcome != "" {
		message.Sections = append(message.Sections, outcome)
	}
	return message
}

// taskCardState maps every combination the old switch enumerated onto one of
// nine states. The order is the priority order: an outcome that already
// happened outranks a control that is still offered, and a running turn
// outranks a publication that is not moving while it runs.
func taskCardState(
	task core.Incident,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
	followup core.PublicationFollowup,
) cardState {
	switch {
	case followup.PRState == "merged":
		return cardState{StripeDone, "✅", "Merged", custodyNobody}
	case followup.PRState == "closed":
		return cardState{StripeIdle, "⏸", "PR closed", custodyNobody}
	case task.Status == core.IncidentClosed || task.Workflow == core.WorkflowClosed:
		return cardState{StripeIdle, "⏸", "Closed", custodyNobody}
	case task.ActiveTurnID != "":
		return cardState{StripeWorking, "⚙️", "Working", custodyEmisar}
	case publication.State == core.PublicationFailed:
		// Two different failures wear two different colours. One has a retry
		// button on this card, which makes it an ask; the other needs a fresh
		// task or a change that does not exist, which is where the run
		// actually stopped. Red for the stop, salmon for the ask — a red card
		// the operator can clear with one button teaches them to ignore red.
		if publication.FailureCode == core.PublicationFailureSessionBinding ||
			(codeChangesKnown && !hasCodeChanges) {
			return cardState{StripeFailed, "🛑", "Failed", custodyOperator}
		}
		return cardState{StripeNeedsYou, "✋", "Needs you", custodyOperator}
	case publication.InProgress():
		return cardState{StripeWorking, "⚙️", "Working", custodyEmisar}
	case publication.NeedsUpdate():
		return cardState{StripeNeedsYou, "📦", "Ready to publish", custodyOperator}
	case publication.Published():
		return publishedTaskState(followup)
	case task.Workflow == core.WorkflowBlocked:
		return cardState{StripeNeedsYou, "✋", "Needs you", custodyOperator}
	case task.Workflow == core.WorkflowInvestigating,
		task.Workflow == core.WorkflowProvisioningChannel,
		task.Workflow == core.WorkflowProvisioningSession,
		task.Workflow == core.WorkflowHolding,
		task.Workflow == core.WorkflowClosing:
		return cardState{StripeWorking, "⚙️", "Working", custodyEmisar}
	case task.LastError != "":
		return cardState{StripeNeedsYou, "✋", "Needs you", custodyOperator}
	case hasCodeChanges:
		return cardState{StripeNeedsYou, "📦", "Ready to publish", custodyOperator}
	default:
		// Parked is idle, not owed. Nothing is running and no decision is
		// pending; the card holds an open invitation to reply, which is a
		// different thing from an outstanding ask and gets a different colour.
		return cardState{StripeIdle, "⏸", "Parked", custodyNobody}
	}
}

// publishedTaskState splits "PR open" by who the checks leave it with.
//
// While checks run the machine has it and the stripe stays amber; once they
// land — passing, failing, or absent — the merge is a person's decision and
// the card says so. Unknown is treated as still running, because claiming the
// operator's turn on missing data is the more expensive mistake.
func publishedTaskState(followup core.PublicationFollowup) cardState {
	switch followup.ChecksState {
	case "", "unknown", "pending":
		return cardState{StripeWorking, "🔀", "PR open", custodyEmisar}
	default:
		return cardState{StripeNeedsYou, "🔀", "PR open", custodyOperator}
	}
}

// taskAsk is the closing clause of the state line: the specific thing wanted,
// or the sentence that says nothing is.
func taskAsk(
	state cardState,
	task core.Incident,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
) string {
	switch state.Word {
	case "Merged":
		return "nothing needed from you"
	case "PR closed":
		return "nothing needed from you"
	case "Closed":
		return "nothing needed from you"
	case "Failed":
		if publication.FailureCode == core.PublicationFailureSessionBinding {
			return "start a fresh task to publish this change"
		}
		return "add or restore the intended change, then retry"
	case "Needs you":
		if publication.State == core.PublicationFailed {
			// Not the button's own label lowercased: that turns "Retry PR
			// update" into "retry pr update", and a card that cannot spell PR
			// is not one to trust with a repository.
			if publication.HasPR() {
				return "correct the blocker, then retry the PR update"
			}
			return "correct the blocker, then retry the draft PR"
		}
		return "read *Action needed*, then reply here"
	case "Ready to publish":
		if publication.HasPR() {
			return fmt.Sprintf("update PR #%d with the current tree", publication.PRNumber)
		}
		return "create the draft PR"
	case "PR open":
		if state.Custody == custodyOperator {
			return fmt.Sprintf("review and merge PR #%d", publication.PRNumber)
		}
		return "checks are running; nothing needed from you"
	case "Parked":
		if codeChangesKnown && !hasCodeChanges {
			return "reply with the change you want, or close the task"
		}
		return "reply here to continue, or close the task"
	default:
		return "nothing needed from you"
	}
}

// taskLedger renders the run as five positions.
//
// Every publication and followup state lands on one of them rather than on a
// section of its own: "publishing" is a detail on Draft PR, not a paragraph
// about Draft PR. Terminal states get no ledger at all — rule 9, a finished
// card shrinks to a receipt.
func taskLedger(
	task core.Incident,
	state cardState,
	hasCodeChanges bool,
	publication core.Publication,
	now time.Time,
) []LedgerStep {
	if state.Custody == custodyNobody && state.Word != "Parked" {
		return nil
	}
	// The middle step is named for the phase it is in. Before a change exists
	// the work is understanding the trigger; after one exists it is the change.
	changeLabel := "Investigate the trigger"
	if hasCodeChanges {
		changeLabel = "Make the change"
	}
	// A step is complete when the thing it names has happened, which is not
	// the same as a PR existing. A PR whose latest attempt failed, went stale,
	// or is still publishing has not landed, and marking Draft PR done in
	// those states would put the marker on "Review & merge" and tell the
	// operator to go and merge something that was never pushed.
	changesMade := hasCodeChanges || publication.HasPR() || publication.InProgress()
	reviewPassed := publication.State == core.PublicationPublishing ||
		publication.State == core.PublicationPublished ||
		(publication.HasPR() && publication.State != core.PublicationReviewing)
	prLanded := publication.HasPR() && !publication.InProgress() &&
		publication.State != core.PublicationFailed && !publication.NeedsUpdate()
	steps := []LedgerStep{
		{Label: "Workspace ready"},
		{Label: changeLabel},
		{Label: "Readiness review"},
		{Label: "Draft PR"},
		{Label: "Review & merge", Owner: "yours"},
	}
	done := []bool{task.CoopSessionID != "", changesMade, reviewPassed, prLanded, false}
	if done[0] && !task.CreatedAt.IsZero() {
		// The only per-step timestamp the record actually holds. Inventing the
		// other four from the task's updated_at would be four confident lies.
		steps[0].When = compactDuration(now.Sub(task.CreatedAt)) + " ago"
	}
	// One word each. The detail column is the first to give way when a line
	// runs long, and "needs a…" is not a state anybody can act on — the state
	// line and the ask carry the full sentence.
	switch publication.State {
	case core.PublicationReviewing:
		steps[2].Detail = "running"
	case core.PublicationRetrying:
		steps[3].Detail = "retrying"
	case core.PublicationPublishing:
		steps[3].Detail = "publishing"
	case core.PublicationFailed:
		steps[3].Detail = "failed"
	case core.PublicationStale:
		steps[3].Detail = "needs update"
	}
	if reviewPassed && steps[2].Detail == "" {
		steps[2].Detail = "green"
	}
	if publication.HasPR() {
		// "#482", not "PR #482": the step is already labelled Draft PR, and the
		// repetition costs the characters the status word needs.
		steps[3].Detail = strings.TrimSpace(
			fmt.Sprintf("#%d %s", publication.PRNumber, steps[3].Detail),
		)
		if !publication.PublishedAt.IsZero() {
			steps[3].When = compactDuration(now.Sub(publication.PublishedAt)) + " ago"
		}
	}
	// Checks nest under Draft PR as Children when lifecycle data reaches this
	// function. It does not yet — the card is handed one lifecycle event, not
	// the check set — so the seam stays empty rather than guessed at.
	current := len(steps) - 1
	for index, complete := range done {
		if !complete {
			current = index
			break
		}
		steps[index].Glyph = "✓"
	}
	steps[current].Current = true
	// Only when the step has nothing else to say. A step already reporting
	// "#482 needs update" does not need a second column repeating that
	// somebody has to act on it, and the two together squeeze both.
	if current == 3 && state.Custody == custodyOperator &&
		steps[3].When == "" && steps[3].Detail == "" {
		steps[3].Owner = "yours to publish"
	}
	return steps
}

// taskBlocker is the one section that says what to do about a stopped card.
//
// task.LastError and a publication failure are the same kind of fact — a thing
// a person has to clear — so they render in one place rather than in two
// sections that could both appear and disagree about which is current.
func taskBlocker(
	task core.Incident,
	codeChangesKnown bool,
	hasCodeChanges bool,
	publication core.Publication,
) string {
	if task.LastError != "" {
		return "*Action needed*\n" + truncateUTF8(escapeSlackText(task.LastError), 800)
	}
	if publication.State != core.PublicationFailed || publication.LastError == "" {
		return ""
	}
	detail := "*Action needed*\n" + truncateUTF8(escapeSlackText(publication.LastError), 800)
	switch {
	case publication.FailureCode == core.PublicationFailureSessionBinding:
		return detail + "\n\nThis needs a fresh task. The existing isolated workspace is " +
			"retained for inspection."
	case codeChangesKnown && !hasCodeChanges:
		return detail + "\n\nAdd or restore the intended code changes before trying again."
	default:
		return detail + "\n\nCorrect the blocker, then use *" +
			publishAction(task, publication).Label + "*. Responder will confirm that the " +
			"task still has changes before it reviews or publishes anything."
	}
}

// taskOutcome is the receipt a terminal card shrinks to: what happened, and
// the identifiers that let someone check it later.
func taskOutcome(
	state cardState,
	publication core.Publication,
	followup core.PublicationFollowup,
) string {
	switch state.Word {
	case "Merged":
		detail := fmt.Sprintf("*PR merged*\n<%s|PR #%d> was merged.", publication.PRURL, publication.PRNumber)
		if followup.MergeSHA != "" {
			detail += " Merge commit `" + escapeSlackText(shortSHA(followup.MergeSHA)) + "`."
		}
		return detail + "\nStart a new engineering task to publish another change."
	case "PR closed":
		return fmt.Sprintf(
			"*PR closed*\n<%s|PR #%d> was closed without merging. Start a new engineering "+
				"task to publish another change.",
			publication.PRURL, publication.PRNumber,
		)
	default:
		return ""
	}
}

// taskFooter is rule 7: identifiers are footnotes, and the space they used to
// occupy as a fields grid states the safety boundary where people read.
func taskFooter(task core.Incident) string {
	parts := []string{"Isolated fork — cannot merge or deploy"}
	// Folded into the same line rather than given its own, because the
	// sentence is only true for a thread-scoped card and a card is a fixed
	// height instrument before it is a place to put sentences.
	if task.IsThreadScoped() {
		parts = append(parts, "replies here continue the same isolated task session")
	}
	parts = append(parts, "`"+safeInlineCode(ShortID(task.ID))+"`")
	if task.CoopForkName != "" {
		parts = append(parts, "`"+safeInlineCode(task.CoopForkName)+"`")
	}
	if started := slackDate(task.CreatedAt, "2006-01-02 15:04 UTC"); started != "" {
		parts = append(parts, "started "+started)
	}
	return strings.Join(parts, "  ·  ")
}

// taskFallback leads with the state word.
//
// A notification, the sidebar and a screen reader all get this string and none
// of them get the stripe or the glyph, so the first word has to be the one the
// colour would otherwise have carried.
func taskFallback(
	task core.Incident,
	state cardState,
	repositoryName string,
	ask string,
	ledger []LedgerStep,
	publication core.Publication,
	followup core.PublicationFollowup,
) string {
	fallback := state.Word + " — " + escapeSlackText(singleLine(task.Title)) + "."
	if name := strings.TrimSpace(repositoryName); name != "" {
		fallback += " " + escapeSlackText(name) + ";"
	}
	if position := ledgerPosition(ledger); position > 0 {
		fallback += fmt.Sprintf(" step %d of %d;", position, len(ledger))
	}
	fallback += " " + strings.ReplaceAll(ask, "*", "") + "."
	if task.LastError != "" {
		fallback += " Action needed: " + truncateUTF8(escapeSlackText(task.LastError), 500)
	}
	if progress := publicationFallback(publication, followup); progress != "" {
		fallback += " " + progress
	}
	return fallback
}

// ledgerPosition is the 1-based index of the marked step, or 0 when the run
// has no ledger because it is over.
func ledgerPosition(ledger []LedgerStep) int {
	for index, step := range ledger {
		if step.Current {
			return index + 1
		}
	}
	return 0
}

// taskActions assigns controls by custody rather than by state machine.
//
// One primary at most and only when the ball is with the operator; red only
// for irreversible destruction, which is why Stop is neutral here — it
// preserves the fork and the queued work, and a red button that destroys
// nothing spends the colour that Discard needs.
//
// Anything carrying a confirmation stays a button. Block Kit has one confirm
// dialog per overflow element, not per option, so a menu holding a confirmable
// action would either guard every harmless item beside it or drop the guard.
func taskActions(
	task core.Incident,
	state cardState,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
	followup core.PublicationFollowup,
) ([]Action, []Action) {
	// The card renders before Slack has told us where it lives; controls that
	// route by message would have nowhere to go.
	if task.RootTS == "" {
		return nil, nil
	}
	changes := Action{ID: ActionChanges, Label: "View diff", Value: task.ID}
	viewPR := Action{ID: ActionViewPR, Label: "Open PR", Value: task.ID, URL: publication.PRURL}
	checkDelivery := Action{ID: ActionCheckDelivery, Label: "Check delivery", Value: task.ID}
	closeTask := closeWorkAction(task, hasCodeChanges, publication)
	fullRequest := Action{ID: ActionFullRequest, Label: "Open the full request", Value: task.ID}
	help := Action{ID: ActionHelp, Label: "How this works", Value: task.ID}
	// The overflow copies of these drop their confirmations deliberately: both
	// are read-only, and the alternative is one dialog guarding every option
	// in the menu, which teaches the operator to dismiss it unread.
	askUpdate := Action{ID: ActionUpdate, Label: "Ask for an update", Value: task.ID}
	rerunReview := Action{ID: ActionReview, Label: "Re-run readiness check", Value: task.ID}
	// Hiding the diff is only honest when the absence of changes is a fact.
	// While a publication runs the caller has not asked the fork, so an
	// unknown count must not be rendered as an empty one.
	showDiff := hasCodeChanges || !codeChangesKnown

	var actions []Action
	overflow := []Action{fullRequest, help}
	switch state.Word {
	case "Working":
		if task.ActiveTurnID != "" {
			actions = append(actions, Action{
				ID: ActionStop, Label: "Stop", Value: task.ID,
				Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
			})
		}
		if showDiff {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		overflow = append([]Action{askUpdate}, overflow...)
		return actions, overflow
	case "Needs you":
		if publication.State == core.PublicationFailed {
			actions = append(actions, publishAction(task, publication))
		}
		if showDiff {
			actions = append(actions, changes)
		}
	case "Failed":
		// Nothing here can be retried from this card, so nothing pretends to
		// be. The diff stays where there is retained work to inspect, and goes
		// where the failure was that there is none — offering a view of an
		// empty tree is the same false affordance as offering the retry.
		if publication.FailureCode == core.PublicationFailureSessionBinding {
			actions = append(actions, changes)
		}
	case "Ready to publish":
		actions = append(actions, publishAction(task, publication), changes)
		overflow = append([]Action{rerunReview}, overflow...)
	case "PR open":
		actions = append(actions, viewPR)
		if showDiff {
			actions = append(actions, changes)
		}
		overflow = append([]Action{checkDelivery}, overflow...)
	case "Merged", "PR closed":
		actions = append(actions, changes)
		overflow = append([]Action{checkDelivery}, overflow...)
	case "Closed":
		if showDiff {
			actions = append(actions, changes)
		}
		if publication.Published() {
			overflow = append([]Action{checkDelivery}, overflow...)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		// The one red button on any task card. It destroys committed work that
		// was never published, and it is the only control here that cannot be
		// undone.
		if hasCodeChanges && !publication.Published() {
			actions = append(actions, Action{
				ID: ActionDiscardWork, Label: "Discard retained work",
				Value: task.ID, Style: "danger",
				Confirm: "Permanently delete this closed task's unpublished committed work and isolated Coop state? This cannot be undone. Dirty uncommitted work is never discarded.",
			})
		}
		return actions, overflow
	default: // Parked
		actions = append(actions, Action{
			ID: ActionUpdate, Label: "Ask agent for update", Value: task.ID,
			Confirm: "Ask Responder to inspect current evidence and post a concise update?",
		})
	}
	if publication.HasPR() && !containsAction(actions, ActionViewPR) {
		actions = append(actions, viewPR)
	}
	// Close is last wherever it appears, and it keeps the confirmation that
	// distinguishes closing a task with retained work from closing an empty
	// one, verbatim, because that wording is the only place the difference is
	// stated. It stays a button for the same reason: an overflow cannot carry
	// a confirmation of its own.
	actions = append(actions, closeTask)
	return actions, overflow
}

func containsAction(actions []Action, id string) bool {
	for _, action := range actions {
		if action.ID == id {
			return true
		}
	}
	return false
}

// FullRequestMessage posts the whole ask as a thread reply.
//
// The card quotes the first two lines; this is where the rest of it lives, so
// the request stays reachable without ever being the tallest block on an
// instrument that has to stay readable at a glance.
func FullRequestMessage(task core.Incident, signal core.Signal) Message {
	body := strings.TrimSpace(firstNonemptyUI(signal.Summary, signal.Title))
	if body == "" {
		body = "The original request was not recorded with this task."
	}
	return Message{
		Text: truncateUTF8(
			"The full request for "+ShortID(task.ID)+": "+escapeSlackText(singleLine(body)), 4000,
		),
		Header:   "The full request",
		Sections: []string{truncateUTF8(escapeSlackText(body), 2900)},
		Context: []string{
			"Quoted as it was received. Reply in this thread to change what is being asked for.",
		},
	}
}

func publicationFallback(
	publication core.Publication,
	followup core.PublicationFollowup,
) string {
	if followup.PRState == "merged" {
		return fmt.Sprintf("PR #%d is merged.", publication.PRNumber)
	}
	if followup.PRState == "closed" {
		return fmt.Sprintf("PR #%d is closed.", publication.PRNumber)
	}
	noun := "Draft PR publication"
	if publication.HasPR() {
		noun = "PR update"
	}
	switch publication.State {
	case core.PublicationReviewing:
		return noun + " readiness review is in progress."
	case core.PublicationPublishing:
		return noun + " is in progress."
	case core.PublicationRetrying:
		return noun + " is waiting for an automatic retry."
	case core.PublicationFailed:
		return noun + " needs attention."
	default:
		return ""
	}
}

func MemoryReviewMessage(item core.MemoryReviewItem, entries []core.MemoryEntry) Message {
	header := "Review saved memory"
	intro := "This saved memory has not been used recently. Keep it if it is still useful, or forget it."
	if item.Kind == "duplicate" {
		header = "Possible duplicate memory"
		intro = "These entries remember the same guidance in the same scope. Merge them to keep the newest copy, or keep them separate."
	}
	message := Message{
		Text:     header + ". " + item.Reason,
		Header:   header,
		Sections: []string{intro},
		Context: []string{
			"This review never changes memory until you choose an action. Fresh evidence and current repository state still take precedence over anything kept.",
		},
	}
	for index, entry := range entries {
		lastUsed := "never recalled"
		if !entry.LastRecalledAt.IsZero() {
			lastUsed = "last used " + entry.LastRecalledAt.UTC().Format("2006-01-02")
		}
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%d. %s*\n> %s\n%s · %s · expires %s",
			index+1,
			escapeSlackText(strings.ReplaceAll(entry.SubjectKey, "_", " ")),
			escapeSlackText(entry.Value),
			guidanceEntryScopeLabel(entry),
			lastUsed,
			expiryStamp(entry.ExpiresAt, "2006-01-02"),
		))
	}
	if item.Kind == "duplicate" {
		message.Actions = []Action{
			{ID: ActionMergeMemoryReview, Label: "Merge copies", Value: item.ID, Style: "primary", Confirm: "Keep the newest copy and permanently remove the redundant copies?"},
			{ID: ActionDismissMemoryReview, Label: "Keep separate", Value: item.ID},
		}
	} else {
		message.Actions = []Action{
			{ID: ActionKeepMemoryReview, Label: "Keep it", Value: item.ID, Style: "primary"},
			{ID: ActionForgetMemoryReview, Label: "Forget it", Value: item.ID, Style: "danger", Confirm: "Permanently forget this saved memory?"},
		}
	}
	return message
}

func MemoryReviewCompleteMessage(action string, remaining int) Message {
	result := "Memory kept."
	switch action {
	case "forget":
		result = "Memory forgotten."
	case "merge":
		result = "Duplicate copies merged."
	case "dismiss":
		result = "Entries kept separately."
	}
	message := Message{
		Text:     result,
		Header:   "Memory review complete",
		Sections: []string{result},
	}
	if remaining > 0 {
		message.Context = []string{fmt.Sprintf("%d memory review item(s) remain.", remaining)}
		message.Actions = []Action{{ID: ActionReviewMemory, Label: "Review next", Value: "next"}}
	}
	return message
}

func PublicationMessage(publication core.Publication, updated bool) Message {
	action := "created"
	header := "PR ready"
	if updated {
		action = "updated"
		header = "PR updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"Responder %s PR #%d for this engineering task: %s",
			action, publication.PRNumber, publication.PRURL,
		),
		Header: header,
		Sections: []string{
			fmt.Sprintf(
				"<%s|Open PR #%d>\n\nThe branch contains the exact tree approved by "+
					"the latest Coop readiness review. Publication used lease protection, so "+
					"Responder would refuse to overwrite an unexpected remote change.",
				publication.PRURL, publication.PRNumber,
			),
		},
		Context: []string{
			"Responder did not merge, deploy, sign, change review state, or change infrastructure.",
		},
		Actions: []Action{
			{ID: ActionViewPR, Label: "Open PR", Value: publication.IncidentID, URL: publication.PRURL},
			{ID: ActionCheckDelivery, Label: "Check delivery", Value: publication.IncidentID},
		},
	}
}

func PublicationLifecycleMessage(
	publication core.Publication,
	taskTitle string,
	kind string,
	state string,
	summary string,
	status core.PublicationLifecycleStatus,
) Message {
	header := "Delivery update"
	switch kind {
	case "merged":
		header = "PR merged"
	case "checks":
		if state == "succeeded" {
			header = "Checks passed"
		} else {
			header = "Checks need attention"
		}
	case "closed":
		header = "PR closed"
	case "terraform":
		header = "Terraform update"
	case "deployment":
		header = "Deployment update"
	}
	context := []string{"Task: " + escapeSlackText(taskTitle)}
	if status.MergeSHA != "" {
		context = append(context, "Merge commit: `"+escapeSlackText(shortSHA(status.MergeSHA))+"`")
	}
	return Message{
		Text:     header + " for PR #" + fmt.Sprint(publication.PRNumber) + ": " + summary,
		Header:   header,
		Sections: []string{summary},
		Context:  context,
		Actions: []Action{
			{ID: ActionViewPR, Label: "Open PR", Value: publication.IncidentID, URL: publication.PRURL},
			{ID: ActionCheckDelivery, Label: "Refresh status", Value: publication.IncidentID},
		},
	}
}

func WithEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
	pullRequests ...string,
) Message {
	return withEngineeringTaskOffer(
		message, taskTitle, sourceInputID, repositoryLabel,
		"Start task", firstValue(pullRequests),
	)
}

func WithSuggestedEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
	pullRequests ...string,
) Message {
	return withEngineeringTaskOffer(
		message, taskTitle, sourceInputID, repositoryLabel,
		"Prepare code fix", firstValue(pullRequests),
	)
}

func WithPullRequestReview(message Message, sourceInputID string) Message {
	message.Actions = append(message.Actions, Action{
		ID: ActionReviewPullRequest, Label: "Review PR", Value: sourceInputID,
		Confirm: "Review the exact PR diff, discussion, risks, and missing work? This is read-only.",
	})
	return message
}

func withEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
	label string,
	pullRequest string,
) Message {
	if taskTitle = strings.TrimSpace(taskTitle); taskTitle != "" {
		target := ""
		if pullRequest = strings.TrimSpace(pullRequest); pullRequest != "" {
			target = "\nExisting PR: " + escapeSlackText(pullRequest)
		}
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%s*\nRepository: %s%s",
			escapeSlackText(taskTitle), repositoryLabel, target,
		))
	}
	confirmation := "Start this task for " + repositoryLabel +
		" in an isolated working copy? Emisar may edit, test, and commit there, but cannot merge or deploy."
	if pullRequest != "" {
		confirmation = "Start this task from the exact authenticated head of " + pullRequest +
			" and allow its reviewed result to update that same PR? Emisar cannot merge or deploy."
	}
	message.Actions = append(message.Actions, Action{
		ID: ActionStartTask, Label: label, Value: sourceInputID,
		Style:   "primary",
		Confirm: confirmation,
	})
	return message
}

func firstValue(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func ChangesMessage(
	incident core.Incident,
	summary string,
	patch []byte,
	navigation ChangesNavigation,
) Message {
	context := "The fork remains isolated. No merge, signing, push, or deployment occurred."
	if incident.CoopForkName != "" {
		context = "Fork `" + incident.CoopForkName + "`. No merge, signing, push, or deployment occurred."
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	var markdown strings.Builder
	markdown.WriteString(summary)
	if navigation.TotalBytes > 0 {
		page := max(navigation.Page, 1)
		pages := max(navigation.Pages, 1)
		markdown.WriteString(fmt.Sprintf(
			"\n\n*Patch page %d of %d* · bytes %d-%d of %d",
			page,
			pages,
			navigation.FirstByte+1,
			navigation.LastByte,
			navigation.TotalBytes,
		))
		if len(navigation.Digest) >= 12 {
			markdown.WriteString(" · snapshot `" + safeInlineCode(navigation.Digest[:12]) + "`")
		}
	}
	if len(patch) > 0 {
		diff := strings.ToValidUTF8(string(patch), "\uFFFD")
		diff = strings.ReplaceAll(diff, "```", "` ` `")
		markdown.WriteString("\n\n```diff\n")
		markdown.WriteString(diff)
		markdown.WriteString("\n```")
	} else if navigation.TotalBytes == 0 {
		markdown.WriteString(
			"\n\n_No tracked text patch is available. Untracked or binary files may still " +
				"appear in the change summary._",
		)
	}
	message := Message{
		Text:     "Code changes for " + work + " " + ShortID(incident.ID) + ": " + summary,
		Header:   "Code changes",
		Markdown: truncateMarkdown(markdown.String(), 12000),
		Context:  []string{context},
	}
	if navigation.PreviousValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesPrevious, Label: "Previous page",
			Value: navigation.PreviousValue,
		})
	}
	if navigation.NextValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesNext, Label: "Next page",
			Value: navigation.NextValue,
		})
	}
	if navigation.RefreshValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesRefresh, Label: "Refresh diff",
			Value: navigation.RefreshValue,
		})
	}
	return message
}

func ReviewMessage(incident core.Incident, summary string, publishable bool) Message {
	state := "Not ready for review"
	if publishable {
		state = "Ready for external review"
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	message := Message{
		Text:     state + " for " + work + " " + ShortID(incident.ID),
		Header:   state,
		Sections: []string{summary},
		Context:  []string{"No branch was pushed and no pull request was created."},
	}
	if publishable && incident.IsEngineeringTask() {
		message.Context = []string{"The reviewed tree is pinned. Creating a draft PR will not merge or deploy it."}
	} else if !publishable && incident.IsEngineeringTask() {
		message.Context = []string{
			"The isolated change is preserved. Use the controls on the durable task card after correcting the blocker.",
		}
	}
	return message
}

func WithEngineeringTaskDelivery(
	message Message,
	incident core.Incident,
	hasCodeChanges bool,
	publication core.Publication,
	followup core.PublicationFollowup,
) Message {
	if !incident.IsEngineeringTask() {
		return message
	}
	if !hasCodeChanges {
		message.Context = append(
			message.Context,
			"No code changes were produced. There is no diff or draft PR to deliver.",
		)
		return message
	}
	if followup.Terminal() {
		state := "closed"
		if followup.PRState == "merged" {
			state = "merged"
		}
		message.Context = append(message.Context, fmt.Sprintf(
			"Changes are preserved in this task, but PR #%d is already %s. Start a new engineering task to review and publish another change.",
			publication.PRNumber, state,
		))
		message.Actions = append(message.Actions,
			Action{ID: ActionChanges, Label: "View diff", Value: incident.ID},
		)
		if publication.HasPR() {
			message.Actions = append(message.Actions, Action{
				ID: ActionViewPR, Label: "Open PR", Value: incident.ID, URL: publication.PRURL,
			})
		}
		return message
	}
	context := "Changes are preserved in the isolated task fork. View the diff, then create a draft PR for external review."
	publish := Action{
		ID: ActionPublishPR, Label: "Create draft PR (operator)",
		Value: PublicationActionValue(incident.ID, publication.Generation), Style: "primary",
		Confirm: "Run Coop's readiness review, publish the exact approved tree on a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
	}
	if publication.HasPR() {
		context = fmt.Sprintf(
			"View the diff, then update existing PR #%d with the current reviewed tree.",
			publication.PRNumber,
		)
		publish.Label = "Update PR"
		publish.Confirm = "Run a fresh Coop readiness review and update the existing PR using lease-protected branch publication? This cannot merge or deploy."
	}
	message.Context = append(message.Context, context)
	message.Actions = append(message.Actions,
		Action{ID: ActionChanges, Label: "View diff", Value: incident.ID}, publish,
	)
	if publication.HasPR() {
		message.Actions = append(message.Actions, Action{
			ID: ActionViewPR, Label: "Open PR", Value: incident.ID, URL: publication.PRURL,
		})
	}
	return message
}
