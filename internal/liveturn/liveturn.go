// Package liveturn folds a turn's recorded interior into the shape a card
// shows.
//
// It exists because of one measured failure: a real 57-minute turn made 119
// tool calls and told the operator "Still working" twice, byte for byte,
// because the only account on the card was the model's summary of itself. The
// stream underneath it was specific, truthful, and already on disk. This is
// the translation between the two — stored moments in, three lines and four
// counters out.
//
// It reads through two interfaces narrow enough to state what it is allowed to
// know, and it holds no clock, no Slack client and no other part of the
// database. What it owns is the judgement — which moments are worth showing,
// what a reasoning payload is allowed to say in Slack, when a second read is
// worth making — which is the part worth testing on its own and the part that
// would otherwise sit in the middle of the card worker.
package liveturn

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// WindowLines is what the card shows. The renderer keeps three; reading more
// would be paying for rows it is about to drop.
const WindowLines = 3

// maxLineBytes bounds one line before it leaves this package.
//
// The renderer truncates at 46 runes, so this is not what makes the card fit.
// It is what stops a four-kilobyte reasoning summary being carried through the
// sanitizer, the encoder and the delivery ledger to have almost all of it
// thrown away at the end.
const maxLineBytes = 200

// Tail reads what a turn has done. Narrow on purpose: this package decides
// what the moments mean and must not be able to reach anything else in the
// database while doing it.
type Tail interface {
	TailForIncident(
		ctx context.Context, incidentID string, limit int,
	) (core.AgentActivityTail, error)
}

// Findings reads what the work has established.
type Findings interface {
	SummarizeIncidentEvidence(
		ctx context.Context, incidentID string,
	) (core.IncidentEvidence, error)
}

// Fetch reads the card's view of the work behind it.
//
// At most two reads, and none at all for a card with no agent behind it: work
// that never opened a Coop session has no narrated interior. Where there is a
// session the tail is read whether or not a turn is running now, because the
// totals outlive the window — they become the ledger step's receipt the moment
// the turn stops.
//
// A read that fails returns what is known so far beside the error. The caller
// is rendering a card, and a card missing its window is a detail short; a card
// that failed to render is an operator with nothing.
func Fetch(
	ctx context.Context,
	tail Tail,
	findings Findings,
	incident core.Incident,
) (slackui.LiveTurn, error) {
	if incident.CoopSessionID == "" {
		return slackui.LiveTurn{}, nil
	}
	active := incident.ActiveTurnID != ""
	moments, err := tail.TailForIncident(ctx, incident.ID, WindowLines)
	if err != nil {
		return slackui.LiveTurn{Active: active}, err
	}
	// Nothing narrated and nothing running: there is no window to fill and no
	// receipt to write, so the second read would answer a question this card is
	// not going to ask.
	if moments.Recorded == 0 && !active {
		return slackui.LiveTurn{Active: active}, nil
	}
	evidence, err := findings.SummarizeIncidentEvidence(ctx, incident.ID)
	return Project(moments, evidence, active), err
}

// Project builds the card's view of the work behind it.
//
// active is the incident's own answer, not one inferred from the data: a turn
// that has stopped still has all of its moments on disk, and inferring "running"
// from their presence would leave a stopped card looking like a working one.
func Project(
	tail core.AgentActivityTail,
	evidence core.IncidentEvidence,
	active bool,
) slackui.LiveTurn {
	turn := slackui.LiveTurn{
		Active:       active,
		ToolCalls:    tail.ToolCalls,
		LastActivity: tail.LastActivity,
		Evidence:     evidence.Count,
		Claim:        evidence.Claim,
	}
	for _, moment := range tail.Lines {
		if line, ok := Line(moment); ok {
			turn.Lines = append(turn.Lines, line)
		}
	}
	return turn
}

