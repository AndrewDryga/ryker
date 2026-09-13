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
// It reads through three interfaces narrow enough to state what it is allowed
// to know, and it holds no clock, no Slack client and no other part of the
// database. What it owns is the judgement — which moments are worth showing,
// what a reasoning payload is allowed to say in Slack, when a second read is
// worth making — which is the part worth testing on its own and the part that
// would otherwise sit in the middle of the card worker.
package liveturn

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
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

type cumulativeWorkTail interface {
	TailForWork(
		ctx context.Context, incidentID string, limit int,
	) (core.AgentActivityTail, error)
}

// Findings reads what the work has established.
type Findings interface {
	SummarizeIncidentEvidence(
		ctx context.Context, incidentID string,
	) (core.IncidentEvidence, error)
}

// Plan reads what the work said it would do.
//
// Narrow like the two above, and separate from Findings because it is a
// different question about a different table: evidence is what the turn found,
// and this is what it undertook to do before it found anything.
type Plan interface {
	GoalsForIncident(
		ctx context.Context, incidentID string, limit int,
	) ([]core.EpisodeGoal, error)
}

// PlanLimit is how many goals are read for a card.
//
// One more than the strip shows, which is what makes "… and 2 more" say two
// rather than "more": the renderer needs to know the size of what it dropped,
// and a plan larger than this is a plan whose exact size has stopped being the
// interesting fact about it.
const PlanLimit = 16

// Fetch reads the card's view of the work behind it.
//
// At most three reads, and none at all for a card with no agent behind it:
// work that never opened a Coop session has no narrated interior. Where there
// is a session the tail is read whether or not a turn is running now, because
// the totals outlive the window — they become the ledger step's receipt the
// moment the turn stops, and the plan outlives it the same way.
//
// A read that fails returns what is known so far beside the error. The caller
// is rendering a card, and a card missing its window is a detail short; a card
// that failed to render is an operator with nothing.
func Fetch(
	ctx context.Context,
	tail Tail,
	findings Findings,
	plan Plan,
	incident core.Incident,
) (slackui.LiveTurn, error) {
	if incident.CoopSessionID == "" {
		return slackui.LiveTurn{}, nil
	}
	active := incident.ActiveTurnID != ""
	moments, err := tail.TailForIncident(ctx, incident.ID, WindowLines)
	if incident.IsEngineeringTask() {
		if cumulative, ok := tail.(cumulativeWorkTail); ok {
			moments, err = cumulative.TailForWork(ctx, incident.ID, WindowLines)
		}
	}
	if err != nil {
		return slackui.LiveTurn{Active: active}, err
	}
	// Nothing narrated and nothing running: there is no window to fill, no
	// receipt to write and no plan to have been made, so the reads below would
	// answer questions this card is not going to ask.
	if moments.Recorded == 0 && !active {
		return slackui.LiveTurn{Active: active}, nil
	}
	evidence, evidenceErr := findings.SummarizeIncidentEvidence(ctx, incident.ID)
	turn := Project(moments, evidence, active)
	// The plan is the third read and the least load-bearing of the three, so
	// its failure is reported beside a turn that still has its window and its
	// counters rather than replacing them. A card missing its checklist is a
	// card; a card that failed to render is an operator with nothing.
	goals, planErr := plan.GoalsForIncident(ctx, incident.ID, PlanLimit)
	turn.Plan = ProjectPlan(goals)
	return turn, errors.Join(evidenceErr, planErr)
}

