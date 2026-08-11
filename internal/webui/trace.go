package webui

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

// EpisodeMetric is one answer an operator should get before reading the trace.
// Missing is a first-class value: an old episode without a reaction timestamp
// did not react in zero seconds, it has no measurement.
type EpisodeMetric struct {
	Label, Value, Detail, Tone string
	Missing                    bool
}

type TraceStat struct {
	Label, Value string
}

type TraceDetail struct {
	Label, Body, Kind         string
	Group, GroupDetail        string
	Status, Description, Tone string
	Open, ShowCount           bool
	Count, GroupCount         int
	Segments                  []PromptSegment
	Table                     *TraceTable
}

type PromptSegment struct {
	Body, Source, Tone, Hint string
	Tokens                   int
}

type TraceTable struct {
	Headers []string
	Rows    []TraceTableRow
}

type TraceTableRow struct {
	Cells []string
}

// TraceStep is one host-observable fact in the execution story. Why describes
// the product reason for the step, never private model chain-of-thought.
type TraceStep struct {
	ID, Stage, Actor, State, Title, Summary, Why string
	At                                           time.Time
	Relative, Duration                           string
	Stats                                        []TraceStat
	Details                                      []TraceDetail
	order                                        int
}

type EpisodeTrace struct {
	Metrics []EpisodeMetric
	Stats   []TraceStat
	Steps   []TraceStep
}

