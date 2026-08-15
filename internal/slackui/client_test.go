package slackui

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/slack-go/slack"
	"gopkg.in/yaml.v3"
)

func TestRetryAfterRecognizesWrappedSlackRateLimit(t *testing.T) {
	delay, ok := RetryAfter(fmt.Errorf("list channels: %w", &slack.RateLimitedError{
		RetryAfter: 30 * time.Second,
	}))
	if !ok || delay != 30*time.Second {
		t.Fatalf("retry after = %s, %t", delay, ok)
	}
	if _, ok := RetryAfter(errors.New("other failure")); ok {
		t.Fatal("non-rate-limit error reported a retry delay")
	}
}

func TestListChannelsUsesCallingBotsMemberships(t *testing.T) {
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.URL.Path != "/users.conversations" ||
			r.FormValue("types") != "public_channel,private_channel" ||
			r.FormValue("limit") != "200" || r.FormValue("team_id") != "T123" {
			t.Fatalf("membership request = %s %s", r.URL.Path, r.Form.Encode())
		}
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "channels":[
		    {"id":"CPUBLIC","name":"backend-ops","is_private":false},
		    {"id":"CPRIVATE","name":"security","is_private":true}
		  ],
		  "response_metadata":{"next_cursor":""}
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	channels, err := client.ListChannels(context.Background(), "T123")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(paths, []string{"/users.conversations"}) || len(channels) != 2 ||
		!channels[0].Member || !channels[1].Member || !channels[1].Private {
		t.Fatalf("joined channels = %+v; paths = %v", channels, paths)
	}
}

func TestUserNamesPrefersSlackFullNames(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/users.list" {
			t.Fatalf("workspace identity request = %s, want /users.list", r.URL.Path)
		}
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "members":[
		    {"id":"UDISPLAY","name":"login-one","real_name":"Real One","profile":{"display_name":"Display One","real_name":"Profile One"}},
		    {"id":"UPROFILE","name":"login-two","real_name":"Real Two","profile":{"display_name":"","real_name":"Profile Two"}},
		    {"id":"UREAL","name":"login-three","real_name":"Real Three","profile":{}},
		    {"id":"ULOGIN","name":"login-four","real_name":"","profile":{}},
		    {"id":"UEMPTY","name":"","real_name":"","profile":{}}
		  ],
		  "response_metadata":{"next_cursor":""}
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}

	names, err := client.UserNames(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"UDISPLAY": "Profile One",
		"UPROFILE": "Profile Two",
		"UREAL":    "Real Three",
		"ULOGIN":   "login-four",
	}
	if len(names) != len(want) {
		t.Fatalf("names = %#v, want %#v", names, want)
	}
	for id, label := range want {
		if names[id] != label {
			t.Errorf("names[%s] = %q, want %q", id, names[id], label)
		}
	}
}

