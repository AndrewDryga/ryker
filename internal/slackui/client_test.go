package slackui

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"gopkg.in/yaml.v3"
)

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
	if display.Name != "Emisar Responder" || len(display.Name) > 35 {
		t.Fatalf("manifest name = %q", display.Name)
	}
	if display.Description != "Emisar's AI SRE First Responder" || len(display.Description) > 140 {
		t.Fatalf("manifest description = %q", display.Description)
	}
	if len(display.LongDescription) < 174 || len(display.LongDescription) > 4000 {
		t.Fatalf("manifest long description length = %d", len(display.LongDescription))
	}
	if !strings.Contains(display.LongDescription, "incomplete or inaccurate") {
		t.Fatal("manifest long description is missing the AI accuracy disclosure")
	}
	if display.BackgroundColor != "#0A0B0D" {
		t.Fatalf("manifest background color = %q", display.BackgroundColor)
	}
	if manifest.Features.BotUser.DisplayName != "Responder" ||
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
	if command.UsageHint != "help | status | incidents | preferences | rules" ||
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
		len(agent.SuggestedPrompts) != 2 || len(agent.Actions) != 3 {
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
