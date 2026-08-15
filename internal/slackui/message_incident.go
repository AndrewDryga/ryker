package slackui

import (
	"fmt"
	"net/url"
	"strings"
	"time"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
)

func IncidentCardWithPublication(
	incident core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
	followup core.PublicationFollowup,
	lifecycle core.PublicationLifecycleEvent,
	// live is variadic because the live window exists only while a turn runs,
	// and most callers — an offer, a replay, a card composed from stored state
	// with nothing running behind it — have no turn to describe. Naming an
	// empty one at every such call site would state a fact none of them holds.
	live ...LiveTurn,
) Message {
	turn := firstLiveTurn(live)
	if incident.IsEngineeringTask() {
		return engineeringTaskCard(
			incident, repositoryName, signals, hasCodeChanges, codeChangesKnown,
			publication, followup, lifecycle, turn,
		)
	}
	now := time.Now()
	state := incidentCardState(incident)
	severity := displayOr(incident.Severity, "unclassified")
	buttons, overflow := incidentControls(state, incidentActions(
		incident, hasCodeChanges, codeChangesKnown, publication, followup,
	))
	fallback := fmt.Sprintf(
		"%s — %s. Severity %s. Incident %s; Responder %s. %d of %d signals firing in %s.",
		state.Word, escapeSlackText(incident.Title), escapeSlackText(severity),
		ShortID(incident.ID), workflowStateLabel(incident.Workflow),
		incident.FiringCount, incident.SignalCount, escapeSlackText(repositoryName),
	)
	if incident.LastError != "" {
		fallback += " Action needed: " + truncateUTF8(escapeSlackText(incident.LastError), 500)
	}
	message := Message{
		Text:   truncateUTF8(fallback, 4000),
		Header: state.Header(incident.Title),
		Stripe: state.Stripe,
		// Severity moved out of the header and into this line, so the header
		// is the incident's name and nothing else — a "SEV1 | " prefix spent
		// characters restating what the colour and this line both already say.
		Sections: []string{state.stateLine(
			displayTitle(severity)+"  ·  "+signalClause(incident),
			cardAge(incident.CreatedAt, now),
			incidentAsk(state, incident),
		)},
		// One line per signal, firing first, replacing a fields grid that
		// stated the count and never the names. Which alert is firing is the
		// question the grid was standing in front of.
		Ledger:   incidentLedger(signals, turn, now),
		Actions:  buttons,
		Overflow: overflow,
	}
	if incident.LastError != "" {
		message.Sections = append(
			message.Sections,
			"*Action needed*\n"+truncateUTF8(escapeSlackText(incident.LastError), 800),
		)
	}
	signal, hasSignal := primarySignal(signals)
	if known := incidentKnown(incident, signal, hasSignal); known != "" {
		message.Sections = append(message.Sections, known)
	}
	// An incident is investigated by the same kind of turn a task is, so it
	// gets the same window onto it. Only while one runs: a firing incident
	// with nobody working on it is the state this must not be confused with.
	message = withLiveTurn(message, turn, incident.ActiveTurnID != "", now)
	// Coverage — which layers were checked and which were never looked at — is
	// the strip this card most wants and cannot have: core.Coverage never
	// reaches this function, and the signature is shared with every caller.
	// Plumbing it is a service-layer change, not a rendering one.
	if explanation := correlationExplanation(incident, signals); explanation != "" {
		// Context weight, one line: why the signals are one incident is a
		// footnote to the incident, not a paragraph competing with it.
		message.Context = append(message.Context, "Grouped: "+explanation)
	}
	if hasSignal {
		if link := sourceLink(signal.SourceURL); link != "" {
			message.Context = append(message.Context, "Alert source: "+link)
		}
	}
	message.Context = append(message.Context, incidentFooter(incident, repositoryName))
	return message
}