func TestUploadFileUsesFileCompatibleBlocks(t *testing.T) {
	var server *httptest.Server
	var blocks string
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/files.getUploadURLExternal":
			_, _ = fmt.Fprintf(
				w,
				`{"ok":true,"upload_url":%q,"file_id":"F123"}`,
				server.URL+"/upload",
			)
		case "/upload":
			_, _ = fmt.Fprint(w, "ok")
		case "/files.completeUploadExternal":
			if err := r.ParseForm(); err != nil {
				t.Error(err)
			}
			blocks = r.FormValue("blocks")
			_, _ = fmt.Fprint(w, `{"ok":true,"files":[{"id":"F123","title":"Chart"}]}`)
		case "/files.info":
			_, _ = fmt.Fprint(w, `{"ok":true,"file":{"id":"F123","shares":{"private":{"C123":[{"ts":"1700.2","thread_ts":"1700.1"}]}}}}`)
		default:
			t.Errorf("unexpected Slack API path %s", r.URL.Path)
		}
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	message := Message{Text: "CPU summary", Markdown: "CPU is `healthy`."}
	result, err := client.UploadFile(context.Background(), "C123", "1700.1", FileUpload{
		Filename: "cpu.png", Title: "Chart", AltText: "CPU chart",
		Data: []byte("png"), Message: &message,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.FileID != "F123" || result.MessageTS != "1700.2" ||
		!strings.Contains(blocks, `"type":"section"`) ||
		!strings.Contains(blocks, "CPU is `healthy`.") ||
		strings.Contains(blocks, `"type":"markdown"`) {
		t.Fatalf(
			"upload result=%+v blocks=%q",
			result,
			blocks,
		)
	}
}

func TestSelectThreadHistoryKeepsRootAndNewestReplies(t *testing.T) {
	history := []HistoryMessage{{
		Timestamp: "1700.000001",
		Text:      "thread root",
	}}
	for index := 2; index <= 30; index++ {
		history = append(history, HistoryMessage{
			Timestamp: fmt.Sprintf("1700.%06d", index),
			ThreadTS:  "1700.000001",
			Text:      fmt.Sprintf("reply %d", index),
		})
	}
	selected := selectThreadHistory(history, "1700.000001", 5)
	if len(selected) != 5 ||
		selected[0].Text != "thread root" ||
		selected[1].Text != "reply 27" ||
		selected[4].Text != "reply 30" {
		t.Fatalf("selected thread history = %+v", selected)
	}
}

func TestRecentMessagesPaginatesOldThreadAndReturnsNewestTail(t *testing.T) {
	var calls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.FormValue("latest") != "1700.000030" ||
			r.FormValue("oldest") != "" ||
			r.FormValue("inclusive") != "1" {
			t.Errorf("thread history bounds = %s", r.Form.Encode())
		}
		w.Header().Set("Content-Type", "application/json")
		if r.FormValue("cursor") == "" {
			_, _ = fmt.Fprint(w, `{
			  "ok":true,
			  "has_more":true,
			  "response_metadata":{"next_cursor":"page-two"},
			  "messages":[
			    {"ts":"1700.000001","text":"thread root","user":"U1"},
			    {"ts":"1700.000002","thread_ts":"1700.000001","text":"reply 2","user":"U2"}
			  ]
			}`)
			return
		}
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "has_more":false,
		  "response_metadata":{"next_cursor":""},
		  "messages":[
		    {"ts":"1700.000028","thread_ts":"1700.000001","text":"reply 28","user":"U2"},
		    {"ts":"1700.000029","thread_ts":"1700.000001","text":"reply 29","user":"U2"},
		    {"ts":"1700.000030","thread_ts":"1700.000001","text":"reply 30","user":"U2"}
		  ]
		}`)
	}))
	defer server.Close()
	client := &Client{
		api: slack.New(
			"test-token",
			slack.OptionAPIURL(server.URL+"/"),
			slack.OptionHTTPClient(server.Client()),
		),
	}
	history, err := client.RecentMessages(
		context.Background(),
		"COPS",
		"1700.000001",
		"1700.000030",
		"",
		4,
	)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || len(history) != 4 ||
		history[0].Text != "thread root" ||
		history[1].Text != "reply 28" ||
		history[3].Text != "reply 30" {
		t.Fatalf("paginated thread history calls=%d history=%+v", calls, history)
	}
}

func TestRecentMessagesKeepsFileOnlyContext(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "messages":[{
		    "ts":"1700.000100",
		    "text":"",
		    "user":"U1",
		    "files":[{
		      "id":"F1",
		      "name":"failure.png",
		      "mimetype":"image/png",
		      "size":1234,
		      "url_private":"https://files.slack.com/files-pri/T-F/failure.png"
		    }]
		  }]
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	history, err := client.RecentMessages(
		context.Background(), "COPS", "", "1700.000100", "", 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 || history[0].Text != "" ||
		len(history[0].Files) != 1 ||
		history[0].Files[0].Name != "failure.png" {
		t.Fatalf("file-only history = %+v", history)
	}
}

func TestRecentMessagesIncludesBoundedReactionContext(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "messages":[{
		    "ts":"1700.000100",
		    "text":"Production is healthy.",
		    "bot_id":"BEMISAR",
		    "reactions":[
		      {"name":"thumbsup","count":2,"users":["U1","U2"]},
		      {"name":"eyes","count":1,"users":["U3"]}
		    ]
		  }]
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	history, err := client.RecentMessages(
		context.Background(), "COPS", "", "1700.000100", "", 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 || len(history[0].Reactions) != 2 ||
		history[0].Reactions[0].Name != "thumbsup" ||
		history[0].Reactions[0].Count != 2 ||
		!slices.Equal(history[0].Reactions[0].UserIDs, []string{"U1", "U2"}) {
		t.Fatalf("reaction history = %+v", history)
	}
}

func TestRecentMessagesKeepsLegacyAttachmentOnlyThreadRoot(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "messages":[{
		    "ts":"1700.000001",
		    "thread_ts":"1700.000001",
		    "text":"",
		    "bot_id":"BTERRAFORM",
		    "attachments":[{
		      "fallback":"Run run-abc",
		      "pretext":"Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>",
		      "title":"Run run-abc",
		      "title_link":"https://app.terraform.io/app/acme/infra/runs/run-abc",
		      "text":"main deadbeef (gh run 123)"
		    },{
		      "fallback":"Run run-abc - Run Planning",
		      "title":"Run Planning"
		    }]
		  },{
		    "ts":"1700.000002",
		    "thread_ts":"1700.000001",
		    "text":"<@UEMISAR> can you review it?",
		    "user":"U1"
		  }]
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	history, err := client.RecentMessages(
		context.Background(), "COPS", "1700.000001", "1700.000002", "", 20,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 2 || history[0].BotID != "BTERRAFORM" ||
		!strings.Contains(history[0].Text, "Run notification for") ||
		!strings.Contains(history[0].Text, "run-abc") ||
		!strings.Contains(history[0].Text, "main deadbeef") ||
		!strings.Contains(history[0].Text, "Run Planning") {
		t.Fatalf("attachment-only thread history = %+v", history)
	}
}

func TestRecentMessagesKeepsBlockOnlyContext(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{
		  "ok":true,
		  "messages":[{
		    "ts":"1700.000100",
		    "text":"",
		    "bot_id":"BDEPLOY",
		    "blocks":[
		      {"type":"header","text":{"type":"plain_text","text":"Deployment failed"}},
		      {"type":"section","text":{"type":"mrkdwn","text":"Revision abc123 failed readiness."}}
		    ]
		  }]
		}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	history, err := client.RecentMessages(
		context.Background(), "COPS", "", "1700.000100", "", 10,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 ||
		history[0].Text != "Deployment failed\nRevision abc123 failed readiness." {
		t.Fatalf("block-only history = %+v", history)
	}
}

type shippedSlackManifest struct {
	Metadata struct {
		MajorVersion int `yaml:"major_version"`
	} `yaml:"_metadata"`
	DisplayInformation struct {
		Name            string `yaml:"name"`
		Description     string `yaml:"description"`
		LongDescription string `yaml:"long_description"`
		BackgroundColor string `yaml:"background_color"`
	} `yaml:"display_information"`
	Features struct {
		AgentView struct {
			AgentDescription string `yaml:"agent_description"`
			SuggestedPrompts []struct {
				Title   string `yaml:"title"`
				Message string `yaml:"message"`
			} `yaml:"suggested_prompts"`
			Actions []struct {
				Name        string `yaml:"name"`
				Description string `yaml:"description"`
			} `yaml:"actions"`
		} `yaml:"agent_view"`
		AppHome struct {
			HomeTabEnabled             *bool `yaml:"home_tab_enabled"`
			MessagesTabEnabled         *bool `yaml:"messages_tab_enabled"`
			MessagesTabReadOnlyEnabled *bool `yaml:"messages_tab_read_only_enabled"`
		} `yaml:"app_home"`
		BotUser struct {
			DisplayName  string `yaml:"display_name"`
			AlwaysOnline *bool  `yaml:"always_online"`
		} `yaml:"bot_user"`
		SlashCommands []struct {
			Command      string `yaml:"command"`
			Description  string `yaml:"description"`
			UsageHint    string `yaml:"usage_hint"`
			ShouldEscape *bool  `yaml:"should_escape"`
		} `yaml:"slash_commands"`
		Shortcuts []struct {
			Name        string `yaml:"name"`
			Type        string `yaml:"type"`
			CallbackID  string `yaml:"callback_id"`
			Description string `yaml:"description"`
		} `yaml:"shortcuts"`
	} `yaml:"features"`
	OAuth struct {
		Scopes struct {
			Bot []string `yaml:"bot"`
		} `yaml:"scopes"`
	} `yaml:"oauth_config"`
	Settings struct {
		EventSubscriptions struct {
			BotEvents []string `yaml:"bot_events"`
		} `yaml:"event_subscriptions"`
		IncomingWebhooks struct {
			Enabled *bool `yaml:"incoming_webhooks_enabled"`
		} `yaml:"incoming_webhooks"`
		Interactivity struct {
			Enabled *bool `yaml:"is_enabled"`
		} `yaml:"interactivity"`
		IsHosted             *bool `yaml:"is_hosted"`
		IsMCPEnabled         *bool `yaml:"is_mcp_enabled"`
		OrgDeployEnabled     *bool `yaml:"org_deploy_enabled"`
		SocketModeEnabled    *bool `yaml:"socket_mode_enabled"`
		TokenRotationEnabled *bool `yaml:"token_rotation_enabled"`
	} `yaml:"settings"`
}

func readShippedSlackManifest(t *testing.T) shippedSlackManifest {
	t.Helper()
	data, err := os.ReadFile("../../deploy/slack-app-manifest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var manifest shippedSlackManifest
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&manifest); err != nil {
		t.Fatal(err)
	}
	return manifest
}

func TestShippedManifestDescribesSupportedSlackApp(t *testing.T) {
	manifest := readShippedSlackManifest(t)
	display := manifest.DisplayInformation
	if manifest.Metadata.MajorVersion != 1 {
		t.Fatalf("manifest major version = %d, want 1", manifest.Metadata.MajorVersion)
	}
	if display.Name != "Emisar" || len(display.Name) > 35 {
		t.Fatalf("manifest name = %q", display.Name)
	}
	if display.Description !=
		"AI SRE first responder for evidence-backed investigation and governed operations" ||
		len(display.Description) > 140 {
		t.Fatalf("manifest description = %q", display.Description)
	}
	if len(display.LongDescription) < 174 || len(display.LongDescription) > 4000 {
		t.Fatalf("manifest long description length = %d", len(display.LongDescription))
	}
	for _, required := range []string{
		"not given a generic production shell",
		"Policy decides what runs",
		"validates the action",
		"cannot merge, deploy, sign commits",
		"incomplete or inaccurate",
	} {
		if !strings.Contains(display.LongDescription, required) {
			t.Fatalf("manifest long description is missing %q", required)
		}
	}
	if display.BackgroundColor != "#0A0B0D" {
		t.Fatalf("manifest background color = %q", display.BackgroundColor)
	}
	if manifest.Features.BotUser.DisplayName != "Emisar" ||
		manifest.Features.BotUser.AlwaysOnline == nil ||
		*manifest.Features.BotUser.AlwaysOnline {
		t.Fatalf("manifest bot user = %+v", manifest.Features.BotUser)
	}
	if len(manifest.Features.SlashCommands) != 1 {
		t.Fatalf("manifest slash commands = %+v", manifest.Features.SlashCommands)
	}
	command := manifest.Features.SlashCommands[0]
	if command.Command != "/responder" || command.Description == "" ||
		command.UsageHint == "" || command.ShouldEscape == nil || *command.ShouldEscape {
		t.Fatalf("manifest slash command = %+v", command)
	}
	// The hint is the only completion Slack offers — it does not ask the app
	// for dynamic subcommands — so it is the one place a verb that no longer
	// exists is advertised to every operator every time they type the command.
	// It said "incidents | schedules" for a day after both were deleted.
	if command.UsageHint != "status | proactive | shadow | help" ||
		len(command.UsageHint) > 60 {
		t.Fatalf("manifest usage hint must remain short and discoverable: %q", command.UsageHint)
	}
	if manifest.Features.AppHome.HomeTabEnabled == nil ||
		!*manifest.Features.AppHome.HomeTabEnabled ||
		manifest.Features.AppHome.MessagesTabEnabled == nil ||
		!*manifest.Features.AppHome.MessagesTabEnabled {
		t.Fatal("manifest must enable the operations Home and agent Messages tabs")
	}
	// These three prompts are the only prompts. Responder also installed them
	// at runtime through assistant.threads.setSuggestedPrompts until that call
	// was deleted for never once having succeeded, so the manifest is no longer
	// a duplicate of a code path — it is the code path, and deleting an entry
	// here removes a prompt from the product.
	agent := manifest.Features.AgentView
	if agent.AgentDescription == "" || len(agent.AgentDescription) > 300 ||
		len(agent.SuggestedPrompts) != 3 || len(agent.Actions) != 3 {
		t.Fatalf("manifest agent view = %+v", agent)
	}
	for _, prompt := range agent.SuggestedPrompts {
		if prompt.Title == "" || prompt.Message == "" {
			t.Fatalf("manifest suggested prompt = %+v", prompt)
		}
	}
	for _, action := range agent.Actions {
		if action.Name == "" || action.Description == "" {
			t.Fatalf("manifest agent action = %+v", action)
		}
	}
	if len(manifest.Features.Shortcuts) != 1 ||
		manifest.Features.Shortcuts[0].CallbackID != "responder_investigate_message" ||
		manifest.Features.Shortcuts[0].Name != "Investigate message" ||
		len(manifest.Features.Shortcuts[0].Name) >= 25 {
		t.Fatalf("manifest message shortcut = %+v", manifest.Features.Shortcuts)
	}
	for name, value := range map[string]*bool{
		"messages tab read-only": manifest.Features.AppHome.MessagesTabReadOnlyEnabled,
		"incoming webhooks":      manifest.Settings.IncomingWebhooks.Enabled,
		"Slack hosting":          manifest.Settings.IsHosted,
		"Slack MCP":              manifest.Settings.IsMCPEnabled,
		"org deployment":         manifest.Settings.OrgDeployEnabled,
		"token rotation":         manifest.Settings.TokenRotationEnabled,
	} {
		if value == nil || *value {
			t.Fatalf("manifest %s must be explicitly disabled", name)
		}
	}
	if manifest.Settings.Interactivity.Enabled == nil ||
		!*manifest.Settings.Interactivity.Enabled ||
		manifest.Settings.SocketModeEnabled == nil ||
		!*manifest.Settings.SocketModeEnabled {
		t.Fatal("manifest must enable interactivity and Socket Mode")
	}
	wantEvents := []string{
		"app_mention",
		"app_home_opened",
		"channel_archive",
		"channel_deleted",
		"channel_unarchive",
		"group_archive",
		"group_deleted",
		"group_unarchive",
		"member_joined_channel",
		"message.channels",
		"message.groups",
		"message.im",
		"reaction_added",
		"reaction_removed",
	}
	if !slices.Equal(manifest.Settings.EventSubscriptions.BotEvents, wantEvents) {
		t.Fatalf(
			"manifest bot events = %v; want %v",
			manifest.Settings.EventSubscriptions.BotEvents,
			wantEvents,
		)
	}
}

func TestMissingBotScopesUsesTheShippedManifestContract(t *testing.T) {
	manifest := readShippedSlackManifest(t)
	if !slices.Equal(manifest.OAuth.Scopes.Bot, manifestBotScopes()) {
		t.Fatalf("manifest scopes = %v; binary asks for %v", manifest.OAuth.Scopes.Bot, manifestBotScopes())
	}

	granted := splitScopes("chat:write, users:read, groups:write")
	missing := missingBotScopes(granted)
	if !slices.Contains(missing, "app_mentions:read") ||
		!slices.Contains(missing, "pins:write") ||
		slices.Contains(missing, "chat:write") {
		t.Fatalf("missing scopes = %v", missing)
	}
	if missing := missingBotScopes(requiredBotScopes); len(missing) != 0 {
		t.Fatalf("complete manifest scopes reported missing: %v", missing)
	}
	want := "bot token is missing required scopes: reactions:read, reactions:write, usergroups:read; " +
		"apply deploy/slack-app-manifest.yaml and reinstall the app"
	if got := missingBotScopesError(
		[]string{"reactions:read", "reactions:write", "usergroups:read"},
	).Error(); got != want {
		t.Fatalf("scope repair error = %q; want %q", got, want)
	}
}

// An optional scope is requested by the manifest and must not fail preflight.
//
// channels:join arrived in the manifest after both workspaces had already
// installed the app, so every running deployment was a build asking for a scope
// its token did not carry. Treating that as a fatal preflight failure would
// report "Slack: broken" on an installation where posting, reading, reacting,
// and every other capability works — a false alarm covering for a real but
// narrow gap, which is the reverse of the mistake this file usually guards
// against and just as misleading.
func TestOptionalScopesAreRequestedWithoutBeingRequired(t *testing.T) {
	if !slices.Contains(optionalBotScopes, "channels:join") {
		t.Fatalf("optional scopes = %v; channels:join must be requested", optionalBotScopes)
	}
	if slices.Contains(requiredBotScopes, "channels:join") {
		t.Fatal("channels:join must not fail preflight before the app is reinstalled")
	}
	if missing := missingBotScopes(requiredBotScopes); len(missing) != 0 {
		t.Fatalf("an installation without the optional scopes was reported broken: %v", missing)
	}
}

// missing_scope has one repair and it is not waiting.
func TestMissingScopeIsDistinguishedFromAnOrdinaryRefusal(t *testing.T) {
	if !MissingScope(errors.New("missing_scope")) ||
		!MissingScope(fmt.Errorf("join channel: %w", errors.New("missing_scope"))) {
		t.Fatal("a missing scope was not recognized")
	}
	if MissingScope(nil) || MissingScope(errors.New("channel_not_found")) ||
		MissingScope(errors.New("method_not_supported_for_channel_type")) {
		t.Fatal("an ordinary Slack refusal was reported as a missing scope")
	}
}

func TestJoinChannelRefusesAnEmptyChannel(t *testing.T) {
	client := &Client{}
	if err := client.JoinChannel(context.Background(), "  "); err == nil {
		t.Fatal("joining without a channel ID must not reach Slack")
	}
}

func TestSummonChannelMembershipErrorIsActionable(t *testing.T) {
	err := summonChannelMembershipError("responder", "C123ABC", "infra-alerts")
	want := "@responder is not a member of summon channel #infra-alerts (C123ABC); " +
		"in that Slack channel, run: /invite @responder"
	if err.Error() != want {
		t.Fatalf("membership error = %q; want %q", err, want)
	}
}

func TestWatchChannelMembershipErrorIsActionable(t *testing.T) {
	err := channelMembershipError("responder", "watch", "C456DEF", "deploy-alerts")
	want := "@responder is not a member of watch channel #deploy-alerts (C456DEF); " +
		"in that Slack channel, run: /invite @responder"
	if err.Error() != want {
		t.Fatalf("membership error = %q; want %q", err, want)
	}
}

func TestDialSocketModeCompletesWebSocketHandshake(t *testing.T) {
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		_ = connection.Close()
	}))
	defer server.Close()
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	if err := dialSocketMode(context.Background(), websocketURL); err != nil {
		t.Fatal(err)
	}
}

// Colour is the one affordance Slack gives a bot for saying whose turn it is,
// and it lives on an attachment rather than on a block. A striped card
// therefore ships as a single attachment holding the entire block set — and a
// card without a stripe has to keep shipping exactly the payload it always did,
// because every existing surface is one.
func TestCustodyStripeShipsTheCardAsOneColouredAttachment(t *testing.T) {
	type call struct {
		path string
		form url.Values
	}
	var calls []call
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		calls = append(calls, call{path: r.URL.Path, form: r.Form})
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"ok":true,"channel":"C123","ts":"1700.1"}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}

	striped := Message{
		Text:   "Working — VA1: prevent reload-driven Traefik OOM recurrence",
		Header: "⚙️ VA1: prevent reload-driven Traefik OOM recurrence",
		Stripe: StripeWorking,
		Ledger: []LedgerStep{{Label: "Making changes", Current: true, When: "2m"}},
	}
	plain := Message{Text: "Merged.", Header: "VA1", Sections: []string{"Draft PR #482 merged."}}
	ctx := context.Background()
	if _, err := client.Post(ctx, "d1", "C123", "", striped); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Post(ctx, "d2", "C123", "", plain); err != nil {
		t.Fatal(err)
	}
	if err := client.Update(ctx, "C123", "1700.1", striped); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 3 {
		t.Fatalf("expected two posts and an update, got %d calls", len(calls))
	}

	blocks, err := json.Marshal(slack.Blocks{BlockSet: striped.Blocks()})
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range []call{calls[0], calls[2]} {
		if call.form.Get("blocks") != "" {
			t.Errorf("%s sent bare blocks beside the attachment: %s", call.path, call.form.Get("blocks"))
		}
		var attachments []struct {
			Color    string          `json:"color"`
			Fallback string          `json:"fallback"`
			Blocks   json.RawMessage `json:"blocks"`
		}
		if err := json.Unmarshal([]byte(call.form.Get("attachments")), &attachments); err != nil {
			t.Fatalf("%s attachments = %q: %v", call.path, call.form.Get("attachments"), err)
		}
		if len(attachments) != 1 {
			t.Fatalf("%s sent %d attachments; the card is one striped block set", call.path, len(attachments))
		}
		if attachments[0].Color != StripeWorking {
			t.Errorf("%s attachment colour = %q, want %q", call.path, attachments[0].Color, StripeWorking)
		}
		if string(attachments[0].Blocks) != string(blocks) {
			t.Errorf("%s attachment blocks = %s, want %s", call.path, attachments[0].Blocks, blocks)
		}
		// Top-level text is drawn above an attachment rather than hidden
		// behind it, so a striped card that sent one rendered its own
		// fallback as a paragraph and said the state and the title twice.
		if text := call.form.Get("text"); text != "" {
			t.Errorf("%s sent visible top-level text beside the attachment: %q", call.path, text)
		}
		// The form must still carry the key: chat.update leaves an omitted
		// field alone, so a card posted by an older build keeps its visible
		// text forever unless the edit clears it.
		if _, present := call.form["text"]; !present {
			t.Errorf("%s omitted text entirely; an edit then cannot clear an older card's text", call.path)
		}
		// Notifications and the sidebar strip the colour, so the fallback
		// still has to lead with the state word — from the attachment now.
		if attachments[0].Fallback != striped.Text {
			t.Errorf("%s attachment fallback = %q, want %q", call.path, attachments[0].Fallback, striped.Text)
		}
	}

	if attachments := calls[1].form.Get("attachments"); attachments != "" {
		t.Errorf("an unstriped card grew an attachment: %s", attachments)
	}
	if blocks := calls[1].form.Get("blocks"); !strings.Contains(blocks, `"type":"header"`) {
		t.Errorf("an unstriped card no longer sends its blocks: %s", blocks)
	}
	// Beside blocks, top-level text is notification-only and never drawn, so
	// the unstriped payload keeps carrying it exactly as it always did.
	if text := calls[1].form.Get("text"); text != plain.Text {
		t.Errorf("an unstriped card's fallback text = %q, want %q", text, plain.Text)
	}
}

// An ephemeral with no thread_ts lands at channel level whichever message was
// clicked. Thread-scoped work lives entirely inside its thread, so every
// private answer its controls produced — a refusal, "No turn has finished here
// yet", a click acknowledgement — was delivered where the operator was not
// looking, and the button appeared to do nothing. This asserts the field
// reaches Slack, because that is the whole of the bug.
func TestEphemeralCarriesTheThreadItWasAskedFor(t *testing.T) {
	var forms []url.Values
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		forms = append(forms, r.Form)
		_, _ = fmt.Fprint(w, `{"ok":true,"message_ts":"1700.900"}`)
	}))
	defer server.Close()
	client := &Client{api: slack.New(
		"test-token",
		slack.OptionAPIURL(server.URL+"/"),
		slack.OptionHTTPClient(server.Client()),
	)}
	ctx := context.Background()

	if err := client.PostEphemeral(
		ctx, "CTASK", "U123ABC", "1700.100", Notice("On it."),
	); err != nil {
		t.Fatal(err)
	}
	if got := forms[0].Get("thread_ts"); got != "1700.100" {
		t.Fatalf("threaded ephemeral carried thread_ts=%q", got)
	}
	if forms[0].Get("channel") != "CTASK" || forms[0].Get("user") != "U123ABC" {
		t.Fatalf("ephemeral addressed to %s/%s",
			forms[0].Get("channel"), forms[0].Get("user"))
	}

	// A channel-level answer still has no thread, and must not invent one.
	if err := client.PostEphemeral(
		ctx, "CTASK", "U123ABC", "", Notice("Channel-level answer."),
	); err != nil {
		t.Fatal(err)
	}
	if got := forms[1].Get("thread_ts"); got != "" {
		t.Fatalf("unthreaded ephemeral carried thread_ts=%q", got)
	}
}