func buildEpisodeTrace(pricing config.Pricing, page episodePage, present func(string) string) EpisodeTrace {
	if present == nil {
		present = func(value string) string { return value }
	}
	trace := EpisodeTrace{}
	trace.Metrics = episodeMetrics(pricing, page)
	steps := make([]TraceStep, 0, 12+len(page.Events)+len(page.Attempts)+
		len(page.Effects)+len(page.Delivered)+len(page.Audit)+len(page.Turns)+
		len(page.Artifacts)+2*len(page.Wakeups))
	add := func(step TraceStep) {
		step.order = len(steps)
		steps = append(steps, step)
	}

	if page.Source.ID != "" {
		details := []TraceDetail{{Label: "Slack message", Body: present(page.Source.Text), Kind: "text", Open: true}}
		if strings.TrimSpace(page.Source.Attachments) != "" && page.Source.Attachments != "[]" {
			details = append(details, TraceDetail{Label: "Attachment manifest", Body: page.Source.Attachments, Kind: "json"})
		}
		add(TraceStep{
			ID: "source", Stage: "Input", Actor: "Slack", State: page.Source.Kind,
			Title: "Message received", At: page.Source.Received,
			Stats: []TraceStat{{"Channel", page.Source.Channel}, {"Message", page.Source.MessageTS},
				{"Thread", fallback(page.Source.ThreadTS, "top level")}, {"Sender", fallback(page.Source.Sender, page.Source.UserID)}},
			Details: details,
		})
	} else {
		add(TraceStep{
			ID: "source-missing", Stage: "Input", Actor: "Responder", State: "not recorded",
			Title: "Starting input unavailable", At: page.Created,
			Summary: "This historical episode does not retain the Slack or scheduled input that started it.",
			Why:     "The timeline marks the missing record instead of presenting a later event as the beginning of the work.",
		})
	}
	wakeups := page.Wakeups
	if len(wakeups) == 0 && page.Wakeup.ID != "" {
		wakeups = []Wakeup{page.Wakeup}
	}
	for wakeupIndex, wakeup := range wakeups {
		scheduledID, resolvedID := "wakeup-scheduled", "wakeup-resolved"
		if len(wakeups) > 1 {
			scheduledID = fmt.Sprintf("wakeup-%d-scheduled", wakeupIndex+1)
			resolvedID = fmt.Sprintf("wakeup-%d-resolved", wakeupIndex+1)
		}
		details := []TraceDetail{{
			Label: "Exact event matcher", Body: wakeup.Matcher, Kind: "json",
		}}
		stats := []TraceStat{{"Type", wakeup.Kind}, {"Wake-up", wakeup.ID}}
		if !wakeup.Due.IsZero() {
			stats = append(stats, TraceStat{"Due", wakeup.Due.Format(time.RFC3339)})
		}
		if !wakeup.Deadline.IsZero() {
			stats = append(stats, TraceStat{"Deadline", wakeup.Deadline.Format(time.RFC3339)})
		}
		add(TraceStep{
			ID: scheduledID, Stage: "Wait", Actor: "Responder", State: "scheduled",
			Title: "Wake-up scheduled", At: wakeup.Created,
			Summary: wakeupSummary(wakeup),
			Why:     "The external work was not finished, so Responder saved what to watch and released the worker. This durable wake-up could resume the same work after the matching event arrived.",
			Stats:   stats, Details: details,
		})
		if !wakeup.Resolved.IsZero() {
			resolvedDetails := []TraceDetail{}
			if wakeup.Observation != "" && wakeup.Observation != "{}" {
				resolvedDetails = append(resolvedDetails, TraceDetail{
					Label: "Event that satisfied the wait", Body: wakeup.Observation, Kind: "json", Open: true,
				})
			}
			add(TraceStep{
				ID: resolvedID, Stage: "Wait", Actor: "Responder", State: wakeup.State,
				Title: "Wake-up resolved", At: wakeup.Resolved,
				Summary: "The awaited condition was observed; the episode could continue.",
				Stats:   []TraceStat{{"Type", wakeup.Kind}, {"Wake-up", wakeup.ID}, {"Final state", wakeup.State}},
				Details: resolvedDetails,
			})
		}
	}
	if page.Trigger.ID != "" && page.Trigger.ID != page.Source.ID {
		title := "Automatic follow-up started"
		if len(wakeups) > 0 {
			title = "Wake-up delivered"
		}
		details := []TraceDetail{{
			Label: "Resume instruction", Body: present(page.Trigger.Text), Kind: "text", Open: true,
		}}
		add(TraceStep{
			ID: "trigger", Stage: "Trigger", Actor: "Responder", State: page.Trigger.Kind,
			Title: title, At: page.Trigger.Received,
			Summary: "A matching external event resumed the work linked to this Slack thread.",
			Why:     "Responder was waiting for this event. It resumed the existing work automatically instead of requiring another Slack message.",
			Stats: []TraceStat{{"Channel", page.Trigger.Channel},
				{"Thread", fallback(page.Trigger.ThreadTS, "top level")}, {"Trigger", page.Trigger.Kind}},
			Details: details,
		})
	}

	manifests := page.Manifests
	if len(manifests) == 0 && page.Manifest.Version > 0 {
		manifests = []ManifestRow{page.Manifest}
	}
	for manifestIndex, manifest := range manifests {
		modelID, promptID := "model", "prompt"
		if len(manifests) > 1 {
			modelID = fmt.Sprintf("model-%d", manifestIndex+1)
			promptID = fmt.Sprintf("prompt-%d", manifestIndex+1)
		}
		add(TraceStep{
			ID: modelID, Stage: "Routing", Actor: "Responder", State: "selected",
			Title: "Model selected", At: manifest.Created,
			Why:   modelSelectionWhy(manifest),
			Stats: []TraceStat{{"Provider", fallback(manifest.Provider, "not recorded")}, {"Model", fallback(manifest.Model, "not recorded")}, {"Reasoning", fallback(manifest.Effort, "not recorded")}, {"Preset", fallback(manifest.Preset, "none")}, {"Run", fallback(manifest.RunID, "not recorded")}},
		})

		prompt := manifest.SubmittedPrompt
		if prompt == "" {
			if turn, ok := turnByRun(page.Turns, manifest.RunID); ok {
				prompt = turn.Prompt
			} else if manifest.RunID == page.Turn.RunID {
				prompt = page.Turn.Prompt
			}
		}
		promptDetails := []TraceDetail{}
		memoryLayers := 0
		if prompt != "" {
			components, layers := promptContextDetails(prompt, present)
			memoryLayers = layers
			promptDetails = append(promptDetails, components...)
		} else {
			promptDetails = append(promptDetails, TraceDetail{
				Label: "Submitted prompt", Body: "The prompt text was not retained for this attempt. Its digest remains available in the context references.",
				Kind: "missing", Status: "Not retained", Tone: "missing", Open: true,
			})
			promptDetails = append(promptDetails, TraceDetail{
				Label: "Memory components", Body: "The individual memory layers cannot be recovered for this historical attempt because its submitted prompt was not retained.",
				Kind: "missing", Status: "Not retained", Tone: "missing", Open: true,
			})
		}
		if prompt == "" {
			promptDetails = markDetailGroup(promptDetails,
				"Prompt record unavailable",
				"This historical attempt retained prompt metadata, but not the exact text sent to the model.",
			)
		}
		promptDetails = append(promptDetails, contextReferenceDetails(manifest.Refs, present)...)
		if len(manifest.Omissions) > 0 {
			promptDetails = append(promptDetails, TraceDetail{
				Label: "Manifest omissions", Body: present(strings.Join(manifest.Omissions, "\n")), Kind: "missing",
				Status: "Not sent", Tone: "missing", Open: true, ShowCount: true, Count: len(manifest.Omissions),
				Description: "These sources were assembled or considered, then left out before the model call.",
				Group:       "Not sent to the model", GroupDetail: "Responder assembled these inputs but omitted them before submission.",
				GroupCount: 1,
			})
		}
		if prompt != "" {
			segments := promptSegments(present(prompt))
			promptDetails = append(promptDetails, TraceDetail{
				Label: "Final submitted prompt", Body: present(prompt), Kind: "prompt",
				Status: "Exact model input", Tone: "prompt", Open: true,
				Description: "The complete prompt after selection and size trimming. Every section is color-coded by its source; hover a section header for its token estimate.",
				Group:       "Exact model input", GroupDetail: "This is the final text Coop submitted to the model, shown after every source and runtime control that informed it.",
				GroupCount: 1, Segments: segments,
			})
		}
		// Prompt sources can be large. Keep the inventory, counts, and selection
		// rationale scannable while leaving full bodies one click away.
		for index := range promptDetails {
			promptDetails[index].Open = false
		}
		add(TraceStep{
			ID: promptID, Stage: "Context", Actor: "Responder", State: "frozen",
			Title: "Prompt assembled", Summary: fmt.Sprintf("Manifest v%d with %d context components", manifest.Version, len(manifest.Refs)), At: manifest.Created,
			Stats:   []TraceStat{{"Prompt", fallback(manifest.PromptVersion, "unversioned")}, {"Contract", fallback(manifest.Contract, "none")}, {"Tool schema", fallback(manifest.ToolSchema, "none")}, {"Context refs", fmt.Sprint(len(manifest.Refs))}, {"Memory layers", fmt.Sprint(memoryLayers)}, {"Attempt", fmt.Sprint(manifest.AttemptNumber)}},
			Details: promptDetails,
		})
	}

	for index, event := range page.Events {
		why := eventWhy(event.Kind)
		details := []TraceDetail{}
		if payload := presentEventPayload(event.Payload, present); payload != "" && payload != "{}" {
			details = append(details, TraceDetail{Label: "Recorded event payload", Body: payload, Kind: "json"})
		}
		if occurrences := occurrenceDetail(event.Occurrences); occurrences != nil {
			details = append(details, *occurrences)
		}
		add(TraceStep{
			ID: fmt.Sprintf("event-%d", index+1), Stage: eventStage(event.Kind), Actor: event.Actor,
			State: event.Kind, Title: eventTitle(event.Kind), Summary: present(event.Detail), Why: why, At: event.At,
			Stats: []TraceStat{{"Attempt", fmt.Sprint(event.Attempt)}, {"Repeats", repeatValue(event.Repeats)}}, Details: details,
		})
	}

	for index, artifact := range page.Artifacts {
		details := []TraceDetail{}
		if strings.TrimSpace(artifact.Detail) != "" {
			details = append(details, TraceDetail{
				Label: artifactDetailLabel(artifact.Kind), Body: present(artifact.Detail),
				Kind: fallback(artifact.DetailKind, "text"), Open: false,
			})
		}
		stats := make([]TraceStat, 0, len(artifact.Stats))
		for _, stat := range artifact.Stats {
			if strings.TrimSpace(stat.Value) != "" {
				stats = append(stats, TraceStat{stat.Label, present(stat.Value)})
			}
		}
		add(TraceStep{
			ID:    fmt.Sprintf("record-%s-%d", artifact.Kind, index+1),
			Stage: artifactStage(artifact.Kind), Actor: artifactActor(artifact.Kind),
			State: fallback(artifact.State, "recorded"), Title: present(artifact.Title), Summary: present(artifact.Summary),
			Why: artifactWhy(artifact.Kind), At: artifact.At, Stats: stats, Details: details,
		})
	}

	for _, attempt := range page.Attempts {
		detail := strings.TrimSpace(present(attempt.Error))
		if detail == "" {
			detail = "No terminal error was recorded."
		}
		add(TraceStep{
			ID: fmt.Sprintf("attempt-%d", attempt.Number), Stage: "Execution", Actor: "Coop", State: attempt.State,
			Title: fmt.Sprintf("Attempt %d %s", attempt.Number, attempt.State), Summary: attemptSummary(attempt), Why: attemptWhy(attempt), At: attempt.Completed,
			Duration: traceDuration(attempt.Started, attempt.Completed),
			Stats:    []TraceStat{{"Run", attempt.RunID}, {"Failure class", fallback(attempt.Failure, "none")}},
			Details:  []TraceDetail{{Label: "Terminal detail", Body: detail, Kind: "text"}},
		})
	}

	for index, rejection := range page.Rejections {
		add(TraceStep{
			ID: fmt.Sprintf("rejection-%d", index+1), Stage: "Validation", Actor: "Responder", State: "rejected",
			Title: "Host rejected a model result", Summary: present(rejection.Outcome), Why: "The typed result contract refused output that could not be applied safely or consistently, and returned a correction to the same attempt.", At: rejection.At,
			Stats:   []TraceStat{{"Run", fallback(rejection.RunID, "not recorded")}},
			Details: []TraceDetail{{Label: "Correction sent to the model", Body: present(rejection.Detail), Kind: "text", Open: true}},
		})
	}

	turns := page.Turns
	if len(turns) == 0 && page.Turn.RunID != "" {
		turns = []Turn{page.Turn}
	}
	for turnIndex, turn := range turns {
		details := []TraceDetail{}
		if turn.Reason != "" {
			details = append(details, TraceDetail{Label: "Host-visible decision rationale", Body: present(turn.Reason), Kind: "text", Open: true})
		}
		if turn.RawResult != "" {
			details = append(details, TraceDetail{Label: "Raw model result received by Responder", Body: present(prettyJSON(turn.RawResult)), Kind: "json"})
		}
		if len(turn.Operations) > 0 {
			operations := make([]string, 0, len(turn.Operations))
			for _, operation := range turn.Operations {
				operations = append(operations, fmt.Sprintf("%s x%d", operation.Name, operation.Count))
			}
			details = append(details, TraceDetail{
				Label: "Typed result operations",
				Body:  strings.Join(operations, "\n"),
				Kind:  "text",
			})
		}
		details = append(details, TraceDetail{Label: "Provider transcript boundary", Body: "Coop records the submitted prompt, public model result, typed operations, artifacts, usage, and timings. It does not currently return the provider's private chain-of-thought or a granular transcript of every internal tool call, so this page does not invent either.", Kind: "missing"})
		resultID := "result"
		if len(turns) > 1 {
			resultID = fmt.Sprintf("result-%d", turnIndex+1)
		}
		add(TraceStep{
			ID: resultID, Stage: "Result", Actor: "Model", State: turn.State,
			Title: "Model result received", Summary: present(modelSummary(turn)), Why: "Responder parses and validates the result before any reply or side effect can leave the host.", At: turn.Updated,
			Stats:   []TraceStat{{"Run", turn.RunID}, {"Attempt", fmt.Sprint(turn.AttemptNumber)}, {"Action", fallback(turn.Action, "not recorded")}, {"Operations", fmt.Sprint(tallyTotal(turn.Operations))}, {"Follow-ups", fmt.Sprint(len(turn.Followups))}},
			Details: details,
		})
	}

	if page.Manifest.Version > 0 {
		add(usageTraceStep(page))
	}

	if len(page.Claims)+len(page.Evidence)+len(page.Coverage) > 0 {
		add(TraceStep{
			ID: "ledger", Stage: "Evidence", Actor: "Responder", State: "recorded",
			Title: "Evidence ledger updated", Summary: fmt.Sprintf("%d claims, %d evidence records, %d coverage assessments", len(page.Claims), len(page.Evidence), len(page.Coverage)),
			Why: "Structured evidence lets the host distinguish a supported conclusion from a fluent answer and preserve contradictions for later follow-up.", At: page.Turn.Updated,
			Stats:   []TraceStat{{"Claims", fmt.Sprint(len(page.Claims))}, {"Evidence", fmt.Sprint(len(page.Evidence))}, {"Coverage", fmt.Sprint(len(page.Coverage))}},
			Details: ledgerDetails(page, present),
		})
	}

	for index, effect := range page.Effects {
		body := present(effect.Detail)
		if effect.Before != "" || effect.After != "" {
			body = "Before:\n" + present(fallback(effect.Before, "(empty)")) + "\n\nAfter:\n" + present(fallback(effect.After, "(empty)"))
			if effect.Detail != "" {
				body += "\n\n" + present(effect.Detail)
			}
		}
		add(TraceStep{
			ID: fmt.Sprintf("effect-%d", index+1), Stage: "Side effect", Actor: "Responder", State: effect.State,
			Title: present(effect.Title), Summary: present(effect.Kind), Why: sideEffectWhy(effect), At: effect.At,
			Stats:   []TraceStat{{"Type", effect.Kind}, {"ID", fallback(effect.ID, "none")}},
			Details: []TraceDetail{{Label: "Recorded change", Body: fallback(body, "No additional value was recorded."), Kind: "diff", Open: effect.Before != "" || effect.After != ""}},
		})
	}

	for index, delivery := range page.Delivered {
		summary := delivery.Channel
		if delivery.ThreadTS != "" {
			summary += " thread " + delivery.ThreadTS
		}
		details := []TraceDetail{}
		if delivery.Body != "" {
			details = append(details, TraceDetail{Label: "Slack payload", Body: present(delivery.Body), Kind: "json"})
		}
		if delivery.Error != "" {
			details = append(details, TraceDetail{Label: "Delivery error", Body: present(delivery.Error), Kind: "error", Open: true})
		}
		add(TraceStep{
			ID: fmt.Sprintf("delivery-%d", index+1), Stage: "Delivery", Actor: "Slack outbox", State: delivery.State,
			Title: "Slack " + delivery.Operation, Summary: summary, Why: deliveryWhy(delivery), At: delivery.At,
			Duration: traceDuration(delivery.Created, delivery.At),
			Stats:    []TraceStat{{"Message", fallback(delivery.MessageTS, "none")}, {"Retries", fmt.Sprint(delivery.Retries)}, {"Kind", delivery.Kind}}, Details: details,
		})
	}

	for index, audit := range page.Audit {
		// Removing a temporary working marker is Slack plumbing, not another
		// rule decision. The evaluation card already explains the marker and
		// the workflow it belongs to.
		if audit.Kind == "standing_rule.acknowledgement_cleared" {
			continue
		}
		summary, stats := auditTracePresentation(audit, present)
		stage, actor, state := "Audit", audit.Whom, audit.Outcome
		if audit.Kind == "standing_rules.evaluated" || audit.Kind == "standing_rule.acknowledged" {
			stage, actor, state = "", "", ""
		}
		details := auditTraceDetails(audit, present)
		if occurrences := occurrenceDetail(audit.Occurrences); occurrences != nil {
			details = append(details, *occurrences)
		}
		add(TraceStep{
			ID: fmt.Sprintf("audit-%d", index+1), Stage: stage, Actor: actor, State: state,
			Title: eventTitle(audit.Kind), Summary: summary, Why: auditTraceWhy(audit), At: audit.At,
			Stats: stats, Details: details,
		})
	}

	sort.SliceStable(steps, func(i, j int) bool {
		if steps[i].At.IsZero() != steps[j].At.IsZero() {
			return !steps[i].At.IsZero()
		}
		if steps[i].At.Equal(steps[j].At) {
			return steps[i].order < steps[j].order
		}
		return steps[i].At.Before(steps[j].At)
	})
	start := page.Source.Received
	if start.IsZero() {
		start = page.Created
	}
	for index := range steps {
		if !steps[index].At.IsZero() && !start.IsZero() {
			steps[index].Relative = "+" + compactDuration(steps[index].At.Sub(start))
		}
	}
	trace.Steps = steps
	trace.Stats = []TraceStat{
		{"Timeline steps", fmt.Sprint(len(steps))},
		{"Attempts", fmt.Sprint(len(page.Attempts))},
		{"Model turns", fmt.Sprint(len(turns))},
		{"Wake-ups", fmt.Sprint(len(wakeups))},
		{"Durable records", fmt.Sprint(len(page.Artifacts))},
		{"Context components", fmt.Sprint(len(page.Manifest.Refs))},
		{"Evidence records", fmt.Sprint(len(page.Evidence))},
		{"Side effects", fmt.Sprint(len(page.Effects))},
		{"Slack deliveries", fmt.Sprint(len(page.Delivered))},
	}
	return trace
}