// incidentCardState resolves an incident on two axes at once.
//
// The alert state picks the glyph and the word — a firing incident says
// firing. Custody picks the colour, and it can disagree: an incident whose
// agent is blocked is salmon while its signals are still firing, because the
// colour answers whose turn it is and the operator's turn is the fact that
// changes what they do next.
func incidentCardState(incident core.Incident) cardState {
	state := cardState{Stripe: StripeWorking, Glyph: "🔴", Word: "Firing", Custody: custodyEmisar}
	switch {
	case incident.Status == core.IncidentClosed || incident.Workflow == core.WorkflowClosed:
		return cardState{StripeIdle, "⏸", "Closed", custodyNobody}
	case incident.Status == core.IncidentResolved:
		state = cardState{StripeDone, "✅", "Resolved", custodyNobody}
	case incident.Status == core.IncidentMonitoring:
		state = cardState{StripeDone, "🟡", "Monitoring", custodyEmisar}
	case severeSeverity(incident.Severity):
		// Red is otherwise reserved for irreversible destruction, and a sev1
		// page is the one status that earns it: it is already the emergency
		// the colour is warning about.
		state.Stripe = StripeFailed
	}
	switch {
	case incident.Workflow == core.WorkflowBlocked || incident.LastError != "":
		return cardState{StripeNeedsYou, "✋", "Needs you", custodyOperator}
	case incident.Workflow == core.WorkflowParked:
		// Nothing is running and the next move is a person's, whatever the
		// signals are doing.
		state.Stripe = StripeNeedsYou
		state.Custody = custodyOperator
	}
	return state
}

// severeSeverity decides which firing incidents are red.
//
// Severity arrives as free text from whichever source raised the alert, so
// this matches the vocabularies actually seen rather than asserting one.
// Anything unrecognised is amber: over-claiming an emergency costs more than
// under-claiming one, because it is the claim that stops being believed.
func severeSeverity(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "sev1", "sev2", "p1", "p2", "1", "2", "critical", "high", "urgent", "page":
		return true
	default:
		return false
	}
}

func incidentAsk(state cardState, incident core.Incident) string {
	switch {
	case state.Custody != custodyOperator:
		return "nothing needed from you"
	case incident.LastError != "":
		return "read *Action needed*, then reply here"
	case incident.Workflow == core.WorkflowBlocked:
		return "clear the blocker, then reply here"
	default:
		return "reply here with the next step"
	}
}

// signalClause is the count, stated the way the state line has room for.
func signalClause(incident core.Incident) string {
	switch incident.Status {
	case core.IncidentMonitoring, core.IncidentResolved:
		return "all signals recovered"
	default:
		return fmt.Sprintf("%d of %d signals firing", incident.FiringCount, incident.SignalCount)
	}
}

// displayTitle capitalises a free-text severity for the one place it is read
// as a label rather than as data. "sev1" and "critical" arrive lowercase from
// the alert source and read as a leaked field name that way.
func displayTitle(value string) string {
	runes := []rune(escapeSlackText(strings.TrimSpace(value)))
	if len(runes) == 0 {
		return ""
	}
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}

// incidentKnown is what the card can say about the cause.
//
// The agent's own latest update outranks the alert text, because by the time
// there is one it is a reading of the alert rather than a restatement of it.
func incidentKnown(incident core.Incident, signal core.Signal, hasSignal bool) string {
	if update := strings.TrimSpace(incident.LatestUpdate); update != "" {
		return "*What we know*\n" + truncateUTF8(update, 1500)
	}
	if !hasSignal {
		return ""
	}
	if summary := strings.TrimSpace(signal.Summary); summary != "" {
		return "*What we know*\n" + truncateUTF8(escapeSlackText(summary), 1200)
	}
	return ""
}

func incidentFooter(incident core.Incident, repositoryName string) string {
	parts := []string{"`" + safeInlineCode(ShortID(incident.ID)) + "`"}
	if name := strings.TrimSpace(repositoryName); name != "" {
		parts = append(parts, escapeSlackText(name))
	}
	if incident.CoopForkName != "" {
		parts = append(parts, "`"+safeInlineCode(incident.CoopForkName)+"`")
	}
	if started := slackDate(incident.CreatedAt, "2006-01-02 15:04 UTC"); started != "" {
		parts = append(parts, "started "+started)
	}
	return strings.Join(parts, "  ·  ")
}

// signalStripLimit bounds the strip at what a card can show without becoming
// the log rule 9 forbids. Past it the count is what the reader loses, not the
// names — thirty alertnames is not more informative than seven and a number.
const signalStripLimit = 7

// incidentLedger is the signal strip with the investigation's plan above it.
//
// An incident card's ledger is a list of what is firing, not a run's phases, so
// there is no current step for a plan to nest under the way the task card has
// one. It gets a position of its own instead, at the top, with the goals as its
// children — the same nesting, given the parent it was missing. Above rather
// than below because the plan is the present tense and the signals are what
// started it.
//
// No goals is the card exactly as it was: one strip of signals, no parent, no
// empty heading.
func incidentLedger(signals []core.Signal, turn LiveTurn, now time.Time) []LedgerStep {
	steps := signalLedger(signals, now)
	// Seam shared with taskLedger: when Coop's `model.plan` events carry
	// entries they project into the same []PlanStep and arrive here.
	children := planChildren(turn.Plan)
	if len(children) == 0 {
		return steps
	}
	plan := LedgerStep{Label: "Plan", Current: true, Children: children}
	return append([]LedgerStep{plan}, steps...)
}

