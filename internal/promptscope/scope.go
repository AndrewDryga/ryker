// Package promptscope decides which conditional instruction blocks a turn
// carries.
//
// A Coop turn is capped at coop.MaxPromptBytes, and whatever the instructions do
// not spend is what the model gets to see of the actual conversation. An
// operator turn was leaving 27% of its budget for context, so a rule the turn
// cannot possibly use is not free: it is a paragraph of the real thread that
// never reaches the model. The watch assembly already gates the scheduled
// occurrence, host recheck, publication correlation, channel-around-root and
// durable-behavior rules this way. These predicates gate three more.
//
// Every predicate here is deliberately biased toward inclusion, and the bias is
// the whole design. A false positive costs bytes on one turn. A false negative
// silently removes a rule the turn needed, which is a behaviour change that
// appears in no diff and no test unless someone wrote the test — so the terms,
// the verbs and the joiners below are wide on purpose, and each is checked
// against real corpus text rather than an imagined message.
package promptscope

import (
	"strings"
	"unicode"

	"github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/replypolicy"
)

// ReplyPolicy returns the reply rules this turn can use: the shape rules always,
// plus the operational-alert language rules when the target is an app message or
// carries alert text.
//
// The alert block is 2.6 KiB teaching the difference between an app's
// notification state and the actual service state — how to open a recovery, what
// an acknowledgement is not, why a RESOLVED card does not prove recovery. A
// human asking "what is the disk usage on nomad-hvn03 right now?" cannot use one
// sentence of it. replypolicy already carried the split for the incident-room
// lane, whose trigger is always a human message; this applies the same reasoning
// per turn instead of per lane.
func ReplyPolicy(senderType, text string) string {
	if alertLanguage(senderType, text) {
		return replypolicy.ReplyFormattingPolicy
	}
	return replypolicy.ReplyShapePolicy
}

// alertLanguage selects the alert-specific writing prompt. The matching
// language checker is retained only by offline evaluation as style telemetry;
// runtime correctness is validated from typed alert fields and host rendering.
//
// It is widened by the OR: a person who pastes a firing Grafana card, or a
// message-shortcut turn whose selected message is an alert, gets the rules too.
// Both shapes are in the replay corpora as human senders.
func alertLanguage(senderType, text string) bool {
	return senderType == "external_app" || decision.OperationalAlertEvent(text)
}

// visualNouns are the things a generated visual is. The host already keeps a
// narrower list for recognising "send that chart again" in
// generatedVisualRetryRequest; this one adds the plurals and the words that
// appear in a first request rather than a retry.
//
// `image` earns its place despite `container image` and `ImagePullBackOff`,
// which are ordinary ops vocabulary: the tokenizer keeps ImagePullBackOff whole,
// and paying 1.2 KiB on the turns that really do discuss a container image is
// the cheap side of this trade.
var visualNouns = map[string]bool{
	"chart": true, "charts": true, "graph": true, "graphs": true,
	"plot": true, "plots": true, "meme": true, "memes": true,
	"image": true, "images": true, "picture": true, "pictures": true,
	"photo": true, "photos": true, "screenshot": true, "screenshots": true,
	"diagram": true, "diagrams": true, "figure": true, "figures": true,
	"infographic": true, "infographics": true, "visual": true, "visuals": true,
	"visualize": true, "visualise": true, "visualization": true, "visualisation": true,
	"gif": true, "gifs": true, "sparkline": true, "sparklines": true,
	"heatmap": true, "heatmaps": true, "histogram": true, "histograms": true,
	"png": true, "jpg": true, "jpeg": true, "svg": true,
}

// VisualRequest reports whether the message asks for something to look at.
//
// The capability gate is the caller's: a deployment with no visual tool must not
// send these rules at all. This answers the other half — a turn that could
// produce a visual but was never asked for one does not need the meme, alt-text
// and axis-labelling rules either.
func VisualRequest(text string) bool {
	for _, word := range words(text) {
		if visualNouns[word] {
			return true
		}
	}
	return false
}

// CompoundRequest reports whether the message carries more than one instruction.
//
// An app notification is excluded before anything is counted, because the block
// it gates opens "handle every explicit instruction in the current user
// message" and a notification issues none. Without that gate a Terraform card
// reads as three instructions: `Run notification for ...`, `Run run-UBwFp...`
// and `Run Planned - Needs Confirmation` each open with an imperative verb.
func CompoundRequest(senderType, text string) bool {
	if senderType == "external_app" {
		return false
	}
	return enumeratedItems(text) > 1 || instructionClauses(text) > 1
}

// enumeratedItems counts `1.` and `2)` list markers, which carry the compound
// asks that no verb test finds: the production feedback message "1. i told you
// to answer in thread; 2. i told you to update channel memory" is two
// instructions and neither clause opens with a verb.
//
// A marker must open its item, so a decimal (`5.625 days`, `0.050`) and a
// version (`v5@3`) do not count.
func enumeratedItems(text string) int {
	count := 0
	runes := []rune(text)
	for index := 1; index < len(runes)-1; index++ {
		if runes[index] != '.' && runes[index] != ')' {
			continue
		}
		if !unicode.IsDigit(runes[index-1]) || !unicode.IsSpace(runes[index+1]) {
			continue
		}
		start := index - 1
		for start > 0 && unicode.IsDigit(runes[start-1]) {
			start--
		}
		if start == 0 || unicode.IsSpace(runes[start-1]) {
			count++
		}
	}
	return count
}