func auditTracePresentation(audit AuditRow, present func(string) string) (string, []TraceStat) {
	if audit.Kind == "standing_rules.evaluated" {
		var evaluation core.StandingRuleEvaluationAudit
		if err := json.Unmarshal([]byte(audit.Detail), &evaluation); err == nil {
			skipped := max(evaluation.Checked-evaluation.Matched, 0)
			stats := []TraceStat{
				{"Active rules", fmt.Sprint(evaluation.Checked)},
				{"Matched", fmt.Sprint(evaluation.Matched)},
				{"Skipped", fmt.Sprint(skipped)},
			}
			if evaluation.Acknowledged != "" {
				stats = append(stats, TraceStat{
					"Working marker", slackReactionDisplay(evaluation.Acknowledged),
				})
			}
			return "", stats
		}
	}
	if audit.Kind == "standing_rule.acknowledged" {
		name := strings.Trim(strings.TrimSpace(audit.Detail), ":")
		return "", []TraceStat{
			{"Active rules", "Not recorded"},
			{"Matched", "At least 1"},
			{"Skipped", "Not recorded"},
			{"Working marker", slackReactionDisplay(name)},
		}
	}
	stats := []TraceStat{{"Actor", audit.Actor}, {"Object", fallback(audit.Object, "none")}, {"Repeats", repeatValue(audit.Repeats)}}
	summary := present(audit.Detail)
	if audit.Outcome != "reacted" && audit.Outcome != "unreacted" {
		return summary, stats
	}
	name := strings.Trim(strings.TrimSpace(audit.Detail), ":")
	if name == "" {
		return summary, stats
	}
	display := slackReactionDisplay(name)
	stats = append(stats, TraceStat{"Slack name", ":" + name + ":"})
	return display, stats
}

func auditTraceWhy(audit AuditRow) string {
	switch audit.Kind {
	case "standing_rules.evaluated", "standing_rule.acknowledged":
		return ""
	case "standing_rule.acknowledgement_cleared":
		return "Responder removed the temporary acknowledgement after the matched rule finished or became quiet."
	default:
		return "The audit ledger attributes a decision or mutation to an actor and preserves its outcome independently of Slack presentation."
	}
}

func auditTraceDetails(audit AuditRow, present func(string) string) []TraceDetail {
	if audit.Kind == "standing_rule.acknowledged" {
		return []TraceDetail{{
			Label: "Matched rule - details not recorded",
			Body: "Why it matched\nA confirmed channel rule matched this message.\n\n" +
				"What happened\nResponder added " + slackReactionDisplay(audit.Detail) +
				" and started the rule's read-only work.\n\n" +
				"Historical limit\nThis older event did not save the rule name or the rules that were skipped.",
			Kind: "rule", Open: true,
		}}
	}
	if audit.Kind != "standing_rules.evaluated" {
		return nil
	}
	var evaluation core.StandingRuleEvaluationAudit
	if err := json.Unmarshal([]byte(audit.Detail), &evaluation); err != nil {
		return []TraceDetail{{
			Label: "Rule evaluation record", Body: present(audit.Detail), Kind: "json",
		}}
	}
	details := make([]TraceDetail, 0, len(evaluation.Rules))
	for _, rule := range evaluation.Rules {
		state := "Skipped"
		whyLabel := "Why it did not match"
		now := "None. This rule does not affect this message."
		if rule.Matched {
			state = "Matched"
			whyLabel = "Why it matched"
			now = "This workflow now controls which checks run and when Slack gets a reply."
		}
		name := strings.TrimSpace(rule.Name)
		if name == "" {
			name = "Standing rule"
		}
		body := whyLabel + "\n" + present(rule.Why) + "\n\nWhat it watches\n" +
			present(rule.Trigger) + "\n\nWhat it does\n" + present(rule.Work) +
			"\n\nSlack behavior\n" + present(rule.Delivery) +
			"\n\nEffect on this message\n" + now
		details = append(details, TraceDetail{
			Label: state + " - " + present(name), Body: body, Kind: "rule", Open: true,
		})
	}
	return details
}

func slackReactionDisplay(name string) string {
	if emoji, ok := map[string]string{
		"eyes":             "👀",
		"white_check_mark": "✅",
		"heavy_check_mark": "✔️",
		"thumbsup":         "👍",
		"+1":               "👍",
		"tada":             "🎉",
		"warning":          "⚠️",
		"bulb":             "💡",
	}[name]; ok {
		return emoji
	}
	// Custom workspace emoji do not have a universal Unicode representation.
	// Keep their Slack spelling recognizable instead of presenting a bare API name.
	return ":" + name + ":"
}