// signalLedger renders the signals as one line each, firing first.
//
// Firing first because a recovered signal is history and a firing one is the
// incident; a strip ordered by arrival buries the live ones under the ones
// that already cleared.
func signalLedger(signals []core.Signal, now time.Time) []LedgerStep {
	if len(signals) == 0 {
		return nil
	}
	ordered := make([]core.Signal, 0, len(signals))
	for _, signal := range signals {
		if signal.Status == core.SignalFiring {
			ordered = append(ordered, signal)
		}
	}
	firing := len(ordered)
	for _, signal := range signals {
		if signal.Status != core.SignalFiring {
			ordered = append(ordered, signal)
		}
	}
	steps := make([]LedgerStep, 0, min(len(ordered), signalStripLimit)+1)
	for index, signal := range ordered[:min(len(ordered), signalStripLimit)] {
		glyph, when := "○", signal.EndsAt
		if index < firing {
			glyph, when = "●", signal.StartsAt
		}
		if when.IsZero() {
			when = signal.ReceivedAt
		}
		step := LedgerStep{
			Glyph:  glyph,
			Label:  signalName(signal),
			Detail: signalWhere(signal),
		}
		if !when.IsZero() {
			step.When = compactDuration(now.Sub(when))
		}
		steps = append(steps, step)
	}
	if extra := len(ordered) - signalStripLimit; extra > 0 {
		// A blank glyph rather than the default bullet: the line is a count,
		// not another signal, and a bullet would make it look like one.
		steps = append(steps, LedgerStep{Glyph: " ", Label: fmt.Sprintf("… and %d more", extra)})
	}
	return steps
}

// signalName is what a person calls this alert.
//
// Prometheus-shaped sources put it in the alertname label and everything else
// carries it as the title; the summary is the last resort and gets cut at its
// first sentence, because a summary is a paragraph and this is a column.
func signalName(signal core.Signal) string {
	if name := strings.TrimSpace(signal.Labels["alertname"]); name != "" {
		return externalText(name)
	}
	if title := strings.TrimSpace(signal.Title); title != "" {
		return externalText(title)
	}
	summary := externalText(signal.Summary)
	if index := strings.IndexAny(summary, ".;"); index > 0 {
		summary = summary[:index]
	}
	return summary
}

// signalWhere is where the alert fired, from whichever topology label the
// source happens to populate.
func signalWhere(signal core.Signal) string {
	for _, name := range []string{"service", "job", "site", "namespace", "cluster", "instance"} {
		if value := strings.TrimSpace(signal.Labels[name]); value != "" {
			return externalText(value)
		}
	}
	return ""
}

// incidentControls re-places the state machine's output without changing it.
//
// incidentActions encodes which controls are legal in which state, and that is
// real custody logic earned over the lifecycle; what changes here is which of
// them earns a button. Confirmable actions cannot move — Block Kit gives an
// overflow one dialog for all of its options — so the menu takes the read-only
// remainder, and the primary style survives only where the ball is actually
// with the operator.
func incidentControls(state cardState, actions []Action) ([]Action, []Action) {
	if len(actions) == 0 {
		return nil, nil
	}
	buttons := make([]Action, 0, len(actions))
	var overflow []Action
	for _, action := range actions {
		switch {
		case action.ID == ActionStop:
			// Stopping preserves the fork and the queued work, so it is not
			// destruction and does not get the colour destruction needs.
			action.Style = ""
			buttons = append(buttons, action)
		case action.ID == ActionCheckDelivery && action.Confirm == "":
			overflow = append(overflow, action)
		default:
			if state.Custody != custodyOperator && action.Style == "primary" {
				action.Style = ""
			}
			buttons = append(buttons, action)
		}
	}
	return buttons, overflow
}

func ConversationResponseWithIncidentOffer(
	text string,
	sourceInputID string,
	sanitizer *Sanitizer,
) Message {
	message := ConversationResponse(text, sanitizer)
	message.Actions = []Action{{
		ID:    ActionOpenIncident,
		Label: "Open incident room",
		Value: sourceInputID,
		Style: "primary",
		Confirm: "Create a dedicated incident room and isolated Coop working copy from this message? " +
			"No merge, push, deployment, or infrastructure change will occur.",
	}}
	return message
}

