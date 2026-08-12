package webui

import (
	"encoding/json"
	"fmt"
	"net/url"
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
	// Inert renders as a plain line instead of a disclosure: a slot that held
	// nothing has nothing to open, and a control that expands into "no content"
	// teaches people to stop clicking.
	Inert             bool
	Count, GroupCount int
	Segments          []PromptSegment
	Table             *TraceTable
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
	ID, Stage, Actor, State, Title, Summary, Why, Href string
	At                                                 time.Time
	Relative, Duration                                 string
	// Tone colors the step marker: "" for routine, good for a success moment,
	// warn for waiting or degraded, bad for a failure. GapBefore names a quiet
	// stretch longer than a few seconds before this step, because "the model
	// worked for three minutes" is where an episode's wall clock actually goes
	// and a list of near-identical timestamps hides it.
	Tone, GapBefore string
	Stats           []TraceStat
	Details         []TraceDetail
	order           int
	// band is the minimum chapter this step belongs to; -1 derives it from the
	// stage. Chapters are assigned forward-only over the chronological list, so
	// a wake-up scheduled mid-work stays with the work instead of teleporting
	// the reader back to the beginning.
	band int
}

// TraceChapter is one act of the episode: what came in, the work, the answer,
// and what came of it. It exists so a person who has never read this codebase
// can follow the trace as a story instead of a flat ledger.
type TraceChapter struct {
	Title, Blurb, Span string
	Steps              []TraceStep
}

// JourneyStop is one hop in the one-line summary above the trace.
type JourneyStop struct {
	Label, Detail, Tone string
}

// TimeSegment is one chapter's slice of the episode's wall clock, in
// integer thousandths of the full bar so the template stays arithmetic-free.
type TimeSegment struct {
	X, W  int
	Class string
	Title string
}

