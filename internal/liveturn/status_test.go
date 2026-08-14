package liveturn

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

// The status beside a thread has to name this turn, not the kind of turn.
//
// Cost: on the tenant instance one episode recorded 596 tool.started, 594
// tool.completed and 247 model.thought rows while the thread status said "is
// gathering and reconciling evidence…" — a sentence that is true of every
// investigation ever run — rewritten every two minutes to say it again. The
// stream that could have said which call was already on disk and already being
// read by the card two lines below the status.
func TestStatusNamesTheCallInsteadOfTheKindOfWork(t *testing.T) {
	cases := []struct {
		name      string
		tail      core.AgentActivityTail
		want      string
		wantFound bool
	}{{
		name: "an MCP call is named by its action, not its transport",
		tail: core.AgentActivityTail{
			ToolCalls: 3,
			Lines: []core.AgentActivity{toolMoment(
				"mcp.emisar.run_action", "mcp",
				`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
			)},
		},
		want: "is running emisar vl.query", wantFound: true,
	}, {
		name: "a file read is about its path",
		tail: core.AgentActivityTail{
			ToolCalls: 2,
			Lines: []core.AgentActivity{
				toolMoment("Read file '/Users/x/remote-bf1a4735b267827eceebd9f1/terraform/apps_cms.tf'", "read", ""),
			},
		},
		want: "is reading terraform/apps_cms.tf", wantFound: true,
	}, {
		name: "an edit says so",
		tail: core.AgentActivityTail{
			ToolCalls: 1,
			Lines:     []core.AgentActivity{toolMoment("Edit 'internal/service/input.go'", "edit", "")},
		},
		want: "is editing internal/service/input.go", wantFound: true,
	}, {
		name: "a shell call is the command it ran, not the word Terminal",
		tail: core.AgentActivityTail{
			ToolCalls: 4,
			Lines: []core.AgentActivity{toolMoment(
				"Terminal", "execute", `{"input":{"command":"go test ./internal/service"}}`,
			)},
		},
		want: "is running go test ./internal/service", wantFound: true,
	}, {
		name: "a thought is the summary, never the reasoning",
		tail: core.AgentActivityTail{
			ToolCalls: 2,
			Lines: []core.AgentActivity{{
				Kind: coop.EventModelThought, Title: "Reasoning",
				Detail: json.RawMessage(`{"text":"Checking the Data API timeouts\nagainst the deploy"}`),
			}},
		},
		want: "is thinking — Checking the Data API timeouts", wantFound: true,
	}, {
		name: "the count earns its clause at five calls",
		tail: core.AgentActivityTail{
			ToolCalls: 54,
			Lines: []core.AgentActivity{toolMoment(
				"mcp.emisar.run_action", "mcp",
				`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
			)},
		},
		want: "is running emisar vl.query · 54 tool calls", wantFound: true,
	}, {
		name: "and does not below it",
		tail: core.AgentActivityTail{
			ToolCalls: 4,
			Lines:     []core.AgentActivity{toolMoment("Edit 'go.mod'", "edit", "")},
		},
		want: "is editing go.mod", wantFound: true,
	}, {
		// The whole point of reporting false rather than a phrase: the caller
		// keeps the status it would have set, so a turn that has not started
		// narrating is not described by a guess about a call that never
		// happened.
		name: "nothing recorded leaves the static status in place",
		tail: core.AgentActivityTail{ToolCalls: 0},
	}, {
		name: "nothing displayable does too",
		tail: core.AgentActivityTail{
			ToolCalls: 2, Recorded: 9,
			Lines: []core.AgentActivity{{Kind: coop.EventToolCompleted, Title: "Terminal"}},
		},
	}}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			status, ok := Status(test.tail)
			if ok != test.wantFound {
				t.Fatalf("found = %t, want %t (status %q)", ok, test.wantFound, status)
			}
			if status != test.want {
				t.Fatalf("status = %q, want %q", status, test.want)
			}
		})
	}
}

// A status that does not fit is not a longer status.
//
// slackui.Client.SetProgress cuts the field to 100 bytes with no marker, so an
// unbounded phrase does not overflow — it silently loses its last words, and a
// truncated command reads as a different command. The bound is enforced here,
// before the string is ever queued.
func TestStatusFitsTheFieldSlackActuallyHas(t *testing.T) {
	long := strings.Repeat("reconciling the workload against the declared revision ", 12)
	cases := []core.AgentActivityTail{{
		ToolCalls: 617,
		Lines:     []core.AgentActivity{toolMoment(long, "execute", "")},
	}, {
		ToolCalls: 617,
		Lines: []core.AgentActivity{{
			Kind: coop.EventModelThought, Title: "Reasoning",
			Detail: json.RawMessage(`{"text":"` + long + `"}`),
		}},
	}, {
		ToolCalls: 8,
		Lines: []core.AgentActivity{toolMoment(
			"Terminal", "execute", `{"input":{"command":"`+long+`"}}`,
		)},
	}}
	for index, tail := range cases {
		status, ok := Status(tail)
		if !ok {
			t.Fatalf("case %d produced no status", index)
		}
		if runes := utf8.RuneCountInString(status); runes > StatusMaxRunes || runes > 130 {
			t.Fatalf("case %d status is %d runes: %q", index, runes, status)
		}
		if len(status) > 100 {
			t.Fatalf("case %d status is %d bytes, past Slack's field: %q", index, len(status), status)
		}
	}
}