// Line folds one stored moment into one line of the window.
//
// The kinds going in are Coop's event types and the kinds coming out are what
// a reader sees, which is why this is a translation rather than a
// pass-through: a reasoning summary and a file edit arrive narrated the same
// way and are not the same thing to look at.
func Line(moment core.AgentActivity) (slackui.ActivityLine, bool) {
	switch moment.Kind {
	case coop.EventModelThought:
		// The summary title, not the reasoning. Coop stores the title column
		// as its own label — "Reasoning" when the runtime sent none — and puts
		// the actual summary in the detail payload, up to four kilobytes of
		// it. One bounded line of that, and never the thinking itself: raw
		// chain-of-thought does not go to Slack, ever.
		text := firstLine(detailText(moment.Detail))
		if text == "" {
			text = firstLine(moment.Title)
		}
		if text == "" {
			return slackui.ActivityLine{}, false
		}
		return slackui.ActivityLine{Kind: slackui.ActivityThinking, Title: text}, true
	case coop.EventToolStarted:
		title := firstLine(moment.Title)
		kind := slackui.ActivityTool
		if isEdit(moment.ToolKind) {
			kind = slackui.ActivityEdit
		}
		target := packRef(moment.Detail)
		raw := ""
		if isExec(moment.ToolKind) {
			raw = shellCommand(moment.Detail)
		}
		if command := firstLine(normalizeCommand(raw)); command != "" {
			switch {
			// The command is the label when the title is not one. A shell tool
			// whose runtime sends no per-call title leaves its own name behind,
			// and three of those in a row is the window telling an operator
			// "Terminal" three times about three different commands. It is also
			// the label when the title is that same command in worse clothes:
			// one fact, once, in the form a person can read.
			case uninformativeTitle(moment.Title, moment.ToolKind) ||
				sameCommand(moment.Title, raw):
				title = command
			// A pack ref outranks a command line — it is the one durable
			// identifier a tool payload carries — and the target column holds
			// one thing.
			case target == "":
				target = command
			}
		}
		if title == "" {
			return slackui.ActivityLine{}, false
		}
		return slackui.ActivityLine{Kind: kind, Title: title, Target: target}, true
	}
	return slackui.ActivityLine{}, false
}

// isEdit decides which tool calls changed something.
//
// The distinction earns its own glyph because it is the one an operator
// watching a task cares about: reading and searching is the agent working, and
// writing is the agent committing to an answer. The vocabulary is the
// runtimes' own and is matched loosely on purpose — an unrecognised kind
// renders as a tool call, which is true of every kind here.
func isEdit(kind string) bool {
	return core.IsEditToolKind(kind)
}

// execToolKinds are the tool kinds that run a shell command.
//
// Same shape as core.EditToolKinds and for the same reason — the vocabulary is
// each runtime's own, not Responder's — but it stays here because only this
// package asks the question: it decides whether a payload's `command` is a
// command, and nothing counts exec calls in SQL.
var execToolKinds = []string{
	"execute", "exec", "terminal", "bash", "shell", "command", "run",
}

func isExec(kind string) bool {
	return slices.Contains(execToolKinds, strings.ToLower(strings.TrimSpace(kind)))
}

// coopFallbackTitle is what Coop stores when the runtime named nothing
// (coop.Activity.Title). It is a label about the record, not about the work.
const coopFallbackTitle = "tool call"

// uninformativeTitle reports that the stored title names the tool rather than
// the call.
//
// This is the measured failure itself: 118 of the shell calls on disk are
// titled `Terminal` with an empty payload, and the ones that do carry a command
// were rendering under that same word. A title that repeats the tool kind says
// nothing three lines of it did not already say.
func uninformativeTitle(title, toolKind string) bool {
	folded := strings.ToLower(strings.TrimSpace(title))
	switch folded {
	case "", "terminal", coopFallbackTitle:
		return true
	}
	return folded == strings.ToLower(strings.TrimSpace(toolKind))
}

// shellWrappers are the ways a runtime hands a command line to a shell. The
// wrapper is the runtime's plumbing; the operator asked what ran.
var shellWrappers = []string{
	"/bin/bash -lc ", "/bin/bash -c ", "/bin/sh -lc ", "/bin/sh -c ",
	"/bin/zsh -lc ", "/bin/zsh -c ",
	"bash -lc ", "bash -c ", "sh -lc ", "sh -c ", "zsh -lc ", "zsh -c ",
}

// shellCommand reads what a shell tool call ran.
//
// The command was in the payload the whole time the card was saying "Terminal":
// coop.Activity.Detail stores the runtime's input verbatim under `input`, so
// `input.command` is the line itself. Decoded through its own envelope for the
// same reason packRef has one — a tool payload is an object of unknown shape
// and only the key being read is claimed.
func shellCommand(detail json.RawMessage) string {
	if len(detail) == 0 {
		return ""
	}
	var envelope struct {
		Input struct {
			Command string `json:"command"`
		} `json:"input"`
	}
	if json.Unmarshal(detail, &envelope) != nil {
		return ""
	}
	return envelope.Input.Command
}