func WithIncidentOffer(message Message, sourceInputID string) Message {
	// The incident button and confirmation dialog carry the boundary. A context
	// footer is redundant and is concatenated to copied Slack Markdown.
	//
	// So drop it, which this said for months without doing. Every
	// evidence-backed reply that also offered an incident shipped the footer
	// anyway, because the composer adds it upstream: ConciseEvidenceResponse
	// appends "Details saved: N findings…" and this only ever appended the
	// button. Nothing is lost — that footer is a count, not attribution, and
	// the incident room carries the findings themselves.
	message.Context = nil
	message.Actions = append(message.Actions, Action{
		ID: ActionOpenIncident, Label: "Open incident room", Value: sourceInputID,
		Style: "primary",
		Confirm: "Create a dedicated incident room and isolated Coop working copy from this message? " +
			"No merge, push, deployment, or infrastructure change will occur.",
	})
	return message
}

func IncidentEvidenceResponse(
	text string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	sanitizer *Sanitizer,
) Message {
	message := ConciseEvidenceResponse(text, evidence, coverage, sanitizer)
	message.Header = "Investigation update"
	message.Text = truncateUTF8("Investigation update: "+message.Text, 4000)
	message.Context = append(
		message.Context,
		"Use `/responder evidence` for the detailed source ledger. Internal tool output and hidden reasoning are omitted.",
	)
	return message
}

func TimelineMessage(record core.RemediationRecord) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	title := "Remediation timeline"
	if incident.IsEngineeringTask() {
		// Nothing was remediated: the room holds a change someone asked for.
		title = "Engineering task timeline"
	}
	body.WriteString("## " + title + "\n")
	if len(events) == 0 {
		body.WriteString("\nNo " + workNoun(incident) + " activity has been recorded yet.")
	}
	start := max(0, len(events)-40)
	for _, event := range events[start:] {
		fmt.Fprintf(
			&body,
			"\n- **%s** - %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			escapeSlackText(event.Title),
		)
		if event.Detail != "" {
			fmt.Fprintf(
				&body, "  \n  %s",
				truncateUTF8(escapeSlackText(event.Detail), 600),
			)
		}
		if link := sourceLink(event.URL); link != "" {
			fmt.Fprintf(&body, "  \n  %s", link)
		}
	}
	fallback := fmt.Sprintf(
		"Incident %s remediation timeline with %d events.",
		ShortID(incident.ID), len(events),
	)
	if incident.IsEngineeringTask() {
		fallback = fmt.Sprintf(
			"Engineering task %s timeline with %d events.",
			ShortID(incident.ID), len(events),
		)
	}
	return Message{
		Text:     fallback,
		Markdown: truncateMarkdown(body.String(), 12000),
		Context: []string{
			"Built from the alert, agent runs, evidence, Emisar approvals, and publication state. The latest events are shown oldest first.",
		},
	}
}

func HandoffMessage(
	record core.RemediationRecord,
) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	fmt.Fprintf(
		&body,
		"## Shift handoff: %s\n\n**State:** %s, Responder %s",
		escapeSlackText(incident.Title),
		incidentStatusLabel(incident.Status),
		workActivityLabel(incident),
	)
	// Signals and severity are the alert's own fields. An engineering task has
	// no alert behind it, so on a task they rendered as "0 firing / 0 total,
	// severity unclassified" — three numbers that read as a quiet outage rather
	// than as work nobody paged for.
	if !incident.IsEngineeringTask() {
		fmt.Fprintf(
			&body,
			"  \n**Signals:** %d firing / %d total  \n**Severity:** %s",
			incident.FiringCount,
			incident.SignalCount,
			displayOr(incident.Severity, "unclassified"),
		)
	}
	body.WriteString("\n")
	if incident.LastError != "" {
		fmt.Fprintf(&body, "\n**Operator action needed:** %s\n", incident.LastError)
	}
	if len(events) > 0 {
		body.WriteString("\n### Latest decisions and findings\n")
		start := max(0, len(events)-8)
		for _, event := range events[start:] {
			fmt.Fprintf(
				&body,
				"\n- **%s:** %s",
				event.CreatedAt.UTC().Format("15:04 UTC"),
				event.Title,
			)
		}
	}
	message := EvidenceResponse(
		body.String(), record.Evidence[:min(len(record.Evidence), 6)],
		record.Coverage[:min(len(record.Coverage), 12)],
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"This handoff is generated from durable "+workNoun(incident)+
			" state; unknown coverage remains explicit.",
	)
	return message
}

