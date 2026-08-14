package liveturn

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// The rows in these tests are copied from responder.db as they are stored, not
// invented: the shapes are what decides the rendering, and a fixture written
// from the shape this package hopes for would pass while the card kept saying
// "Terminal".
func toolStarted(title, toolKind, detail string) core.AgentActivity {
	moment := core.AgentActivity{
		Kind: coop.EventToolStarted, Title: title, ToolKind: toolKind,
	}
	if detail != "" {
		moment.Detail = json.RawMessage(detail)
	}
	return moment
}

// genericTerminal is the most common shell call on disk — 118 of them — and it
// carries nothing to show. It is the floor: the fix must not make a row with no
// command render worse than it did.
const (
	genericTerminalTitle  = "Terminal"
	genericTerminalDetail = `{"input":{}}`
)

func TestLineKeepsGenericTerminalRowsWhenNoCommandWasStored(t *testing.T) {
	for index := range 3 {
		line, ok := Line(toolStarted(
			genericTerminalTitle, "execute", genericTerminalDetail,
		))
		if !ok {
			t.Fatalf("row %d dropped", index)
		}
		if line.Title != "Terminal" || line.Kind != slackui.ActivityTool {
			t.Fatalf("row %d = %+v", index, line)
		}
		if line.Target != "" {
			t.Fatalf("row %d invented a target: %q", index, line.Target)
		}
	}
}