// clauseJoiners end one instruction and begin the next without punctuation:
// "confirm the current uptime of nomad-hvn03 and record what you observed" is
// two outcomes, and the corpus is full of that shape. Longer joiners come first
// so "and then" is not consumed as "and".
var clauseJoiners = []string{
	" and then ", " and also ", " as well as ", " after that ",
	" and ", " then ", " also ", " plus ", " but ", " & ",
}

// clauseFillers are the words a clause may open with before its verb.
var clauseFillers = map[string]bool{
	"please": true, "also": true, "then": true, "and": true, "but": true,
	"so": true, "now": true, "just": true, "quickly": true, "always": true,
	"first": true, "second": true, "third": true, "next": true, "finally": true,
	"additionally": true, "plus": true, "otherwise": true, "instead": true,
	"again": true, "still": true, "actually": true, "maybe": true,
}

// requestOpeners are the words a clause asking for something opens with: an
// imperative verb, or the auxiliary that opens a question. Both count, because
// "did the restart finish, and was the failure a push timeout?" asks for two
// outcomes in one sentence and neither half is imperative.
//
// A wh-word is deliberately absent. "What is the disk usage on nomad-hvn03 right
// now?" is one question however many clauses it has, and treating `what` as an
// opener made every ordinary question compound.
var requestOpeners = map[string]bool{
	"acknowledge": true, "add": true, "analyse": true, "analyze": true,
	"answer": true, "apply": true, "ask": true, "assess": true, "audit": true,
	"build": true, "cancel": true, "change": true, "check": true, "close": true,
	"compare": true, "confirm": true, "create": true, "decide": true,
	"delete": true, "deploy": true, "describe": true, "diagnose": true,
	"disable": true, "do": true, "draft": true, "enable": true, "ensure": true,
	"explain": true, "extend": true, "fetch": true, "find": true, "finish": true,
	"fix": true, "follow": true, "generate": true, "get": true, "give": true,
	"identify": true, "ignore": true, "implement": true, "include": true,
	"inspect": true, "investigate": true, "keep": true, "list": true,
	"look": true, "make": true, "merge": true, "move": true, "note": true,
	"offer": true, "open": true, "pause": true, "ping": true, "plan": true,
	"post": true, "prepare": true, "propose": true, "publish": true,
	"pull": true, "push": true, "put": true, "read": true, "record": true,
	"remember": true, "remind": true, "remove": true, "rename": true,
	"reply": true, "report": true, "resolve": true, "respond": true,
	"restart": true, "resume": true, "review": true, "revert": true,
	"rollback": true, "run": true, "save": true, "schedule": true,
	"search": true, "send": true, "set": true, "share": true, "show": true,
	"split": true, "start": true, "stop": true, "summarise": true,
	"summarize": true, "tell": true, "test": true, "track": true,
	"trigger": true, "try": true, "update": true, "upgrade": true, "use": true,
	"validate": true, "verify": true, "watch": true, "write": true,

	"am": true, "are": true, "can": true, "could": true, "did": true,
	"does": true, "has": true, "have": true, "is": true, "may": true,
	"might": true, "must": true, "shall": true, "should": true, "was": true,
	"were": true, "will": true, "would": true,
}

// instructionClauses counts the clauses that ask for something.
func instructionClauses(text string) int {
	normalized := strings.ToLower(text)
	normalized = strings.ReplaceAll(normalized, "’", "'")
	normalized = strings.ReplaceAll(normalized, "n't", " not")
	for _, joiner := range clauseJoiners {
		normalized = strings.ReplaceAll(normalized, joiner, "\n")
	}
	count := 0
	for _, clause := range strings.FieldsFunc(normalized, clauseBreak) {
		if opensWithARequest(clause) {
			count++
		}
	}
	return count
}

func clauseBreak(value rune) bool {
	switch value {
	case '\n', '\r', '.', '!', '?', ';', ':', ',':
		return true
	}
	return false
}

func opensWithARequest(clause string) bool {
	tokens := words(clause)
	for len(tokens) > 0 && clauseFillers[tokens[0]] {
		tokens = tokens[1:]
	}
	return len(tokens) > 0 && requestOpeners[tokens[0]]
}

// words splits on everything that is not a letter or a digit, which keeps
// ImagePullBackOff and GraphQL whole while `image:` and `chart,` reduce to the
// word. It is the tokenizer generatedVisualRetryRequest already uses.
func words(text string) []string {
	return strings.FieldsFunc(strings.ToLower(text), func(value rune) bool {
		return !unicode.IsLetter(value) && !unicode.IsDigit(value)
	})
}