// The count is the one clause that never gives way.
//
// It is the only number in the line the card's window does not already show,
// and eight characters cannot be the reason a status does not fit — so the
// phrase is shortened around it rather than the other way round.
func TestStatusKeepsTheCountWhenThePhraseWillNotFit(t *testing.T) {
	status, ok := Status(core.AgentActivityTail{
		ToolCalls: 119,
		Lines: []core.AgentActivity{toolMoment(
			strings.Repeat("verify-the-declared-revision-", 9), "execute", "",
		)},
	})
	if !ok {
		t.Fatal("no status")
	}
	if !strings.HasSuffix(status, "· 119 tool calls") {
		t.Fatalf("the count was truncated away: %q", status)
	}
	if !strings.Contains(status, "…") {
		t.Fatalf("the phrase was not marked as cut: %q", status)
	}
}

// A pack ref carries a 64-character digest, and the status field is 100 bytes.
//
// The window on the card strips it in the renderer. A status never passes
// through the message sanitizer — it is a delivery field, not a message body —
// so stripping it there and stopping would have left the whole status being one
// immutable reference and nothing about the work.
func TestStatusNeverCarriesAPackDigest(t *testing.T) {
	// A payload that names a pack and nothing else: no server and no tool, so
	// the MCP reading declines and the pack ref is what is left to say which
	// call this was. That is the one path a digest can reach the line by.
	status, ok := Status(core.AgentActivityTail{
		ToolCalls: 6,
		Lines: []core.AgentActivity{toolMoment("Query metrics", "query",
			`{"input":{"arguments":{"pack_ref":"victoriametrics@0.1.7/sha256:2cb5c4d9e8f70a1b3c5d7e9f0a2b4c6d8e0f1a3b5c7d9e1f3a5b7c9d1e3f5a7b"}}}`,
		)},
	})
	if !ok {
		t.Fatal("no status")
	}
	if strings.Contains(status, "sha256") {
		t.Fatalf("the digest reached the status: %q", status)
	}
	if !strings.Contains(status, "victoriametrics@0.1.7") {
		t.Fatalf("the readable half of the ref was lost too: %q", status)
	}
}

// A credential in a transcript must not be relayed by the one string that
// bypasses Sanitizer.Message.
func TestStatusRedactsCredentialShapesTheSanitizerWouldHaveCaught(t *testing.T) {
	status, ok := Status(core.AgentActivityTail{
		ToolCalls: 5,
		Lines: []core.AgentActivity{toolMoment("Terminal", "execute",
			`{"input":{"command":"curl -H 'token: xoxb-2222222222-3333333333-abcdefghijklmnop'"}}`,
		)},
	})
	if !ok {
		t.Fatal("no status")
	}
	if strings.Contains(status, "xoxb-") {
		t.Fatalf("a token reached the status: %q", status)
	}
}

// The host's own checkin row gets the same reading, with the totals the feed
// has room for and the status does not.
func TestProgressCarriesWhatWasLastDoneAndTheTotals(t *testing.T) {
	tail := core.AgentActivityTail{
		ToolCalls: 54,
		Lines: []core.AgentActivity{toolMoment(
			"mcp.emisar.run_action", "mcp",
			`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
		)},
	}
	got, ok := Progress(tail, 2)
	if !ok {
		t.Fatal("no progress context")
	}
	if got != "last: emisar vl.query · 54 tool calls · 2 evidence" {
		t.Fatalf("progress = %q", got)
	}
	// Unlike the status, one tool call is still worth counting here: the feed
	// row is read later, next to the row before it, and "1" against "54" is the
	// comparison the whole line exists for. The verb is kept for the same
	// reason — out of context "Edit go.mod" says what "go.mod" does not.
	single, ok := Progress(core.AgentActivityTail{
		ToolCalls: 1,
		Lines:     []core.AgentActivity{toolMoment("Edit 'go.mod'", "edit", "")},
	}, 0)
	if !ok || single != "last: Edit go.mod · 1 tool calls" {
		t.Fatalf("single-call progress = %q, %t", single, ok)
	}
	if _, ok := Progress(core.AgentActivityTail{}, 0); ok {
		t.Fatal("an empty tail produced progress context")
	}
}

func toolMoment(title, kind, detail string) core.AgentActivity {
	moment := core.AgentActivity{
		Kind: coop.EventToolStarted, Title: title, ToolKind: kind,
	}
	if detail != "" {
		moment.Detail = json.RawMessage(detail)
	}
	return moment
}
