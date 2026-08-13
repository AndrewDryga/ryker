package webui

import (
	"encoding/json"
	"fmt"
	"html/template"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
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
	// Tight stops the identity columns from wrapping. The table already
	// scrolls horizontally, and a cell broken mid-token renders
	// "mcp.emisar.run_action" as four unreadable fragments — a scrollbar is
	// the cheaper cost.
	Tight bool
	// IDPrefix namespaces the per-row toggle controls. A page carries several
	// of these tables, and a duplicated control id would make one row's click
	// open another card's record.
	IDPrefix string
}

type TraceTableRow struct {
	Cells []string
	// Href links the row's name cell to the record behind it — a retained
	// artifact body, openable from the trace.
	Href template.URL
	// Expand is the full record behind a summarized row, opened by clicking
	// anywhere in the row and rendered across the table below it. ExpandAt is
	// only where the caret is drawn — the whole row is the control, because a
	// target the width of one column is a target you have to aim at.
	Expand   string
	ExpandAt int
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
	// Icon names the glyph drawn on the rail marker, so a reader learns the
	// vocabulary of actions — message, route, briefing, bolt, sparkle, plane —
	// and can scan a trace by shape before reading a word.
	Icon string
	// Chip is the state worth printing beside the title. Most stored states
	// restate the title ("Planning the work · planning") and render nothing;
	// a chip appears only when it says something the title does not — a
	// failure, a wait, or an audit outcome.
	Chip string
	// Bar is this kind's micro-visualization — the briefing's token
	// composition, a turn's fresh/cached/output split — or nil.
	Bar *StepBar
	// Rules is the standing-rule evaluation rendered as structure: every
	// rule the channel holds, whether it matched, and why — instead of a
	// paragraph blob behind a disclosure.
	Rules []TraceRule
	Stats []TraceStat
	// Footer is one flat label-over-value strip at the very bottom of the
	// card, below every disclosure: replay fingerprints live here, since two
	// hashes are facts to glance at, not a table to open.
	Footer      []TraceStat
	FooterLabel string
	Details     []TraceDetail
	order       int
	// band is the minimum chapter this step belongs to; -1 derives it from the
	// stage. Chapters are assigned forward-only over the chronological list, so
	// a wake-up scheduled mid-work stays with the work instead of teleporting
	// the reader back to the beginning.
	band int
}

// StepBar is one proportional strip inside a card, sized in integer
// thousandths so the template stays arithmetic-free.
type StepBar struct {
	Slices []BarSlice
	Note   string
}

type BarSlice struct {
	Label, Value, Class string
	X, W                int
}

