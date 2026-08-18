package liveturn

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

// The status beside a thread says which kind of progress is happening without
// copying the transcript. Exact calls, paths, thoughts and counts belong to the
// card's work record, where they have context and room.
func TestStatusNamesProgressWithoutCopyingTheTranscript(t *testing.T) {
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
		want: "is checking evidence...", wantFound: true,
	}, {
		name: "a file read is about its path",
		tail: core.AgentActivityTail{
			ToolCalls: 2,
			Lines: []core.AgentActivity{
				toolMoment("Read file '/Users/x/remote-bf1a4735b267827eceebd9f1/terraform/apps_cms.tf'", "read", ""),
			},
		},
		want: "is inspecting the workspace...", wantFound: true,
	}, {
		name: "an edit says so",
		tail: core.AgentActivityTail{
			ToolCalls: 1,
			Lines:     []core.AgentActivity{toolMoment("Edit 'internal/service/input.go'", "edit", "")},
		},
		want: "is editing the change...", wantFound: true,
	}, {
		name: "a shell call is the command it ran, not the word Terminal",
		tail: core.AgentActivityTail{
			ToolCalls: 4,
			Lines: []core.AgentActivity{toolMoment(
				"Terminal", "execute", `{"input":{"command":"go test ./internal/service"}}`,
			)},
		},
		want: "is checking evidence...", wantFound: true,
	}, {
		name: "a thought is the summary, never the reasoning",
		tail: core.AgentActivityTail{
			ToolCalls: 2,
			Lines: []core.AgentActivity{{
				Kind: coop.EventModelThought, Title: "Reasoning",
				Detail: json.RawMessage(`{"text":"Checking the Data API timeouts\nagainst the deploy"}`),
			}},
		},
		want: "is reasoning through the evidence...", wantFound: true,
	}, {
		name: "the count earns its clause at five calls",
		tail: core.AgentActivityTail{
			ToolCalls: 54,
			Lines: []core.AgentActivity{toolMoment(
				"mcp.emisar.run_action", "mcp",
				`{"input":{"server":"emisar","tool":"run_action","arguments":{"action_id":"vl.query"}}}`,
			)},
		},
		want: "is checking evidence...", wantFound: true,
	}, {
		name: "and does not below it",
		tail: core.AgentActivityTail{
			ToolCalls: 4,
			Lines:     []core.AgentActivity{toolMoment("Edit 'go.mod'", "edit", "")},
		},
		want: "is editing the change...", wantFound: true,
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

// Twenty-three statuses in the 2026-08-17 Slack delivery ledger exposed the
// agent harness instead of useful progress: complete shell commands, checkout
// paths, and even a SKILL.md read. The detailed activity stays in the work
// record; the narrow assistant status must describe the kind of progress and
// must never relay transcript-authored command or reasoning text.
func TestThreadStatusKeepsExecutionPlumbingInTheWorkRecord(t *testing.T) {
	cases := []core.AgentActivityTail{
		{
			ToolCalls: 9,
			Lines: []core.AgentActivity{toolMoment(
				"Terminal", "execute",
				`{"input":{"command":"sed -n '1,240p' .agent/skills/work/SKILL.md && git status --short"}}`,
			)},
		},
		{
			ToolCalls: 8,
			Lines: []core.AgentActivity{{
				Kind: coop.EventModelThought, Title: "Reasoning",
				Detail: json.RawMessage(`{"text":"Correcting report to include only complete_episode"}`),
			}},
		},
	}
	for index, tail := range cases {
		status, ok := Status(tail)
		if !ok {
			t.Fatalf("case %d produced no status", index)
		}
		for _, plumbing := range []string{
			"sed -n", "SKILL.md", "git status", "complete_episode", "tool calls",
		} {
			if strings.Contains(status, plumbing) {
				t.Fatalf("case %d leaked %q in %q", index, plumbing, status)
			}
		}
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

// Counts are useful in the work record and meaningless in ambient channel
// chrome. Keeping them out also keeps the public status stable while a turn
// emits hundreds of activity moments.
func TestStatusKeepsToolCountsInTheWorkRecord(t *testing.T) {
	status, ok := Status(core.AgentActivityTail{
		ToolCalls: 119,
		Lines: []core.AgentActivity{toolMoment(
			strings.Repeat("verify-the-declared-revision-", 9), "execute", "",
		)},
	})
	if !ok {
		t.Fatal("no status")
	}
	if strings.Contains(status, "119") || strings.Contains(status, "tool calls") {
		t.Fatalf("the execution count reached the public status: %q", status)
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
	if status != "is checking evidence..." {
		t.Fatalf("tool detail reached the public status: %q", status)
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
