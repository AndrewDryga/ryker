package liveturn

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
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

// genericTerminal is the most common shell call on disk, and its own payload
// carries nothing to show. It is the floor: the fix must not make a row with no
// command render worse than it did.
//
// "Its own payload" is the whole qualifier. These rows are not commandless —
// the runtime names the command on a later moment under the same tool call id,
// and 1,249 of the 1,251 on the blitz instance could be recovered that way. The
// floor is a call that has not settled yet, which is the case below.
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
		`{"input":{"command":"git -C /coop/repositories/blitz-app-svelte show --stat","cwd":"/coop"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	want := "git -C /coop/repositories/blitz-app-svelte show --stat"
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
	detail := `{"input":{"command":"/bin/bash -lc \"sed -n '938,960p' games/tft/api.ts; grep -n \\\"DATA_API\\\\|data.v2\\\" shared/constants/urls*\"","cwd":"/coop/repositories/blitz-app-svelte/src"}}`
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
	detail := `{"input":{"command":"/bin/bash -lc \"sed -n '1,40p' terraform/modules/google-cloud/elixir/server.tf; sed -n '1,35p' terraform/modules/google-cloud/elixir/outputs.tf; rg -n 'health_check_path' terraform/environments/production/app_datalake.tf | head -20\"","cwd":"/coop/repositories/blitz-infra"}}`
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
// the exec gate alone would not have kept it out. It used to render as the
// transport's title beside the pack ref, which is the same two strings for
// every action in that pack: what the call did was the action and the query,
// both of them already in the payload.
func TestLineNamesTheActionAndItsQueryForMCPCallWithNoCommand(t *testing.T) {
	detail := `{"input":{"arguments":{"action_id":"vl.query","args":{"limit":200,"query":"_time:[2026-08-13T23:05:00Z,2026-08-13T23:20:00Z] service:data-api | sort by (_time) asc"},"pack_ref":"victorialogs@0.1.6/sha256:db374853549b53ae2d6825453b515e128c61975d1f18ca9b007c4f116fabe59f","reason":"Inspect Data API application logs during the timeout burst","runner_refs":["nomad-hvn01~f5e3a96782c44bd31186fcaa14ba6efb"],"wait":"30s"},"server":"emisar","tool":"run_action"}}`
	line, ok := Line(toolStarted("mcp.emisar.run_action", "execute", detail))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "emisar vl.query" {
		t.Fatalf("title = %q", line.Title)
	}
	want := "_time:[2026-08-13T23:05:00Z,2026-08-13T23:20:00Z] service:data-api | sort by (_time) asc"
	if line.Target != want {
		t.Fatalf("target = %q, want %q", line.Target, want)
	}
}

// The complaint this was made for: a window of `⚡ Terminal ×2` and `⚡ Read
// File`, where every row on disk knew which action it ran or which file it
// opened. One case per tool kind the ledger actually records, with the payloads
// and titles as responder.db stores them.
func TestLineSaysWhatEachToolKindDid(t *testing.T) {
	for name, testCase := range map[string]struct {
		title, toolKind, detail string
		wantKind                string
		wantTitle, wantTarget   string
	}{
		"mcp action with args": {
			title:     "mcp.emisar.run_action",
			toolKind:  "execute",
			detail:    `{"input":{"arguments":{"action_id":"vl.query","args":{"limit":20,"query":"_time:15m (\"cs2/in-game\" OR \"path_norm=cs2/in-game\") | sort by (_time) desc"},"pack_ref":"victorialogs@0.1.6/sha256:db374853549b53ae2d6825453b515e128c61975d1f18ca9b007c4f116fabe59f","reason":"Check the latest 15 minutes of in-game route traffic","runner_refs":["nomad-hvn01~f5e3a96782c44bd31186fcaa14ba6efb"],"wait":"30s"},"server":"emisar","tool":"run_action"}}`,
			wantKind:  slackui.ActivityTool,
			wantTitle: "emisar vl.query",
			// The limit is an argument too; the query is the one that says what
			// this call was looking at.
			wantTarget: `_time:15m ("cs2/in-game" OR "path_norm=cs2/in-game") | sort by (_time) desc`,
		},
		"mcp action with a url": {
			title:      "mcp.emisar.run_action",
			toolKind:   "execute",
			detail:     `{"input":{"arguments":{"action_id":"net.http_probe","args":{"max_time":15,"url":"https://blitz.gg/cs2/in-game"},"pack_ref":"network-tls@0.1.14/sha256:0c82f0b2e0a44d1e9d4b3a5c6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091","reason":"Probe the public in-game route","runner_refs":["nomad-hvn01~f5e3a96782c44bd31186fcaa14ba6efb"],"wait":"30s"},"server":"emisar","tool":"run_action"}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "emisar net.http_probe",
			wantTarget: "https://blitz.gg/cs2/in-game",
		},
		// A lookup passes no arguments of its own. The action is still the
		// answer, and the pack ref left in the envelope is not: it says which
		// pack, which is the same for every row from that pack.
		"mcp action with no args": {
			title:      "mcp.emisar.get_action",
			toolKind:   "execute",
			detail:     `{"input":{"arguments":{"action_id":"vl.query","pack_ref":"victorialogs@0.1.6/sha256:db374853549b53ae2d6825453b515e128c61975d1f18ca9b007c4f116fabe59f"},"server":"emisar","tool":"get_action"}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "emisar vl.query",
			wantTarget: "",
		},
		// Discovery names no action, so the tool is what ran.
		"mcp call with no action": {
			title:      "mcp.emisar.find_actions",
			toolKind:   "execute",
			detail:     `{"input":{"arguments":{"query":"read-only HTTP probe for CS2 in-game public user route"},"server":"emisar","tool":"find_actions"}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "emisar find_actions",
			wantTarget: "read-only HTTP probe for CS2 in-game public user route",
		},
		// A second server, whose arguments are named nothing this knows. Sorted
		// order picks one, and picks the same one every time the card rewrites.
		"mcp call to another server": {
			title:      "mcp.codex_apps.github.fetch_commit",
			toolKind:   "execute",
			detail:     `{"input":{"arguments":{"commit_sha":"1b016292e91141be46b1f23f155a2a37ac5d39e6","repo_full_name":"theblitzapp/blitz-infra"},"server":"codex_apps","tool":"github.fetch_commit"}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "codex_apps github.fetch_commit",
			wantTarget: "1b016292e91141be46b1f23f155a2a37ac5d39e6",
		},
		"read in a fork checkout": {
			title:      `Read file '/Users/andrewdryga/Projects/blitz/blitz-infra-forks/remote-bf1a4735b267827eceebd9f1/terraform/apps_cms.tf'`,
			toolKind:   "read",
			detail:     `{"input":{}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Read file",
			wantTarget: "terraform/apps_cms.tf",
		},
		"read in a coop repository": {
			title:      `Read file '/coop/repositories/blitz-app-svelte/src/games/tft/api.ts'`,
			toolKind:   "read",
			detail:     "",
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Read file",
			wantTarget: "src/games/tft/api.ts",
		},
		"read titled with a bare path": {
			title:      "Read /coop/repositories/blitz-app-svelte/src/games/tft/api.ts",
			toolKind:   "read",
			detail:     `{"input":{}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Read",
			wantTarget: "src/games/tft/api.ts",
		},
		// The apostrophe is not the opening quote. Taking it for one would end
		// the run on the path's own quote and label the row `s file`.
		"read titled with an apostrophe in it": {
			title:      `Read the agent's file '/coop/repositories/blitz-infra/terraform/apps_cms.tf'`,
			toolKind:   "read",
			detail:     `{"input":{}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Read the agent's file",
			wantTarget: "terraform/apps_cms.tf",
		},
		// A title that is only a path has no verb to keep, and a line with no
		// title is dropped rather than shown. The path becomes the label.
		"read titled with nothing but a path": {
			title:     "/coop/repositories/blitz-infra/terraform/apps_cms.tf",
			toolKind:  "read",
			detail:    "",
			wantKind:  slackui.ActivityTool,
			wantTitle: "terraform/apps_cms.tf",
		},
		// Nine reads on disk are titled this and carry nothing else. There is
		// no path to find, and the row must not gain one.
		"read with no path anywhere": {
			title:     "Read File",
			toolKind:  "read",
			detail:    `{"input":{}}`,
			wantKind:  slackui.ActivityTool,
			wantTitle: "Read File",
		},
		"edit with no path anywhere": {
			title:     "Edit",
			toolKind:  "edit",
			detail:    "",
			wantKind:  slackui.ActivityEdit,
			wantTitle: "Edit",
		},
		"write with no path anywhere": {
			title:     "Write",
			toolKind:  "edit",
			detail:    "",
			wantKind:  slackui.ActivityEdit,
			wantTitle: "Write",
		},
		"search names its pattern": {
			title:      `Search for 'function dataURL|const dataURL' in api.ts`,
			toolKind:   "search",
			detail:     "",
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Search",
			wantTarget: "function dataURL|const dataURL",
		},
		"search over a repository": {
			title:      `Search for 'analyzed_comps|14\.14|frontend-utilities' in blitz-app-svelte`,
			toolKind:   "search",
			detail:     "",
			wantKind:   slackui.ActivityTool,
			wantTitle:  "Search",
			wantTarget: `analyzed_comps|14\.14|frontend-utilities`,
		},
		// A search that never named a pattern has nothing to move out of its
		// title, so the title stays whole rather than becoming the bare word.
		"search with no pattern": {
			title:     "Search",
			toolKind:  "search",
			detail:    `{"input":{}}`,
			wantKind:  slackui.ActivityTool,
			wantTitle: "Search",
		},
		"exec still shows its command": {
			title:      "Terminal",
			toolKind:   "execute",
			detail:     `{"input":{"command":"git -C /coop/repositories/blitz-infra show --stat HEAD","cwd":"/Users/andrewdryga/Projects/blitz/blitz-infra-forks/remote-bf1a4735b267827eceebd9f1"}}`,
			wantKind:   slackui.ActivityTool,
			wantTitle:  "git -C /coop/repositories/blitz-infra show --stat HEAD",
			wantTarget: "",
		},
		"other keeps its own title": {
			title:     "ToolSearch",
			toolKind:  "other",
			detail:    "",
			wantKind:  slackui.ActivityTool,
			wantTitle: "ToolSearch",
		},
		"unnamed tool kind keeps its own title": {
			title:     "Context compacting",
			toolKind:  "",
			detail:    `{"input":{}}`,
			wantKind:  slackui.ActivityTool,
			wantTitle: "Context compacting",
		},
	} {
		t.Run(name, func(t *testing.T) {
			line, ok := Line(toolStarted(testCase.title, testCase.toolKind, testCase.detail))
			if !ok {
				t.Fatal("row dropped")
			}
			if line.Kind != testCase.wantKind {
				t.Errorf("kind = %q, want %q", line.Kind, testCase.wantKind)
			}
			if line.Title != testCase.wantTitle {
				t.Errorf("title = %q, want %q", line.Title, testCase.wantTitle)
			}
			if line.Target != testCase.wantTarget {
				t.Errorf("target = %q, want %q", line.Target, testCase.wantTarget)
			}
			// The digest is what makes a pack ref immutable and what makes it 64
			// characters of a 46-rune line. No row spends the card on one.
			if rendered := line.Title + " " + line.Target; strings.Contains(rendered, "sha256:") {
				t.Errorf("line carries a pack digest: %q", rendered)
			}
		})
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
// to carry a `command` key is not a shell call, and its own title stands. The
// path beside it is what a read is about, and the row shows that instead.
func TestLineIgnoresCommandKeyForNonExecToolKinds(t *testing.T) {
	line, ok := Line(toolStarted("Read api.ts", "read",
		`{"input":{"command":"not a shell call","path":"games/tft/api.ts"}}`,
	))
	if !ok {
		t.Fatal("row dropped")
	}
	if line.Title != "Read api.ts" || line.Target != "games/tft/api.ts" {
		t.Fatalf("line = %+v", line)
	}
	if strings.Contains(line.Title+line.Target, "not a shell call") {
		t.Fatalf("read call rendered its payload's command: %+v", line)
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
	if line.Title != "api.ts" || line.Target != "games/tft/api.ts" {
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
				`{"input":{"command":"git -C /coop/repositories/blitz-app-svelte show --stat","cwd":"/coop"}}`),
			toolStarted(`"grep -n \"function dataURL\" games/tft/api.ts | head -20"`, "execute",
				`{"input":{"command":"/bin/bash -lc \"grep -n \\\"function dataURL\\\" games/tft/api.ts | head -20\"","cwd":"/coop/repositories/blitz-app-svelte/src"}}`),
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

// The renderer truncates from the right, so a path handed over whole arrives on
// the card as the half that says where the agent works. What survives has to be
// the end.
func TestShortenPathKeepsTheEndThatNamesTheFile(t *testing.T) {
	for name, testCase := range map[string]struct{ in, want string }{
		"fork checkout": {
			in:   "/Users/andrewdryga/Projects/blitz/blitz-infra-forks/remote-bf1a4735b267827eceebd9f1/terraform/apps_cms.tf",
			want: "terraform/apps_cms.tf",
		},
		"coop repository": {
			in:   "/coop/repositories/blitz-app-svelte/src/games/tft/api.ts",
			want: "src/games/tft/api.ts",
		},
		// A directory a person named `remote-something` is inside the work, not
		// the checkout the work happens in.
		"remote directory that is not a checkout": {
			in:   "/coop/repositories/blitz-infra/remote-config/main.tf",
			want: "remote-config/main.tf",
		},
		"already repository relative": {
			in:   "src/games/tft/api.ts",
			want: "src/games/tft/api.ts",
		},
		"outside any workspace": {
			in:   "/Users/andrewdryga/Projects/os/ryker/internal/liveturn/liveturn.go",
			want: "…/internal/liveturn/liveturn.go",
		},
		// Nothing to drop off the front, so nothing claims to have been dropped.
		"one long name": {
			in:   "a-single-file-name-that-will-not-fit-the-column.tf",
			want: "a-single-file-name-that-will-not-fit-the-column.tf",
		},
		"bare name": {in: "api.ts", want: "api.ts"},
		"empty":     {in: "  ", want: ""},
	} {
		t.Run(name, func(t *testing.T) {
			got := shortenPath(testCase.in)
			if got != testCase.want {
				t.Fatalf("shortenPath(%q) = %q, want %q", testCase.in, got, testCase.want)
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

// The measured failure: a start moment that names the tool, an empty payload,
// and the command sitting on the same call's later moment. Three of these in a
// row is the window telling an operator "Terminal" three times about three
// different commands, which is what a real Blitz Realtime Gateway task card
// showed while it was running cargo clippy.
func TestLineNamesTheCommandTheSettledMomentSupplied(t *testing.T) {
	moment := toolStarted(genericTerminalTitle, "execute", genericTerminalDetail)
	moment.SettledTitle = `git stash -q && cargo clippy --locked --all-targets`

	line, ok := Line(moment)
	if !ok {
		t.Fatal("row dropped")
	}

	if line.Title != moment.SettledTitle {
		t.Fatalf("title = %q, want the command %q", line.Title, moment.SettledTitle)
	}
	if line.Target != "" {
		t.Fatalf("target = %q, want the command as the label only", line.Target)
	}
}

// A settled title that is another placeholder is not an improvement, and
// swapping one uninformative word for another would only look like a fix.
func TestLineIgnoresASettledTitleThatNamesTheToolAgain(t *testing.T) {
	moment := toolStarted(genericTerminalTitle, "execute", genericTerminalDetail)
	moment.SettledTitle = "tool call"

	line, ok := Line(moment)
	if !ok {
		t.Fatal("row dropped")
	}

	if line.Title != "Terminal" {
		t.Fatalf("title = %q, want the original placeholder kept", line.Title)
	}
}

// The payload still wins when it has the command: it is the call's own input,
// where a settled title is a label a runtime chose afterwards.
func TestLinePrefersTheStoredCommandOverASettledTitle(t *testing.T) {
	moment := toolStarted(genericTerminalTitle, "execute",
		`{"input":{"command":"go test ./internal/liveturn/"}}`)
	moment.SettledTitle = "something the runtime relabelled it"

	line, ok := Line(moment)
	if !ok {
		t.Fatal("row dropped")
	}

	if line.Title != "go test ./internal/liveturn/" {
		t.Fatalf("title = %q, want the stored command", line.Title)
	}
}