func TestLineShowsCommandWhenTitleOnlyNamesTheTool(t *testing.T) {
	line, ok := Line(toolStarted("Terminal", "execute",
		`{"input":{"command":"git -C /coop/repositories/tenant-app-svelte show --stat","cwd":"/coop"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	want := "git -C /coop/repositories/tenant-app-svelte show --stat"
	if line.Title != want {
		t.Fatalf("title = %q, want %q", line.Title, want)
	}
	// The command is the label, not a second column beside the tool's name:
	// "Terminal git -C …" would be the same duplication with more words.
	if line.Target != "" {
		t.Fatalf("target = %q, want the command as the label only", line.Target)
	}
}

// A wrapped call arrives escaped twice over, and the runtime titles it with the
// inner quoted string verbatim. Both are the same command; one is readable.
func TestLineUnwrapsWrappedCommandStoredAsItsOwnTitle(t *testing.T) {
	title := `"sed -n '938,960p' games/tft/api.ts; grep -n \"DATA_API\\|data.v2\" shared/constants/urls*"`
	detail := `{"input":{"command":"/bin/bash -lc \"sed -n '938,960p' games/tft/api.ts; grep -n \\\"DATA_API\\\\|data.v2\\\" shared/constants/urls*\"","cwd":"/coop/repositories/tenant-app-svelte/src"}}`
	line, ok := Line(toolStarted(title, "execute", detail))
	if !ok {
		t.Fatal("row dropped")
	}
	want := `sed -n '938,960p' games/tft/api.ts; grep -n "DATA_API\|data.v2" shared/constants/urls*`
	if line.Title != want {
		t.Fatalf("title = %q, want %q", line.Title, want)
	}
	if strings.Contains(line.Title, `\"`) {
		t.Fatalf("title still carries shell escaping: %q", line.Title)
	}
	if line.Title == "Terminal" {
		t.Fatalf("title = %q", line.Title)
	}
	if strings.HasPrefix(line.Title, "/bin/bash") {
		t.Fatalf("title still carries the shell wrapper: %q", line.Title)
	}
	// Same fact once. The command must not also be repeated in the target.
	if line.Target != "" {
		t.Fatalf("target = %q, want empty", line.Target)
	}
}

// The activity store bounds a title at 300 bytes and marks the cut with an
// ellipsis while the payload keeps the whole line, so the stored title is the
// command with pieces missing. Showing both would print it twice, once cut.
func TestLineReplacesTruncatedTitleWithTheWholeCommand(t *testing.T) {
	title := `"sed -n '1,40p' terraform/modules/google-cloud/elixir/server.tf; sed -n '1,35p' terraform/modules/google-cloud/elixir/outputs.tf; rg -n 'health_check_path' terraform/environments/production/app_datala…`
	detail := `{"input":{"command":"/bin/bash -lc \"sed -n '1,40p' terraform/modules/google-cloud/elixir/server.tf; sed -n '1,35p' terraform/modules/google-cloud/elixir/outputs.tf; rg -n 'health_check_path' terraform/environments/production/app_datalake.tf | head -20\"","cwd":"/coop/repositories/tenant-infra"}}`
	line, ok := Line(toolStarted(title, "execute", detail))
	if !ok {
		t.Fatal("row dropped")
	}
	if !strings.HasPrefix(line.Title, "sed -n '1,40p' terraform/modules/google-cloud/elixir/server.tf;") {
		t.Fatalf("title = %q", line.Title)
	}
	if strings.Contains(line.Title, "…") {
		t.Fatalf("title kept the store's truncation marker over the whole command: %q", line.Title)
	}
	if line.Target != "" {
		t.Fatalf("target = %q, want the command shown once", line.Target)
	}
}

// Secrets are not this package's job. liveturn bounds a line and hands it on;
// redaction belongs to internal/slackui/message_sanitizer.go, which rewrites
// credential shapes on the way to Slack, and the 46-rune squeeze belongs to the
// renderer (monospaceLineRunes). This asserts only what liveturn owns: the
// command comes through as a string, bounded at maxLineBytes.
func TestLineCarriesSecretShapedCommandForTheSanitizerToRedact(t *testing.T) {
	command := `curl -H "Authorization: Bearer xoxb-1234567890-abcdefghijklmnop" https://slack.com/api/auth.test`
	detail, err := json.Marshal(map[string]any{
		"input": map[string]any{"command": command, "cwd": "/coop"},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	line, ok := Line(toolStarted("Terminal", "execute", string(detail)))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != command {
		t.Fatalf("title = %q, want the command verbatim", line.Title)
	}
	if len(line.Title) > maxLineBytes {
		t.Fatalf("title is %d bytes, over the %d-byte bound", len(line.Title), maxLineBytes)
	}
}

func TestLineBoundsALongCommand(t *testing.T) {
	command := "rg -n " + strings.Repeat("a", 400) + " /coop"
	detail, err := json.Marshal(map[string]any{
		"input": map[string]any{"command": command},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	line, ok := Line(toolStarted("Terminal", "execute", string(detail)))
	if !ok {
		t.Fatal("row dropped")
	}
	if len(line.Title) != maxLineBytes {
		t.Fatalf("title is %d bytes, want %d", len(line.Title), maxLineBytes)
	}
	if !strings.HasPrefix(line.Title, "rg -n aaa") {
		t.Fatalf("title = %q", line.Title)
	}
}

// A heredoc or a multi-line script is one line on the card. The rest is not
// summarized, it is dropped: the window is three lines tall.
func TestLineKeepsOnlyTheFirstLineOfAMultiLineCommand(t *testing.T) {
	detail, err := json.Marshal(map[string]any{
		"input": map[string]any{"command": "cat <<'EOF' > /tmp/x\nsecond line\nthird line\nEOF"},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	line, ok := Line(toolStarted("Terminal", "execute", string(detail)))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "cat <<'EOF' > /tmp/x" {
		t.Fatalf("title = %q", line.Title)
	}
}

// An Emisar call is stored with tool_kind execute and carries no command, so
// the exec gate alone would not have kept it out. It must still name the tool
// and target the pack ref, digest and all — stripping the digest is the
// renderer's job, not this package's.
func TestLineKeepsPackRefForMCPCallWithNoCommand(t *testing.T) {
	detail := `{"input":{"arguments":{"action_id":"vl.query","args":{"limit":200,"query":"_time:[2026-08-13T23:05:00Z,2026-08-13T23:20:00Z] service:data-api | sort by (_time) asc"},"pack_ref":"victorialogs@0.1.6/sha256:db374853549b53ae2d6825453b515e128c61975d1f18ca9b007c4f116fabe59f","reason":"Inspect Data API application logs during the timeout burst","runner_refs":["nomad-hst01~f5e3a96782c44bd31186fcaa14ba6efb"],"wait":"30s"},"server":"emisar","tool":"run_action"}}`
	line, ok := Line(toolStarted("mcp.emisar.run_action", "execute", detail))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "mcp.emisar.run_action" {
		t.Fatalf("title = %q", line.Title)
	}
	want := "victorialogs@0.1.6/sha256:db374853549b53ae2d6825453b515e128c61975d1f18ca9b007c4f116fabe59f"
	if line.Target != want {
		t.Fatalf("target = %q, want %q", line.Target, want)
	}
}

// A title that says something the command does not is kept, and the command
// goes beside it. This is the only case where both are shown.
func TestLineKeepsInformativeTitleAndPutsCommandInTarget(t *testing.T) {
	line, ok := Line(toolStarted("Run the migration check", "execute",
		`{"input":{"command":"mix ecto.migrations","cwd":"/coop"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "Run the migration check" {
		t.Fatalf("title = %q", line.Title)
	}
	if line.Target != "mix ecto.migrations" {
		t.Fatalf("target = %q", line.Target)
	}
}

// A pack ref outranks a command line when a payload somehow carries both: it is
// the durable identifier, and the target column holds one thing.
func TestLinePrefersPackRefOverCommandInTarget(t *testing.T) {
	line, ok := Line(toolStarted("mcp.emisar.run_action", "execute",
		`{"input":{"command":"emisar run","arguments":{"pack_ref":"victorialogs@0.1.6/sha256:db374"}}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Target != "victorialogs@0.1.6/sha256:db374" {
		t.Fatalf("target = %q", line.Target)
	}
	if line.Title != "mcp.emisar.run_action" {
		t.Fatalf("title = %q", line.Title)
	}
}

// The kind gate is half the guard. A read or fetch tool whose payload happens
// to carry a `command` key is not a shell call, and its own title stands.
func TestLineIgnoresCommandKeyForNonExecToolKinds(t *testing.T) {
	line, ok := Line(toolStarted("Read api.ts", "read",
		`{"input":{"command":"not a shell call","path":"games/tft/api.ts"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "Read api.ts" || line.Target != "" {
		t.Fatalf("line = %+v", line)
	}
}

func TestLineFallsBackWhenDetailIsAbsentEmptyOrUnparseable(t *testing.T) {
	for name, detail := range map[string]string{
		"absent":      "",
		"empty":       `{}`,
		"no input":    `{"status":"in_progress"}`,
		"empty input": `{"input":{}}`,
		"null input":  `{"input":null}`,
		"unparseable": `{"input":{"command":`,
		"wrong type":  `{"input":{"command":["ls","-la"]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			line, ok := Line(toolStarted("Terminal", "execute", detail))
			if !ok {
				t.Fatal("row dropped")
			}
			if line.Title != "Terminal" || line.Target != "" {
				t.Fatalf("line = %+v", line)
			}
		})
	}
}

// A row with neither a title nor a command is still nothing to show.
func TestLineDropsToolCallWithNoTitleAndNoCommand(t *testing.T) {
	if line, ok := Line(toolStarted("", "execute", `{"input":{}}`)); ok {
		t.Fatalf("rendered an empty line: %+v", line)
	}
}

// A shell call with no title of its own is now renderable, where before the
// empty title dropped it.
func TestLineShowsCommandWhenTitleIsEmpty(t *testing.T) {
	line, ok := Line(toolStarted("", "bash", `{"input":{"command":"go test ./..."}}`))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "go test ./..." {
		t.Fatalf("title = %q", line.Title)
	}
}

func TestLineMapsEditToolKindToEditActivity(t *testing.T) {
	line, ok := Line(toolStarted("api.ts", "edit",
		`{"input":{"path":"games/tft/api.ts","command":"ignored"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Kind != slackui.ActivityEdit {
		t.Fatalf("kind = %q, want %q", line.Kind, slackui.ActivityEdit)
	}
	if line.Title != "api.ts" || line.Target != "" {
		t.Fatalf("line = %+v", line)
	}
}

func TestLineRendersThoughtSummaryUnchanged(t *testing.T) {
	line, ok := Line(core.AgentActivity{
		Kind:   coop.EventModelThought,
		Title:  "Reasoning",
		Detail: json.RawMessage(`{"text":"Checking the Data API timeouts\nagainst the deploy"}`),
	})
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Kind != slackui.ActivityThinking {
		t.Fatalf("kind = %q", line.Kind)
	}
	if line.Title != "Checking the Data API timeouts" {
		t.Fatalf("title = %q", line.Title)
	}
}

// The failure this change was made for: three shell calls in a row, three
// different commands, one word on the card. The assertion is that the three
// labels differ, because that is what an operator was missing.
func TestProjectShowsThreeDistinctCommandsForThreeShellCalls(t *testing.T) {
	tail := core.AgentActivityTail{
		ToolCalls: 3,
		Recorded:  4,
		Lines: []core.AgentActivity{
			toolStarted("Terminal", "execute",
				`{"input":{"command":"git -C /coop/repositories/tenant-app-svelte show --stat","cwd":"/coop"}}`),
			toolStarted(`"grep -n \"function dataURL\" games/tft/api.ts | head -20"`, "execute",
				`{"input":{"command":"/bin/bash -lc \"grep -n \\\"function dataURL\\\" games/tft/api.ts | head -20\"","cwd":"/coop/repositories/tenant-app-svelte/src"}}`),
			toolStarted("Terminal", "execute",
				`{"input":{"command":"rg -n --glob '*.ts' \"analyzed_comps\" /coop | head -40","cwd":"/coop"}}`),
			{Kind: coop.EventModelThought, Title: "Reasoning",
				Detail: json.RawMessage(`{"text":"Reading the diff first"}`)},
		},
	}
	turn := Project(tail, core.IncidentEvidence{}, true)
	if len(turn.Lines) != 4 {
		t.Fatalf("lines = %d, want 4", len(turn.Lines))
	}
	seen := map[string]int{}
	for _, line := range turn.Lines[:3] {
		if line.Title == "Terminal" {
			t.Fatalf("shell call still rendered as the tool name: %+v", turn.Lines)
		}
		seen[line.Title]++
	}
	if len(seen) != 3 {
		t.Fatalf("three shell calls rendered %d distinct labels: %v", len(seen), seen)
	}
	if turn.ToolCalls != 3 || !turn.Active {
		t.Fatalf("turn = %+v", turn)
	}
}

// Unwrapping is refused unless the whole string is one quoted run, because a
// command that merely starts and ends with a quote is not a quoted command and
// stripping its ends would change what it says.
func TestNormalizeCommandLeavesCommandsThatOnlyLookQuoted(t *testing.T) {
	for name, testCase := range map[string]struct{ in, want string }{
		"two quoted runs": {
			in:   `"echo one" && "echo two"`,
			want: `"echo one" && "echo two"`,
		},
		"unterminated": {
			in:   `sh -c "echo one`,
			want: `"echo one`,
		},
		"dangling escape": {
			in:   `"echo one\"`,
			want: `"echo one\"`,
		},
		"wrapper only": {
			in:   `/bin/bash -lc "echo one"`,
			want: `echo one`,
		},
		"no wrapper": {
			in:   `rg -n "pattern" /coop`,
			want: `rg -n "pattern" /coop`,
		},
		"sh -c wrapper": {
			in:   `/bin/sh -c "ls -la"`,
			want: `ls -la`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			if got := normalizeCommand(testCase.in); got != testCase.want {
				t.Fatalf("normalizeCommand(%q) = %q, want %q", testCase.in, got, testCase.want)
			}
		})
	}
}

func TestIsExecMatchesRuntimeVocabularyCaseInsensitively(t *testing.T) {
	for _, kind := range []string{"execute", "Execute", " EXEC ", "terminal", "bash", "shell", "command", "run"} {
		if !isExec(kind) {
			t.Fatalf("isExec(%q) = false", kind)
		}
	}
	for _, kind := range []string{"", "read", "search", "fetch", "edit", "other"} {
		if isExec(kind) {
			t.Fatalf("isExec(%q) = true", kind)
		}
	}
}
