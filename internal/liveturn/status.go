package liveturn

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// StatusMaxRunes bounds the derived Slack assistant status.
//
// Slack's assistant status field is 100 bytes and slackui.Client.SetProgress
// cuts to it without a marker, so a longer line is not a longer status — it is
// the same status with its last words missing and nothing saying so. This is
// the smaller of the two bounds on purpose: what leaves this package already
// fits, so the cut never happens.
const StatusMaxRunes = 96

// statusToolCallFloor is when the count is worth its own clause.
//
// Below it the number says less than the line it would be shortening. "is
// running goimports · 2 tool calls" spends eleven characters telling an
// operator the turn has barely started, which the card already shows and the
// status has no room to repeat.
const statusToolCallFloor = 5

// statusThoughtRunes bounds a reasoning summary inside the status.
const statusThoughtRunes = 60

// Status folds a turn's recorded interior into the assistant status Slack shows
// beside the thread.
//
// It exists for the same measured failure the rest of this package does, at the
// other end of it: while 596 tool calls were being recorded, the status said
// "is gathering and reconciling evidence…" — a sentence true of every turn ever
// run, refreshed every two minutes to say it again. The stream underneath was
// already specific and already on disk.
//
// It reports false when there is nothing displayable, which is what keeps the
// static status in place rather than replacing it with a guess. A turn that has
// recorded nothing yet has not started narrating, and "is running" about no
// call would be worse than the general sentence it replaced.
func Status(tail core.AgentActivityTail) (string, bool) {
	moment, ok := latestLine(tail)
	if !ok {
		return "", false
	}
	status := statusPhrase(moment)
	if status == "" {
		return "", false
	}
	suffix := ""
	if tail.ToolCalls >= statusToolCallFloor {
		suffix = fmt.Sprintf(" · %d tool calls", tail.ToolCalls)
	}
	return boundStatus(status, suffix), true
}

// Progress is the activity clause the host adds to its own checkin prose.
//
// Same reading as Status and deliberately not the same sentence: a status is
// the present tense beside a thread, and this is a line in the episode feed
// that will still be read tomorrow. So this one names what was last done rather
// than what is being done, and carries the totals whatever they are — the feed
// row is where "54 tool calls · 2 evidence" is the whole point, not a clause
// that has to earn its width against a 100-byte bound.
//
// It reports false when the turn has narrated nothing displayable, which leaves
// the host's own sentence exactly as it was.
func Progress(tail core.AgentActivityTail, evidence int) (string, bool) {
	parts := make([]string, 0, 3)
	if moment, ok := latestLine(tail); ok {
		if subject := statusSubject(moment); subject != "" {
			parts = append(parts, "last: "+subject)
		}
	}
	if tail.ToolCalls > 0 {
		parts = append(parts, fmt.Sprintf("%d tool calls", tail.ToolCalls))
	}
	if evidence > 0 {
		parts = append(parts, fmt.Sprintf("%d evidence", evidence))
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, " · "), true
}

// latestLine is the newest moment worth showing.
//
// Tail lines are newest first and already filtered to the displayable kinds,
// but Line is what decides whether a row says anything — a shell call with no
// command and a tool-shaped title makes no line — so the walk continues past
// the ones it refuses rather than falling back to the static status because the
// newest row happened to be empty.
func latestLine(tail core.AgentActivityTail) (slackui.ActivityLine, bool) {
	for _, moment := range tail.Lines {
		if line, ok := Line(moment); ok {
			return line, true
		}
	}
	return slackui.ActivityLine{}, false
}

// statusPhrase is the verb and its object, in the grammar Slack's status line
// expects: it renders as "Emisar <status>", so every phrase here begins with a
// verb in the third person and never with a capital.
func statusPhrase(line slackui.ActivityLine) string {
	if line.Kind == slackui.ActivityThinking {
		thought := statusText(line.Title, statusThoughtRunes)
		if thought == "" {
			return ""
		}
		return "is thinking — " + thought
	}
	subject := statusSubject(line)
	if subject == "" {
		return ""
	}
	// A verb taken from the title must not then be followed by the title. `Edit
	// 'input.go'` arrives split into `Edit` and the path, and "is editing Edit
	// input.go" is the harness narrating itself — the exact stutter the window
	// below the status was built to stop.
	verb, titleIsVerb := statusVerb(line)
	if titleIsVerb {
		if target := statusText(line.Target, statusSubjectRunes); target != "" {
			subject = target
		} else {
			// The title is all there is, so it is the object rather than the
			// verb, and the general verb goes in front of it.
			verb = "is running"
		}
	}
	return verb + " " + subject
}

// statusVerb reads what kind of act the call was, and says whether the title
// was what told it.
//
// The verb comes from the line's own title because that is where the runtimes
// put it — a file tool is titled `Read file`, an edit `Edit` — and a card that
// said "is running Read file" would be narrating the tool harness rather than
// the work. Anything unrecognised runs, which is true of every tool call.
func statusVerb(line slackui.ActivityLine) (verb string, titleIsVerb bool) {
	if line.Kind == slackui.ActivityEdit {
		return "is editing", true
	}
	if statusReadTitle(line.Title) {
		return "is reading", true
	}
	return "is running", false
}

// statusReadTitle reports that a title is a file tool's verb rather than the
// name of the thing it ran. Matched on the first word so that `Read file`,
// `Read File` and `Reading` are one answer.
func statusReadTitle(title string) bool {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(title)))
	if len(fields) == 0 {
		return false
	}
	switch fields[0] {
	case "read", "reading", "open", "opening", "view", "cat":
		return true
	}
	return false
}

// statusSubject is what the line is about, whole.
//
// Where both halves are worth saying — an MCP action and what it was aimed at
// — they are joined, and the join is dropped rather than truncated when the
// pair will not fit: half an argument is not a shorter fact, it is a different
// one. The caller drops the title when its own verb already said it; this
// keeps it, because the progress row that also calls this is read later and out
// of context, where "Edit go.mod" says more than "go.mod".
func statusSubject(line slackui.ActivityLine) string {
	title := statusText(line.Title, StatusMaxRunes)
	target := statusText(line.Target, StatusMaxRunes)
	switch {
	case title == "" && target == "":
		return ""
	case title == "":
		return target
	case target == "":
		return title
	}
	joined := title + " " + target
	if utf8.RuneCountInString(joined) > statusSubjectRunes {
		return title
	}
	return joined
}

// statusSubjectRunes is how much of the line a subject may claim before the
// argument beside it is dropped. Sized so a verb, the count clause and the
// subject together still clear the bound without the final cut ever firing.
const statusSubjectRunes = 52

// statusText is the bound every transcript string passes on its way to the
// status.
//
// The pack digest is stripped here rather than by the card sanitizer because
// the status never passes through it: a status is a delivery field, not a
// message body, so `victoriametrics@0.1.7/sha256:<64 hex>` would arrive whole
// at a 100-byte field and be the entire status.
func statusText(value string, limit int) string {
	value = strings.TrimSpace(slackui.SanitizeActivityText(firstLine(value)))
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	return string([]rune(value)[:max(limit-1, 0)]) + "…"
}

// boundStatus fits the phrase and its count clause into the field.
//
// The count is never what gives way. It is the one number in the line that the
// window on the card does not already show, and a clause of eight characters
// cannot be the reason a status does not fit — so the phrase is shortened
// around it.
func boundStatus(status, suffix string) string {
	room := StatusMaxRunes - utf8.RuneCountInString(suffix)
	if utf8.RuneCountInString(status) > room {
		status = string([]rune(status)[:max(room-1, 0)]) + "…"
	}
	return status + suffix
}
