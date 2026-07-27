package slackui

import (
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

func TestMissingBotScopesUsesTheShippedManifestContract(t *testing.T) {
	data, err := os.ReadFile("../../deploy/slack-app-manifest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		OAuth struct {
			Scopes struct {
				Bot []string `yaml:"bot"`
			} `yaml:"scopes"`
		} `yaml:"oauth_config"`
	}
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
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