// promptContextDetails makes the memory envelope inspectable without storing a
// second copy of it. The exact JSON already lives inside the submitted prompt;
// this projection only labels its independently assembled layers so an
// operator can answer "which memory influenced this turn?" without searching
// a wall of instructions. It deliberately does not infer a layer when the
// prompt predates retention or when a field is absent.
func promptContextDetails(prompt string, present func(string) string) ([]TraceDetail, int) {
	const open = "<untrusted-slack-context>\n"
	const close = "\n</untrusted-slack-context>"
	start := strings.LastIndex(prompt, open)
	if start < 0 {
		return nil, 0
	}
	start += len(open)
	end := strings.Index(prompt[start:], close)
	if end < 0 {
		return nil, 0
	}

	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(prompt[start:start+end]), &envelope) != nil {
		return nil, 0
	}
	details := make([]TraceDetail, 0, len(envelope)+12)
	layerCount := 0
	seen := map[string]bool{}

	// Slack conversation. Alias sets represent schema evolution; only the value
	// selected by the compiler is shown, never duplicate spellings of it.
	slack := []TraceDetail{}
	for _, aliases := range [][]string{
		{"target_message", "source_message"},
		{"recent_messages_around_target", "recent_messages", "recent_channel_messages"},
		{"referenced_thread"}, {"attachments"}, {"channel_context"}, {"channel_id"},
	} {
		key, raw := firstPromptField(envelope, aliases...)
		for _, alias := range aliases {
			seen[alias] = true
		}
		if key == "" {
			key = aliases[0]
			slack = append(slack, missingPromptFieldDetail(key))
			continue
		}
		slack = append(slack, promptFieldDetail(key, raw, present))
	}
	details = append(details, markDetailGroup(slack,
		"Slack conversation",
		"The triggering message and nearby conversation selected for this turn. Included rows show their complete submitted content.",
	)...)

	// Memory. Each root is selected independently and expanded into the actual
	// values sent to the model so the page never hides memory behind a digest.
	for _, layer := range []struct {
		keys, priority            []string
		label, group, groupDetail string
	}{
		{[]string{"prior_operational_context"}, []string{"current_incidents", "open_commitments", "pending_approvals", "operator_confirmed_memory", "confirmed_memory", "automatically_synthesized_continuity", "recent_same_channel_evidence", "responder_preferences"}, "Operational memory", "Operational memory", "Current commitments, confirmed guidance, preferences, and recent evidence selected for this work."},
		{[]string{"structured_memory", "conversation_situation"}, []string{"goal", "situation_summary", "channel_purpose", "topology", "decisions", "constraints", "unresolved_questions", "evidence_refs"}, "Conversation memory", "Conversation memory", "A compact summary of the exact thread when available, otherwise the channel's continuity summary."},
		{[]string{"related_situations"}, nil, "Related conversation summaries", "Related conversations", "Up to six relevant summaries selected from the workspace's recent conversation memory."},
	} {
		key, raw := firstPromptField(envelope, layer.keys...)
		for _, alias := range layer.keys {
			seen[alias] = true
		}
		var rows []TraceDetail
		if key == "" {
			rows = []TraceDetail{missingMemoryDetail(layer.label, layer.keys[0])}
		} else {
			layerCount++
			rows = memoryLayerDetails(raw, key, layer.label, layer.priority, present)
		}
		details = append(details, markDetailGroup(rows, layer.group, layer.groupDetail)...)
	}

	workspace := []TraceDetail{}
	for _, key := range []string{
		"repository", "initial_task_changes_fingerprint", "structured_corrections",
		"reply_shape_corrections", "context_omitted", "captured_at",
	} {
		seen[key] = true
		if emptyJSON(envelope[key]) {
			if key == "context_omitted" {
				workspace = append(workspace, missingPromptFieldDetail(key))
			}
			continue
		}
		workspace = append(workspace, promptFieldDetail(key, envelope[key], present))
	}
	details = append(details, markDetailGroup(workspace,
		"Workspace and prompt controls",
		"Repository selection, retry corrections, and any content removed to fit the model input.",
	)...)

	rest := make([]string, 0, len(envelope))
	for key, raw := range envelope {
		if !seen[key] && !emptyJSON(raw) {
			rest = append(rest, key)
		}
	}
	sort.Strings(rest)
	for _, key := range rest {
		detail := promptFieldDetail(key, envelope[key], present)
		if len(rest) > 0 && key == rest[0] {
			detail.Group = "Other submitted context"
			detail.GroupDetail = "Additional typed context retained by this prompt version."
			detail.GroupCount = len(rest)
		}
		details = append(details, detail)
	}
	return details, layerCount
}

func firstPromptField(envelope map[string]json.RawMessage, keys ...string) (string, json.RawMessage) {
	for _, key := range keys {
		if !emptyJSON(envelope[key]) {
			return key, envelope[key]
		}
	}
	return "", nil
}

func missingPromptFieldDetail(key string) TraceDetail {
	label, tone := promptFieldPresentation(key)
	return TraceDetail{
		Label: label, Body: "No content selected.", Kind: "missing",
		Status: "Not sent", Description: promptSelectionDescription(key, false), Tone: tone,
		Open: true, ShowCount: true,
	}
}

func missingMemoryDetail(label, key string) TraceDetail {
	return TraceDetail{
		Label: label, Body: "No content selected.", Kind: "missing",
		Status: "Not sent", Description: promptSelectionDescription(key, false), Tone: promptTone(key),
		Open: true, ShowCount: true,
	}
}

func promptFieldDetail(key string, raw json.RawMessage, present func(string) string) TraceDetail {
	label, tone := promptFieldPresentation(key)
	return TraceDetail{
		Label: label, Body: promptFieldBody(key, raw, present), Kind: "context",
		Status: "Sent to model", Description: promptSelectionDescription(key, true), Tone: tone,
		Open: true, ShowCount: true, Count: contextEntryCount(raw),
	}
}

func promptTone(key string) string {
	_, tone := promptFieldPresentation(key)
	return tone
}

func promptSelectionDescription(key string, included bool) string {
	selected, absent := "Included in the exact model input.", "No eligible content was selected for this turn."
	if value, ok := map[string][2]string{
		"target_message":                {"The exact Slack message that started this episode.", "The source message was not retained in this historical prompt."},
		"source_message":                {"The exact Slack message that started this episode.", "The source message was not retained in this historical prompt."},
		"recent_messages_around_target": {"A bounded chronological window around the triggering message, not simply the latest channel messages.", "No additional nearby Slack messages were admitted into this prompt."},
		"recent_messages":               {"A bounded chronological window around the triggering message, not simply the latest channel messages.", "No additional nearby Slack messages were admitted into this prompt."},
		"recent_channel_messages":       {"A bounded chronological window around the triggering message, not simply the latest channel messages.", "No additional nearby Slack messages were admitted into this prompt."},
		"referenced_thread":             {"The referenced or anchored thread, included when the request points to another conversation.", "This request did not resolve to a separate referenced thread."},
		"attachments":                   {"Slack files and attachment metadata admitted for this request.", "No Slack attachments were admitted for this request."},
		"channel_context":               {"Channel metadata used to understand where the conversation is happening.", "No additional channel metadata was needed."},
		"channel_id":                    {"The Slack channel that scopes conversation and channel memory.", "The prompt did not retain a channel identifier."},
		"prior_operational_context":     {"Operational state selected by recency, scope, provenance, and relevance.", "No current operational memory was relevant to this turn."},
		"structured_memory":             {"The exact thread summary when available; otherwise the compact channel summary.", "No compact conversation summary was available for this turn."},
		"conversation_situation":        {"The exact thread summary when available; otherwise the compact channel summary.", "No compact conversation summary was available for this turn."},
		"related_situations":            {"At most 6 relevance-ranked summaries selected from up to 40 recent candidates.", "None of the recent conversation summaries were relevant enough to include."},
		"repository":                    {"The repository or repository set chosen for this channel and request.", "No repository was selected for this turn."},
		"context_omitted":               {"Context removed by deterministic size trimming before submission.", "Nothing was removed from the assembled prompt for size."},
	}[key]; ok {
		if included {
			return value[0]
		}
		return value[1]
	}
	if included {
		return selected
	}
	return absent
}

// contextEntryCount reports how many semantic values from an assembled
// context component reached this exact prompt. A JSON object is one record;
// its encoding fields are not separate memories or Slack messages. Lists keep
// their item count so the episode page can distinguish one retained item from
// a bounded transcript or evidence set without exposing storage details.
func contextEntryCount(raw json.RawMessage) int {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		if strings.TrimSpace(string(raw)) == "" {
			return 0
		}
		return 1
	}
	switch typed := value.(type) {
	case nil:
		return 0
	case []any:
		return len(typed)
	case map[string]any:
		if len(typed) == 0 {
			return 0
		}
		return 1
	case string:
		if strings.TrimSpace(typed) == "" {
			return 0
		}
		return 1
	default:
		return 1
	}
}

func promptFieldBody(key string, raw json.RawMessage, present func(string) string) string {
	switch key {
	case "target_message", "source_message":
		return slackPromptMessages(raw, present)
	case "referenced_thread", "recent_messages_around_target", "recent_messages",
		"recent_channel_messages", "channel_context":
		return slackPromptMessages(raw, present)
	case "channel_id":
		var value string
		if json.Unmarshal(raw, &value) == nil {
			return present(value)
		}
	case "repository":
		var value string
		if json.Unmarshal(raw, &value) == nil {
			return value
		}
	case "attachments":
		return humanJSON(raw, present, 0)
	}
	return humanJSON(raw, present, 0)
}