// TraceRule is one standing rule as the evaluation saw it: its name, whether
// it matched this message, the reason either way, and — for matched rules —
// the definition that now governs the turn.
type TraceRule struct {
	Name, Why, Effect string
	Matched           bool
	Facts             []TraceStat
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
			ID: "source", Stage: "Input", Actor: "Slack", State: sourceKindLabel(page.Source), Icon: "message",
			Title: sourceTitle(page.Source), At: page.Source.Received,
			Why: sourceWhy(page.Source),
			Stats: []TraceStat{{"Channel", page.Source.Channel}, {"Message", page.Source.MessageTS},
				{"Thread", fallback(page.Source.ThreadTS, "top level")},
				{sourceSenderLabel(page.Source), fallback(page.Source.Sender, page.Source.UserID)}},
			Details: details,
		})
	} else {
		add(TraceStep{
			ID: "source-missing", Stage: "Input", Actor: "Responder", State: "not recorded", Icon: "info",
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
			ID: scheduledID, Stage: "Wait", Actor: "Responder", State: "scheduled", Icon: "clock",
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
				ID: resolvedID, Stage: "Wait", Actor: "Responder", State: wakeup.State, Tone: "good", Icon: "clock",
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
			ID: "trigger", Stage: "Trigger", Actor: "Responder", State: page.Trigger.Kind, Icon: "clock",
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
			ID: modelID, Stage: "Routing", Actor: "Responder", State: "selected", Icon: "route",
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
		// The budget's cuts, keyed by layer kind, render inside the category
		// they were cut from; anything unmapped stays in the general block.
		trimmedByKind, leftoverTrims := map[string][]string{}, []string{}
		for _, ref := range manifest.Refs {
			if ref.Visibility != "omitted" || strings.TrimSpace(ref.Omitted) == "" {
				continue
			}
			if trimmedLayerLabel[ref.Kind] != "" {
				trimmedByKind[ref.Kind] = append(trimmedByKind[ref.Kind], ref.Omitted)
			} else {
				leftoverTrims = append(leftoverTrims, ref.Omitted)
			}
		}
		promptDetails := []TraceDetail{}
		memoryLayers := 0
		if prompt != "" {
			components, layers := promptContextDetails(prompt, present, trimmedByKind)
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
		runtimeAccess, replayVerification := contextReferenceDetails(manifest.Refs, present, page.StoredArtifacts)
		promptDetails = append(promptDetails, runtimeAccess...)
		if prompt == "" && len(manifest.Omissions) > 0 {
			// Without prompt text there are no category sections to place the
			// cuts in; the flat list is all this attempt can still say.
			leftoverTrims = manifest.Omissions
		}
		if len(leftoverTrims) > 0 {
			promptDetails = append(promptDetails, TraceDetail{
				Label: "Trimmed to fit the turn", Body: present(strings.Join(leftoverTrims, "\n")), Kind: "missing",
				Status: "Not sent", Tone: "missing", Open: true, ShowCount: true, Count: len(leftoverTrims),
				Description: promptCapNote,
				Group:       "Not sent to the model", GroupDetail: "Responder assembled these inputs, then dropped them before submission to fit the turn.",
				GroupCount: 1,
			})
		}
		var composition *StepBar
		briefTokens := 0
		if prompt != "" {
			segments := promptSegments(present(prompt))
			composition, briefTokens = promptCompositionBar(segments, len(prompt), len(manifest.Omissions) > 0)
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
			ID: promptID, Stage: "Context", Actor: "Responder", State: "recorded", Icon: "doc",
			Title: "Model briefed", Summary: promptStepSummary(manifest, memoryLayers, briefTokens), At: manifest.Created,
			Bar:         composition,
			Stats:       []TraceStat{{"Prompt", fallback(manifest.PromptVersion, "unversioned")}, {"Contract", fallback(manifest.Contract, "none")}, {"Tool schema", fallback(manifest.ToolSchema, "none")}, {"Attempt", fmt.Sprint(manifest.AttemptNumber)}},
			Footer:      replayVerification,
			FooterLabel: "Replay verification — hashes a replay uses to prove the same inputs; the model never sees them",
			Details:     promptDetails,
		})
	}

	for index, event := range page.Events {
		if event.Kind == "episode_created" && hasCommitment {
			// The commitment step already renders "Episode created"; a second
			// card at the same instant is plumbing.
			continue
		}
		if event.Kind == "context_extended" && manifestEventCovered(event.Payload, manifests) {
			// The kernel writes this receipt inside the transaction that
			// creates a context manifest — the same fact the "Model briefed"
			// card for that manifest already presents in full. The event
			// renders only when its manifest is not on the page.
			continue
		}
		if (event.Kind == "external_wait_started" || event.Kind == "wakeup_resolved") &&
			wakeupEventCovered(event.Payload, wakeups, event.Kind == "wakeup_resolved") {
			// These receipts are written alongside the wakeup row itself; the
			// "Wake-up scheduled" and "Wake-up resolved" cards already present
			// the same facts with the full matcher and observation.
			continue
		}
		includePayload := true
		step := TraceStep{
			ID: fmt.Sprintf("event-%d", index+1), Stage: eventStage(event.Kind), Actor: actorName(event.Actor), Icon: eventIcon(event.Kind),
			State: event.Kind, Title: eventTitle(event.Kind), Summary: present(event.Detail),
			Why: eventWhy(event.Kind), At: event.At,
		}
		if event.Attempt > 1 {
			step.Stats = append(step.Stats, TraceStat{"Attempt", fmt.Sprint(event.Attempt)})
		}
		if event.Repeats > 0 {
			step.Stats = append(step.Stats, TraceStat{"Repeats", repeatValue(event.Repeats)})
		}
		switch event.Kind {
		case "phase_changed":
			if payload := decodePhasePayload(event.Payload); payload.Phase != "" {
				step.State, step.Title = payload.Phase, phaseTitle(payload.Phase)
				step.Summary, step.Why = phaseCardSummary(payload, event.Detail, step.Title, present)
				// The card already says everything a routine phase payload
				// holds; a JSON block restating the title in four spellings
				// is noise. Payloads with more than the routine keys stay.
				includePayload = !routinePhasePayload(event.Payload)
			}
		case "completion_submitted":
			// The model's own closing statement. Its verdict and status are
			// structure, not prose — the summary carries only the words meant
			// for the channel, and the private assessment reads as text rather
			// than as a field inside a JSON dump.
			if completion := decodeCompletionEvent(event.Payload); completion.Message != "" || completion.Verdict != "" {
				step.Summary = present(completion.Message)
				if completion.Verdict != "" {
					step.State, step.Tone = completion.Verdict, stateTone(completion.Verdict)
					step.Stats = append(step.Stats, TraceStat{"Verdict", completion.Verdict})
				}
				if completion.Status != "" {
					step.Stats = append(step.Stats, TraceStat{"Status", strings.ReplaceAll(completion.Status, "_", " ")})
				}
				step.Details = append(step.Details, completionDetails(completion, present)...)
				includePayload = !routineEventPayload(event.Payload, "id", "type", "completion")
			}
		case "external_wait_started":
			// Rendered only when the wakeup row itself is not on the page.
			if wait := decodeWakeupEvent(event.Payload); wait.WakeupID != "" {
				step.Summary = "The episode parked itself until a matching " + strings.ReplaceAll(wait.Kind, "_", " ") +
					" event arrives — no worker is held while it waits."
				step.Stats = append(step.Stats, TraceStat{"Wake-up", wait.WakeupID})
				includePayload = !routineEventPayload(event.Payload, "kind", "wakeup_id", "deadline", "due_at")
			}
		case "wakeup_resolved":
			if wait := decodeWakeupEvent(event.Payload); wait.WakeupID != "" {
				step.Summary = "The awaited " + strings.ReplaceAll(wait.Kind, "_", " ") + " event arrived; the episode could continue."
				step.Stats = append(step.Stats, TraceStat{"Wake-up", wait.WakeupID})
			}
		case "progress_reported":
			if step.Summary == "" {
				step.Summary = present(decodePhasePayload(event.Payload).Summary)
			}
			includePayload = !routinePhasePayload(event.Payload)
		case "episode_reopened":
			if step.Summary == "" || cannedPhaseStatus(step.Summary) {
				step.Summary = "A follow-up in the same conversation brought the finished episode back to life; it continues with its memory intact."
			}
			includePayload = !routinePhasePayload(event.Payload)
		case "episode_cancelled":
			includePayload = !routinePhasePayload(event.Payload)
		case "destination_changed":
			if dest := decodeDestinationChange(event.Payload); dest.ChannelID != "" || dest.Reason != "" {
				step.Summary = destinationChangeSummary(dest, present)
				if dest.ChannelID != "" {
					step.Stats = append(step.Stats, TraceStat{"New destination", present(dest.ChannelID)})
				}
				if dest.ThreadTS != "" {
					step.Stats = append(step.Stats, TraceStat{"Thread", dest.ThreadTS})
				}
				includePayload = !routineEventPayload(event.Payload, "channel_id", "destination_revision", "reason", "thread_ts")
			}
		case "migration_recovered":
			if merged := decodeMigrationRecovered(event.Payload); merged != "" {
				step.Summary = "An upgrade found this conversation's earlier record under a different episode and merged it into this one, so its history is not lost."
				step.Stats = append(step.Stats, TraceStat{"Merged from", merged})
			}
			// The recovered record is replayed as its own card; this receipt
			// only needs to say what was merged and from where.
			includePayload = !routineEventPayload(event.Payload,
				"merged_from_episode", "original_kind", "original_idempotency_key", "original_payload_json")
		case "operator_input_requested":
			if question, choices := decodeOperatorInput(event.Payload); question != "" {
				step.Summary = "“" + present(question) + "”"
				if len(choices) > 0 {
					step.Stats = append(step.Stats, TraceStat{"Choices", strings.Join(choices, " · ")})
				}
				includePayload = !routineEventPayload(event.Payload, "id", "type", "operator_input")
			}
		case "task_offered":
			if task := decodeTaskOffered(event.Payload); task.Title != "" {
				step.Summary = present(task.Title)
				for _, stat := range []TraceStat{{"Repository", task.Repository}, {"Kind", task.Kind}} {
					if stat.Value != "" {
						step.Stats = append(step.Stats, stat)
					}
				}
				// The brief the engineer would receive is the reviewable part
				// of an offer; JSON around it is not.
				if strings.TrimSpace(task.Prompt) != "" {
					step.Details = append(step.Details, TraceDetail{
						Label: "What the task would ask for", Body: present(task.Prompt), Kind: "text",
						Description: "The exact instructions that would be handed to the engineering session if an operator confirms.",
					})
				}
				includePayload = !routineEventPayload(event.Payload, "id", "type", "task")
			}
		case "feedback.recorded":
			if feedback := decodeFeedbackEvent(event.Payload); feedback.Summary != "" {
				step.Summary = present(feedback.Summary)
				if feedback.Category != "" {
					step.Stats = append(step.Stats, TraceStat{"Category", strings.ReplaceAll(feedback.Category, "_", " ")})
				}
				if feedback.Sentiment != "" {
					step.Stats = append(step.Stats, TraceStat{"Sentiment", feedback.Sentiment})
				}
				if strings.TrimSpace(feedback.Details) != "" {
					step.Details = append(step.Details, TraceDetail{Label: "What prompted it", Body: present(feedback.Details), Kind: "text"})
				}
				includePayload = !routineEventPayload(event.Payload, "id", "type", "feedback")
			}
		case "evidence_recorded":
			// The claim is the card's line; the observation — the part a person
			// actually re-checks — reads as text instead of hiding in the JSON.
			if evidence := decodeEvidenceEvent(event.Payload); evidence.Observation != "" {
				if step.Summary == "" {
					step.Summary = present(evidence.Claim)
				}
				for _, stat := range []TraceStat{
					{"Relation", strings.ReplaceAll(evidence.Relation, "_", " ")},
					{"Confidence", evidence.Confidence},
					{"Source", evidence.SourceName},
				} {
					if strings.TrimSpace(stat.Value) != "" {
						step.Stats = append(step.Stats, stat)
					}
				}
				step.Details = append(step.Details, TraceDetail{
					Label: "What the model observed", Body: present(evidence.Observation), Kind: "text", Open: true,
				})
				if provenance := evidenceProvenance(evidence, present); provenance != nil {
					step.Details = append(step.Details, *provenance)
				}
				includePayload = !routineEventPayload(event.Payload, "id", "type", "evidence")
			}
		}
		if includePayload {
			if payload := presentEventPayload(event.Payload, present); payload != "" && payload != "{}" {
				step.Details = append(step.Details, TraceDetail{Label: "Recorded event payload", Body: payload, Kind: "json"})
			}
		}
		if occurrences := occurrenceDetail(event.Occurrences); occurrences != nil {
			step.Details = append(step.Details, *occurrences)
		}
		add(step)
	}

	for index, artifact := range page.Artifacts {
		if artifact.Kind == "progress" && progressDuplicatesPhase(artifact, phaseEvents, commitmentAt, hasCommitment) {
			// The kernel event for the same phase change renders the step; the
			// progress record repeats it in the same instant.
			continue
		}
		if artifact.Kind == "publication_lifecycle" && timelineRepeatsLifecycle(artifact, page.Artifacts) {
			// Publishing writes the same sentence twice: once to the incident
			// timeline, once to the lifecycle ledger. The timeline card names
			// what happened ("PR merged"), so it is the one that renders.
			continue
		}
		if artifact.Kind == "incident_timeline" && artifact.State == "agent.finding" &&
			timelineRepeatsAnswer(artifact, page) {
			// This episode's own answer is copied into the incident thread it
			// belongs to. The answer already has cards of its own here.
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
			Stage: artifactStage(artifact.Kind), Actor: artifactActor(artifact.Kind), Icon: artifactIcon(artifact.Kind),
			State: fallback(artifact.State, "recorded"), Title: present(artifact.Title), Summary: present(artifact.Summary),
			Why: artifactWhy(artifact.Kind), At: artifact.At, Stats: stats, Details: details,
		}
		switch artifact.Kind {
		case "commitment":
			step.Title, step.Summary, step.Why = "Episode created", "", ""
		case "progress":
			step.Title = phaseTitle(artifact.State)
			step.Summary, step.Why = phaseCardSummary(
				phasePayload{Phase: artifact.State}, artifact.Summary, step.Title, present)
		case "evaluation":
			step.Title = decisionTitle(artifact.State)
		case "incident_timeline":
			// Some timeline kinds store a whole sentence as their title. A
			// sentence is a summary; the header names the kind of update. A
			// heading does not end in a period, and does not run past a line.
			if raw := present(artifact.Title); len(raw) > 60 ||
				strings.Contains(raw, ". ") || strings.HasSuffix(raw, ".") {
				if step.Summary == "" {
					step.Summary = raw
				}
				step.Title = timelineKindTitle(artifact.State)
			}
			// The rest carry their content in the detail. A card whose only
			// words are a generic heading says nothing, so its opening lines
			// become the summary and the full text stays one click away.
			if step.Summary == "" && strings.TrimSpace(artifact.Detail) != "" {
				lead, isReference := timelineLead(present(artifact.Detail))
				switch {
				case isReference:
					step.Stats = append(step.Stats, TraceStat{"Reference", lead})
					step.Details = nil
				default:
					step.Summary = lead
				}
			}
			step.Why = timelineKindWhy(artifact.State)
		}
		add(step)
	}

	for _, attempt := range page.Attempts {
		step := TraceStep{
			ID: fmt.Sprintf("attempt-%d", attempt.Number), Stage: "Execution", Actor: "Coop", State: attempt.State, Icon: "bolt",
			Title: fmt.Sprintf("Attempt %d %s", attempt.Number, attempt.State), Summary: attemptSummary(attempt),
			Why: attemptWhy(attempt), At: attempt.Completed, Tone: stateTone(attempt.State),
			Duration: traceDuration(attempt.Started, attempt.Completed),
			Stats:    []TraceStat{{"Run", attempt.RunID}},
		}
		// A class is a token; some rows carry the whole failure message in
		// this column, and the summary already shows that.
		if attempt.Failure != "" && len(attempt.Failure) <= 48 && !strings.Contains(attempt.Failure, " ") {
			step.Stats = append(step.Stats, TraceStat{"Failure class", attempt.Failure})
		}
		if detail := strings.TrimSpace(present(attempt.Error)); detail != "" {
			step.Details = []TraceDetail{{Label: "Terminal detail", Body: detail, Kind: "text"}}
		}
		add(step)
	}

	for index, rejection := range page.Rejections {
		add(TraceStep{
			ID: fmt.Sprintf("rejection-%d", index+1), Stage: "Validation", Actor: "Responder", State: "rejected", Tone: "bad", Icon: "x",
			Title: "Answer rejected", Summary: correctionClassSummary(rejection.Outcome),
			Why: "The result did not fit the required format, so Responder sent a correction back instead of acting on it.", At: rejection.At,
			Stats:   []TraceStat{{"Run", fallback(rejection.RunID, "not recorded")}, {"Check", rejection.Outcome}},
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
			ID: resultID, Stage: "Result", Actor: "Model", State: fallback(turn.State, "received"), Tone: stateTone(turn.State), Icon: "sparkle",
			Title: "Model result received", Summary: present(modelSummary(turn)),
			Why: "Responder checks every result against its contract before anything reaches Slack.", At: turn.Updated,
			Stats:   []TraceStat{{"Run", turn.RunID}, {"Attempt", fmt.Sprint(turn.AttemptNumber)}, {"Action", fallback(turn.Action, "not recorded")}, {"Operations", fmt.Sprint(tallyTotal(turn.Operations))}, {"Follow-ups", fmt.Sprint(len(turn.Followups))}},
			Details: details,
		})
	}

	for _, step := range activityTraceSteps(page) {
		add(step)
	}

	if page.Manifest.Version > 0 {
		add(usageTraceStep(page))
	}

	if len(page.Claims)+len(page.Evidence)+len(page.Coverage) > 0 {
		add(TraceStep{
			ID: "ledger", Stage: "Evidence", Actor: "Responder", State: "recorded", Icon: "db",
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
		stats := []TraceStat{{"ID", fallback(effect.ID, "none")}}
		// The title of a conversation-memory change is the note's slot —
		// "Goal", "Open loops". What was written into it is the fact.
		if written := fallback(effect.After, effect.Detail); effect.Kind == "conversation memory" &&
			strings.TrimSpace(written) != "" {
			stats = append(stats, TraceStat{"Note", summary})
			summary = truncate(strings.Join(strings.Fields(present(written)), " "), 220)
		}
		if effect.Kind == "work episode" {
			// A delegated episode's objective is prose that may carry raw Slack
			// markup; identifiers like rule names must stay exact.
			summary = cleanTitle(summary)
			href = "/episodes/" + url.PathEscape(effect.ID)
			// Alert-driven episodes append the provider run id to their title;
			// it is an identifier, not part of the sentence.
			if base, run, found := strings.Cut(summary, " · Run "); found &&
				strings.HasPrefix(run, "run-") && !strings.Contains(run, " ") {
				summary = base
				stats = append(stats, TraceStat{"Run", run})
			}
		}
		add(TraceStep{
			ID: fmt.Sprintf("effect-%d", index+1), Stage: "Side effect", Actor: "Responder", State: effect.State, Icon: "bookmark",
			Tone:  stateTone(effect.State),
			Title: effectTitle(effect), Summary: summary, Why: sideEffectWhy(effect), Href: href, At: effect.At,
			Stats:   stats,
			Details: []TraceDetail{{Label: "Recorded change", Body: fallback(body, "No additional value was recorded."), Kind: "diff", Open: effect.Before != "" || effect.After != ""}},
		})
	}

	for index, delivery := range page.Delivered {
		// Where it went is a fact about the delivery, not what the delivery
		// was; the channel and thread are stats, and the sentence says what
		// Slack actually shows.
		summary := deliverySummary(delivery, present)
		details := []TraceDetail{}
		if delivery.Body != "" {
			details = append(details, TraceDetail{Label: "Slack payload", Body: present(delivery.Body), Kind: "json"})
		}
		if delivery.Error != "" {
			details = append(details, TraceDetail{Label: "Delivery error", Body: present(delivery.Error), Kind: "error", Open: true})
		}
		stats := []TraceStat{{"Channel", fallback(delivery.Channel, "not recorded")},
			{"Thread", fallback(delivery.ThreadTS, "top level")},
			{"Message", fallback(delivery.MessageTS, "none")}, {"Kind", delivery.Kind}}
		if delivery.Retries > 0 {
			stats = append(stats, TraceStat{"Retries", fmt.Sprint(delivery.Retries)})
		}
		step := TraceStep{
			ID: fmt.Sprintf("delivery-%d", index+1), Stage: "Delivery", Actor: "Slack outbox", State: delivery.State, Icon: "plane",
			Tone:  stateTone(delivery.State),
			Title: deliveryTitle(delivery), Summary: summary, Why: deliveryWhy(delivery), At: delivery.At,
			Duration: traceDuration(delivery.Created, delivery.At),
			Stats:    stats, Details: details,
		}
		if delivery.Operation == "status" {
			// A "working on it" post is not an outcome. The band is a floor,
			// not a placement, so the earlier of the two work chapters lets it
			// sit wherever the story has actually reached.
			step.band = bandReady
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
		step := TraceStep{
			ID: fmt.Sprintf("audit-%d", index+1), Stage: stage, Actor: actor, State: state, Icon: auditIcon(audit.Kind),
			Tone:  stateTone(audit.Outcome),
			Title: auditTitle(audit.Kind), Summary: summary, Why: auditTraceWhy(audit), At: audit.At,
			Stats: stats, band: auditBand(audit.Kind),
		}
		if audit.Kind == "standing_rules.evaluated" {
			if rules, verdict, ok := standingRuleCards(audit, present); ok {
				step.Rules, step.Summary, step.Stats = rules, verdict, nil
			}
		}
		if step.Rules == nil {
			step.Details = auditTraceDetails(audit, present)
		}
		if occurrences := occurrenceDetail(audit.Occurrences); occurrences != nil {
			step.Details = append(step.Details, *occurrences)
		}
		add(step)
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
		if steps[index].Icon == "" {
			steps[index].Icon = "dot"
		}
		steps[index].Chip = stepChip(steps[index])
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
		// Counted here because this strip is what a reader scans before
		// deciding whether to open anything. A trace that recorded twenty
		// Emisar actions and advertised only its context components read as
		// though the interior of the turn still was not kept.
		{countActivityTools(page.Activity), "Tool call", "Tool calls"},
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
	bandReady
	bandWork
	bandAnswer
	bandOutcome
)

// The chapter that used to be called "The work" held routing, briefing and
// queueing — everything up to the moment a model started, and none of the work
// itself, because none of it was recorded yet. Now that a turn's interior is
// kept, the name belongs to the chapter that earns it.
var chapterNames = [...]struct{ title, blurb string }{
	{"What came in", "The message or event that started this."},
	{"Getting ready", "How Responder set this up: the routing, the model, and its briefing."},
	{"The work", "What the model did once it started: what it reasoned about, what it ran, and what came back."},
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
		return bandReady
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
	// The bar measures the execution: arrival to answer. Aftermath records
	// often land hours later — a quality review, a delegated task finishing —
	// and drawn to scale they would compress the real fifty seconds into
	// slivers. A dominant final chapter becomes a legend note instead.
	tail := ""
	if final := spans[len(spans)-1]; chapters[final.index].Title == chapterNames[bandOutcome-1].title {
		body := final.start.Sub(spans[0].start)
		if trailing := last.Sub(final.start); trailing > 2*body {
			tail = "follow-up records over " + compactDuration(trailing) + " more"
			last = final.start
			spans = spans[:len(spans)-1]
		}
	}
	if len(spans) < 2 {
		return nil
	}
	total := last.Sub(spans[0].start)
	if total < 2*time.Second {
		return nil
	}
	segments := make([]TimeSegment, 0, len(spans)+1)
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
	segments[len(segments)-1].W = 1000 - segments[len(segments)-1].X
	if tail != "" {
		segments = append(segments, TimeSegment{Class: "tail", Title: tail})
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

// manifestEventCovered reports whether a context_extended event's manifest is
// already rendered as a "Model briefed" card, which presents the same fact
// with its full contents.
func manifestEventCovered(payload string, manifests []ManifestRow) bool {
	var decoded struct {
		ManifestID string `json:"manifest_id"`
	}
	if json.Unmarshal([]byte(payload), &decoded) != nil || decoded.ManifestID == "" {
		return false
	}
	for _, manifest := range manifests {
		if manifest.ID == decoded.ManifestID {
			return true
		}
	}
	return false
}

type completionEvent struct {
	Message, Status, Verdict string
	// Assessment is the model's own one-line judgment, written for the record
	// rather than for the channel; Blocker and Next say what stopped the work
	// and what it expects to happen.
	Assessment, Blocker, Next string
	Gaps                      []string
}

// decodeCompletionEvent unwraps a complete_episode operation's payload: the
// public message at the top of the completion, the machine status, verdict and
// private assessment nested inside it.
func decodeCompletionEvent(payload string) completionEvent {
	var decoded struct {
		Completion struct {
			Message    string `json:"message"`
			Completion struct {
				Status  string   `json:"status"`
				Verdict string   `json:"verdict"`
				Summary string   `json:"summary"`
				Blocker string   `json:"blocker"`
				Next    string   `json:"next"`
				Gaps    []string `json:"gaps"`
			} `json:"completion"`
		} `json:"completion"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	inner := decoded.Completion.Completion
	return completionEvent{
		Message: decoded.Completion.Message, Status: inner.Status, Verdict: inner.Verdict,
		Assessment: inner.Summary, Blocker: inner.Blocker, Next: inner.Next, Gaps: inner.Gaps,
	}
}

// completionDetails renders the parts of a completion the channel never saw:
// the model's own assessment of the outcome, what it says is still missing,
// and what it expects next.
func completionDetails(completion completionEvent, present func(string) string) []TraceDetail {
	details := []TraceDetail{}
	if strings.TrimSpace(completion.Assessment) != "" {
		details = append(details, TraceDetail{
			Label: "The model's own assessment", Body: present(completion.Assessment), Kind: "text",
			Description: "Written for the record, not for the channel — this is the line a later review reads.",
		})
	}
	if strings.TrimSpace(completion.Blocker) != "" {
		details = append(details, TraceDetail{
			Label: "What blocked it", Body: present(completion.Blocker), Kind: "text", Open: true, Tone: "missing",
		})
	}
	if len(completion.Gaps) > 0 {
		details = append(details, TraceDetail{
			Label: "What it could not cover", Body: present(strings.Join(completion.Gaps, "\n")), Kind: "text",
			Tone: "missing", ShowCount: true, Count: len(completion.Gaps),
		})
	}
	if strings.TrimSpace(completion.Next) != "" {
		details = append(details, TraceDetail{
			Label: "What it expects next", Body: present(completion.Next), Kind: "text",
		})
	}
	return details
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

// The kernel and the model write several receipt kinds with stable envelopes;
// each decoder unwraps just the fields a card presents.

type wakeupEventPayload struct {
	Kind     string `json:"kind"`
	WakeupID string `json:"wakeup_id"`
}

func decodeWakeupEvent(payload string) wakeupEventPayload {
	var decoded wakeupEventPayload
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded
}

// wakeupEventCovered reports whether the wakeup this receipt describes already
// renders as its own scheduled/resolved card pair on the page.
func wakeupEventCovered(payload string, wakeups []Wakeup, needResolved bool) bool {
	id := decodeWakeupEvent(payload).WakeupID
	if id == "" {
		return false
	}
	for _, wakeup := range wakeups {
		if wakeup.ID == id && (!needResolved || !wakeup.Resolved.IsZero()) {
			return true
		}
	}
	return false
}

type destinationChange struct {
	ChannelID string `json:"channel_id"`
	Reason    string `json:"reason"`
	ThreadTS  string `json:"thread_ts"`
}

func decodeDestinationChange(payload string) destinationChange {
	var decoded destinationChange
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded
}

func destinationChangeSummary(dest destinationChange, present func(string) string) string {
	where := "a different destination"
	if dest.ChannelID != "" {
		where = present(dest.ChannelID)
		if dest.ThreadTS != "" {
			where += " (in a thread)"
		}
	}
	switch dest.Reason {
	case "communication_policy":
		return "The channel's communication policy routes this reply to " + where + " instead of where the work started."
	case "":
		return "Later messages for this episode go to " + where + "."
	}
	return "Later messages for this episode go to " + where + " — " + strings.ReplaceAll(dest.Reason, "_", " ") + "."
}

func decodeMigrationRecovered(payload string) string {
	var decoded struct {
		MergedFrom string `json:"merged_from_episode"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded.MergedFrom
}

func decodeOperatorInput(payload string) (string, []string) {
	var decoded struct {
		OperatorInput struct {
			Question string   `json:"question"`
			Choices  []string `json:"choices"`
		} `json:"operator_input"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded.OperatorInput.Question, decoded.OperatorInput.Choices
}

type taskOffer struct {
	Kind       string `json:"kind"`
	Title      string `json:"title"`
	Repository string `json:"repository"`
	Prompt     string `json:"prompt"`
}

func decodeTaskOffered(payload string) taskOffer {
	var decoded struct {
		Task taskOffer `json:"task"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded.Task
}

type feedbackEvent struct {
	Category  string `json:"category"`
	Sentiment string `json:"sentiment"`
	Summary   string `json:"summary"`
	Details   string `json:"details"`
}

func decodeFeedbackEvent(payload string) feedbackEvent {
	var decoded struct {
		Feedback feedbackEvent `json:"feedback"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded.Feedback
}

type evidenceEvent struct {
	ClaimID      string            `json:"claim_id"`
	Claim        string            `json:"claim"`
	Observation  string            `json:"observation"`
	Relation     string            `json:"relation"`
	HealthEffect string            `json:"health_effect"`
	SourceType   string            `json:"source_type"`
	SourceID     string            `json:"source_id"`
	SourceName   string            `json:"source_name"`
	Freshness    string            `json:"freshness"`
	Confidence   string            `json:"confidence"`
	ObservedAt   string            `json:"observed_at"`
	Dimensions   map[string]string `json:"dimensions"`
}

func decodeEvidenceEvent(payload string) evidenceEvent {
	var decoded struct {
		Evidence evidenceEvent `json:"evidence"`
	}
	_ = json.Unmarshal([]byte(payload), &decoded)
	return decoded.Evidence
}

// evidenceProvenance is the rest of an evidence row: where the observation came
// from, how fresh it was, and what it was scoped to. These are the fields a
// later reviewer needs to decide whether to trust the row, so they read as
// labeled lines instead of as a JSON dump.
func evidenceProvenance(evidence evidenceEvent, present func(string) string) *TraceDetail {
	lines := []string{}
	appendLine := func(label, value string) {
		if strings.TrimSpace(value) != "" {
			lines = append(lines, label+"\n"+present(value))
		}
	}
	source := strings.TrimSpace(evidence.SourceType)
	if evidence.SourceID != "" {
		source = strings.TrimSpace(source + " " + evidence.SourceID)
	}
	appendLine("Where it came from", source)
	appendLine("How current it was", evidence.Freshness)
	if effect := evidence.HealthEffect; effect != "" && effect != "none" {
		appendLine("Effect on system health", strings.ReplaceAll(effect, "_", " "))
	}
	if len(evidence.Dimensions) > 0 {
		keys := make([]string, 0, len(evidence.Dimensions))
		for key := range evidence.Dimensions {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		scope := make([]string, 0, len(keys))
		for _, key := range keys {
			scope = append(scope, strings.ReplaceAll(key, "_", " ")+": "+evidence.Dimensions[key])
		}
		appendLine("What it was scoped to", strings.Join(scope, "\n"))
	}
	appendLine("Claim it answers", evidence.ClaimID)
	if len(lines) == 0 {
		return nil
	}
	return &TraceDetail{
		Label: "Where this came from", Body: strings.Join(lines, "\n\n"), Kind: "text",
		Description: "Provenance a later review uses to decide whether this observation still holds.",
	}
}

// phaseExplain says what actually happened in the machine at each phase
// transition, in plain present-tense words. Each sentence is written from the
// store call that sets the phase, not invented: "planning" is LeaseAgentRun
// moving a queued run to a worker, "investigating" is the Coop turn starting,
// and so on. This is the line that lets someone build a mental model of the
// pipeline from one episode.
func phaseExplain(phase string) string {
	return map[string]string{
		"accepted":                   "Responder took ownership of this work and queued it for a background worker.",
		"planning":                   "A background worker took this job off the queue and is preparing the model call — no model is running yet.",
		"investigating":              "The prepared call went to Coop; from here until the result arrives, the model is the one working.",
		"executing":                  "The prepared call went to Coop; from here until the result arrives, the model is the one working.",
		"finalizing":                 "The model finished its turn. Before anything reaches Slack, Responder checks the result: it must parse, the answer must be complete — a verdict, coverage explained, claims the evidence supports — anything it offers must be well-formed, and the reply must fit the shape bounds. A failure goes back to the model as a correction instead of posting.",
		"finished":                   "The final outcome is recorded; nothing more runs for this episode.",
		"resuming":                   "A new attempt is starting from this episode's saved state.",
		"retrying":                   "The previous attempt failed; the work is queued to run again from the preserved context.",
		"waiting":                    "The work is parked until the dependency recovers — no worker is held while it waits.",
		"waiting_for_external_event": "The episode parked itself until a matching external event arrives or its deadline passes — no worker is held while it waits.",
		"waiting_for_operator":       "The episode parked itself until the operator answers in Slack.",
		"queued":                     "The work is waiting for a dependency before a worker can pick it up.",
		"continuing":                 "Unfinished work from the previous turn carries forward into a new one.",
		"expanding_scope":            "The quick lane was not enough; the work moved to the full investigation lane.",
	}[phase]
}

// cannedNextAction recognizes the host's fixed checklist strings, verbatim
// from the setWorkEpisodePhaseTx call sites. In a timeline, "Next:" printed
// from a checklist contradicts the card that actually comes next; only a
// next action that carries real information survives onto the card.
func cannedNextAction(next string) bool {
	return map[string]bool{
		"Establish the evidence plan":                    true,
		"Complete the evidence plan":                     true,
		"Complete the requested work":                    true,
		"Validate and deliver the result":                true,
		"Run the next attempt":                           true,
		"Continue unfinished work":                       true,
		"Retry the work from preserved context":          true,
		"Waiting for execution runtime":                  true,
		"Resume when the dependency is ready":            true,
		"Resume when the provider limit window recovers": true,
		"Resume when the matching event arrives":         true,
		"Continue in the full investigation lane":        true,
		"Review the blocker or retry":                    true,
	}[next]
}

// phaseCardSummary is the one line a phase card carries: the recorded status
// when it says something real (a rate-limit message, a blocker), otherwise
// the plain explanation of what this stage is — plus any next action that is
// not host boilerplate. When a real status takes the headline, the stage's
// explanation moves to the "why" line rather than being dropped: the specific
// fact and the mechanism behind it are both worth having.
func phaseCardSummary(payload phasePayload, status, title string, present func(string) string) (string, string) {
	summary := strings.TrimSpace(present(status))
	if strings.EqualFold(summary, title) || strings.EqualFold(summary, payload.Phase) ||
		cannedPhaseStatus(summary) {
		summary = ""
	}
	explain, why := phaseExplain(payload.Phase), ""
	if summary == "" {
		summary = explain
	} else {
		why = explain
	}
	if next := strings.TrimSpace(payload.NextAction); next != "" && !cannedNextAction(next) {
		summary = strings.TrimSpace(summary + " Next: " + present(next))
	}
	return summary, why
}

// cannedPhaseStatus recognizes the host's fixed status labels, which restate
// the phase rather than describe this episode.
func cannedPhaseStatus(status string) bool {
	return map[string]bool{
		"Accepted":                       true,
		"Planning the work":              true,
		"Investigating":                  true,
		"Preparing the result":           true,
		"Completed":                      true,
		"Resuming work":                  true,
		"Verified privately":             true,
		"Waiting for an external update": true,
		"Waiting for your answer":        true,
	}[status]
}

// routinePhasePayload reports whether a phase payload holds only the fields
// the card itself already presents — the phase in a few spellings and the
// next action.
func routinePhasePayload(payload string) bool {
	return routineEventPayload(payload,
		"phase", "state", "status", "next_action", "summary", "progress_due_at", "due_at")
}

// routineEventPayload reports whether the payload holds only the listed keys —
// facts the card itself already presents, so a JSON block would restate them.
func routineEventPayload(payload string, keys ...string) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil {
		return false
	}
	routine := map[string]bool{}
	for _, key := range keys {
		routine[key] = true
	}
	for key := range fields {
		if !routine[key] {
			return false
		}
	}
	return true
}

// phaseTitle names a work phase the way a person would say it. The stored
// "investigating" label marks the moment the Coop turn starts on every lane —
// a plain reply as much as an investigation — so the card says what the
// transition means rather than repeating the stage's internal name.
func phaseTitle(phase string) string {
	if title, ok := map[string]string{
		"accepted":                   "Accepted the work",
		"planning":                   "Planning the work",
		"investigating":              "Model working",
		"executing":                  "Model working",
		"implementing":               "Implementing",
		"verifying":                  "Verifying",
		"finalizing":                 "Wrapping up",
		"finished":                   "Finished the work",
		"waiting":                    "Waiting",
		"waiting_for_external_event": "Waiting for an external event",
		"waiting_for_operator":       "Waiting for the operator",
		"blocked":                    "Blocked",
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
	// The commitment's episode id is this page's own id.
	if kind == "commitment" && label == "Episode" {
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

// actorName says who did a thing in the words the rest of the page uses. The
// ledger stores process names; a card should not be the only place a person
// meets "agent" or "control-plane@localhost".
func actorName(actor string) string {
	switch actor {
	case "agent":
		return "Model"
	case "control-plane@localhost", "control-plane":
		return "Control plane"
	case "scheduler":
		return "Scheduler"
	}
	return actor
}

// sourceWhy says why this input produced an episode at all. Responder does not
// answer everything it sees: a mention is addressed to it, a direct message is
// a private conversation, and a channel message only gets here after the watch
// decided it was worth work.
func sourceWhy(source SourceInput) string {
	switch source.Kind {
	case "bot_message":
		return "Another app posted this. Responder watches app messages because alerts and run notifications are operational events, not conversation."
	case "mention":
		return "Someone addressed Responder directly, so the message is handled without a watch decision."
	case "direct":
		return "A direct message to Responder. Everything said here is meant for it."
	case "recheck":
		return "Not a new message — Responder re-examined an earlier one after something changed."
	case "schedule", "scheduled":
		return "No one sent anything. A schedule came due and started this run on its own."
	case "action":
		return "Someone pressed a button on a Responder message in Slack."
	case "slash":
		return "Someone ran a Responder slash command."
	case "reaction_added":
		return "Someone reacted to a message with an emoji Responder watches."
	default:
		return "A message in a channel Responder watches. The watch decision below is what turned it into work."
	}
}

// sourceSenderLabel names the sender field for what it is: a person for human
// messages, an app for everything a bot posted.
func sourceSenderLabel(source SourceInput) string {
	if source.Kind == "bot_message" || strings.HasPrefix(source.UserID, "B") {
		return "App"
	}
	return "Sender"
}

func promptStepSummary(manifest ManifestRow, memoryLayers, totalTokens int) string {
	if totalTokens > 0 {
		return "~" + humanTokens(int64(totalTokens)) + " tokens went to the model, kept exactly as sent."
	}
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
		"waiting_for_external_event", "waiting_for_operator", "episode_cancelled",
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

// deliverySummary says what Slack actually shows after this delivery. The
// channel and thread it went to are stats; repeating them as the only sentence
// on the card told a reader where something happened without ever saying what.
func deliverySummary(delivery Delivery, present func(string) string) string {
	where := delivery.Channel
	if where == "" {
		where = "Slack"
	}
	switch delivery.Operation {
	case "status":
		if status := strings.TrimSpace(delivery.Status); status != "" {
			return "“" + present(status) + "” now shows beside Responder's name in " + where + "."
		}
		return "The progress note beside Responder's name in " + where + " was taken down."
	case "reaction":
		if delivery.Kind == "failure_marker_remove" {
			return "The failure marker on the message in " + where + " was removed."
		}
		return "A marker was added to the message in " + where + " so the failure is visible where it happened."
	case "post":
		if delivery.ThreadTS != "" {
			return "The answer was posted in " + where + ", in the thread the request came from."
		}
		return "The answer was posted to " + where + "."
	case "update":
		return "An earlier Responder message in " + where + " was edited in place."
	case "delete":
		return "A Responder message was removed from " + where + "."
	}
	return where
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
		// An empty status text is the spinner coming down, not going up.
		if strings.TrimSpace(delivery.Status) == "" {
			return "Slack status cleared"
		}
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

// stepChip decides whether a state deserves ink beside the title. Routine
// success states restate the title; trouble and audit outcomes do not.
func stepChip(step TraceStep) string {
	if step.State == "" {
		return ""
	}
	if step.Tone == "warn" || step.Tone == "bad" || strings.HasPrefix(step.ID, "audit-") {
		return strings.ReplaceAll(step.State, "_", " ")
	}
	return ""
}

func eventIcon(kind string) string {
	switch kind {
	case "phase_changed", "progress_reported":
		return "milestone"
	case "episode_created", "completed":
		return "flag"
	case "context_extended":
		return "docplus"
	case "external_wait_started", "wakeup_resolved":
		return "clock"
	case "operator_input_requested", "feedback.recorded":
		return "message"
	case "task_offered":
		return "bookmark"
	case "destination_changed":
		return "route"
	case "migration_recovered":
		return "shield"
	case "evidence_recorded":
		return "db"
	case "completion_submitted":
		return "sparkle"
	default:
		return "dot"
	}
}

func artifactIcon(kind string) string {
	if icon, ok := map[string]string{
		"commitment":                 "flag",
		"progress":                   "milestone",
		"goal":                       "target",
		"scheduled_run":              "clock",
		"evaluation":                 "branch",
		"standing_rule_run":          "shield",
		"standing_assignment_action": "shield",
		"feedback":                   "message",
		"replay_candidate":           "bookmark",
		"incident_timeline":          "flag",
		"publication_lifecycle":      "branch",
		"publication":                "branch",
		"quality_finding":            "search",
	}[kind]; ok {
		return icon
	}
	return "dot"
}

func auditIcon(kind string) string {
	switch {
	case kind == "standing_rules.evaluated" || kind == "standing_rule.acknowledged":
		return "shield"
	case strings.HasPrefix(kind, "slack.watch"):
		return "eye"
	case kind == "result.legacy_shape":
		return "info"
	case strings.HasSuffix(kind, ".remember") || kind == "schedule.created":
		return "bookmark"
	case strings.HasPrefix(kind, "emisar.approval"):
		return "shield"
	case kind == "slack.reaction":
		return "message"
	default:
		return "shield"
	}
}

// promptCompositionBar reduces the exact submitted prompt to the questions an
// operator actually asks of it: how much of the model's attention went to
// instructions, memory, the Slack conversation, and the request — and how
// close the whole turn came to its budget. The strip's full width is the
// budget; the unfilled remainder is headroom. A trimmed turn draws full by
// definition: its budget was the ceiling it hit.
func promptCompositionBar(segments []PromptSegment, promptBytes int, trimmed bool) (*StepBar, int) {
	if len(segments) == 0 {
		return nil, 0
	}
	families := []struct {
		label, class string
		tokens       int
	}{
		{label: "Instructions", class: "sys"},
		{label: "Memory", class: "mem"},
		{label: "Slack", class: "slack"},
		{label: "Request", class: "user"},
	}
	familyOf := map[string]int{
		"system": 0, "trusted": 0, "structure": 0,
		"memory": 1, "operational": 1, "conversation": 1, "related": 1,
		"slack": 2,
		"user":  3,
	}
	total := 0
	for _, segment := range segments {
		index, known := familyOf[segment.Tone]
		if !known {
			index = 0
		}
		families[index].tokens += segment.Tokens
		total += segment.Tokens
	}
	if total == 0 {
		return nil, 0
	}

	budget := coop.MaxPromptBytes
	used := 1000
	bar := &StepBar{}
	if trimmed || promptBytes >= budget {
		bar.Note = fmt.Sprintf("the turn budget was full at %s — lower-value layers were dropped to fit", humanKiB(promptBytes))
	} else {
		used = max(promptBytes*1000/budget, 30)
		bar.Note = fmt.Sprintf("%d%% of the %d KiB turn budget used · %s of headroom",
			max(promptBytes*100/budget, 1), budget>>10, humanKiB(budget-promptBytes))
	}
	for _, family := range families {
		if family.tokens == 0 {
			continue
		}
		bar.Slices = append(bar.Slices, BarSlice{
			Label: family.label, Class: family.class,
			Value: "~" + humanTokens(int64(family.tokens)),
			W:     max(family.tokens*used/total, 8),
		})
	}
	scale, x := 0, 0
	for _, slice := range bar.Slices {
		scale += slice.W
	}
	for index := range bar.Slices {
		bar.Slices[index].W = bar.Slices[index].W * used / scale
		bar.Slices[index].X = x
		x += bar.Slices[index].W
	}
	bar.Slices[len(bar.Slices)-1].W = used - bar.Slices[len(bar.Slices)-1].X
	if used < 1000 {
		bar.Slices = append(bar.Slices, BarSlice{
			Label: "headroom", Class: "free",
			Value: humanKiB(budget - promptBytes),
			X:     used, W: 1000 - used,
		})
	}
	return bar, total
}

func humanKiB(bytes int) string {
	return fmt.Sprintf("%.1f KiB", float64(bytes)/1024)
}

// usageBar draws what a turn's tokens were made of. Cached input dominating
// the strip is the picture of a cheap turn; fresh input dominating is the
// picture of an expensive one.
func usageBar(spent EpisodeTokens) *StepBar {
	total := spent.Total()
	if total <= 0 {
		return nil
	}
	bar := &StepBar{Note: spent.CacheLabel() + " of input served from cache"}
	for _, part := range []struct {
		label, class string
		tokens       int64
	}{
		{"Cached input", "cache", spent.Cached},
		{"Fresh input", "in", spent.Input},
		{"Output", "out", spent.Output},
		{"Reasoning", "think", spent.Reasoning},
	} {
		if part.tokens <= 0 {
			continue
		}
		bar.Slices = append(bar.Slices, BarSlice{
			Label: part.label, Class: part.class,
			Value: humanTokens(part.tokens),
			W:     max(int(part.tokens*1000/total), 8),
		})
	}
	return layoutBar(bar)
}

// layoutBar normalizes slice widths to exactly one thousand units and lays
// them end to end.
func layoutBar(bar *StepBar) *StepBar {
	if bar == nil || len(bar.Slices) == 0 {
		return nil
	}
	scale := 0
	for _, slice := range bar.Slices {
		scale += slice.W
	}
	x := 0
	for index := range bar.Slices {
		bar.Slices[index].W = bar.Slices[index].W * 1000 / scale
		bar.Slices[index].X = x
		x += bar.Slices[index].W
	}
	bar.Slices[len(bar.Slices)-1].W = 1000 - bar.Slices[len(bar.Slices)-1].X
	return bar
}

// standingRuleCards turns the evaluation audit into structure: a verdict
// sentence and one card per rule — every rule the channel holds, whether it
// matched, and why. Matched rules carry their definition as labeled facts.
func standingRuleCards(audit AuditRow, present func(string) string) ([]TraceRule, string, bool) {
	var evaluation core.StandingRuleEvaluationAudit
	if json.Unmarshal([]byte(audit.Detail), &evaluation) != nil || len(evaluation.Rules) == 0 {
		return nil, "", false
	}
	rules := make([]TraceRule, 0, len(evaluation.Rules))
	for _, rule := range evaluation.Rules {
		card := TraceRule{
			Name:    fallback(strings.TrimSpace(present(rule.Name)), "Standing rule"),
			Why:     present(rule.Why),
			Matched: rule.Matched,
		}
		if rule.Matched {
			card.Facts = []TraceStat{
				{"Watches", present(rule.Trigger)},
				{"Does", present(rule.Work)},
				{"In Slack", present(rule.Delivery)},
			}
			card.Effect = "This rule now controls which checks run and when Slack gets a reply."
		}
		rules = append(rules, card)
	}
	verdict := fmt.Sprintf("%d of %d channel rule%s matched", evaluation.Matched,
		evaluation.Checked, plural(evaluation.Checked))
	if evaluation.Acknowledged != "" {
		verdict += " · " + slackReactionDisplay(evaluation.Acknowledged) + " added while it works"
	}
	return rules, verdict, true
}

func auditTracePresentation(audit AuditRow, present func(string) string) (string, []TraceStat) {
	if audit.Kind == "standing_rules.evaluated" {
		var evaluation core.StandingRuleEvaluationAudit
		if err := json.Unmarshal([]byte(audit.Detail), &evaluation); err == nil {
			if evaluation.Checked == 0 {
				// Three zeros and no rule cards say nothing. The fact worth
				// stating is that this channel has no standing rules at all.
				return "This channel has no standing rules, so there was nothing to match. " +
					"Rules are added by asking Responder in the channel and confirming.", nil
			}
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
	// A watch row whose detail is just the channel token says where but not
	// what; the decision itself belongs in the sentence. Detail with prose in
	// it (a failure, a coalesce note) already carries the decision.
	if audit.Kind == "slack.watch" && !strings.Contains(strings.TrimSpace(audit.Detail), " ") {
		switch audit.Outcome {
		case "replied":
			summary = "Responder read this message and decided it deserved a reply in " + summary + "."
		case "ignored":
			summary = "Responder read this message and decided no reply was needed in " + summary + "."
		}
	}
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

// auditTraceWhy explains the audit kinds whose title is a term of art. Rows
// that already say what they did get nothing: a recurring paragraph about what
// an audit ledger is would drown them.
func auditTraceWhy(audit AuditRow) string {
	switch audit.Kind {
	case "result.legacy_shape":
		return "The model answered in an older result format that Responder still accepts. It was read successfully — this row exists so the count of old-format answers stays visible while the contract moves on."
	case "coop.budget.auto_extend":
		return "The turn ran into its token budget and Responder raised it rather than cutting the work short."
	case "slack.paused":
		return "Responder stops replying in a channel while it is paused; the work still runs and is recorded here."
	case "slack.replay":
		return "The exact inputs and answer were saved as a replay candidate, which can become a regression test."
	}
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
func promptContextDetails(prompt string, present func(string) string, trimmed map[string][]string) ([]TraceDetail, int) {
	envelope, ok := promptEnvelope(prompt)
	if !ok {
		return nil, 0
	}
	details := make([]TraceDetail, 0, len(envelope)+12)
	layerCount := 0
	seen := map[string]bool{}

	// Slack conversation. Alias sets represent schema evolution; only the value
	// selected by the compiler is shown, never duplicate spellings of it. A
	// quiet slot keeps its own inert row, in place, with its own reason — and
	// a slot the budget cut says it was trimmed, never that nothing existed.
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
			if len(trimmed[slackTrimKind[aliases[0]]]) == 0 {
				slack = append(slack, missingPromptFieldDetail(aliases[0]))
			}
			continue
		}
		slack = append(slack, promptFieldDetail(key, raw, present))
	}
	slack = append(slack, trimmedRows(trimmed, present, "channel_history", "referenced_thread")...)
	details = append(details, markDetailGroup(slack,
		"Slack conversation",
		"The triggering message and nearby conversation selected for this turn. Included rows show their complete submitted content.",
	)...)

	// Memory. Each root is selected independently and expanded into the actual
	// values sent to the model so the page never hides memory behind a digest.
	for _, layer := range []struct {
		keys, priority, trimKinds []string
		label, group, groupDetail string
	}{
		{[]string{"prior_operational_context"}, []string{"current_incidents", "open_commitments", "pending_approvals", "operator_confirmed_memory", "confirmed_memory", "automatically_synthesized_continuity", "recent_same_channel_evidence", "responder_preferences"}, []string{"prior_evidence", "dreamed_memory", "confirmed_memory", "prior_operational_context"}, "Operational memory", "Operational memory", "Current commitments, confirmed guidance, preferences, and recent evidence selected for this work."},
		{[]string{"structured_memory", "conversation_situation"}, []string{"goal", "situation_summary", "channel_purpose", "topology", "decisions", "constraints", "unresolved_questions", "evidence_refs"}, []string{"channel_knowledge", "channel_situation"}, "Conversation memory", "Conversation memory", "A compact summary of the exact thread when available, otherwise the channel's continuity summary."},
		{[]string{"related_situations"}, nil, []string{"related_situations"}, "Related conversation summaries", "Related conversations", "Up to six relevant summaries selected from the workspace's recent conversation memory."},
	} {
		key, raw := firstPromptField(envelope, layer.keys...)
		for _, alias := range layer.keys {
			seen[alias] = true
		}
		cut := trimmedRows(trimmed, present, layer.trimKinds...)
		var rows []TraceDetail
		switch {
		case key != "":
			layerCount++
			rows = memoryLayerDetails(raw, key, layer.label, layer.priority, present)
		case len(cut) == 0:
			rows = []TraceDetail{missingMemoryDetail(layer.label, layer.keys[0])}
		}
		// When a layer is absent because the budget cut it, the trimmed rows
		// carry the story; a quiet "nothing was relevant" row would be false.
		rows = append(rows, cut...)
		details = append(details, markDetailGroup(rows, layer.group, layer.groupDetail)...)
	}

	workspace := []TraceDetail{}
	for _, key := range []string{
		"repository", "initial_task_changes_fingerprint", "structured_corrections",
		"reply_shape_corrections", "context_omitted", "captured_at",
	} {
		seen[key] = true
		if emptyJSON(envelope[key]) {
			continue
		}
		detail := promptFieldDetail(key, envelope[key], present)
		if strings.TrimSpace(detail.Body) == "" {
			// A field whose rendering comes out blank must not offer a
			// disclosure that opens onto nothing.
			continue
		}
		workspace = append(workspace, detail)
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

// slackTrimKind links a Slack envelope slot to the budget's omission kind, so
// a slot absent because it was cut renders as trimmed rather than quiet.
var slackTrimKind = map[string]string{
	"recent_messages_around_target": "channel_history",
	"referenced_thread":             "referenced_thread",
}

// trimmedLayerLabel names each budget-omission kind the way its section does.
var trimmedLayerLabel = map[string]string{
	"channel_history":           "Older channel messages",
	"referenced_thread":         "Referenced Slack thread",
	"prior_evidence":            "Operational memory · Channel evidence",
	"dreamed_memory":            "Operational memory · Synthesized continuity",
	"confirmed_memory":          "Operational memory · Confirmed memory",
	"prior_operational_context": "Operational memory",
	"channel_knowledge":         "Conversation memory · Knowledge",
	"channel_situation":         "Conversation memory · Situation summary",
	"related_situations":        "Related conversation summaries",
}

// trimmedRows renders the budget's cuts inside the category they were cut
// from: an amber inert row per layer, its reason inline.
func trimmedRows(trimmed map[string][]string, present func(string) string, kinds ...string) []TraceDetail {
	rows := []TraceDetail{}
	for _, kind := range kinds {
		for _, reason := range trimmed[kind] {
			rows = append(rows, TraceDetail{
				Label: trimmedLayerLabel[kind], Kind: "missing", Status: "Trimmed",
				Description: present(reason), Tone: "trimmed", Inert: true,
			})
		}
	}
	return rows
}

// missingPromptFieldDetail is the inert row a quiet context slot keeps in its
// own group: nothing to open, the reason inline.
func missingPromptFieldDetail(key string) TraceDetail {
	label, tone := promptFieldPresentation(key)
	return TraceDetail{
		Label: label, Kind: "missing", Status: "Not sent",
		Description: promptSelectionDescription(key, false), Tone: tone,
		Inert: true,
	}
}

func missingMemoryDetail(label, key string) TraceDetail {
	return TraceDetail{
		Label: label, Kind: "missing", Status: "Not sent",
		Description: promptSelectionDescription(key, false), Tone: promptTone(key),
		Inert: true,
	}
}

// promptCapNote states the budget every turn is trimmed against, from the
// transport constant that enforces it.
var promptCapNote = fmt.Sprintf(
	"Everything sent must fit Coop's %d KiB turn cap (roughly %s tokens).",
	coop.MaxPromptBytes>>10, humanTokens(int64(coop.MaxPromptBytes/4)))

// promptEnvelope extracts the typed context envelope from a retained prompt.
func promptEnvelope(prompt string) (map[string]json.RawMessage, bool) {
	const open = "<untrusted-slack-context>\n"
	const close = "\n</untrusted-slack-context>"
	start := strings.LastIndex(prompt, open)
	if start < 0 {
		return nil, false
	}
	start += len(open)
	end := strings.Index(prompt[start:], close)
	if end < 0 {
		return nil, false
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(prompt[start:start+end]), &envelope) != nil {
		return nil, false
	}
	return envelope, true
}

func firstPromptField(envelope map[string]json.RawMessage, keys ...string) (string, json.RawMessage) {
	for _, key := range keys {
		if !emptyJSON(envelope[key]) {
			return key, envelope[key]
		}
	}
	return "", nil
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
		"context_omitted":               {promptCapNote + " These notes are sent to the model, so it knows what it is missing.", "Nothing was removed from the assembled prompt for size."},
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

// modelSelectionWhy explains how the routing decision is actually made, from
// the code that makes it: Responder never ranks models per message. The
// channel's setup binds it to a repository; the repository's configuration
// names a Coop policy; the policy's model ladder picks what runs and rotates
// on rate limits. The manifest records the effective answerer, so a rotated
// turn shows the fallback that ran, not the first rung that was configured.
func modelSelectionWhy(manifest ManifestRow) string {
	if manifest.Preset == "" {
		return "No Coop policy was recorded for this attempt, so the routing source is unknown."
	}
	if repository := manifestRepository(manifest.Refs); repository != "" {
		return fmt.Sprintf(
			"Routing is set statically in the configuration. This channel's repository binding (%s) names Coop policy %s, whose model ladder picks what runs and rotates on rate limits.",
			repository, manifest.Preset)
	}
	return fmt.Sprintf(
		"Routing is set statically in the configuration. Coop policy %s's model ladder picks what runs and rotates on rate limits.",
		manifest.Preset)
}

// manifestRepository names the repository the attempt was bound to, from the
// manifest's own reference rows.
func manifestRepository(refs []ContextRef) string {
	for _, ref := range refs {
		if ref.Kind != "repository" {
			continue
		}
		name, _, _ := strings.Cut(ref.What, " @ ")
		return strings.TrimSpace(name)
	}
	return ""
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

// contextReferenceDetails returns the runtime-access table and, separately,
// the replay fingerprints as flat facts — the caller renders those as the
// card's footer strip, below the model-visible content they verify.
func contextReferenceDetails(refs []ContextRef, present func(string) string, stored map[string]bool) (runtimeDetail []TraceDetail, replay []TraceStat) {
	runtime := make([]TraceTableRow, 0, len(refs))
	for _, ref := range refs {
		switch ref.Kind {
		case "source_input":
			// The source message is already the first timeline step and appears
			// as a colored model-visible prompt component. Do not show it again.
			continue
		case "compiled_prompt", "assembled_context":
			name := "Final prompt"
			if ref.Kind == "assembled_context" {
				name = "Selected context"
			}
			fingerprint := fallback(ref.Digest, "not recorded")
			if ref.Omitted != "" {
				fingerprint += " · omitted: " + present(ref.Omitted)
			}
			replay = append(replay, TraceStat{name, fingerprint})
			continue
		default:
			if ref.Visibility != "omitted" {
				row := contextReferenceTableRow(ref, present)
				if ref.Kind == "artifact" && stored[ref.FullDigest] {
					row.Href = template.URL("/artifacts/" + url.PathEscape(ref.FullDigest))
				}
				runtime = append(runtime, row)
			}
		}
	}
	if len(runtime) > 0 {
		runtimeDetail = []TraceDetail{{
			Label: "Repositories and session controls", Kind: "context",
			Status: "Runtime access", Tone: "runtime", ShowCount: true, Count: len(runtime),
			Group: "Runtime access", GroupCount: len(runtime),
			Table: &TraceTable{
				Headers: []string{"Type", "Name", "Revision", "How it was used"},
				Rows:    runtime,
			},
		}}
	}
	return runtimeDetail, replay
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
		"repository":       "The bound repository, checked out for the model through Coop",
		"execution_policy": "Controls tools and whether files can change",
		"artifact":         "Exact file handed to the model for this turn",
	}[ref.Kind]
	if ref.Kind == "repository" && ref.Visibility == "companion" {
		kind = "Companion repository"
		role = "Read-only companion checkout, mounted beside the bound repository"
	}
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
		// Not the next action: the panel below states it in full, and a tile
		// showing the same sentence cut off at a hundred characters is the
		// same instruction twice, worse the first time.
		metric.Detail = "Nothing more runs until somebody unblocks it. What it needs is below."
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

// correctionClassSummary names the finalization check that failed. The stored
// value is the check's own token; a person reading the trace needs to know
// what the host actually objected to.
func correctionClassSummary(class string) string {
	if summary, ok := map[string]string{
		"unreadable": "The result did not parse — Responder could not read an answer out of it at all.",
		"incomplete": "The answer was readable but unfinished: a missing verdict, uncovered ground left unexplained, or a claim the evidence did not support.",
		"rejected":   "The answer parsed and was complete, but something it proposed was not well-formed enough to act on.",
		"shape":      "The reply did not fit the channel's shape bounds — too long, or built wrong for where it was going.",
	}[class]; ok {
		return summary
	}
	return "The result failed the " + strings.ReplaceAll(class, "_", " ") + " check."
}

func modelSummary(turn Turn) string {
	if turn.Message != "" {
		return truncate(strings.Join(strings.Fields(turn.Message), " "), 220)
	}
	if turn.Action != "" || turn.Reason != "" {
		// "ignore: <reason>" is the ledger's spelling, not a sentence.
		if lead, ok := map[string]string{
			"ignore":  "Decided not to reply.",
			"reply":   "Decided to reply.",
			"observe": "Decided to watch without replying.",
		}[turn.Action]; ok {
			return strings.TrimSpace(lead + " " + turn.Reason)
		}
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
	switch kind {
	case "external_wait_started", "wakeup_resolved", "operator_input_requested":
		return "Wait"
	case "destination_changed":
		return "Delivery"
	case "feedback.recorded":
		return "Review"
	case "task_offered":
		return "Side effect"
	case "migration_recovered":
		return "Recovery"
	}
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
		"context_extended":           "Context recorded",
		"evidence_recorded":          "Model logged evidence",
		"completion_submitted":       "Model reported completion",
		"completed":                  "Episode completed",
		"blocked":                    "Blocked",
		"external_wait_started":      "Waiting for an external event",
		"wakeup_resolved":            "Wake-up resolved",
		"operator_input_requested":   "Model asked the operator",
		"progress_reported":          "Model reported progress",
		"task_offered":               "Model offered an engineering task",
		"feedback.recorded":          "Model recorded operator feedback",
		"destination_changed":        "Reply destination changed",
		"migration_recovered":        "Recovered from an earlier episode",
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

// timelineRepeatsLifecycle reports whether an incident-timeline entry already
// carries this lifecycle event's sentence. Both records are written by the
// same publish step, so their text matches exactly.
func timelineRepeatsLifecycle(lifecycle EpisodeArtifact, artifacts []EpisodeArtifact) bool {
	text := strings.TrimSpace(lifecycle.Summary)
	if text == "" {
		return false
	}
	for _, artifact := range artifacts {
		if artifact.Kind != "incident_timeline" {
			continue
		}
		if strings.TrimSpace(artifact.Title) == text || strings.TrimSpace(artifact.Summary) == text {
			return true
		}
	}
	return false
}

// timelineRepeatsAnswer reports whether an incident-timeline finding is this
// episode's own reply, mirrored into the thread the work belongs to.
func timelineRepeatsAnswer(artifact EpisodeArtifact, page episodePage) bool {
	text := strings.TrimSpace(artifact.Detail)
	if text == "" {
		return false
	}
	for _, turn := range append([]Turn{page.Turn}, page.Turns...) {
		for _, said := range []string{turn.Message, turn.Prose, turn.Completion.Summary} {
			if said = strings.TrimSpace(said); said != "" && said == text {
				return true
			}
		}
	}
	return false
}

// timelineLead reduces a timeline detail to the line a card can lead with. A
// detail that is a bare identifier — a Slack timestamp, a session id — is a
// reference, not a sentence, and says so.
func timelineLead(detail string) (string, bool) {
	trimmed := strings.TrimSpace(detail)
	if !strings.Contains(trimmed, " ") {
		return trimmed, true
	}
	lead, _, _ := strings.Cut(trimmed, "\n\n")
	return strings.TrimSpace(lead), false
}

// timelineKindWhy says what an incident-timeline entry is for. An incident
// thread mixes operator messages, agent findings, and publication events; the
// line explains why each belongs on the same rail.
func timelineKindWhy(kind string) string {
	switch kind {
	case "agent.finding":
		return "A delegated agent reported back into the incident thread while this episode was running."
	case "operator.message":
		return "An operator message in the incident thread; it can start or redirect the delegated work."
	case "coop.session.created":
		return "The engineering work runs in its own isolated Coop session, separate from this conversation's session."
	case "slack.thread.bound":
		return "The engineering task was tied to the Slack thread it came from, so its updates return to the same place."
	case "agent.failure":
		return "The delegated agent stopped before finishing; the incident keeps the failure so the work can resume."
	}
	if strings.HasPrefix(kind, "publication.") {
		return "Recorded because this incident opened a pull request; Responder tracks it until the change is merged and applied."
	}
	return ""
}

// timelineKindTitle names an incident-timeline entry by its kind when the
// stored title is a full sentence rather than a heading.
func timelineKindTitle(kind string) string {
	if title, ok := map[string]string{
		"publication.checks":    "PR checks reported",
		"publication.merged":    "PR merged",
		"publication.terraform": "Terraform run update",
		"agent.finding":         "Investigation update",
		"agent.failure":         "Delegated agent failed",
		"operator.message":      "Operator message",
		"coop.session.created":  "Isolated engineering task started",
		"slack.thread.bound":    "Engineering task started in source thread",
	}[kind]; ok {
		return title
	}
	return "Incident update"
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

// activityTraceSteps is the interior of the turn — what the model reasoned
// about and what it ran — as cards on the rail rather than one summary.
//
// Consecutive tool calls collapse into a single tabular card. That is what
// makes both shapes work: a mechanical turn that runs twenty-six Emisar
// actions back to back stays one card, while a turn that thinks, acts, thinks
// again produces a card per beat and keeps the order those beats happened in.
// The earlier single card lost exactly that — it lumped every thought into one
// block and every call into another, so "considered X, then did Y" was
// unrecoverable from the page.
func activityTraceSteps(page episodePage) []TraceStep {
	moments := page.Activity
	steps := []TraceStep{}
	for index := 0; index < len(moments); {
		if moments[index].Kind != "tool" {
			steps = append(steps, activityMomentStep(moments[index], len(steps)))
			index++
			continue
		}
		run := index
		for run < len(moments) && moments[run].Kind == "tool" {
			run++
		}
		steps = append(steps, activityCallsStep(moments[index:run], len(steps)))
		index = run
	}
	return steps
}

// activityCallsStep renders one unbroken run of tool calls.
func activityCallsStep(calls []ActivityMoment, ordinal int) TraceStep {
	first, end := calls[0].At, calls[0].At
	rows := make([]TraceTableRow, 0, len(calls))
	kinds := map[string]int{}
	failed, running := 0, 0
	for _, call := range calls {
		if !call.At.IsZero() {
			if first.IsZero() || call.At.Before(first) {
				first = call.At
			}
			if call.At.After(end) {
				end = call.At
			}
		}
		if call.ToolKind != "" {
			kinds[call.ToolKind]++
		}
		switch call.Status {
		case "":
			running++
		case "failed":
			failed++
		}
		rows = append(rows, TraceTableRow{
			Cells: []string{
				activityOffset(first, call.At),
				fallback(call.Title, "unnamed call"),
				fallback(call.ToolKind, "—"),
				fallback(call.Status, "still running"),
				fallback(call.Duration, "—"),
				fallback(call.Detail, "—"),
			},
			Expand: call.Arguments, ExpandAt: 5,
		})
	}

	step := TraceStep{
		ID: fmt.Sprintf("activity-%d", ordinal+1), Stage: "Execution", Actor: "Model",
		State: "recorded", Icon: "bolt", At: first, band: bandWork,
	}
	if len(calls) == 1 {
		step.Title = fallback(calls[0].Title, "Tool call")
	} else {
		// No summary line naming the operations: the table sits open directly
		// underneath and lists every one of them, so a header repeating the
		// first few is the same sentence twice.
		step.Title = countList([]countPart{{len(calls), "tool call", "tool calls"}})
	}
	if failed > 0 {
		step.Tone = "warn"
	}
	if !first.IsZero() && end.After(first) {
		step.Duration = compactDuration(end.Sub(first))
	}
	for kind, count := range kinds {
		step.Stats = append(step.Stats, TraceStat{kind, fmt.Sprint(count)})
	}
	sort.Slice(step.Stats, func(i, j int) bool { return step.Stats[i].Label < step.Stats[j].Label })
	if failed > 0 {
		step.Stats = append(step.Stats, TraceStat{"failed", fmt.Sprint(failed)})
	}
	// A call with no terminal update is not a call that succeeded.
	if running > 0 {
		step.Stats = append(step.Stats, TraceStat{"never finished", fmt.Sprint(running)})
	}
	step.Details = []TraceDetail{{
		Label: "Every call, in order", Kind: "context", Status: "Tool calls",
		// The one fact a reader cannot infer from the table: results were
		// never recorded, so an empty-looking call is not a call that
		// returned nothing.
		Description: "Click a row for the whole recorded input. Arguments are kept, " +
			"results are not: results dominate a transcript and routinely carry " +
			"credentials and log bodies.",
		Open: true, ShowCount: true, Count: len(rows),
		Table: &TraceTable{
			Headers:  []string{"At", "What ran", "Kind", "Status", "Took", "Arguments"},
			Rows:     rows,
			Tight:    true,
			IDPrefix: step.ID,
		},
	}}
	return step
}

// activityMomentStep renders one non-tool beat: a stretch of reasoning, a plan
// the model revised, a permission answered without a person, or a gap.
func activityMomentStep(moment ActivityMoment, ordinal int) TraceStep {
	step := TraceStep{
		ID: fmt.Sprintf("activity-%d", ordinal+1), Stage: "Execution", Actor: "Model",
		State: "recorded", At: moment.At, Tone: moment.Tone, band: bandWork,
	}
	switch moment.Kind {
	case "thought":
		step.Icon, step.Title = "sparkle", "Reasoning"
		step.Summary = core.TruncateUTF8WithSuffix(moment.Detail, 160, "…")
		if len(moment.Detail) > len(step.Summary) {
			step.Details = []TraceDetail{{
				Label: "In full", Body: moment.Detail, Kind: "text",
			}}
		}
	case "plan":
		step.Icon, step.Title = "milestone", "Plan updated"
		lines := make([]string, 0, len(moment.Entries))
		done := 0
		for _, entry := range moment.Entries {
			line := "• " + entry.Content
			if entry.Status != "" {
				line += " — " + entry.Status
			}
			if entry.Status == "completed" {
				done++
			}
			lines = append(lines, line)
		}
		step.Summary = fmt.Sprintf("%d of %d steps done", done, len(moment.Entries))
		step.Details = []TraceDetail{{
			Label: "The plan as it stood", Body: strings.Join(lines, "\n"), Kind: "text",
			Open: true, ShowCount: true, Count: len(lines),
		}}
	case "permission":
		step.Icon, step.Title = "shield", "Permission decided"
		step.Summary = strings.TrimSpace(fallback(moment.Title, "a tool call") +
			" — " + fallback(moment.Detail, "decided"))
		step.Why = "The agent asked to do something and nobody human was there to " +
			"answer. This is what the policy chose on their behalf."
	case "elided":
		step.Icon, step.Title, step.Tone = "info", "Activity not recorded", "warn"
		step.Summary = moment.Detail
		if moment.Dropped > 0 {
			step.Stats = []TraceStat{{"Moments dropped", fmt.Sprint(moment.Dropped)}}
		}
	default:
		step.Icon, step.Title = "dot", fallback(moment.Title, "Activity")
		step.Summary = moment.Detail
	}
	return step
}

func countActivityTools(moments []ActivityMoment) int {
	count := 0
	for _, moment := range moments {
		if moment.Kind == "tool" {
			count++
		}
	}
	return count
}

func activityOffset(start, at time.Time) string {
	if start.IsZero() || at.IsZero() || at.Before(start) {
		return "—"
	}
	return "+" + compactDuration(at.Sub(start))
}

func usageTraceStep(page episodePage) TraceStep {
	at := page.Turn.Updated
	if at.IsZero() {
		at = page.Manifest.Created
	}
	step := TraceStep{
		ID: "usage", Stage: "Measurement", Actor: "Responder", State: "recorded", Icon: "gauge", At: at,
		Title: "Usage measured",
	}
	if !page.Spent.Recorded() {
		step.State = "not measured"
		step.Summary = "The provider reported no token counts — missing telemetry, not a free turn."
		return step
	}
	summary := humanTokens(page.Spent.Total()) + " tokens"
	if page.Spent.Clock.Recorded() {
		summary += " · " + page.Spent.Clock.Total() + " of model time"
	}
	step.Summary = summary
	step.Bar = usageBar(page.Spent)
	if page.Spent.Clock.Recorded() {
		step.Details = []TraceDetail{{
			Label: "Where the time went",
			Body:  "Total: " + page.Spent.Clock.Total() + "\n" + page.Spent.Clock.Split(),
			Kind:  "text",
		}}
	}
	return step
}

func eventWhy(kind string) string {
	switch kind {
	case "evidence_recorded":
		return "The contract makes the model file evidence — a claim, the observation, its source and confidence — instead of just asserting conclusions. These rows feed the claim assessment and the operational memory of future turns in this channel."
	case "context_extended":
		return "The kernel's receipt for freezing a context manifest. It renders here because the manifest itself could not be loaded on this page."
	case "operator_input_requested":
		return "The model stopped instead of guessing. The question went to Slack, and the episode waits for the answer."
	case "task_offered":
		return "Proposed by the model — nothing runs until an operator confirms it."
	case "progress_reported":
		return "Long work must report progress before its deadline; a missing report is treated as a stall and recovered."
	case "feedback.recorded":
		return "Saved so future replies in this channel can adapt to what the operator asked for."
	}
	return ""
}

func attemptSummary(attempt Attempt) string {
	if attempt.Failure != "" {
		// Known machine classes read as sentences; real failure messages
		// already do.
		if prose, ok := map[string]string{
			"episode_terminal": "The episode reached its final state before this attempt finished, so the attempt's result was no longer needed.",
			"superseded":       "A newer attempt took over this work before this one finished.",
		}[attempt.Failure]; ok {
			return prose
		}
		return attempt.Failure
	}
	if attempt.State == "succeeded" {
		// The title already says it; an echo under it is noise.
		return ""
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
	return "One Coop run of this episode's work. Attempts are numbered because a run that fails or is overtaken does not lose the episode — the next attempt starts again from the same saved context."
}

func sideEffectWhy(effect SideEffect) string {
	if effect.State == "offered" || effect.State == "waiting" {
		return "Proposed by the model — nothing runs until it is confirmed."
	}
	return ""
}

func deliveryWhy(delivery Delivery) string {
	if delivery.Operation == "status" {
		if strings.TrimSpace(delivery.Status) == "" {
			return "The episode ended, so the native status came down — a spinner that outlives its work reads as a hang."
		}
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

// StoppedOn is what a blocked or waiting episode is actually waiting for.
//
// The model records all of this and the page showed none of it. A reader got
// the word "blocked" and one truncated sentence of instruction, so the two
// questions they actually had — what is missing, and has anyone tried the
// obvious thing — had no answer anywhere on the screen. Every field here was
// already in the completion payload.
type StoppedOn struct {
	// Headline names the kind of obstacle in words a person uses.
	Headline string
	// Why is the model's own one-line account of where it got to.
	Why string
	// Needs is what would unblock it; Tried is what it already did, so nobody
	// repeats it.
	Needs, Tried []string
	// Do is the specific action that would let the work continue.
	Do string
}

// blockerHeadline names each recorded blocker_kind. The values are the
// model's, taken from the contract it answers under; anything unmapped falls
// back to the token with its underscores opened out, because inventing a
// friendly name for a class this code has never seen would be a guess.
func blockerHeadline(kind string) string {
	if headline, ok := map[string]string{
		"source_unavailable":      "It could not reach the code or data it needed",
		"capability_unavailable":  "It has no tool that can do this",
		"access_denied":           "It was refused access",
		"operator_input_required": "It needs an answer from a person",
		"tool_failure":            "A tool it depends on failed",
		"authority_boundary":      "This is past what it is allowed to do on its own",
	}[kind]; ok {
		return headline
	}
	if kind == "" {
		return "It stopped before finishing"
	}
	runes := []rune(strings.ReplaceAll(kind, "_", " "))
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}

// stoppedOn builds the waiting panel from the last completion that reported a
// blocker. It returns nil when the episode is not parked on anything, so the
// panel is absent rather than empty on the great majority of pages.
func stoppedOn(page episodePage) *StoppedOn {
	if !resolvableState(page.Item.State) {
		return nil
	}
	turns := page.Turns
	if len(turns) == 0 {
		turns = []Turn{page.Turn}
	}
	panel := StoppedOn{Do: strings.TrimSpace(page.Item.Next)}
	for _, turn := range turns {
		completion := turn.Completion
		if completion.Summary == "" && completion.Blocker == "" && len(completion.Gaps) == 0 {
			continue
		}
		panel.Headline = blockerHeadline(completion.Kind)
		panel.Why = strings.TrimSpace(fallback(completion.Blocker, completion.Summary))
		panel.Needs, panel.Tried = completion.Gaps, completion.Attempts
		if next := strings.TrimSpace(completion.Next); next != "" {
			panel.Do = next
		}
	}
	if panel.Headline == "" {
		// No completion said why. The episode's own status line is then the
		// only account there is, and saying that plainly beats a blank panel.
		panel.Headline = blockerHeadline("")
		panel.Why = strings.TrimSpace(page.Item.Status)
	}
	return &panel
}