// normalizeCommand turns a stored command line back into what a person typed.
//
// A wrapped call arrives as `/bin/bash -lc "grep -n \"x\" f"`, which is three
// facts — the shell, the quoting the shell needed, and the command — of which
// the card has room for one. Unwrapping is refused unless the remainder is one
// quoted string end to end, because `"a" && "b"` is not a quoted string and
// stripping its ends would change what it says.
func normalizeCommand(value string) string {
	value = strings.TrimSpace(stripShellWrapper(strings.TrimSpace(value)))
	if unwrapped, ok := unquote(value); ok {
		return unwrapped
	}
	return value
}

func stripShellWrapper(value string) string {
	for _, wrapper := range shellWrappers {
		if rest, found := strings.CutPrefix(value, wrapper); found {
			return rest
		}
	}
	return value
}

// unquote unwraps one pair of double quotes, and says whether it found one.
//
// An unescaped quote inside, or a dangling backslash where the closing quote
// should be, means the ends are not a pair — the string merely starts and stops
// with a quote — and the value is returned untouched.
func unquote(value string) (string, bool) {
	if len(value) < 2 || value[0] != '"' || value[len(value)-1] != '"' {
		return value, false
	}
	inner := value[1 : len(value)-1]
	var unescaped strings.Builder
	for index := 0; index < len(inner); index++ {
		switch char := inner[index]; {
		case char == '\\':
			if index+1 >= len(inner) {
				return value, false
			}
			if next := inner[index+1]; next == '"' || next == '\\' {
				unescaped.WriteByte(next)
				index++
				continue
			}
			unescaped.WriteByte(char)
		case char == '"':
			return value, false
		default:
			unescaped.WriteByte(char)
		}
	}
	return unescaped.String(), true
}

// sameCommand reports that a title is the command again, worse dressed.
//
// The runtimes that title a shell call at all title it with the command, in the
// escaped form the wrapper needed, and the activity store then bounds that
// title at 300 bytes with an ellipsis while keeping the whole line in the
// payload. On disk that is 32 of the 49 shell calls that carry a command: same
// fact, cut and escaped. Rendering both would put the command on the card
// twice, once unreadable.
func sameCommand(title, command string) bool {
	stored, ran := commandKey(title), commandKey(command)
	if stored == "" || ran == "" {
		return false
	}
	if stored == ran {
		return true
	}
	prefix, truncated := strings.CutSuffix(stored, "…")
	return truncated && prefix != "" && strings.HasPrefix(ran, prefix)
}

// commandKey is the form in which two writings of one command line compare
// equal. Comparing is not rendering, so unlike normalizeCommand it strips the
// quoting either way: a title cut mid-string keeps its opening quote and never
// reaches its closing one, and refusing that pair here would call a truncated
// command a different command.
func commandKey(value string) string {
	value = strings.TrimSpace(stripShellWrapper(strings.TrimSpace(value)))
	value = strings.TrimSuffix(strings.TrimPrefix(value, `"`), `"`)
	return strings.NewReplacer(`\"`, `"`, `\\`, `\`).Replace(value)
}

// detailText reads the reasoning summary out of a stored thought.
//
// The payload is the same shape coop.Activity encodes, so it is decoded with
// that type rather than with a second private struct that could drift from it.
func detailText(detail json.RawMessage) string {
	if len(detail) == 0 {
		return ""
	}
	decoded, ok := coop.DecodeActivity(detail)
	if !ok {
		return ""
	}
	return decoded.Text
}

// packRef names what a tool call reached for, when the call says so.
//
// An Emisar call carries the immutable pack reference it resolved, which is
// the one durable identifier in a tool payload whose shape is otherwise
// per-tool. The renderer strips the sha256 digest — what makes the reference
// immutable is also what makes it 64 characters of a 46-character line —
// leaving `victoriametrics@0.1.7`, which is what a person reads it as.
//
// Anything else is left alone. A tool's arguments are an object of unknown
// shape, and guessing a target out of one would put a confident wrong noun on
// the card.
func packRef(detail json.RawMessage) string {
	if len(detail) == 0 {
		return ""
	}
	var envelope struct {
		Input struct {
			Arguments struct {
				PackRef string `json:"pack_ref"`
			} `json:"arguments"`
		} `json:"input"`
	}
	if json.Unmarshal(detail, &envelope) != nil {
		return ""
	}
	return firstLine(envelope.Input.Arguments.PackRef)
}

// firstLine is the bound every string from a transcript passes before it
// reaches the card. The renderer sanitizes and truncates too; this is the
// earlier of the two, and the one that stops four kilobytes travelling.
func firstLine(value string) string {
	value = strings.TrimSpace(value)
	if index := strings.IndexAny(value, "\r\n"); index >= 0 {
		value = strings.TrimSpace(value[:index])
	}
	return core.TruncateUTF8(value, maxLineBytes)
}