func slackPromptMessages(raw json.RawMessage, present func(string) string) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return present(prettyJSON(string(raw)))
	}
	items := []any{value}
	if list, ok := value.([]any); ok {
		items = list
	}
	parts := make([]string, 0, len(items))
	for _, item := range items {
		message, ok := item.(map[string]any)
		if !ok {
			parts = append(parts, humanValue(item, present, 0))
			continue
		}
		sender := firstString(message, "sender_name", "sender", "sender_id", "user_id")
		if sender != "" && !strings.HasPrefix(sender, "@") {
			sender = present("<@" + sender + ">")
		}
		text := present(firstString(message, "text", "message"))
		if sender == "" {
			sender = "Unknown sender"
		}
		body := sender
		if text != "" {
			body += "\n" + text
		}
		metadata := []string{}
		if ts := firstString(message, "message_ts", "ts"); ts != "" {
			metadata = append(metadata, "Message "+ts)
		}
		if thread := firstString(message, "thread_ts"); thread != "" {
			metadata = append(metadata, "Thread "+thread)
		}
		if link := firstString(message, "message_link", "permalink"); link != "" {
			metadata = append(metadata, "Slack link "+link)
		}
		if len(metadata) > 0 {
			body += "\n" + strings.Join(metadata, " · ")
		}
		parts = append(parts, body)
	}
	return strings.Join(parts, "\n\n")
}

func firstString(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func humanJSON(raw json.RawMessage, present func(string) string, depth int) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return present(prettyJSON(string(raw)))
	}
	return humanValue(value, present, depth)
}

func humanValue(value any, present func(string) string, depth int) string {
	switch typed := value.(type) {
	case nil:
		return "Not set"
	case string:
		return present(typed)
	case bool:
		if typed {
			return "Yes"
		}
		return "No"
	case float64:
		return fmt.Sprintf("%v", typed)
	case []any:
		lines := make([]string, 0, len(typed))
		for _, item := range typed {
			text := humanValue(item, present, depth+1)
			if strings.Contains(text, "\n") {
				text = strings.ReplaceAll(text, "\n", "\n  ")
			}
			lines = append(lines, "• "+text)
		}
		return strings.Join(lines, "\n")
	case map[string]any:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			if key == "id" || strings.HasSuffix(key, "_id") {
				continue
			}
			keys = append(keys, key)
		}
		sort.Strings(keys)
		lines := make([]string, 0, len(keys))
		for _, key := range keys {
			text := humanValue(typed[key], present, depth+1)
			if strings.TrimSpace(text) == "" {
				continue
			}
			if strings.Contains(text, "\n") {
				text = "\n  " + strings.ReplaceAll(text, "\n", "\n  ")
			}
			lines = append(lines, eventTitle(key)+": "+text)
		}
		return strings.Join(lines, "\n")
	default:
		encoded, _ := json.MarshalIndent(typed, "", "  ")
		return present(string(encoded))
	}
}

func memoryLayerDetails(raw json.RawMessage, rootKey, label string, priority []string, present func(string) string) []TraceDetail {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) == 0 {
		return []TraceDetail{{
			Label: label, Body: humanJSON(raw, present, 0), Kind: "context",
			Status: "Sent to model", Description: promptSelectionDescription(rootKey, true), Tone: promptTone(rootKey),
			Open: true, ShowCount: true, Count: contextEntryCount(raw),
		}}
	}
	keys := make([]string, 0, len(fields))
	seen := map[string]bool{}
	for _, key := range priority {
		if !emptyJSON(fields[key]) {
			keys = append(keys, key)
			seen[key] = true
		}
	}
	rest := make([]string, 0, len(fields))
	for key, value := range fields {
		if !seen[key] && !emptyJSON(value) {
			rest = append(rest, key)
		}
	}
	sort.Strings(rest)
	keys = append(keys, rest...)
	details := make([]TraceDetail, 0, len(keys))
	for _, key := range keys {
		body := humanJSON(fields[key], present, 0)
		if key == "recent_same_channel_evidence" {
			body = evidenceMemoryBody(fields[key], present)
		}
		details = append(details, TraceDetail{
			Label: label + " · " + eventTitle(key),
			Body:  body, Kind: "context",
			Status: "Sent to model", Description: memorySelectionDescription(rootKey, key), Tone: promptTone(rootKey),
			Open: true, ShowCount: true, Count: contextEntryCount(fields[key]),
		})
	}
	return details
}

func memorySelectionDescription(rootKey, key string) string {
	switch key {
	case "operator_confirmed_memory", "confirmed_memory":
		return "Up to 10 enabled operator-confirmed memories selected from the 100 newest candidates by scope and relevance."
	case "automatically_synthesized_continuity", "dreamed_memory":
		return "Up to 4 compact continuity notes selected from the 20 newest candidates by conversation overlap."
	case "recent_same_channel_evidence":
		return "The 10 newest evidence records from this channel, excluding evidence created by the current input."
	case "responder_preferences":
		return "Effective preferences after workspace, channel, and operator precedence was resolved."
	case "goal", "situation_summary", "channel_purpose", "topology", "decisions", "constraints", "unresolved_questions", "evidence_refs":
		return "Part of the compact thread or channel continuity summary selected for this conversation."
	}
	return promptSelectionDescription(rootKey, true)
}

func evidenceMemoryBody(raw json.RawMessage, present func(string) string) string {
	var records []map[string]any
	if json.Unmarshal(raw, &records) != nil {
		return humanJSON(raw, present, 0)
	}
	items := make([]string, 0, len(records))
	for _, record := range records {
		claim := present(firstString(record, "claim"))
		observation := present(firstString(record, "observation"))
		if claim == "" && observation == "" {
			continue
		}
		lines := []string{}
		if claim != "" {
			lines = append(lines, claim)
		}
		if observation != "" {
			lines = append(lines, "Observed: "+observation)
		}
		if source := firstString(record, "source_name", "source_type"); source != "" {
			lines = append(lines, "Source: "+present(source))
		}
		if at := firstString(record, "observed_at"); at != "" {
			lines = append(lines, "Observed at: "+at)
		}
		if confidence := firstString(record, "confidence"); confidence != "" {
			lines = append(lines, "Confidence: "+confidence)
		}
		items = append(items, strings.Join(lines, "\n"))
	}
	return strings.Join(items, "\n\n")
}

func modelSelectionWhy(manifest ManifestRow) string {
	target := strings.TrimSpace(manifest.Provider + "/" + manifest.Model)
	if target == "/" {
		target = "an unrecorded target"
	}
	effort := fallback(manifest.Effort, "an unrecorded reasoning effort")
	if manifest.Preset != "" {
		return fmt.Sprintf("Preset %s routed this episode to %s at %s effort. The manifest records the effective choice; it does not retain a scorecard of rejected model or effort alternatives.", manifest.Preset, target, effort)
	}
	return fmt.Sprintf("The effective routing policy selected %s at %s effort. No preset or alternative-candidate score was retained for this attempt.", target, effort)
}

type promptRange struct {
	start, end int
	source     string
	tone       string
}

type jsonFieldRange struct {
	key        string
	start, end int
}

func promptSegments(prompt string) []PromptSegment {
	ranges := []promptRange{}
	for _, section := range []struct{ tag, source, tone string }{
		{"trusted-responder-context", "Trusted Responder context", "trusted"},
	} {
		open, close := "<"+section.tag+">", "</"+section.tag+">"
		if start := strings.Index(prompt, open); start >= 0 {
			if tail := strings.Index(prompt[start+len(open):], close); tail >= 0 {
				ranges = append(ranges, promptRange{start, start + len(open) + tail + len(close), section.source, section.tone})
			}
		}
	}
	if start := strings.Index(prompt, "<untrusted-slack-context>"); start >= 0 {
		if tail := strings.Index(prompt[start:], "</untrusted-slack-context>"); tail >= 0 {
			end := start + tail + len("</untrusted-slack-context>")
			ranges = append(ranges, untrustedPromptRanges(prompt, start, end)...)
		}
	}
	if start := strings.LastIndex(prompt, "\nUSER:"); start >= 0 {
		ranges = append(ranges, promptRange{start + 1, len(prompt), "User request", "user"})
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].start < ranges[j].start })

	segments := []PromptSegment{}
	add := func(body, source, tone string) {
		if body == "" {
			return
		}
		tokens := max(1, (utf8.RuneCountInString(body)+3)/4)
		segments = append(segments, PromptSegment{
			Body: body, Source: source, Tone: tone, Tokens: tokens,
			Hint: fmt.Sprintf("%s · about %s tokens", source, humanTokens(int64(tokens))),
		})
	}
	cursor := 0
	for _, section := range ranges {
		if section.start < cursor {
			continue
		}
		add(prompt[cursor:section.start], "System instructions", "system")
		add(prompt[section.start:section.end], section.source, section.tone)
		cursor = section.end
	}
	add(prompt[cursor:], "System instructions", "system")
	if len(segments) == 0 {
		add(prompt, "Submitted prompt", "system")
	}
	return segments
}

