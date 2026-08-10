package webui

import (
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"

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
	Label, Body, Kind string
	Open              bool
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

func buildEpisodeTrace(pricing config.Pricing, page episodePage) EpisodeTrace {
	trace := EpisodeTrace{}
	trace.Metrics = episodeMetrics(pricing, page)
	steps := make([]TraceStep, 0, 12+len(page.Events)+len(page.Attempts)+
		len(page.Effects)+len(page.Delivered)+len(page.Audit))
	add := func(step TraceStep) {
		step.order = len(steps)
		steps = append(steps, step)
	}

	if page.Source.ID != "" {
		details := []TraceDetail{{Label: "Exact Slack message", Body: page.Source.Text, Kind: "text", Open: true}}
		if strings.TrimSpace(page.Source.Attachments) != "" && page.Source.Attachments != "[]" {
			details = append(details, TraceDetail{Label: "Attachment manifest", Body: page.Source.Attachments, Kind: "json"})
		}
		add(TraceStep{
			ID: "source", Stage: "Input", Actor: "Slack", State: page.Source.Kind,
			Title: "Message received", Summary: sourceSummary(page.Source), At: page.Source.Received,
			Why:     "This is the immutable source event that caused Responder to consider work.",
			Stats:   []TraceStat{{"Channel", page.Source.Channel}, {"Message", page.Source.MessageTS}, {"Sender", page.Source.UserID}},
			Details: details,
		})
	}

	if page.Manifest.Version > 0 {
		model := strings.TrimSpace(page.Manifest.Provider + " " + page.Manifest.Model)
		if model == "" {
			model = "Target not recorded"
		}
		add(TraceStep{
			ID: "model", Stage: "Routing", Actor: "Responder", State: "selected",
			Title: "Model selected", Summary: model, At: page.Manifest.Created,
			Why:   "Responder freezes the effective model target so cost, quality, and replay can be attributed to the model that actually answered.",
			Stats: []TraceStat{{"Provider", fallback(page.Manifest.Provider, "not recorded")}, {"Model", fallback(page.Manifest.Model, "not recorded")}, {"Reasoning", fallback(page.Manifest.Effort, "not recorded")}, {"Preset", fallback(page.Manifest.Preset, "none")}},
		})

		prompt := page.Manifest.SubmittedPrompt
		if prompt == "" {
			prompt = page.Turn.Prompt
		}
		promptDetails := []TraceDetail{}
		if prompt != "" {
			promptDetails = append(promptDetails, TraceDetail{Label: "Submitted prompt", Body: prompt, Kind: "prompt"})
		} else {
			promptDetails = append(promptDetails, TraceDetail{Label: "Submitted prompt", Body: "The prompt text was not retained for this attempt. Its digest remains available in the context references.", Kind: "missing", Open: true})
		}
		for _, ref := range page.Manifest.Refs {
			body := ref.What + "\nVisibility: " + ref.Visibility
			if ref.Digest != "" {
				body += "\nDigest: " + ref.Digest
			}
			if ref.Omitted != "" {
				body += "\nOmitted: " + ref.Omitted
			}
			promptDetails = append(promptDetails, TraceDetail{
				Label: fallback(contextLabel(ref.Kind), eventTitle(ref.Kind)),
				Body:  body, Kind: "context",
			})
		}
		if len(page.Manifest.Omissions) > 0 {
			promptDetails = append(promptDetails, TraceDetail{Label: "Omitted context", Body: strings.Join(page.Manifest.Omissions, "\n"), Kind: "context"})
		}
		add(TraceStep{
			ID: "prompt", Stage: "Context", Actor: "Responder", State: "frozen",
			Title: "Prompt assembled", Summary: fmt.Sprintf("Manifest v%d with %d context components", page.Manifest.Version, len(page.Manifest.Refs)), At: page.Manifest.Created,
			Why:     "The frozen manifest makes the answer reproducible: it records the contract, policy, repository revision, memories, and artifacts that were eligible to influence this attempt.",
			Stats:   []TraceStat{{"Prompt", fallback(page.Manifest.PromptVersion, "unversioned")}, {"Contract", fallback(page.Manifest.Contract, "none")}, {"Tool schema", fallback(page.Manifest.ToolSchema, "none")}, {"Components", fmt.Sprint(len(page.Manifest.Refs))}},
			Details: promptDetails,
		})
	}

	for index, event := range page.Events {
		why := eventWhy(event.Kind)
		details := []TraceDetail{}
		if event.Payload != "" && event.Payload != "{}" {
			details = append(details, TraceDetail{Label: "Recorded event payload", Body: event.Payload, Kind: "json"})
		}
		add(TraceStep{
			ID: fmt.Sprintf("event-%d", index+1), Stage: eventStage(event.Kind), Actor: event.Actor,
			State: event.Kind, Title: eventTitle(event.Kind), Summary: event.Detail, Why: why, At: event.At,
			Stats: []TraceStat{{"Attempt", fmt.Sprint(event.Attempt)}, {"Repeats", repeatValue(event.Repeats)}}, Details: details,
		})
	}

	for _, attempt := range page.Attempts {
		detail := strings.TrimSpace(attempt.Error)
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

	for index, rejection := range page.Turn.Rejections {
		add(TraceStep{
			ID: fmt.Sprintf("rejection-%d", index+1), Stage: "Validation", Actor: "Responder", State: "rejected",
			Title: "Host rejected a model result", Summary: rejection.Outcome, Why: "The typed result contract refused output that could not be applied safely or consistently, and returned a correction to the same attempt.", At: rejection.At,
			Details: []TraceDetail{{Label: "Correction sent to the model", Body: rejection.Detail, Kind: "text", Open: true}},
		})
	}

	if page.Turn.RunID != "" {
		details := []TraceDetail{}
		if page.Turn.Reason != "" {
			details = append(details, TraceDetail{Label: "Host-visible decision rationale", Body: page.Turn.Reason, Kind: "text", Open: true})
		}
		if page.Turn.RawResult != "" {
			details = append(details, TraceDetail{Label: "Raw model result received by Responder", Body: prettyJSON(page.Turn.RawResult), Kind: "json"})
		}
		if len(page.Turn.Operations) > 0 {
			operations := make([]string, 0, len(page.Turn.Operations))
			for _, operation := range page.Turn.Operations {
				operations = append(operations, fmt.Sprintf("%s x%d", operation.Name, operation.Count))
			}
			details = append(details, TraceDetail{
				Label: "Typed result operations",
				Body:  strings.Join(operations, "\n"),
				Kind:  "text",
			})
		}
		details = append(details, TraceDetail{Label: "Provider transcript boundary", Body: "Coop records the submitted prompt, public model result, typed operations, artifacts, usage, and timings. It does not currently return the provider's private chain-of-thought or a granular transcript of every internal tool call, so this page does not invent either.", Kind: "missing"})
		add(TraceStep{
			ID: "result", Stage: "Result", Actor: "Model", State: page.Turn.State,
			Title: "Model result received", Summary: modelSummary(page.Turn), Why: "Responder parses and validates the result before any reply or side effect can leave the host.", At: page.Turn.Updated,
			Stats:   []TraceStat{{"Action", fallback(page.Turn.Action, "not recorded")}, {"Operations", fmt.Sprint(tallyTotal(page.Turn.Operations))}, {"Follow-ups", fmt.Sprint(len(page.Turn.Followups))}},
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
			Details: ledgerDetails(page),
		})
	}

	for index, effect := range page.Effects {
		body := effect.Detail
		if effect.Before != "" || effect.After != "" {
			body = "Before:\n" + fallback(effect.Before, "(empty)") + "\n\nAfter:\n" + fallback(effect.After, "(empty)")
			if effect.Detail != "" {
				body += "\n\n" + effect.Detail
			}
		}
		add(TraceStep{
			ID: fmt.Sprintf("effect-%d", index+1), Stage: "Side effect", Actor: "Responder", State: effect.State,
			Title: effect.Title, Summary: effect.Kind, Why: sideEffectWhy(effect), At: effect.At,
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
			details = append(details, TraceDetail{Label: "Slack payload", Body: delivery.Body, Kind: "json"})
		}
		if delivery.Error != "" {
			details = append(details, TraceDetail{Label: "Delivery error", Body: delivery.Error, Kind: "error", Open: true})
		}
		add(TraceStep{
			ID: fmt.Sprintf("delivery-%d", index+1), Stage: "Delivery", Actor: "Slack outbox", State: delivery.State,
			Title: "Slack " + delivery.Operation, Summary: summary, Why: deliveryWhy(delivery), At: delivery.At,
			Duration: traceDuration(delivery.Created, delivery.At),
			Stats:    []TraceStat{{"Message", fallback(delivery.MessageTS, "none")}, {"Retries", fmt.Sprint(delivery.Retries)}, {"Kind", delivery.Kind}}, Details: details,
		})
	}

	for index, audit := range page.Audit {
		add(TraceStep{
			ID: fmt.Sprintf("audit-%d", index+1), Stage: "Audit", Actor: audit.Whom, State: audit.Outcome,
			Title: audit.Kind, Summary: audit.Detail, Why: "The audit ledger attributes a decision or mutation to an actor and preserves its outcome independently of Slack presentation.", At: audit.At,
			Stats: []TraceStat{{"Actor", audit.Actor}, {"Object", fallback(audit.Object, "none")}, {"Repeats", repeatValue(audit.Repeats)}},
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
		{"Context components", fmt.Sprint(len(page.Manifest.Refs))},
		{"Evidence records", fmt.Sprint(len(page.Evidence))},
		{"Side effects", fmt.Sprint(len(page.Effects))},
		{"Slack deliveries", fmt.Sprint(len(page.Delivered))},
	}
	return trace
}

func episodeMetrics(pricing config.Pricing, page episodePage) []EpisodeMetric {
	respond := EpisodeMetric{Label: "Time to respond", Value: "Not recorded", Missing: true,
		Detail: "No sent Slack reply is retained for this episode."}
	if !page.Source.Received.IsZero() {
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
			respond.Detail = "From Slack receipt to the first sent public reply."
		}
	}

	react := EpisodeMetric{Label: "Time to react", Value: "Not recorded", Missing: true,
		Detail: "No persisted Slack processing indicator is linked to this episode."}
	if !page.Source.Received.IsZero() {
		var first time.Time
		for _, delivery := range page.Delivered {
			if delivery.State == "sent" && delivery.Operation == "status" && !delivery.At.IsZero() &&
				(first.IsZero() || delivery.At.Before(first)) {
				first = delivery.At
			}
		}
		if !first.IsZero() {
			react.Value, react.Missing, react.Tone = compactDuration(first.Sub(page.Source.Received)), false, "good"
			react.Detail = "From Slack receipt to the first persisted native status update."
		}
	}

	cost := episodeCost(pricing, page.Spent)
	costMetric := EpisodeMetric{Label: "Episode cost", Value: "Not priced", Missing: true,
		Detail: "Token usage exists, but no matching configured price was available."}
	if cost.Priceable() {
		costMetric.Value, costMetric.Missing = cost.Money(), false
		costMetric.Detail = "Calculated from recorded tokens and the configured model price."
		if cost.Partial() {
			costMetric.Value += " partial"
			costMetric.Tone = "warn"
		}
	} else if !page.Spent.Recorded() {
		costMetric.Value = "Not measured"
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
	failedAttempts, corrections, deliveries, parseFailures := 0, len(page.Turn.Rejections), 0, 0
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
	if page.Turn.Unreadable != "" {
		parseFailures = 1
	}
	count := failedAttempts + corrections + deliveries + parseFailures
	return count, fmt.Sprintf("%d failed attempts · %d host corrections · %d delivery failures · %d unreadable results", failedAttempts, corrections, deliveries, parseFailures)
}

func sourceSummary(source SourceInput) string {
	text := strings.Join(strings.Fields(source.Text), " ")
	if text == "" {
		return source.Kind + " event in " + source.Channel
	}
	return truncate(text, 180)
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

func contextLabel(kind string) string {
	return map[string]string{
		"source_input": "Source message", "compiled_prompt": "Compiled prompt digest",
		"assembled_context": "Assembled context", "repository": "Repository context",
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
	title := strings.ReplaceAll(kind, "_", " ")
	if title == "" {
		return "Episode event"
	}
	runes := []rune(title)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
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
	switch kind {
	case "episode_created":
		return "The episode kernel created the durable unit of work before execution began."
	case "planning":
		return "Responder classified the request and established the work boundary before calling the model."
	case "context_extended":
		return "Additional context was frozen so later results can be traced to the exact inputs they used."
	case "working":
		return "The episode entered active execution after its prerequisites were ready."
	case "verifying":
		return "The host checked the returned result and any required completion contract before publishing it."
	case "completed":
		return "The episode reached a terminal state after its result and side effects were accepted."
	default:
		return "This is a durable episode-kernel transition recorded for replay and diagnosis."
	}
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

func ledgerDetails(page episodePage) []TraceDetail {
	details := []TraceDetail{}
	for _, claim := range page.Claims {
		body := claim.Status + " · confidence " + fallback(claim.Confidence, "not recorded") +
			fmt.Sprintf("\nSupporting evidence: %d · contradicting evidence: %d", claim.Supporting, claim.Contradicting)
		if claim.Detail != "" {
			body += "\n" + claim.Detail
		}
		details = append(details, TraceDetail{Label: "Claim · " + claim.Claim, Body: body, Kind: "evidence"})
	}
	for _, evidence := range page.Evidence {
		body := evidence.Observation + "\n" + evidence.Relation + " · " + evidence.Source
		if evidence.Freshness != "" {
			body += "\nFreshness: " + evidence.Freshness
		}
		details = append(details, TraceDetail{Label: "Evidence · " + evidence.Claim, Body: body, Kind: "evidence"})
	}
	for _, coverage := range page.Coverage {
		body := coverage.Status + " · " + coverage.Source
		if coverage.Detail != "" {
			body += "\n" + coverage.Detail
		}
		details = append(details, TraceDetail{Label: "Coverage · " + coverage.Layer, Body: body, Kind: "evidence"})
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