// ProjectPlan folds stored goals into the checklist a card shows.
//
// The state travels as the store wrote it. Choosing a glyph here would put the
// card's vocabulary in the package that reads the database, and the renderer
// already owns every other column of that strip.
func ProjectPlan(goals []core.EpisodeGoal) []slackui.PlanStep {
	if len(goals) == 0 {
		return nil
	}
	plan := make([]slackui.PlanStep, 0, len(goals))
	for _, goal := range goals {
		plan = append(plan, slackui.PlanStep{
			Label: firstLine(goal.RequestedOutcome),
			State: string(goal.State),
		})
	}
	return plan
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
//
// A tool call is read by what its payload is rather than by what the runtime
// titled it, because the titles are about the tool and the operator is asking
// about the call: `mcp.emisar.run_action` is `emisar vl.query` and the query it
// ran, and `Read file '/Users/…/remote-bf1a…/terraform/apps_cms.tf'` is `Read
// file` and `terraform/apps_cms.tf`. Both facts were on disk the whole time the
// window was saying `Terminal ×2` and `Read File`.
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
		// The specific readings run first, in the order of how much a payload
		// says about itself: an MCP envelope names its own call, a file tool
		// names a path, a search names what it looked for. Each answers only
		// when it found that thing, so a row none of them recognises falls
		// through to the shell reading below and renders as it always did.
		if label, argument, ok := mcpToolCall(moment.Detail); ok {
			return slackui.ActivityLine{Kind: kind, Title: label, Target: argument}, true
		}
		if verb, path, ok := fileToolCall(title, moment.ToolKind, moment.Detail); ok {
			return slackui.ActivityLine{Kind: kind, Title: verb, Target: path}, true
		}
		if query, ok := searchToolCall(title, moment.ToolKind); ok {
			return slackui.ActivityLine{Kind: kind, Title: searchLabel, Target: query}, true
		}
		target := packRef(moment.Detail)
		raw := ""
		if isExec(moment.ToolKind) {
			raw = shellCommand(moment.Detail)
			// The start of a shell call is not always the moment that knows
			// what ran. A Claude runtime sends title "Terminal" and an input of
			// {} when the call opens and names the command only when it
			// settles, so the payload reading above finds nothing and the
			// window said "Terminal" three times about three different
			// commands. The settled title is that same call's later moment, and
			// it is used only when it says more than the placeholder did.
			if raw == "" && !uninformativeTitle(moment.SettledTitle, moment.ToolKind) {
				raw = moment.SettledTitle
			}
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
// each runtime's own, not Ryker's — but it stays here because only this
// package asks the question: it decides whether a payload's `command` is a
// command, and nothing counts exec calls in SQL.
var execToolKinds = []string{
	"execute", "exec", "terminal", "bash", "shell", "command", "run",
}

func isExec(kind string) bool {
	return slices.Contains(execToolKinds, strings.ToLower(strings.TrimSpace(kind)))
}

// readToolKinds are the tool kinds whose subject is a path but which change
// nothing. The kinds that do change one are core.EditToolKinds, and both halves
// are asked the same question here — where is the file — so isFile is the two
// lists together rather than a third list that would have to be kept level with
// them.
var readToolKinds = []string{"read", "read_file", "readfile", "move", "rename"}

func isFile(kind string) bool {
	return isEdit(kind) ||
		slices.Contains(readToolKinds, strings.ToLower(strings.TrimSpace(kind)))
}

// searchToolKinds are the tool kinds that look for a string rather than open a
// file. Live rows only ever say `search`; the rest are the same runtimes' other
// names for it, matched loosely for the reason execToolKinds is.
var searchToolKinds = []string{"search", "grep", "glob", "find"}

func isSearch(kind string) bool {
	return slices.Contains(searchToolKinds, strings.ToLower(strings.TrimSpace(kind)))
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
// It is now the fallback rather than the first answer: a payload that names its
// server and tool is read by mcpToolCall, which has the action and the
// arguments to say what this one call did, and a pack ref is the same string on
// every call made through that pack. This is what is left for a payload that
// names a pack and nothing else.
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

// mcpToolCall names an MCP call the way the operator who asked for it would.
//
// The stored title is the transport's — `mcp.emisar.run_action`, the same
// string for every action a pack has — and the call's own identity is two levels
// inside the payload: which server, which action, and what it was aimed at. A
// window of those titles said "an MCP tool was called" three times about three
// different investigations.
//
// The envelope and its field names are the ones webui's activityCall reads for
// the episode table. It is the same stored payload and two readings of it would
// drift into two accounts of one call.
func mcpToolCall(detail json.RawMessage) (label, argument string, ok bool) {
	input := toolInput(detail)
	if len(input) == 0 {
		return "", "", false
	}
	var envelope struct {
		Server    string          `json:"server"`
		Tool      string          `json:"tool"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if json.Unmarshal(input, &envelope) != nil || envelope.Server == "" || envelope.Tool == "" {
		return "", "", false
	}
	var call struct {
		ActionID string          `json:"action_id"`
		Args     json.RawMessage `json:"args"`
	}
	_ = json.Unmarshal(envelope.Arguments, &call)
	// The action is what ran; the tool is the door it ran through. `run_action`
	// on its own is true of most of the calls on disk.
	operation := call.ActionID
	if operation == "" {
		operation = envelope.Tool
	}
	argument = argumentTarget(call.Args)
	if argument == "" {
		argument = argumentTarget(envelope.Arguments, envelopeArgumentSkip...)
	}
	return firstLine(envelope.Server + " " + operation), firstLine(argument), true
}

// toolInput unwraps the stored `{"input": …}` envelope, treating an input that
// carries nothing as absent — which is most rows: several adapters record the
// envelope for MCP calls only, so `{"input":{}}` is what a read, an edit or a
// search leaves behind.
func toolInput(detail json.RawMessage) json.RawMessage {
	if len(detail) == 0 {
		return nil
	}
	var wrapper struct {
		Input json.RawMessage `json:"input"`
	}
	if json.Unmarshal(detail, &wrapper) != nil {
		return nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(wrapper.Input, &fields) != nil || len(fields) == 0 {
		return nil
	}
	return wrapper.Input
}

// argumentKeyOrder is the order in which a call's arguments are asked which of
// them is the target. A url or a query names what the call reached for; a limit
// or a timeout is how it asked.
var argumentKeyOrder = []string{"url", "query", "path", "target", "name", "id"}

// envelopeArgumentSkip are the keys that say the same thing on every call made
// through one pack, or are prose about the call rather than the call. Same list
// webui skips, for the same reason: what is left is what differs between two
// rows in the window.
var envelopeArgumentSkip = []string{
	"action_id", "pack_ref", "runner_refs", "reason", "wait",
}

// argumentTarget picks the one argument the card has room for.
//
// The order is fixed end to end — named keys, then any string in sorted order,
// then a number or a bool — because a map range is not, and a card that
// rewrites every ten seconds would show a different argument each time from the
// same stored row.
func argumentTarget(object json.RawMessage, skip ...string) string {
	var fields map[string]json.RawMessage
	if len(object) == 0 || json.Unmarshal(object, &fields) != nil {
		return ""
	}
	omit := make(map[string]bool, len(skip))
	for _, key := range skip {
		omit[key] = true
	}
	names := make([]string, 0, len(fields))
	for name := range fields {
		if !omit[name] {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	for _, name := range argumentKeyOrder {
		if omit[name] {
			continue
		}
		if value, _ := argumentScalar(fields[name]); value != "" {
			return value
		}
	}
	for _, name := range names {
		if value, isText := argumentScalar(fields[name]); isText && value != "" {
			return value
		}
	}
	for _, name := range names {
		if value, _ := argumentScalar(fields[name]); value != "" {
			return value
		}
	}
	return ""
}

// argumentScalar reads one argument as text, and says whether it was a string.
//
// An object or an array is not an answer: the card has one column and a nested
// payload would fill it with punctuation. A number or a bool is an answer only
// when nothing better was passed, which is what the second return says.
func argumentScalar(raw json.RawMessage) (value string, isText bool) {
	if len(raw) == 0 {
		return "", false
	}
	var decoded any
	if json.Unmarshal(raw, &decoded) != nil {
		return "", false
	}
	switch typed := decoded.(type) {
	case string:
		return strings.TrimSpace(typed), true
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64), false
	case bool:
		return strconv.FormatBool(typed), false
	}
	return "", false
}

// fileToolCall splits a file tool's row into what it did and what it did it to.
//
// The path is in the title on disk and nowhere else — every read and edit
// payload stored is `{"input":{}}` — so `Read file '/Users/…/apps_cms.tf'` is
// one string holding two facts, of which the second is the one that differs
// between rows. A row that names no path keeps its title whole: nine reads on
// disk are titled `Read File` and carry nothing at all, and there is nothing to
// make of that but the words.
func fileToolCall(
	title, toolKind string, detail json.RawMessage,
) (verb, path string, ok bool) {
	if !isFile(toolKind) {
		return "", "", false
	}
	verb, path = splitTitlePath(title)
	if path == "" {
		if path = detailPath(detail); path == "" {
			return "", "", false
		}
		verb = title
	}
	path = shortenPath(path)
	if verb == "" {
		// A title that was only a path leaves nothing to label the row with,
		// and a line with no title is dropped rather than shown. The path is a
		// worse label than a verb and a better one than nothing.
		return path, "", true
	}
	return verb, path, true
}

// splitTitlePath separates the verb of a file tool's title from the path in it.
//
// A quoted run is the path outright: that is how the runtimes write it. An
// unquoted one is only taken from the end of the title and only when it has a
// separator in it, because `Read File` also ends in a word and calling `File` a
// path would put a noun on the card that names nothing.
func splitTitlePath(title string) (verb, path string) {
	if inner, rest, found := quotedRun(title); found {
		return trimVerb(rest), inner
	}
	fields := strings.Fields(title)
	if len(fields) == 0 {
		return title, ""
	}
	last := fields[len(fields)-1]
	if !strings.Contains(last, "/") {
		return title, ""
	}
	return trimVerb(strings.TrimSuffix(title, last)), last
}

// trimVerb drops the punctuation that was holding the path on: `Read file:` and
// `Edit —` are the same label as `Read file` and `Edit` with the argument gone.
func trimVerb(value string) string {
	return strings.TrimRight(strings.TrimSpace(value), " :-–—,")
}

// detailPath reads a path out of a tool payload that sent one.
//
// No row on disk does: every read, edit and search payload recorded is either
// absent or `{"input":{}}`, and the path is in the title. This is here for the
// runtimes that do record their arguments, and is deliberately not the only way
// a path reaches the card — writing this and stopping would have left the rows
// that exist rendering exactly as they did.
func detailPath(detail json.RawMessage) string {
	if len(detail) == 0 {
		return ""
	}
	var envelope struct {
		Input struct {
			Path     string `json:"path"`
			FilePath string `json:"file_path"`
			Target   string `json:"target"`
		} `json:"input"`
	}
	if json.Unmarshal(detail, &envelope) != nil {
		return ""
	}
	for _, value := range []string{
		envelope.Input.Path, envelope.Input.FilePath, envelope.Input.Target,
	} {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

// pathTargetRunes is how much of a path the target column has.
//
// The renderer's line is 46 runes and it truncates from the right, which is the
// wrong end of a path: an absolute checkout path is prefix for its first forty
// characters, so `/Users/andrewdryga/Projects/blitz/blitz-in…` is a line that
// spent itself saying where the agent works. A glyph, a verb the length of
// `Read file` and the gaps between them leave this, and the shortening spends
// it on the end of the path instead.
const pathTargetRunes = 32

// shortenPath cuts a path down to the part that says which file.
//
// Two prefixes are dropped outright because they are the same on every row of a
// turn: the checkout Coop made for a fork (`remote-<hex>`), and the repository
// directory under `repositories`. What is left is the path as the repository
// itself writes it — `terraform/apps_cms.tf` — which is the form the operator
// would type. Anything still too long keeps its tail, marked, because the file
// name is at that end.
func shortenPath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	if trimmed := strings.TrimSuffix(path, "/"); trimmed != "" {
		path = trimmed
	}
	path = workspaceRelative(path)
	if utf8.RuneCountInString(path) <= pathTargetRunes {
		return path
	}
	segments := strings.Split(path, "/")
	if len(segments) == 1 {
		// One long name with nothing to drop off the front of it. The marker
		// would claim a cut that did not happen.
		return path
	}
	tail := segments[len(segments)-1]
	for index := len(segments) - 2; index > 0; index-- {
		candidate := strings.Join(segments[index:], "/")
		if utf8.RuneCountInString(candidate)+2 > pathTargetRunes {
			break
		}
		tail = candidate
	}
	return "…/" + tail
}

// workspaceRelative drops the part of a path that is where the work happens
// rather than what was worked on. The scan runs from the right so that a
// checkout inside a checkout resolves to the inner one.
func workspaceRelative(path string) string {
	segments := strings.Split(path, "/")
	for index := len(segments) - 2; index >= 0; index-- {
		switch {
		case isCheckoutDir(segments[index]):
			return strings.Join(segments[index+1:], "/")
		case segments[index] == "repositories" && index+2 < len(segments):
			return strings.Join(segments[index+2:], "/")
		}
	}
	return path
}

// isCheckoutDir reports that a directory is a checkout Coop made rather than one
// a person named. The hex id is what makes the difference: `remote-config` is a
// directory in a repository and `remote-bf1a4735b267827eceebd9f1` is the
// repository.
func isCheckoutDir(segment string) bool {
	id, found := strings.CutPrefix(segment, "remote-")
	if !found || len(id) < 16 {
		return false
	}
	for index := 0; index < len(id); index++ {
		switch char := id[index]; {
		case char >= '0' && char <= '9', char >= 'a' && char <= 'f':
		default:
			return false
		}
	}
	return true
}

// searchLabel is what a search row is called once the pattern moved out of its
// title. It is deliberately short: monoLines sizes the label column from the
// widest label in the window and squeezes the target column first, so a longer
// one here — `Search in blitz-app-svelte` — would take runes off the pattern on
// every other row too. The scope the title names is dropped for that reason;
// what was searched for is the fact worth the width.
const searchLabel = "Search"

// searchToolCall reads what a search looked for.
//
// The pattern is quoted in the title (`Search for 'analyzed_comps|14\.14' in
// blitz-app-svelte`) and the payload is empty, so the title is the only source.
// A title with no quoted run is left to render as it is: it is either a search
// this does not recognise or one that never named its pattern, and inventing a
// target from the rest of the sentence would say something the row does not.
func searchToolCall(title, toolKind string) (query string, ok bool) {
	if !isSearch(toolKind) {
		return "", false
	}
	inner, _, found := quotedRun(title)
	if !found {
		return "", false
	}
	return inner, true
}

// quotedRun reads the first quoted run out of a title, and what the title says
// without it.
//
// Two rules keep the run the one the runtime meant. It opens at the start of a
// word, because the apostrophe in `the agent's file 'x.ts'` would otherwise open
// a run that closes on the path's own quote and put `s file` on the card. And it
// closes at the next mark rather than the last, so `Search for 'a' in 'b'`
// yields `a` rather than everything between the ends.
func quotedRun(title string) (inner, rest string, found bool) {
	for _, mark := range []byte{'\'', '"', '`'} {
		for start := 0; start < len(title); start++ {
			if title[start] != mark || (start > 0 && !isTitleSpace(title[start-1])) {
				continue
			}
			end := strings.IndexByte(title[start+1:], mark)
			if end < 0 {
				break
			}
			end += start + 1
			if inner = strings.TrimSpace(title[start+1 : end]); inner == "" {
				break
			}
			rest = strings.TrimSpace(
				strings.TrimSpace(title[:start]) + " " + strings.TrimSpace(title[end+1:]),
			)
			return inner, rest, true
		}
	}
	return "", title, false
}

func isTitleSpace(char byte) bool {
	return char == ' ' || char == '\t'
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