func untrustedPromptRanges(prompt string, start, end int) []promptRange {
	const open = "<untrusted-slack-context>"
	const close = "</untrusted-slack-context>"
	contentStart := start + len(open)
	contentEnd := end - len(close)
	raw := prompt[contentStart:contentEnd]
	fields := topLevelJSONFields(raw)
	if len(fields) == 0 {
		return []promptRange{{start, end, "Slack context", "slack"}}
	}
	// Keep the host-owned trust wrapper separate from the model-visible fields
	// inside it. Assigning the opening tag to the first field and the closing
	// tag to the last field made the trace imply that safety markup came from
	// Slack or memory, and made those fields' token counts inaccurate.
	ranges := make([]promptRange, 0, len(fields)+2)
	firstFieldStart := contentStart + fields[0].start
	ranges = append(ranges, promptRange{start, firstFieldStart, "Safety boundary", "structure"})
	for index, field := range fields {
		fieldStart := contentStart + field.start
		fieldEnd := contentStart + field.end
		if index+1 < len(fields) {
			fieldEnd = contentStart + fields[index+1].start
		}
		source, tone := promptFieldPresentation(field.key)
		ranges = append(ranges, promptRange{fieldStart, fieldEnd, source, tone})
	}
	lastFieldEnd := contentStart + fields[len(fields)-1].end
	ranges = append(ranges, promptRange{lastFieldEnd, end, "Safety boundary", "structure"})
	return ranges
}

func topLevelJSONFields(raw string) []jsonFieldRange {
	i := skipJSONSpace(raw, 0)
	if i >= len(raw) || raw[i] != '{' {
		return nil
	}
	i++
	fields := []jsonFieldRange{}
	for {
		i = skipJSONSpace(raw, i)
		if i < len(raw) && raw[i] == ',' {
			i = skipJSONSpace(raw, i+1)
		}
		if i >= len(raw) || raw[i] == '}' {
			return fields
		}
		start := i
		keyEnd := scanJSONString(raw, i)
		if keyEnd <= i {
			return nil
		}
		var key string
		if json.Unmarshal([]byte(raw[i:keyEnd]), &key) != nil {
			return nil
		}
		i = skipJSONSpace(raw, keyEnd)
		if i >= len(raw) || raw[i] != ':' {
			return nil
		}
		i = skipJSONSpace(raw, i+1)
		valueEnd := scanJSONValue(raw, i)
		if valueEnd <= i {
			return nil
		}
		fields = append(fields, jsonFieldRange{key: key, start: start, end: valueEnd})
		i = valueEnd
	}
}

func skipJSONSpace(raw string, i int) int {
	for i < len(raw) && strings.ContainsRune(" \t\r\n", rune(raw[i])) {
		i++
	}
	return i
}

func scanJSONString(raw string, i int) int {
	if i >= len(raw) || raw[i] != '"' {
		return -1
	}
	for i++; i < len(raw); i++ {
		switch raw[i] {
		case '\\':
			i++
		case '"':
			return i + 1
		}
	}
	return -1
}

func scanJSONValue(raw string, i int) int {
	if i >= len(raw) {
		return -1
	}
	if raw[i] == '"' {
		return scanJSONString(raw, i)
	}
	if raw[i] != '{' && raw[i] != '[' {
		for i < len(raw) && raw[i] != ',' && raw[i] != '}' && raw[i] != ']' {
			i++
		}
		return skipJSONSpaceBackward(raw, i)
	}
	stack := []byte{raw[i]}
	for i++; i < len(raw); i++ {
		switch raw[i] {
		case '"':
			i = scanJSONString(raw, i) - 1
			if i < 0 {
				return -1
			}
		case '{', '[':
			stack = append(stack, raw[i])
		case '}', ']':
			stack = stack[:len(stack)-1]
			if len(stack) == 0 {
				return i + 1
			}
		}
	}
	return -1
}

func skipJSONSpaceBackward(raw string, i int) int {
	for i > 0 && strings.ContainsRune(" \t\r\n", rune(raw[i-1])) {
		i--
	}
	return i
}

func promptFieldPresentation(key string) (string, string) {
	if value, ok := map[string][2]string{
		"prior_operational_context":        {"Operational memory", "operational"},
		"structured_memory":                {"Conversation memory", "conversation"},
		"conversation_situation":           {"Conversation memory", "conversation"},
		"related_situations":               {"Related conversation summaries", "related"},
		"referenced_thread":                {"Referenced Slack thread", "slack"},
		"target_message":                   {"Source Slack message", "slack"},
		"source_message":                   {"Source Slack message", "slack"},
		"recent_messages":                  {"Recent Slack messages", "slack"},
		"recent_channel_messages":          {"Recent Slack messages", "slack"},
		"recent_messages_around_target":    {"Recent Slack messages", "slack"},
		"channel_context":                  {"Slack channel context", "slack"},
		"channel_id":                       {"Slack channel", "slack"},
		"attachments":                      {"Slack attachments", "slack"},
		"repository":                       {"Repository selection", "trusted"},
		"context_omitted":                  {"Context intentionally omitted", "structure"},
		"initial_task_changes_fingerprint": {"Existing task changes", "structure"},
		"structured_corrections":           {"Structured-result retry state", "structure"},
		"reply_shape_corrections":          {"Reply-format retry state", "structure"},
		"captured_at":                      {"Context capture time", "structure"},
	}[key]; ok {
		return value[0], value[1]
	}
	return eventTitle(key), "slack"
}

func contextReferenceDetails(refs []ContextRef, present func(string) string) []TraceDetail {
	runtime := make([]TraceTableRow, 0, len(refs))
	replay := make([]TraceTableRow, 0, 2)
	for _, ref := range refs {
		switch ref.Kind {
		case "source_input":
			// The source message is already the first timeline step and appears
			// as a colored model-visible prompt component. Do not show it again.
			continue
		case "compiled_prompt", "assembled_context":
			name, use := "Final prompt", "Confirms an exact prompt replay"
			if ref.Kind == "assembled_context" {
				name, use = "Selected context", "Confirms the same context was selected"
			}
			fingerprint := fallback(ref.Digest, "not recorded")
			if ref.Omitted != "" {
				use += "; omitted: " + present(ref.Omitted)
			}
			replay = append(replay, TraceTableRow{Cells: []string{name, fingerprint, use}})
			continue
		default:
			if ref.Visibility != "omitted" {
				runtime = append(runtime, contextReferenceTableRow(ref, present))
			}
		}
	}
	details := make([]TraceDetail, 0, 2)
	if len(runtime) > 0 {
		details = append(details, TraceDetail{
			Label: "Repositories and session controls", Kind: "context",
			Status: "Runtime access", Tone: "runtime", ShowCount: true, Count: len(runtime),
			Group: "Runtime access", GroupCount: len(runtime),
			Table: &TraceTable{
				Headers: []string{"Type", "Name", "Revision", "How it was used"},
				Rows:    runtime,
			},
		})
	}
	if len(replay) > 0 {
		details = append(details, TraceDetail{
			Label: "Integrity fingerprints", Kind: "context",
			Status: "Not model input", Tone: "structure", ShowCount: true, Count: len(replay),
			Description: "Responder stores these hashes so a replay can prove it used the same inputs. The model never sees them.",
			Group:       "Replay verification", GroupCount: len(replay),
			Table: &TraceTable{
				Headers: []string{"Input", "Fingerprint", "Purpose"},
				Rows:    replay,
			},
		})
	}
	return details
}

func markDetailGroup(details []TraceDetail, label, description string) []TraceDetail {
	if len(details) == 0 {
		return details
	}
	details[0].Group = label
	details[0].GroupDetail = description
	details[0].GroupCount = len(details)
	return details
}

func contextReferenceTableRow(ref ContextRef, present func(string) string) TraceTableRow {
	kind := fallback(contextLabel(ref.Kind), eventTitle(ref.Kind))
	name, revision := present(ref.What), "-"
	if ref.Kind == "repository" {
		if repository, commit, ok := strings.Cut(name, " @ "); ok {
			name, revision = repository, commit
		}
	}
	if ref.Kind == "artifact" && ref.Digest != "" {
		revision = ref.Digest
	}
	role := map[string]string{
		"repository":       "Code available to inspect through Coop",
		"execution_policy": "Controls tools and whether files can change",
		"artifact":         "File available to inspect through Coop",
	}[ref.Kind]
	if role == "" {
		role = "Available through the model session"
	}
	return TraceTableRow{Cells: []string{kind, name, revision, role}}
}

func presentEventPayload(payload string, present func(string) string) string {
	if strings.TrimSpace(payload) == "" {
		return ""
	}
	var value any
	if json.Unmarshal([]byte(payload), &value) != nil {
		return present(payload)
	}
	value = presentEventValue(stripZeroTimes(value), present)
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return present(payload)
	}
	return string(encoded)
}