type EpisodeTrace struct {
	Metrics  []EpisodeMetric
	Journey  []JourneyStop
	Stats    []TraceStat
	Steps    []TraceStep
	Chapters []TraceChapter
	TimeBar  []TimeSegment
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

	// A phase change is stored twice: as a kernel event and as a durable
	// progress record written in the same instant. One fact renders once.
	phaseEvents := map[string][]time.Time{}
	for _, event := range page.Events {
		if event.Kind != "phase_changed" {
			continue
		}
		if payload := decodePhasePayload(event.Payload); payload.Phase != "" {
			phaseEvents[payload.Phase] = append(phaseEvents[payload.Phase], event.At)
		}
	}
	commitmentAt, hasCommitment := time.Time{}, false
	for _, artifact := range page.Artifacts {
		if artifact.Kind == "commitment" {
			commitmentAt, hasCommitment = artifact.At, true
			break
		}
	}

	if page.Source.ID != "" {
		details := []TraceDetail{{Label: "Slack message", Body: present(page.Source.Text), Kind: "text", Open: true}}
		if strings.TrimSpace(page.Source.Attachments) != "" && page.Source.Attachments != "[]" &&
			page.Source.Attachments != "null" {
			details = append(details, TraceDetail{Label: "Attachment manifest", Body: page.Source.Attachments, Kind: "json"})
		}
		add(TraceStep{
			ID: "source", Stage: "Input", Actor: "Slack", State: sourceKindLabel(page.Source),
			Title: sourceTitle(page.Source), At: page.Source.Received,
			Stats: []TraceStat{{"Channel", page.Source.Channel}, {"Message", page.Source.MessageTS},
				{"Thread", fallback(page.Source.ThreadTS, "top level")}, {"Sender", fallback(page.Source.Sender, page.Source.UserID)}},
			Details: details,
		})
	} else {
		add(TraceStep{
			ID: "source-missing", Stage: "Input", Actor: "Responder", State: "not recorded",
			Title: "Starting input unavailable", At: page.Created,
			Summary: "The message or event that started this episode was not retained.",
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
			Why:     "Instead of holding a worker, Responder saved what to watch for and let go. The matching event resumes this exact episode.",
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
				ID: resolvedID, Stage: "Wait", Actor: "Responder", State: wakeup.State, Tone: "good",
				Title: "Wake-up resolved", At: wakeup.Resolved,
				Summary: "The awaited event arrived; the episode could continue.",
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
			Summary: "The awaited event arrived, so Responder resumed this work on its own — no new Slack message was needed.",
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
				Label: "Submitted prompt", Body: "The exact prompt text was not kept for this attempt. Its fingerprint is under Replay verification below.",
				Kind: "missing", Status: "Not retained", Tone: "missing", Open: true,
			})
		}
		if prompt == "" {
			promptDetails = markDetailGroup(promptDetails,
				"Prompt text unavailable",
				"This attempt kept the prompt's metadata and fingerprint, but not its text.",
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
			ID: promptID, Stage: "Context", Actor: "Responder", State: "recorded",
			Title: "Model briefed", Summary: promptStepSummary(manifest, memoryLayers), At: manifest.Created,
			Stats:   []TraceStat{{"Prompt", fallback(manifest.PromptVersion, "unversioned")}, {"Contract", fallback(manifest.Contract, "none")}, {"Tool schema", fallback(manifest.ToolSchema, "none")}, {"Context refs", fmt.Sprint(len(manifest.Refs))}, {"Memory layers", fmt.Sprint(memoryLayers)}, {"Attempt", fmt.Sprint(manifest.AttemptNumber)}},
			Details: promptDetails,
		})
	}

	for index, event := range page.Events {
		if event.Kind == "episode_created" && hasCommitment {
			// The commitment step already says Responder took the job; a second
			// card at the same instant saying "episode created" is plumbing.
			continue
		}
		details := []TraceDetail{}
		if payload := presentEventPayload(event.Payload, present); payload != "" && payload != "{}" {
			details = append(details, TraceDetail{Label: "Recorded event payload", Body: payload, Kind: "json"})
		}
		if occurrences := occurrenceDetail(event.Occurrences); occurrences != nil {
			details = append(details, *occurrences)
		}
		step := TraceStep{
			ID: fmt.Sprintf("event-%d", index+1), Stage: eventStage(event.Kind), Actor: event.Actor,
			State: event.Kind, Title: eventTitle(event.Kind), Summary: present(event.Detail),
			Why: eventWhy(event.Kind), At: event.At, Details: details,
		}
		if event.Attempt > 1 {
			step.Stats = append(step.Stats, TraceStat{"Attempt", fmt.Sprint(event.Attempt)})
		}
		if event.Repeats > 0 {
			step.Stats = append(step.Stats, TraceStat{"Repeats", repeatValue(event.Repeats)})
		}
		if event.Kind == "phase_changed" {
			if payload := decodePhasePayload(event.Payload); payload.Phase != "" {
				step.State, step.Title = payload.Phase, phaseTitle(payload.Phase)
				step.Summary = present(fallback(payload.NextAction, payload.Summary))
			}
		}
		add(step)
	}

	for index, artifact := range page.Artifacts {
		if artifact.Kind == "progress" && progressDuplicatesPhase(artifact, phaseEvents, commitmentAt, hasCommitment) {
			// The kernel event for the same phase change renders the step; the
			// progress record repeats it in the same instant.
			continue
		}
		details := []TraceDetail{}
		if strings.TrimSpace(artifact.Detail) != "" {
			details = append(details, TraceDetail{
				Label: artifactDetailLabel(artifact.Kind), Body: present(artifact.Detail),
				Kind: fallback(artifact.DetailKind, "text"), Open: false,
			})
		}
		stats := make([]TraceStat, 0, len(artifact.Stats))
		for _, stat := range artifact.Stats {
			if strings.TrimSpace(stat.Value) != "" && !droppedArtifactStat(artifact.Kind, stat.Label) {
				stats = append(stats, TraceStat{stat.Label, present(stat.Value)})
			}
		}
		step := TraceStep{
			ID:    fmt.Sprintf("record-%s-%d", artifact.Kind, index+1),
			Stage: artifactStage(artifact.Kind), Actor: artifactActor(artifact.Kind),
			State: fallback(artifact.State, "recorded"), Title: present(artifact.Title), Summary: present(artifact.Summary),
			Why: artifactWhy(artifact.Kind), At: artifact.At, Stats: stats, Details: details,
		}
		switch artifact.Kind {
		case "commitment":
			step.Title, step.Summary = "Responder took the job", ""
		case "progress":
			step.Title = phaseTitle(artifact.State)
			if strings.EqualFold(strings.TrimSpace(artifact.Summary), strings.TrimSpace(artifact.State)) {
				step.Summary = ""
			}
		case "evaluation":
			step.Title = decisionTitle(artifact.State)
		}
		add(step)
	}

	for _, attempt := range page.Attempts {
		step := TraceStep{
			ID: fmt.Sprintf("attempt-%d", attempt.Number), Stage: "Execution", Actor: "Coop", State: attempt.State,
			Title: fmt.Sprintf("Attempt %d %s", attempt.Number, attempt.State), Summary: attemptSummary(attempt),
			Why: attemptWhy(attempt), At: attempt.Completed, Tone: stateTone(attempt.State),
			Duration: traceDuration(attempt.Started, attempt.Completed),
			Stats:    []TraceStat{{"Run", attempt.RunID}},
		}
		if attempt.Failure != "" {
			step.Stats = append(step.Stats, TraceStat{"Failure class", attempt.Failure})
		}
		if detail := strings.TrimSpace(present(attempt.Error)); detail != "" {
			step.Details = []TraceDetail{{Label: "Terminal detail", Body: detail, Kind: "text"}}
		}
		add(step)
	}

	for index, rejection := range page.Rejections {
		add(TraceStep{
			ID: fmt.Sprintf("rejection-%d", index+1), Stage: "Validation", Actor: "Responder", State: "rejected", Tone: "bad",
			Title: "Answer rejected", Summary: present(rejection.Outcome),
			Why: "The result did not fit the required format, so Responder sent a correction back instead of acting on it.", At: rejection.At,
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
			details = append(details, TraceDetail{Label: "Why the model chose this", Body: present(turn.Reason), Kind: "text", Open: true})
		}
		if turn.RawResult != "" {
			details = append(details, TraceDetail{Label: "Raw model result", Body: present(prettyJSON(turn.RawResult)), Kind: "json"})
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
		resultID := "result"
		if len(turns) > 1 {
			resultID = fmt.Sprintf("result-%d", turnIndex+1)
		}
		add(TraceStep{
			ID: resultID, Stage: "Result", Actor: "Model", State: turn.State, Tone: stateTone(turn.State),
			Title: "Model result received", Summary: present(modelSummary(turn)),
			Why: "Responder checks every result against its contract before anything reaches Slack.", At: turn.Updated,
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
			Title: "Evidence recorded", Summary: countList([]countPart{
				{len(page.Claims), "claim", "claims"},
				{len(page.Evidence), "evidence record", "evidence records"},
				{len(page.Coverage), "coverage assessment", "coverage assessments"}}),
			Why: "Claims and observations are stored separately so the conclusion can be re-checked later.", At: page.Turn.Updated,
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
		summary := present(effect.Title)
		href := ""
		if effect.Kind == "work episode" {
			// A delegated episode's objective is prose that may carry raw Slack
			// markup; identifiers like rule names must stay exact.
			summary = cleanTitle(summary)
			href = "/episodes/" + url.PathEscape(effect.ID)
		}
		add(TraceStep{
			ID: fmt.Sprintf("effect-%d", index+1), Stage: "Side effect", Actor: "Responder", State: effect.State,
			Tone:  stateTone(effect.State),
			Title: effectTitle(effect), Summary: summary, Why: sideEffectWhy(effect), Href: href, At: effect.At,
			Stats:   []TraceStat{{"ID", fallback(effect.ID, "none")}},
			Details: []TraceDetail{{Label: "Recorded change", Body: fallback(body, "No additional value was recorded."), Kind: "diff", Open: effect.Before != "" || effect.After != ""}},
		})
	}

	for index, delivery := range page.Delivered {
		summary := delivery.Channel
		if delivery.ThreadTS != "" {
			summary += " · thread " + delivery.ThreadTS
		}
		details := []TraceDetail{}
		if delivery.Body != "" {
			details = append(details, TraceDetail{Label: "Slack payload", Body: present(delivery.Body), Kind: "json"})
		}
		if delivery.Error != "" {
			details = append(details, TraceDetail{Label: "Delivery error", Body: present(delivery.Error), Kind: "error", Open: true})
		}
		stats := []TraceStat{{"Message", fallback(delivery.MessageTS, "none")}, {"Kind", delivery.Kind}}
		if delivery.Retries > 0 {
			stats = append(stats, TraceStat{"Retries", fmt.Sprint(delivery.Retries)})
		}
		step := TraceStep{
			ID: fmt.Sprintf("delivery-%d", index+1), Stage: "Delivery", Actor: "Slack outbox", State: delivery.State,
			Tone:  stateTone(delivery.State),
			Title: deliveryTitle(delivery), Summary: summary, Why: deliveryWhy(delivery), At: delivery.At,
			Duration: traceDuration(delivery.Created, delivery.At),
			Stats:    stats, Details: details,
		}
		if delivery.Operation == "status" {
			step.band = bandWork
		}
		add(step)
	}

	for index, audit := range page.Audit {
		// Removing a temporary working marker is Slack plumbing, not another
		// rule decision, and result corrections already render as their own
		// rejection steps.
		if audit.Kind == "standing_rule.acknowledgement_cleared" || audit.Kind == "result.correction" {
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
			Tone:  stateTone(audit.Outcome),
			Title: auditTitle(audit.Kind), Summary: summary, Why: auditTraceWhy(audit), At: audit.At,
			Stats: stats, Details: details, band: auditBand(audit.Kind),
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
	steps = foldLoneAttempt(steps)
	start := page.Source.Received
	if start.IsZero() {
		start = page.Created
	}
	previous := time.Time{}
	for index := range steps {
		if !steps[index].At.IsZero() && !start.IsZero() {
			steps[index].Relative = "+" + compactDuration(steps[index].At.Sub(start))
		}
		if steps[index].Tone == "" {
			steps[index].Tone = stateTone(steps[index].State)
		}
		// A quiet stretch is a fact worth a mark of its own: almost all of an
		// episode's wall clock sits between two adjacent steps, usually around
		// the model working.
		if !previous.IsZero() && !steps[index].At.IsZero() {
			if gap := steps[index].At.Sub(previous); gap >= 10*time.Second {
				steps[index].GapBefore = compactDuration(gap)
			}
		}
		if !steps[index].At.IsZero() {
			previous = steps[index].At
		}
	}
	trace.Steps = steps
	trace.Chapters = traceChapters(steps)
	trace.Journey = traceJourney(page, turns, wakeups)
	trace.TimeBar = traceTimeBar(trace.Chapters)
	for _, stat := range []struct {
		count            int
		singular, plural string
	}{
		{len(page.Attempts), "Attempt", "Attempts"},
		{len(turns), "Model turn", "Model turns"},
		{len(wakeups), "Wake-up", "Wake-ups"},
		{len(page.Manifest.Refs), "Context component", "Context components"},
		{len(page.Evidence), "Evidence record", "Evidence records"},
		{len(page.Effects), "Side effect", "Side effects"},
		{len(page.Delivered), "Slack delivery", "Slack deliveries"},
	} {
		if stat.count == 0 {
			continue
		}
		label := stat.plural
		if stat.count == 1 {
			label = stat.singular
		}
		trace.Stats = append(trace.Stats, TraceStat{label, fmt.Sprint(stat.count)})
	}
	return trace
}

// Chapters. Zero means "derive from the stage"; explicit bands exist for the
// few steps whose stage alone places them wrong, like a status delivery that
// is progress feedback rather than an outcome.
const (
	bandIn = iota + 1
	bandWork
	bandAnswer
	bandOutcome
)

var chapterNames = [...]struct{ title, blurb string }{
	{"What came in", "The message or event that started this."},
	{"The work", "How Responder handled it: the model, its briefing, and checkpoints along the way."},
	{"The answer", "What the model returned and what Responder decided to do."},
	{"What came of it", "Replies, saved changes, and follow-ups."},
}

func stepBand(step TraceStep) int {
	if step.band != 0 {
		return step.band
	}
	switch step.Stage {
	case "Input", "Trigger", "Wait", "Schedule":
		return bandIn
	case "Plan", "Routing", "Context", "Preparation", "Execution", "Validation", "":
		return bandWork
	case "Result", "Decision", "Evidence", "Measurement":
		return bandAnswer
	default:
		return bandOutcome
	}
}

// traceChapters cuts the chronological rail into acts. Assignment is
// forward-only: each step lands in its own band or the story's current one,
// whichever is later, so chapters stay contiguous in time and a late
// acknowledgement cannot teleport the reader back to the beginning.
func traceChapters(steps []TraceStep) []TraceChapter {
	if len(steps) == 0 {
		return nil
	}
	chapters := []TraceChapter{}
	current := 0
	for _, step := range steps {
		band := stepBand(step)
		if band < current {
			band = current
		}
		if len(chapters) == 0 || band > current {
			chapters = append(chapters, TraceChapter{
				Title: chapterNames[band-1].title,
				Blurb: chapterNames[band-1].blurb,
			})
			current = band
		}
		last := len(chapters) - 1
		chapters[last].Steps = append(chapters[last].Steps, step)
	}
	for index := range chapters {
		chapterSteps := chapters[index].Steps
		first, last := chapterSteps[0].Relative, chapterSteps[len(chapterSteps)-1].Relative
		if first == "" {
			continue
		}
		chapters[index].Span = first
		if last != first && last != "" {
			chapters[index].Span = first + " → " + last
		}
	}
	return chapters
}

// traceTimeBar turns the chapters into one proportional strip of the
// episode's wall clock. The rail says what happened in order; this says what
// the order cost — usually that nearly all of it sat inside "The work".
func traceTimeBar(chapters []TraceChapter) []TimeSegment {
	type span struct {
		index int
		start time.Time
	}
	spans := []span{}
	var last time.Time
	for index, chapter := range chapters {
		var first time.Time
		for _, step := range chapter.Steps {
			if step.At.IsZero() {
				continue
			}
			if first.IsZero() {
				first = step.At
			}
			if step.At.After(last) {
				last = step.At
			}
		}
		if !first.IsZero() {
			spans = append(spans, span{index, first})
		}
	}
	if len(spans) < 2 || last.IsZero() {
		return nil
	}
	total := last.Sub(spans[0].start)
	if total < 2*time.Second {
		return nil
	}
	segments := make([]TimeSegment, 0, len(spans))
	for position, current := range spans {
		end := last
		if position+1 < len(spans) {
			end = spans[position+1].start
		}
		width := int(end.Sub(current.start) * 1000 / total)
		segments = append(segments, TimeSegment{
			W:     max(width, 5),
			Class: fmt.Sprintf("c%d", current.index),
			Title: chapters[current.index].Title + " · " + compactDuration(end.Sub(current.start)),
		})
	}
	x, scale := 0, 0
	for _, segment := range segments {
		scale += segment.W
	}
	for index := range segments {
		segments[index].W = segments[index].W * 1000 / scale
		segments[index].X = x
		x += segments[index].W
	}
	if len(segments) > 0 {
		segments[len(segments)-1].W = 1000 - segments[len(segments)-1].X
	}
	return segments
}

// traceJourney is the one-line version of the whole episode: what arrived,
// what worked on it, how long that took, and how it ended. It only states
// what the durable records state.
func traceJourney(page episodePage, turns []Turn, wakeups []Wakeup) []JourneyStop {
	stops := []JourneyStop{}
	if page.Source.ID != "" {
		label := sourceTitle(page.Source)
		detail := page.Source.Channel
		if !page.Source.Received.IsZero() {
			detail = strings.TrimPrefix(detail+" · "+page.Source.Received.UTC().Format("15:04 UTC"), " · ")
		}
		stops = append(stops, JourneyStop{Label: label, Detail: detail})
	}
	if page.Manifest.Version > 0 {
		detail := strings.Trim(page.Manifest.Model+"/"+page.Manifest.Effort, "/")
		stops = append(stops, JourneyStop{Label: "Model briefed", Detail: detail})
	}
	if worked := workedDuration(page, turns); worked > 0 {
		detail := ""
		if len(page.Attempts) > 1 {
			detail = fmt.Sprintf("%d attempts", len(page.Attempts))
		}
		if len(wakeups) > 0 {
			detail = strings.TrimPrefix(detail+" · slept between wake-ups", " · ")
		}
		stops = append(stops, JourneyStop{Label: "Worked " + compactDuration(worked), Detail: detail})
	}
	if outcome := journeyOutcome(page); outcome.Label != "" {
		stops = append(stops, outcome)
	}
	if end := journeyEnd(page); end.Label != "" {
		stops = append(stops, end)
	}
	if len(stops) < 2 {
		return nil
	}
	return stops
}

func workedDuration(page episodePage, turns []Turn) time.Duration {
	var start, end time.Time
	for _, attempt := range page.Attempts {
		if !attempt.Started.IsZero() && (start.IsZero() || attempt.Started.Before(start)) {
			start = attempt.Started
		}
		if attempt.Completed.After(end) {
			end = attempt.Completed
		}
	}
	if start.IsZero() && page.Manifest.Version > 0 {
		start = page.Manifest.Created
	}
	for _, turn := range turns {
		if turn.Updated.After(end) {
			end = turn.Updated
		}
	}
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return 0
	}
	return end.Sub(start)
}

func firstReply(page episodePage) (Delivery, bool) {
	var first Delivery
	found := false
	for _, delivery := range page.Delivered {
		if delivery.State != "sent" || delivery.Operation == "status" || delivery.At.IsZero() {
			continue
		}
		if !found || delivery.At.Before(first.At) {
			first, found = delivery, true
		}
	}
	return first, found
}

// latestDecision is the persisted evaluation of what the source event needed:
// a reply, an investigation, or nothing.
func latestDecision(page episodePage) (action, reason string) {
	for _, artifact := range page.Artifacts {
		if artifact.Kind == "evaluation" {
			action, reason = artifact.State, artifact.Summary
		}
	}
	return action, reason
}

func journeyOutcome(page episodePage) JourneyStop {
	action, _ := latestDecision(page)
	if reply, ok := firstReply(page); ok {
		detail := ""
		if !page.Source.Received.IsZero() {
			detail = compactDuration(reply.At.Sub(page.Source.Received)) + " after the message"
		}
		return JourneyStop{Label: "Replied in " + fallback(reply.Channel, "Slack"), Detail: detail, Tone: "good"}
	}
	switch page.State {
	case "failed":
		return JourneyStop{Label: "Failed", Tone: "bad"}
	case "blocked", "waiting_operator", "waiting_approval":
		return JourneyStop{Label: "Waiting on you", Tone: "warn"}
	case "waiting_external":
		return JourneyStop{Label: "Waiting on an external event", Tone: "warn"}
	}
	if action == "ignore" {
		return JourneyStop{Label: "Chose not to reply", Tone: "good"}
	}
	if action != "" {
		return JourneyStop{Label: "Decided: " + strings.ReplaceAll(action, "_", " ")}
	}
	return JourneyStop{}
}

func journeyEnd(page episodePage) JourneyStop {
	total := ""
	if !page.Source.Received.IsZero() && !page.Updated.IsZero() && page.Updated.After(page.Source.Received) {
		total = compactDuration(page.Updated.Sub(page.Source.Received))
	}
	tokens := ""
	if page.Spent.Recorded() {
		tokens = humanTokens(page.Spent.Total()) + " tokens"
	}
	detail := strings.TrimPrefix(strings.TrimSuffix(total+" · "+tokens, " · "), " · ")
	switch page.State {
	case "completed":
		return JourneyStop{Label: "Done", Detail: detail, Tone: "good"}
	case "failed", "blocked", "waiting_operator", "waiting_approval", "waiting_external":
		return JourneyStop{}
	case "cancelled":
		return JourneyStop{Label: "Cancelled", Detail: detail}
	case "superseded":
		return JourneyStop{Label: "Superseded", Detail: detail}
	default:
		return JourneyStop{Label: "Still open", Detail: detail}
	}
}

// foldLoneAttempt merges a single successful Coop attempt into the model
// result it produced. "Attempt 1 succeeded · no terminal error" next to the
// result it succeeded with is the same fact twice; failures and retries keep
// their own steps because they are the story.
func foldLoneAttempt(steps []TraceStep) []TraceStep {
	attemptIndex, resultIndex, attempts := -1, -1, 0
	for index, step := range steps {
		if strings.HasPrefix(step.ID, "attempt-") {
			attempts++
			attemptIndex = index
		}
		if step.ID == "result" || strings.HasPrefix(step.ID, "result-") {
			resultIndex = index
		}
	}
	if attempts != 1 || resultIndex < 0 || attemptIndex < 0 ||
		steps[attemptIndex].State != "succeeded" || len(steps[attemptIndex].Details) > 0 {
		return steps
	}
	if steps[resultIndex].Duration == "" {
		steps[resultIndex].Duration = steps[attemptIndex].Duration
	}
	return append(steps[:attemptIndex], steps[attemptIndex+1:]...)
}

type countPart struct {
	count            int
	singular, plural string
}

func countList(parts []countPart) string {
	kept := []string{}
	for _, part := range parts {
		if part.count == 0 {
			continue
		}
		label := part.plural
		if part.count == 1 {
			label = part.singular
		}
		kept = append(kept, fmt.Sprintf("%d %s", part.count, label))
	}
	return strings.Join(kept, " · ")
}

type phasePayload struct {
	Phase      string `json:"phase"`
	NextAction string `json:"next_action"`
	Summary    string `json:"summary"`
}

func decodePhasePayload(payload string) phasePayload {
	var decoded phasePayload
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded
}

// phaseTitle names a work phase the way a person would say it.
func phaseTitle(phase string) string {
	if title, ok := map[string]string{
		"accepted":      "Accepted the work",
		"planning":      "Planning the work",
		"investigating": "Investigating",
		"executing":     "Executing",
		"implementing":  "Implementing",
		"verifying":     "Verifying",
		"finalizing":    "Wrapping up",
		"finished":      "Finished the work",
		"waiting":       "Waiting",
		"blocked":       "Blocked",
	}[phase]; ok {
		return title
	}
	return eventTitle(phase)
}

func progressDuplicatesPhase(artifact EpisodeArtifact, phaseEvents map[string][]time.Time, commitmentAt time.Time, hasCommitment bool) bool {
	const window = 5 * time.Second
	if hasCommitment && artifact.State == "accepted" &&
		absDuration(artifact.At.Sub(commitmentAt)) <= window {
		return true
	}
	for _, at := range phaseEvents[artifact.State] {
		if absDuration(artifact.At.Sub(at)) <= window {
			return true
		}
	}
	return false
}

func absDuration(duration time.Duration) time.Duration {
	if duration < 0 {
		return -duration
	}
	return duration
}

// droppedArtifactStat hides identifiers that only restate storage plumbing.
func droppedArtifactStat(kind, label string) bool {
	if kind == "progress" && (label == "Record" || label == "Sequence" || label == "Phase") {
		return true
	}
	return false
}

func sourceTitle(source SourceInput) string {
	switch source.Kind {
	case "bot_message":
		return "App message received"
	case "mention":
		return "Responder was mentioned"
	case "recheck":
		return "Follow-up input received"
	case "schedule", "scheduled":
		return "Scheduled run started"
	default:
		if strings.HasPrefix(source.UserID, "B") {
			return "App message received"
		}
		return "Message received"
	}
}

func sourceKindLabel(source SourceInput) string {
	return strings.ReplaceAll(source.Kind, "_", " ")
}

func promptStepSummary(manifest ManifestRow, memoryLayers int) string {
	parts := countList([]countPart{
		{len(manifest.Refs), "context component", "context components"},
		{memoryLayers, "memory layer", "memory layers"},
	})
	if parts == "" {
		return "The exact input for this attempt was recorded."
	}
	return parts + " — the exact input, kept as sent."
}

func decisionTitle(action string) string {
	if title, ok := map[string]string{
		"ignore":           "Decided: no reply needed",
		"reply":            "Decided: reply",
		"investigate":      "Decided: investigate",
		"engineering_task": "Decided: open an engineering task",
	}[action]; ok {
		return title
	}
	if action == "" {
		return "Decision recorded"
	}
	return "Decided: " + strings.ReplaceAll(action, "_", " ")
}

func stateTone(state string) string {
	switch state {
	case "failed", "rejected", "error", "unreadable", "discarded", "refused", "dead":
		return "bad"
	case "blocked", "waiting", "waiting_operator", "waiting_approval", "waiting_external",
		"pending", "offered", "retrying", "cancelled", "superseded", "disabled", "not measured":
		return "warn"
	case "completed", "succeeded", "sent", "saved", "resolved", "finished", "confirmed",
		"published", "approved", "applied":
		return "good"
	default:
		return ""
	}
}

func effectTitle(effect SideEffect) string {
	noun := map[string]string{
		"conversation memory": "Conversation memory",
		"durable memory":      "Durable memory",
		"preference":          "Preference",
		"standing rule":       "Standing rule",
		"scheduled task":      "Scheduled task",
		"engineering task":    "Engineering task",
		"Emisar approval":     "Emisar approval",
		"visual":              "Visual",
		"publication":         "Publication",
		"work episode":        "Delegated work",
	}[effect.Kind]
	if noun == "" {
		noun = eventTitle(effect.Kind)
	}
	verb := map[string]string{
		"saved":     "saved",
		"reported":  "noted",
		"offered":   "offered",
		"waiting":   "awaiting approval",
		"attached":  "attached",
		"disabled":  "disabled",
		"completed": "completed",
	}[effect.State]
	if verb == "" {
		verb = strings.ReplaceAll(effect.State, "_", " ")
	}
	return strings.TrimSpace(noun + " " + verb)
}

func deliveryTitle(delivery Delivery) string {
	switch delivery.Operation {
	case "post":
		if delivery.ThreadTS != "" {
			return "Replied in the thread"
		}
		return "Posted to Slack"
	case "update":
		return "Updated the Slack message"
	case "status":
		return "Working status shown in Slack"
	case "reaction":
		if delivery.Kind == "failure_marker_remove" {
			return "Cleared the processing-failure marker"
		}
		return "Marked the message after processing failed"
	case "delete":
		return "Removed a Slack message"
	default:
		return "Slack " + delivery.Operation
	}
}

// auditTitle names common audit kinds in plain words; anything unmapped falls
// back to the generic title-casing.
func auditTitle(kind string) string {
	if title, ok := map[string]string{
		"result.legacy_shape":          "Result used an older format",
		"slack.watch":                  "Watch decision",
		"slack.watch.engineering_task": "Engineering task offered",
		"slack.reaction":               "Reaction",
		"slack.replay":                 "Replay recorded",
		"slack.paused":                 "Paused",
		"memory.remember":              "Memory saved",
		"preference.remember":          "Preference saved",
		"rule.remember":                "Standing rule saved",
		"schedule.created":             "Schedule created",
		"emisar.approval.opened":       "Emisar approval opened",
		"emisar.approval.pending":      "Emisar approval pending",
		"emisar.approval.completed":    "Emisar approval completed",
		"episode.resolve":              "Episode resolved by an operator",
		"engineering_task.discard":     "Engineering task discarded",
		"coop.session.created":         "Coop session created",
		"coop.budget.auto_extend":      "Coop budget extended",
		"fixture.review":               "Correction reviewed",
		"agent.report":                 "Agent report",
	}[kind]; ok {
		return title
	}
	return eventTitle(kind)
}

func auditBand(kind string) int {
	switch kind {
	case "slack.watch", "slack.watch.engineering_task", "result.legacy_shape", "agent.report":
		return bandAnswer
	case "memory.remember", "preference.remember", "rule.remember", "schedule.created",
		"episode.resolve", "fixture.review", "publication.draft_pr", "slack.reaction":
		return bandOutcome
	default:
		return 0
	}
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
	// Audit rows carry their meaning in the title and outcome; a recurring
	// paragraph about what an audit ledger is would drown them.
	return ""
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
		Inert: true,
	}
}

func missingMemoryDetail(label, key string) TraceDetail {
	return TraceDetail{
		Label: label, Body: "No content selected.", Kind: "missing",
		Status: "Not sent", Description: promptSelectionDescription(key, false), Tone: promptTone(key),
		Inert: true,
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
		return fmt.Sprintf("Preset %s routed this episode to %s at %s effort.", manifest.Preset, target, effort)
	}
	return fmt.Sprintf("The routing policy selected %s at %s effort.", target, effort)
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
	outcome := episodeOutcome(page)

	// One card answers "how fast" — the reply for its value, the first visible
	// acknowledgement (a status or a working reaction) in its detail.
	respond := EpisodeMetric{Label: "Time to respond", Value: "—", Missing: true}
	acknowledged := ""
	if !page.Source.Received.IsZero() {
		if reacted := firstAcknowledgement(page); !reacted.IsZero() {
			acknowledged = "Acknowledged in " + compactDuration(reacted.Sub(page.Source.Received)) + "."
		}
		if reply, ok := firstReply(page); ok {
			respond.Value, respond.Missing, respond.Tone = compactDuration(reply.At.Sub(page.Source.Received)), false, "good"
			respond.Detail = strings.TrimSpace("From the message to the reply in " + fallback(reply.Channel, "Slack") + ". " + acknowledged)
		} else if successor, ok := firstRespondingSuccessor(page); ok {
			respond.Value, respond.Missing, respond.Tone = compactDuration(successor.ResponseAt.Sub(page.Source.Received)), false, "good"
			respond.Detail = strings.TrimSpace("A successor episode replied in Slack. " + acknowledged)
		} else {
			respond.Detail = strings.TrimSpace("No Slack reply was sent. " + acknowledged)
		}
	} else {
		respond.Detail = "The start time was not recorded."
	}

	cost := episodeCost(pricing, page.Spent)
	spend := EpisodeMetric{Label: "Model spend", Value: "—", Missing: true,
		Detail: "The provider reported no token usage."}
	if page.Spent.Recorded() {
		tokens := humanTokens(page.Spent.Total())
		spend.Missing = false
		spend.Detail = tokens + " tokens · " + page.Spent.CacheLabel() + " served from cache"
		switch {
		case cost.Reported():
			spend.Value = cost.ReportedMoney()
			spend.Detail += fmt.Sprintf(" · provider reported %d turn(s)", cost.ReportedTurns)
			if cost.EstimatedKnown() {
				spend.Detail += " · " + cost.EstimatedMoney() + " estimated for unreported rows"
			}
		case cost.EstimatedKnown():
			spend.Value = cost.EstimatedMoney() + " est."
		default:
			spend.Value = tokens + " tok"
			spend.Detail = "No price is configured for this model · " + page.Spent.CacheLabel() + " served from cache"
		}
	} else if cost.Reported() {
		spend.Value, spend.Missing = cost.ReportedMoney(), false
		spend.Detail = fmt.Sprintf("Provider reported %d turn(s); token counts were not reported.", cost.ReportedTurns)
	}

	errors, breakdown := episodeErrorCount(page)
	errorMetric := EpisodeMetric{Label: "Errors", Value: fmt.Sprint(errors), Detail: breakdown}
	if errors > 0 {
		errorMetric.Tone = "bad"
	} else {
		errorMetric.Tone = "good"
		errorMetric.Detail = "No failed attempts, corrections, or delivery failures."
	}
	return []EpisodeMetric{outcome, respond, spend, errorMetric}
}

// firstAcknowledgement is the first visible sign Responder picked the work up:
// a sent Slack status, or the working reaction a standing rule added.
func firstAcknowledgement(page episodePage) time.Time {
	var first time.Time
	for _, delivery := range page.Delivered {
		if delivery.State == "sent" && delivery.Operation == "status" && !delivery.At.IsZero() &&
			(first.IsZero() || delivery.At.Before(first)) {
			first = delivery.At
		}
	}
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
	return first
}

// episodeOutcome is the first thing the page answers: how did this end, or
// what is it waiting for right now.
func episodeOutcome(page episodePage) EpisodeMetric {
	metric := EpisodeMetric{Label: "Outcome"}
	action, reason := latestDecision(page)
	switch page.State {
	case "failed":
		metric.Value, metric.Tone = "Failed", "bad"
		metric.Detail = failureDetail(page)
	case "blocked", "waiting_operator", "waiting_approval":
		metric.Value, metric.Tone = "Waiting on you", "warn"
		metric.Detail = truncate(page.Next, 110)
	case "waiting_external":
		metric.Value, metric.Tone = "Waiting on an event", "warn"
		metric.Detail = "Parked until the awaited external event arrives."
	case "cancelled":
		metric.Value, metric.Detail = "Cancelled", "Stopped before it finished."
	case "superseded":
		metric.Value = "Superseded"
		if successor, ok := firstRespondingSuccessor(page); ok {
			metric.Detail = "A newer episode replied: " + truncate(successor.Title, 80)
		} else {
			metric.Detail = "A newer episode took over this work."
		}
	case "completed":
		metric.Tone = "good"
		if reply, ok := firstReply(page); ok {
			metric.Value = "Replied"
			metric.Detail = "In " + fallback(reply.Channel, "Slack")
			if !page.Source.Received.IsZero() {
				metric.Detail += ", " + compactDuration(reply.At.Sub(page.Source.Received)) + " after the message"
			}
		} else if action == "ignore" {
			metric.Value, metric.Detail = "No reply needed", truncate(reason, 110)
		} else {
			metric.Value, metric.Detail = "Completed", truncate(reason, 110)
		}
	default:
		metric.Value = "In progress"
		metric.Detail = truncate(fallback(page.Status, page.Next), 110)
	}
	return metric
}

func failureDetail(page episodePage) string {
	for index := len(page.Attempts) - 1; index >= 0; index-- {
		if page.Attempts[index].Failure != "" {
			return truncate(page.Attempts[index].Failure, 110)
		}
		if page.Attempts[index].Error != "" {
			return truncate(page.Attempts[index].Error, 110)
		}
	}
	return "The last attempt did not finish."
}

func episodeCost(pricing config.Pricing, spent EpisodeTokens) UsageCost {
	cost := UsageCost{Currency: pricing.Currency, Configured: len(pricing.Models) > 0}
	for _, row := range spent.Rows {
		if row.CostedTurns > 0 {
			cost.ReportedUSD += row.CostUSD
			cost.ReportedTurns += row.CostedTurns
			continue
		}
		if !row.Measured {
			continue
		}
		cost.MeasuredRows++
		amount, known := pricing.Cost(row.Provider, row.Model, core.ContextUsage{
			InputTokens: int(row.Input), CachedInputTokens: int(row.Cached),
			OutputTokens: int(row.Output), ReasoningTokens: int(row.Reasoning),
		})
		if known {
			cost.Estimated += amount
			cost.EstimatedRows++
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
	processingFailures, failedAttempts, unaccountedAttempts, deliveries, parseFailures := 0, 0, 0, 0, 0
	failuresByRun := make(map[string]int, len(page.Turns)+1)
	for _, turn := range page.Turns {
		processingFailures += turn.Failures
		failuresByRun[turn.RunID] += turn.Failures
	}
	if len(page.Turns) == 0 && page.Turn.RunID != "" {
		processingFailures += page.Turn.Failures
		failuresByRun[page.Turn.RunID] += page.Turn.Failures
	}
	for _, attempt := range page.Attempts {
		if attempt.State == "failed" || attempt.Failure != "" {
			failedAttempts++
			if failuresByRun[attempt.RunID] == 0 {
				unaccountedAttempts++
			}
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
	count := processingFailures + unaccountedAttempts + corrections + deliveries + parseFailures
	return count, fmt.Sprintf("%d processing failures · %d failed attempts · %d host corrections · %d delivery failures · %d unreadable results", processingFailures, failedAttempts, corrections, deliveries, parseFailures)
}

func firstRespondingSuccessor(page episodePage) (SideEffect, bool) {
	var first SideEffect
	for _, effect := range page.Effects {
		if effect.Kind != "work episode" || !effect.Responded || effect.ResponseAt.IsZero() {
			continue
		}
		if first.ResponseAt.IsZero() || effect.ResponseAt.Before(first.ResponseAt) {
			first = effect
		}
	}
	return first, !first.ResponseAt.IsZero()
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
	if title, ok := map[string]string{
		"standing_rules.evaluated":   "Standing rules",
		"standing_rule.acknowledged": "Standing rules",
		"episode_created":            "Episode created",
		"phase_changed":              "Phase changed",
		"context_extended":           "More context added",
		"completed":                  "Episode completed",
		"blocked":                    "Blocked",
	}[kind]; ok {
		return title
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
		return "The job is recorded durably, so it survives restarts and cannot silently disappear when a model turn ends."
	case "goal":
		return "A required outcome that can block completion until it is satisfied."
	case "evaluation":
		return "The recorded judgment of whether this needed a reply, an investigation, or nothing."
	case "standing_rule_run":
		return "A confirmed channel rule matched this event and started its work."
	case "standing_assignment_action":
		return "A confirmed autonomous assignment matched this event and started its bounded work."
	case "replay_candidate":
		return "Kept for human review; it can become a regression test."
	case "quality_finding":
		return "A later production review checked this episode and kept its verdict."
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
		Title: "Usage measured",
	}
	if !page.Spent.Recorded() {
		step.State = "not measured"
		step.Summary = "The provider reported no token counts — missing telemetry, not a free turn."
		return step
	}
	summary := humanTokens(page.Spent.Total()) + " tokens · " + page.Spent.CacheLabel() + " served from cache"
	if page.Spent.Clock.Recorded() {
		summary += " · " + page.Spent.Clock.Total() + " of model time"
	}
	step.Summary = summary
	detail := fmt.Sprintf("Fresh input: %s\nCached input: %s\nOutput: %s\nReasoning: %s",
		humanTokens(page.Spent.Input), humanTokens(page.Spent.Cached),
		humanTokens(page.Spent.Output), humanTokens(page.Spent.Reasoning))
	step.Details = []TraceDetail{{Label: "Token breakdown", Body: detail, Kind: "text"}}
	if page.Spent.Clock.Recorded() {
		step.Details = append(step.Details, TraceDetail{
			Label: "Where the time went",
			Body:  "Total: " + page.Spent.Clock.Total() + "\n" + page.Spent.Clock.Split(),
			Kind:  "text",
		})
	}
	return step
}

func eventWhy(kind string) string {
	if kind == "context_extended" {
		return "The added context was recorded so the result can be traced to the exact inputs it used."
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
		return "The failure is kept so a retry can start over from the same evidence."
	}
	return ""
}

func sideEffectWhy(effect SideEffect) string {
	if effect.State == "offered" || effect.State == "waiting" {
		return "Proposed by the model — nothing runs until it is confirmed."
	}
	return ""
}

func deliveryWhy(delivery Delivery) string {
	if delivery.Operation == "status" {
		return "A native status shows progress without adding a message to the conversation."
	}
	if delivery.Operation == "reaction" {
		return "A single reaction reports Responder health without adding another message to the conversation."
	}
	return ""
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
