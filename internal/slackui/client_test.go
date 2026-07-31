package slackui

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/slack-go/slack"
	"gopkg.in/yaml.v3"
)

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
	if command.UsageHint != "help | status | work | incidents | preferences | rules" ||
		len(command.UsageHint) > 60 {
		t.Fatalf("manifest usage hint must remain short and discoverable: %q", command.UsageHint)
	}
	if manifest.Features.AppHome.HomeTabEnabled == nil ||
		!*manifest.Features.AppHome.HomeTabEnabled ||
		manifest.Features.AppHome.MessagesTabEnabled == nil ||
		!*manifest.Features.AppHome.MessagesTabEnabled {
		t.Fatal("manifest must enable the operations Home and agent Messages tabs")
	}
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
	if !slices.Equal(manifest.OAuth.Scopes.Bot, requiredBotScopes) {
		t.Fatalf("manifest scopes = %v; doctor scopes = %v", manifest.OAuth.Scopes.Bot, requiredBotScopes)
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