func presentEventValue(value any, present func(string) string) any {
	switch item := value.(type) {
	case map[string]any:
		for key, child := range item {
			item[key] = presentEventValue(child, present)
		}
		return item
	case []any:
		for index := range item {
			item[index] = presentEventValue(item[index], present)
		}
		return item
	case string:
		return present(item)
	default:
		return value
	}
}

func stripZeroTimes(value any) any {
	switch item := value.(type) {
	case map[string]any:
		for key, child := range item {
			if text, ok := child.(string); ok && strings.HasPrefix(text, "0001-01-01T00:00:00") {
				delete(item, key)
				continue
			}
			item[key] = stripZeroTimes(child)
		}
		return item
	case []any:
		for index := range item {
			item[index] = stripZeroTimes(item[index])
		}
		return item
	default:
		return value
	}
}

func emptyJSON(raw json.RawMessage) bool {
	value := strings.TrimSpace(string(raw))
	return value == "" || value == "null" || value == "{}" || value == "[]"
}

func episodeMetrics(pricing config.Pricing, page episodePage) []EpisodeMetric {
	respond := EpisodeMetric{Label: "Time to respond", Value: "Not recorded", Missing: true,
		Detail: "No sent Slack reply is retained for this episode."}
	if !page.Source.Received.IsZero() {
		respond.Detail = "Started " + page.Source.Received.UTC().Format("2006-01-02 15:04 UTC")
		var first time.Time
		for _, delivery := range page.Delivered {
			if delivery.State != "sent" || delivery.Operation == "status" || delivery.At.IsZero() {
				continue
			}
			if first.IsZero() || delivery.At.Before(first) {
				first = delivery.At
			}
		}
		if !first.IsZero() {
			respond.Value, respond.Missing, respond.Tone = compactDuration(first.Sub(page.Source.Received)), false, "good"
		}
	}

	react := EpisodeMetric{Label: "Time to react", Value: "Not recorded", Missing: true,
		Detail: "No processing indicator linked to this episode was retained. Older episodes may have shown a Slack status before Responder recorded episode ownership."}
	if !page.Source.Received.IsZero() {
		var first time.Time
		for _, delivery := range page.Delivered {
			if delivery.State == "sent" && delivery.Operation == "status" && !delivery.At.IsZero() &&
				(first.IsZero() || delivery.At.Before(first)) {
				first = delivery.At
			}
		}
		// Standing workflows acknowledge work with a temporary reaction before
		// an episode-owned Slack status exists. That is still the operator's
		// first visible processing indicator, and the audit record is durable.
		for _, audit := range page.Audit {
			if audit.At.IsZero() || (audit.Kind != "standing_rule.acknowledged" &&
				audit.Kind != "standing_rules.evaluated") {
				continue
			}
			if audit.Kind == "standing_rules.evaluated" {
				var evaluation core.StandingRuleEvaluationAudit
				if json.Unmarshal([]byte(audit.Detail), &evaluation) != nil || evaluation.Acknowledged == "" {
					continue
				}
			}
			if first.IsZero() || audit.At.Before(first) {
				first = audit.At
			}
		}
		if !first.IsZero() {
			react.Value, react.Missing, react.Tone = compactDuration(first.Sub(page.Source.Received)), false, "good"
			react.Detail = "From Slack receipt to the first linked status or working reaction."
		}
	}

	cost := episodeCost(pricing, page.Spent)
	tokens := "not measured"
	if page.Spent.Recorded() {
		tokens = humanTokens(page.Spent.Total())
	}
	costMetric := EpisodeMetric{Label: "Episode cost / tokens", Value: "Not priced / " + tokens, Missing: true,
		Detail: "Token usage exists, but no matching configured price was available."}
	if cost.Priceable() {
		costMetric.Value, costMetric.Missing = cost.Money()+" / "+tokens, false
		costMetric.Detail = "Calculated from recorded tokens and the configured model price."
		if cost.Partial() {
			costMetric.Value += " partial"
			costMetric.Tone = "warn"
		}
	} else if !page.Spent.Recorded() {
		costMetric.Value = "Not measured / " + tokens
		costMetric.Detail = "The provider did not report token usage for this episode."
	}

	errors, breakdown := episodeErrorCount(page)
	errorMetric := EpisodeMetric{Label: "Errors", Value: fmt.Sprint(errors), Detail: breakdown}
	if errors > 0 {
		errorMetric.Tone = "bad"
	} else {
		errorMetric.Tone = "good"
	}
	return []EpisodeMetric{respond, react, costMetric, errorMetric}
}

func episodeCost(pricing config.Pricing, spent EpisodeTokens) UsageCost {
	cost := UsageCost{Currency: pricing.Currency, Configured: len(pricing.Models) > 0}
	for _, row := range spent.Rows {
		if !row.Measured {
			continue
		}
		cost.Measured++
		amount, known := pricing.Cost(row.Provider, row.Model, core.ContextUsage{
			InputTokens: int(row.Input), CachedInputTokens: int(row.Cached),
			OutputTokens: int(row.Output), ReasoningTokens: int(row.Reasoning),
		})
		if known {
			cost.Total += amount
			cost.Priced++
		}
	}
	return cost
}

func episodeErrorCount(page episodePage) (int, string) {
	corrections := len(page.Rejections)
	if corrections == 0 {
		// Keep hand-built and historical projections useful when only the
		// latest-turn correction list is available.
		corrections = len(page.Turn.Rejections)
	}
	failedAttempts, deliveries, parseFailures := 0, 0, 0
	for _, attempt := range page.Attempts {
		if attempt.State == "failed" || attempt.Failure != "" {
			failedAttempts++
		}
	}
	for _, delivery := range page.Delivered {
		if delivery.State == "failed" || delivery.Error != "" {
			deliveries++
		}
	}
	turns := page.Turns
	if len(turns) == 0 && (page.Turn.RunID != "" || page.Turn.Unreadable != "") {
		turns = []Turn{page.Turn}
	}
	for _, turn := range turns {
		if turn.Unreadable != "" {
			parseFailures++
		}
	}
	count := failedAttempts + corrections + deliveries + parseFailures
	return count, fmt.Sprintf("%d failed attempts · %d host corrections · %d delivery failures · %d unreadable results", failedAttempts, corrections, deliveries, parseFailures)
}

func wakeupSummary(wakeup Wakeup) string {
	matcher := map[string]any{}
	_ = json.Unmarshal([]byte(wakeup.Matcher), &matcher)
	provider := strings.TrimSpace(fmt.Sprint(matcher["provider"]))
	if provider == "<nil>" {
		provider = ""
	}
	provider = map[string]string{
		"hcp_terraform": "HCP Terraform",
		"github":        "GitHub",
		"emisar":        "Emisar",
	}[provider]
	if provider == "" {
		provider = "external"
	}
	for _, field := range []string{"run_id", "request_id", "pull_request", "deployment_id"} {
		value := strings.TrimSpace(fmt.Sprint(matcher[field]))
		if value != "" && value != "<nil>" {
			object := "object"
			if field == "run_id" {
				object = "run"
			} else if field == "request_id" {
				object = "request"
			} else if field == "pull_request" {
				object = "pull request"
			} else if field == "deployment_id" {
				object = "deployment"
			}
			return fmt.Sprintf("Wait for %s %s %s to change state.", provider, object, value)
		}
	}
	return fmt.Sprintf("Wait for a matching %s event before continuing.", provider)
}

func modelSummary(turn Turn) string {
	if turn.Message != "" {
		return truncate(strings.Join(strings.Fields(turn.Message), " "), 220)
	}
	if turn.Action != "" || turn.Reason != "" {
		return strings.TrimSpace(turn.Action + ": " + turn.Reason)
	}
	if turn.Unreadable != "" {
		return "Result could not be parsed: " + turn.Unreadable
	}
	return fallback(turn.Error, "The result carried no public message.")
}

func turnByRun(turns []Turn, runID string) (Turn, bool) {
	for _, turn := range turns {
		if turn.RunID == runID {
			return turn, true
		}
	}
	return Turn{}, false
}

func contextLabel(kind string) string {
	return map[string]string{
		"source_input": "Source message", "compiled_prompt": "Prompt replay fingerprint",
		"assembled_context": "Context replay fingerprint", "repository": "Repository snapshot",
		"execution_policy": "Execution policy", "artifact": "Attached artifact",
	}[kind]
}

func eventStage(kind string) string {
	switch {
	case strings.Contains(kind, "evidence") || strings.Contains(kind, "claim") || strings.Contains(kind, "coverage"):
		return "Evidence"
	case strings.Contains(kind, "complete") || strings.Contains(kind, "blocked"):
		return "Decision"
	case strings.Contains(kind, "context") || strings.Contains(kind, "plan"):
		return "Preparation"
	default:
		return "Execution"
	}
}

func eventTitle(kind string) string {
	if kind == "standing_rules.evaluated" || kind == "standing_rule.acknowledged" {
		return "Standing rules"
	}
	title := strings.NewReplacer("_", " ", ".", " ").Replace(kind)
	if title == "" {
		return "Episode event"
	}
	runes := []rune(title)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}