func PostmortemDraft(record core.RemediationRecord) Message {
	incident := record.Incident
	events := core.RemediationTimeline(record)
	var body strings.Builder
	closedAt := incident.ClosedAt
	if closedAt.IsZero() {
		closedAt = incident.ResolvedAt
	}
	closed := "Still open"
	if !closedAt.IsZero() {
		closed = closedAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	// The document is the same shape either way — what was verified, what was
	// approved, what happened when, what is still open. Only the two lines
	// naming the work change, because a rename does not get a post-incident
	// review and a reader handed one stops trusting the rest of the draft.
	heading, label := "Post-incident draft", "Incident"
	if incident.IsEngineeringTask() {
		heading, label = "Engineering task review draft", "Engineering task"
	}
	fmt.Fprintf(
		&body,
		"## %s: %s\n\n"+
			"**%s:** `%s`  \n**Severity:** %s  \n**Started:** %s  \n**Closed:** %s\n\n"+
			"### What is verified\n",
		heading,
		escapeSlackText(incident.Title),
		label,
		ShortID(incident.ID),
		displayOr(incident.Severity, "unclassified"),
		incident.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		closed,
	)
	if len(record.Evidence) == 0 {
		body.WriteString("\nNo structured evidence was recorded. Root cause must remain unassigned.")
	} else {
		for _, item := range record.Evidence[:min(len(record.Evidence), 8)] {
			fmt.Fprintf(
				&body, "\n- **%s:** %s",
				escapeSlackText(item.Claim), escapeSlackText(item.Observation),
			)
		}
	}
	body.WriteString("\n\n### Remediation and approvals\n")
	if len(record.Approvals) == 0 && record.Publication.IncidentID == "" {
		body.WriteString("\nNo governed operation or code publication was recorded.")
	}
	for _, approval := range record.Approvals {
		status := strings.ReplaceAll(displayOr(approval.Status, "unknown"), "_", " ")
		fmt.Fprintf(
			&body, "\n- **%s** on `%s`: %s",
			escapeSlackText(approval.ActionID), safeInlineCode(approval.RunnerRef),
			escapeSlackText(status),
		)
		if link := sourceLink(firstNonemptyUI(approval.RunURL, approval.ApprovalURL)); link != "" {
			fmt.Fprintf(&body, " - %s", link)
		}
	}
	if record.Publication.IncidentID != "" {
		publication := record.Publication
		fmt.Fprintf(
			&body, "\n- **Draft PR:** %s",
			escapeSlackText(strings.ReplaceAll(string(publication.State), "_", " ")),
		)
		if link := sourceLink(publication.PRURL); link != "" {
			fmt.Fprintf(&body, " - %s", link)
		}
	}
	body.WriteString("\n\n### Timeline\n")
	start := max(0, len(events)-20)
	for _, event := range events[start:] {
		fmt.Fprintf(
			&body,
			"\n- **%s:** %s",
			event.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
			escapeSlackText(event.Title),
		)
	}
	body.WriteString("\n\n### Follow-up\n")
	body.WriteString("\n- [ ] Confirm impact and affected users")
	body.WriteString("\n- [ ] Confirm root cause from cited evidence")
	for _, item := range record.Coverage {
		if item.Status == "unknown" || item.Status == "degraded" {
			fmt.Fprintf(
				&body, "\n- [ ] Resolve %s coverage: %s",
				escapeSlackText(item.Layer), truncateUTF8(escapeSlackText(item.Detail), 300),
			)
		}
	}
	for _, approval := range record.Approvals {
		if approval.TerminalAt.IsZero() {
			fmt.Fprintf(
				&body, "\n- [ ] Complete Emisar approval for `%s`",
				safeInlineCode(approval.ActionID),
			)
		}
	}
	writePostmortemCommitments(&body, record.Commitments)
	message := EvidenceResponse(
		body.String(), nil, record.Coverage[:min(len(record.Coverage), 12)],
		NewSanitizer(30000),
	)
	message.Context = append(
		message.Context,
		"Generated from the durable remediation record. It does not invent impact, root cause, owners, or actions that were not recorded.",
	)
	return message
}

func incidentDirectoryStatus(incident core.Incident) string {
	if incident.Status == core.IncidentClosed {
		return "closed"
	}
	return workActivityLabel(incident)
}

// workCardState is the one-line read of a work item for surfaces that list
// several of them and hold no publication to consult.
//
// The App Home strip called incidentCardState for everything, so an engineering
// task with a turn running flew the red 🔴 Firing glyph of a paging outage —
// on the one page where a reader compares open work side by side, which is
// exactly where a false alarm costs the most. A task's own state machine is
// taskCardState; the publication arguments it does not have here resolve to the
// states that do not depend on one.
func workCardState(incident core.Incident) cardState {
	if incident.IsEngineeringTask() {
		return taskCardState(
			incident, false, false, core.Publication{}, core.PublicationFollowup{},
		)
	}
	return incidentCardState(incident)
}

func ManualHandoff(channelID string) Message {
	return handoffMessage(
		channelID, "Incident room ready", "incident room",
		"the isolated workspace",
		"The originating request remains linked here for reference.",
	)
}

func EngineeringTaskHandoff(channelID string) Message {
	return handoffMessage(
		channelID, "Engineering room ready", "engineering room",
		"an isolated writable working copy",
		"No merge, push, deployment, or infrastructure change occurs without separate authorization.",
	)
}

// handoffMessage is a pointer, so it is one line.
//
// It carries no button: Slack renders a channel mention as a link already, and
// a "Go to the room" button beside one would be a control that does nothing the
// text does not. Grey, because a handoff is informational — the work has moved,
// and nobody is waiting on anything here.
func handoffMessage(channelID, header, room, workspace, boundary string) Message {
	mention := "<#" + channelID + ">"
	return Message{
		Text:   "Responder created " + room + " " + mention + ".",
		Header: header,
		Stripe: StripeIdle,
		Sections: []string{
			"Moved to " + mention + " — I'm preparing " + workspace + " there.",
		},
		Context: []string{boundary},
	}
}

// incidentActions is the incident card's control set, and only the incident
// card's.
//
// An engineering task never reaches here: IncidentCardWithPublication hands one
// to engineeringTaskCard before this is called, and that card derives its
// controls from taskActions, which owns the task-shaped states — ready to
// publish, PR open, merged, closed with retained work. The branches that asked
// `incident.IsEngineeringTask()` are gone rather than kept as insurance: a
// condition that cannot be true is a claim that it can, and the next reader
// would have had to prove otherwise before touching anything around it.
func incidentActions(
	incident core.Incident,
	hasCodeChanges bool,
	codeChangesKnown bool,
	publication core.Publication,
	followup core.PublicationFollowup,
) []Action {
	if incident.RootTS == "" {
		return nil
	}
	// One control, two labels, decided by whether a diff is already open — the
	// same rule the task card follows, because it is the same button and an
	// incident's diff is put away exactly the way a task's is.
	changes := Action{ID: ActionChanges, Label: "View diff", Value: incident.ID}
	if incident.ChangesMessageTS != "" {
		changes.Label = "Hide diff"
	}
	review := Action{
		ID: ActionReview, Label: "Run readiness check", Value: incident.ID,
		Confirm: "Compare the isolated changes with the current repository state, check rebase and configured validation and policy gates, and report whether the fix is ready for external review. This does not merge, push, sign, or deploy.",
	}
	publish := publishAction(incident, publication)
	viewPR := Action{
		ID: ActionViewPR, Label: "Open PR", Value: incident.ID,
		URL: publication.PRURL,
	}
	checkDelivery := Action{
		ID: ActionCheckDelivery, Label: "Check delivery", Value: incident.ID,
	}
	closeIncident := closeWorkAction(incident, hasCodeChanges, publication)
	if incident.Status == core.IncidentClosed {
		actions := make([]Action, 0, 3)
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
			if publication.Published() {
				actions = append(actions, checkDelivery)
			}
		}
		return actions
	}
	if incident.CoopSessionID == "" {
		actions := make([]Action, 0, 2)
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return append(actions, closeIncident)
	}
	if incident.ActiveTurnID != "" {
		actions := []Action{{
			ID: ActionStop, Label: "Stop current run", Value: incident.ID, Style: "danger",
			Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
		}}
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return actions
	}
	if followup.Terminal() {
		actions := []Action{changes}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return append(actions, closeIncident)
	}
	if publication.InProgress() {
		actions := make([]Action, 0, 2)
		if incident.CoopSessionID != "" {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return actions
	}
	if publication.State == core.PublicationFailed {
		if publication.FailureCode == core.PublicationFailureSessionBinding {
			actions := []Action{changes}
			if publication.HasPR() {
				actions = append(actions, viewPR)
			}
			return append(actions, closeIncident)
		}
		if codeChangesKnown && !hasCodeChanges {
			actions := make([]Action, 0, 2)
			if publication.HasPR() {
				actions = append(actions, viewPR)
			}
			return append(actions, closeIncident)
		}
		actions := []Action{changes, publish}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return append(actions, closeIncident)
	}
	if publication.Published() && !hasCodeChanges {
		return []Action{viewPR, checkDelivery, closeIncident}
	}
	if publication.NeedsUpdate() {
		return []Action{changes, publish, viewPR, closeIncident}
	}
	if incident.Workflow == core.WorkflowInvestigating {
		actions := make([]Action, 0, 1)
		if hasCodeChanges {
			actions = append(actions, changes)
		}
		if publication.HasPR() {
			actions = append(actions, viewPR)
		}
		return actions
	}
	actions := make([]Action, 0, 4)
	if incident.Workflow != core.WorkflowBlocked {
		actions = append(actions, Action{
			ID: ActionUpdate, Label: "Ask agent for update", Value: incident.ID, Style: "primary",
			Confirm: "Ask Responder to inspect current evidence and post a concise update?",
		})
	}
	if hasCodeChanges {
		actions = append(actions, changes)
		actions = append(actions, review)
	}
	if publication.HasPR() {
		actions = append(actions, viewPR)
		if publication.Published() {
			actions = append(actions, checkDelivery)
		}
	}
	return append(actions, closeIncident)
}

// publishAction is the publication control, named for what pressing it will
// actually do to the PR that already exists — or does not.
//
// Shared by the incident and task cards so the four label variants and their
// confirmations cannot drift apart: the confirmation is the only place the
// operator is told that lease-protected publication cannot merge or deploy.
func publishAction(incident core.Incident, publication core.Publication) Action {
	publish := Action{
		ID: ActionPublishPR, Label: "Create draft PR (operator)",
		Value: PublicationActionValue(incident.ID, publication.Generation), Style: "primary",
		Confirm: "Run a fresh Coop readiness review, recreate the exact approved tree in an isolated checkout, push a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
	}
	if publication.HasPR() {
		publish.Label = "Update PR"
		if publication.State == core.PublicationFailed {
			publish.Label = "Retry PR update"
		}
		publish.Confirm = fmt.Sprintf(
			"Run a fresh Coop readiness review and update existing PR #%d using lease-protected branch publication? This cannot merge or deploy.",
			publication.PRNumber,
		)
	} else if publication.State == core.PublicationFailed {
		publish.Label = "Retry draft PR"
	}
	return publish
}

// closeWorkAction is red only when closing is about to strand something.
//
// Both confirmations are preserved word for word: the second one is the only
// warning that a closed Coop session can no longer be reviewed or published,
// which is the difference between closing an empty task and abandoning work.
func closeWorkAction(
	incident core.Incident,
	hasCodeChanges bool,
	publication core.Publication,
) Action {
	closeWork := Action{
		ID: ActionResolve, Label: "Close incident", Value: incident.ID, Style: "danger",
		Confirm: "Close this work? Responder later reclaims zero-change or published workspace state. Unpublished changes remain retained for operator action.",
	}
	if incident.IsEngineeringTask() {
		closeWork.Label = "Close task"
		if hasCodeChanges && !publication.Published() {
			closeWork.Confirm = "Close this task and retain its unpublished changes? Closed Coop sessions cannot be reviewed or published. Create the draft PR first unless you intend to inspect and explicitly discard the retained work later."
		}
	}
	return closeWork
}

func incidentStatusLabel(status core.IncidentStatus) string {
	switch status {
	case core.IncidentActive:
		return "Active"
	case core.IncidentMonitoring:
		return "Monitoring recovery"
	case core.IncidentResolved:
		return "Resolved"
	case core.IncidentClosed:
		return "Closed"
	default:
		return displayOr(strings.ReplaceAll(string(status), "_", " "), "Unknown")
	}
}

func IncidentStatusMessage(incident core.Incident) Message {
	status := incidentStatusLabel(incident.Status)
	activity := workActivityLabel(incident)
	next := "Reply normally in this incident channel to give Responder its next request."
	noun := "Incident"
	stateLabel := "Alert state"
	if incident.IsEngineeringTask() {
		noun = "Engineering task"
		stateLabel = "Task state"
		next = "Reply normally in this thread to give Responder its next request."
	}
	switch incident.Workflow {
	case core.WorkflowProvisioningChannel, core.WorkflowProvisioningSession:
		next = "Wait for preparation to finish. The work card will update automatically."
	case core.WorkflowHolding:
		next = "Responder will start when capacity is available. Close another work item if this is urgent."
	case core.WorkflowInvestigating:
		next = "An agent turn is running or queued. Wait for its update, or use `/responder stop` to cancel it."
		if incident.IsEngineeringTask() {
			next = "An agent turn is running or queued. Wait for its update; a configured operator can use *Stop* on the current task card."
		}
	case core.WorkflowBlocked:
		// *Action needed* is rendered on the card only when the work item
		// recorded an error, so blocked-with-no-recorded-reason must not point
		// at it — that sends the reader hunting for a section which is not
		// there. taskAsk already learned this; this is its twin.
		next = "Reply here with how to continue, or close the " + workNoun(incident) + "."
		if incident.LastError != "" {
			next = "Read *Action needed* on the work card, resolve that blocker, then reply to continue."
		}
	case core.WorkflowClosed:
		next = "This work item no longer accepts agent turns. Dirty or unpublished changes are retained; published or zero-change workspace state expires by policy."
	}
	// Three sections said the state, then described the state, then said what
	// to do about it — with the label of each restating its own contents. One
	// section carries the same two facts and stops competing with the card
	// this message is a read-only echo of.
	message := Message{
		Text: fmt.Sprintf(
			"%s — %s %s is %s. %s %s",
			activity, noun, ShortID(incident.ID), strings.ToLower(status),
			signalStateSummary(incident), next,
		),
		Header:   noun + " " + ShortID(incident.ID) + ": " + activity,
		Sections: []string{workflowStateDescription(incident) + " " + next},
		Context: []string{
			"*" + stateLabel + ": " + status + "* · Status is read-only. No publication, " +
				"merge, signing, deployment, or infrastructure change was requested.",
		},
	}
	// The only control a status readout has earned. There is no card URL to
	// link back to, so a second button would have nowhere to send anyone.
	if incident.ActiveTurnID != "" {
		message.Actions = []Action{{
			ID: ActionStop, Label: "Stop the turn", Value: incident.ID,
			Confirm: "Stop the active agent turn? The fork and queued work are preserved.",
		}}
	}
	return message
}

// writePostmortemCommitments replaces the line that used to read
// "- [ ] Assign remaining corrective actions and owners".
//
// That sentence was the whole problem with a prose postmortem: it asked a
// reader to do the tracking, in a document nobody re-opens, at the end of the
// week the incident happened. Every episode this incident ran already produced
// a commitment — the same rows the App Home and `/responder commitments` read —
// with a title somebody wrote, a state the lifecycle maintains, and a thread
// the work is still in. Listing those is the difference between an action item
// and an action.
//
// Done work is rendered as a ticked box rather than dropped. A postmortem that
// showed only what is outstanding would answer "what is left" and lose "what we
// did", and the second is most of what a reader came for.
//
// The closing line stays when there is nothing to list. An incident that
// produced no tracked work still needs somebody to say whether anything is
// owed, and a silent section reads as "nothing is owed".
func writePostmortemCommitments(body *strings.Builder, commitments []core.Commitment) {
	if len(commitments) == 0 {
		body.WriteString("\n- [ ] Assign remaining corrective actions and owners\n")
		return
	}
	for _, commitment := range commitments {
		box := "[ ]"
		if commitment.State == core.CommitmentDone {
			box = "[x]"
		}
		fmt.Fprintf(
			body, "\n- %s %s — `%s`", box,
			truncateUTF8(escapeSlackText(commitment.Title), 200),
			safeInlineCode(string(commitment.State)),
		)
		if link := commitmentThreadURL(commitment); link != "" {
			fmt.Fprintf(body, " ([thread](%s))", link)
		}
	}
	body.WriteString("\n")
}

// commitmentThreadURL is the episode link an action item carries.
//
// app_redirect rather than a workspace permalink, matching the App Home: it
// needs no team domain, which this process does not store, and Slack resolves
// it to the same message. A commitment with no channel gets no link rather than
// a broken one.
func commitmentThreadURL(commitment core.Commitment) string {
	if strings.TrimSpace(commitment.ChannelID) == "" {
		return ""
	}
	link := "https://slack.com/app_redirect?channel=" + url.QueryEscape(commitment.ChannelID)
	if anchor := strings.TrimSpace(commitment.ThreadTS); anchor != "" {
		link += "&message_ts=" + url.QueryEscape(anchor)
	}
	return link
}