func artifactStage(kind string) string {
	switch kind {
	case "commitment", "goal":
		return "Plan"
	case "scheduled_run":
		return "Schedule"
	case "evaluation", "standing_rule_run", "standing_assignment_action":
		return "Decision"
	case "feedback", "replay_candidate":
		return "Review"
	case "incident_timeline":
		return "Incident"
	case "publication_lifecycle", "publication":
		return "Publication"
	case "quality_finding":
		return "Review"
	default:
		return "Execution"
	}
}

func artifactActor(kind string) string {
	switch kind {
	case "scheduled_run":
		return "Scheduler"
	case "quality_finding":
		return "Quality watcher"
	case "feedback":
		return "Operator"
	case "replay_candidate":
		return "Regression corpus"
	default:
		return "Responder"
	}
}

func artifactDetailLabel(kind string) string {
	switch kind {
	case "goal":
		return "Goal details"
	case "scheduled_run":
		return "Schedule failure"
	case "evaluation":
		return "Decision details"
	case "standing_rule_run":
		return "Rule result"
	case "standing_assignment_action":
		return "Assignment result"
	case "feedback":
		return "Feedback details"
	case "replay_candidate":
		return "Saved correction"
	case "incident_timeline":
		return "Incident event"
	case "publication_lifecycle":
		return "Publication event"
	case "publication":
		return "Publication error"
	case "quality_finding":
		return "Review evidence"
	default:
		return "Full record"
	}
}

func artifactWhy(kind string) string {
	switch kind {
	case "commitment":
		return "Responder recorded the outcome it accepted responsibility for, so unfinished work cannot disappear when a model turn ends."
	case "goal":
		return "This required outcome is tracked independently from any one model turn and can block completion until it is satisfied."
	case "scheduled_run":
		return "This is the persisted occurrence of a scheduled task, including when it was due and how it ended."
	case "progress":
		return "Responder saved this progress update so the episode can resume from the same point after a restart or follow-up."
	case "evaluation":
		return "This is the persisted decision about whether the source event needed a reply, investigation, or no action."
	case "standing_rule_run":
		return "A confirmed standing rule matched this source event and recorded the action it started."
	case "standing_assignment_action":
		return "A confirmed autonomous assignment matched this source event and recorded the bounded work it started."
	case "feedback":
		return "An operator linked this feedback to the episode so the product issue and its conversation context are not lost."
	case "replay_candidate":
		return "A host correction from this episode was retained for human review before it can become a regression test."
	case "incident_timeline":
		return "This event was added to the incident history linked to the episode."
	case "publication_lifecycle":
		return "This external publication event advanced the linked branch or pull-request workflow."
	case "publication":
		return "This is the durable branch and pull-request state linked to the episode."
	case "quality_finding":
		return "A later production review checked this episode and retained its verdict and supporting evidence."
	default:
		return ""
	}
}

func occurrenceDetail(times []time.Time) *TraceDetail {
	if len(times) <= 1 {
		return nil
	}
	lines := make([]string, 0, len(times))
	for index, at := range times {
		value := "time not recorded"
		if !at.IsZero() {
			value = at.UTC().Format("2006-01-02 15:04:05.000 UTC")
		}
		lines = append(lines, fmt.Sprintf("%d. %s", index+1, value))
	}
	return &TraceDetail{
		Label: "All occurrences", Body: strings.Join(lines, "\n"), Kind: "text",
		Open: false, ShowCount: true, Count: len(times),
	}
}

func usageTraceStep(page episodePage) TraceStep {
	at := page.Turn.Updated
	if at.IsZero() {
		at = page.Manifest.Created
	}
	step := TraceStep{
		ID: "usage", Stage: "Measurement", Actor: "Responder", State: "recorded", At: at,
		Title: "Model usage and timing recorded",
		Why:   "Provider usage and Coop timing are kept separate from wall-clock response time so cost and latency can be diagnosed without guessing.",
	}
	if !page.Spent.Recorded() {
		step.State = "not measured"
		step.Summary = "Not measured for this episode"
		step.Details = []TraceDetail{{Label: "Measurement boundary", Kind: "missing", Open: true,
			Body: "The adapter reported no token counts. This is missing telemetry, not a zero-token turn."}}
		return step
	}
	step.Summary = humanTokens(page.Spent.Total()) + " tokens across " + fmt.Sprint(page.Spent.Measured) + " measured context manifest(s)"
	step.Stats = []TraceStat{
		{"Total tokens", humanTokens(page.Spent.Total())}, {"Cache hit", page.Spent.CacheLabel()},
		{"Timed turns", fmt.Sprint(page.Spent.Clock.TimedTurns)}, {"Wall clock", page.Spent.Clock.Total()},
	}
	detail := fmt.Sprintf("Fresh input: %s\nCached input: %s\nOutput: %s\nReasoning: %s",
		humanTokens(page.Spent.Input), humanTokens(page.Spent.Cached),
		humanTokens(page.Spent.Output), humanTokens(page.Spent.Reasoning))
	timing := "No turn timing was reported."
	if page.Spent.Clock.Recorded() {
		timing = "Total: " + page.Spent.Clock.Total() + "\n" + page.Spent.Clock.Split()
	}
	step.Details = []TraceDetail{
		{Label: "Token breakdown", Body: detail, Kind: "text", Open: true},
		{Label: "Execution timing", Body: timing, Kind: "text", Open: true},
	}
	return step
}

func eventWhy(kind string) string {
	if kind == "context_extended" {
		return "Additional context was frozen so later results can be traced to the exact inputs they used."
	}
	return ""
}

func attemptSummary(attempt Attempt) string {
	if attempt.Failure != "" {
		return attempt.Failure
	}
	if attempt.State != "" {
		return "Coop attempt " + attempt.State
	}
	return "Coop attempt ended"
}

func attemptWhy(attempt Attempt) string {
	if attempt.Failure != "" || attempt.State == "failed" {
		return "The attempt boundary preserves the failure and allows the episode to retry without losing its source event or evidence."
	}
	return "Coop is the authenticated model and tool execution boundary for this attempt."
}

func sideEffectWhy(effect SideEffect) string {
	if effect.State == "offered" || effect.State == "waiting" {
		return "The model proposed this action, but Responder kept it separate from execution until its confirmation or approval boundary is satisfied."
	}
	return "This projection records durable state attributable to the episode, including the exact before and after values where available."
}

func deliveryWhy(delivery Delivery) string {
	if delivery.Operation == "status" {
		return "Native Slack status gives the operator immediate progress feedback without adding a durable message to the conversation."
	}
	return "The outbox sequences Slack writes, retries transient failures, and makes publication independent of model execution."
}

func ledgerDetails(page episodePage, present func(string) string) []TraceDetail {
	details := []TraceDetail{}
	for _, claim := range page.Claims {
		body := claim.Status + " · confidence " + fallback(claim.Confidence, "not recorded") +
			fmt.Sprintf("\nSupporting evidence: %d · contradicting evidence: %d", claim.Supporting, claim.Contradicting)
		if claim.Detail != "" {
			body += "\n" + present(claim.Detail)
		}
		details = append(details, TraceDetail{Label: "Claim · " + present(claim.Claim), Body: body, Kind: "evidence"})
	}
	for _, evidence := range page.Evidence {
		body := evidence.Observation + "\n" + evidence.Relation + " · " + evidence.Source
		if evidence.Freshness != "" {
			body += "\nFreshness: " + evidence.Freshness
		}
		details = append(details, TraceDetail{Label: "Evidence · " + present(evidence.Claim), Body: present(body), Kind: "evidence"})
	}
	for _, coverage := range page.Coverage {
		body := coverage.Status + " · " + coverage.Source
		if coverage.Detail != "" {
			body += "\n" + coverage.Detail
		}
		details = append(details, TraceDetail{Label: "Coverage · " + present(coverage.Layer), Body: present(body), Kind: "evidence"})
	}
	return details
}

func tallyTotal(items []Tally) int {
	total := 0
	for _, item := range items {
		total += item.Count
	}
	return total
}

func repeatValue(repeats int) string {
	if repeats <= 0 {
		return "1"
	}
	return fmt.Sprint(repeats + 1)
}

func fallback(value, otherwise string) string {
	if strings.TrimSpace(value) == "" {
		return otherwise
	}
	return value
}

func traceDuration(start, end time.Time) string {
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return ""
	}
	return compactDuration(end.Sub(start))
}

func compactDuration(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	if duration < time.Second {
		return fmt.Sprintf("%dms", duration.Milliseconds())
	}
	if duration < time.Minute {
		return fmt.Sprintf("%.1fs", duration.Seconds())
	}
	if duration < time.Hour {
		return fmt.Sprintf("%dm %02ds", int(duration.Minutes()), int(duration.Seconds())%60)
	}
	return fmt.Sprintf("%dh %02dm", int(duration.Hours()), int(duration.Minutes())%60)
}
