package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

var testPNG = []byte{
	0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
	0, 0, 0, 13, 'I', 'H', 'D', 'R',
}

func TestSlackAttachmentReachesQueuedCoopTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	const privateURL = "https://files.slack.com/files-pri/T123-F123/bug.png?origin=event"
	slackClient := &fakeSlack{files: map[string][]byte{privateURL: testPNG}}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"reply","attention":{"addressee":"direct",` +
		`"urgency":1,"confidence":3,"novelty":2,"ownership":2},` +
		`"message":"The screenshot shows a failed deployment."}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-file-turn", EnvelopeID: "env-file-turn", EventID: "EvFileTurn",
		Kind: "direct", TeamID: cfg.Slack.TeamID, ChannelID: "DOPERATOR",
		MessageTS: "1700.100", UserID: "U123ABC",
		Attachments: []core.SlackAttachment{{
			ID: "F123", Name: "bug.png", MediaType: "image/png",
			Size: int64(len(testPNG)), URLPrivate: privateURL,
		}},
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit file-only Slack input = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitArtifacts) != 1 ||
		len(coopClient.submitArtifacts[0]) != 1 {
		t.Fatalf("submitted artifacts = %#v", coopClient.submitArtifacts)
	}
	artifact := coopClient.submitArtifacts[0][0]
	digest := sha256.Sum256(testPNG)
	if artifact.Name != "bug.png" || artifact.MediaType != "image/png" ||
		artifact.SHA256 != hex.EncodeToString(digest[:]) ||
		string(artifact.Data) != string(testPNG) {
		t.Fatalf("submitted artifact = %+v", artifact)
	}
	if len(slackClient.downloads) != 1 || slackClient.downloads[0] != privateURL {
		t.Fatalf("Slack downloads = %v", slackClient.downloads)
	}
	prompt := coopClient.submitPrompts[0]
	if !strings.Contains(prompt, `"name":"bug.png"`) ||
		!strings.Contains(prompt, "Attached file for inspection.") ||
		strings.Contains(prompt, privateURL) {
		t.Fatalf("attachment prompt did not contain safe metadata only:\n%s", prompt)
	}
}

func TestSlackAttachmentDownloadRejectsUnsafeOrMismatchedContent(t *testing.T) {
	cfg := serviceConfig(t)
	tests := []struct {
		name       string
		attachment core.SlackAttachment
		data       []byte
		want       string
	}{
		{
			name: "non Slack host",
			attachment: core.SlackAttachment{
				ID: "F1", Name: "bug.png", MediaType: "image/png",
				Size: int64(len(testPNG)), URLPrivate: "https://attacker.example/bug.png",
			},
			data: testPNG, want: "outside Slack file hosting",
		},
		{
			name: "content mismatch",
			attachment: core.SlackAttachment{
				ID: "F2", Name: "fake.pdf", MediaType: "application/pdf",
				Size:       int64(len(testPNG)),
				URLPrivate: "https://files.slack.com/files-pri/T-F/fake.pdf",
			},
			data: testPNG, want: "does not match declared media type",
		},
		{
			name: "stream exceeds limit",
			attachment: core.SlackAttachment{
				ID: "F3", Name: "large.txt", MediaType: "text/plain",
				URLPrivate: "https://files.slack.com/files-pri/T-F/large.txt",
			},
			data: []byte(strings.Repeat("x", cfg.Limits.MaxSlackFileBytes+1)),
			want: "exceeds the configured",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			slackClient := &fakeSlack{files: map[string][]byte{
				test.attachment.URLPrivate: test.data,
			}}
			svc := &Service{cfg: cfg, slack: slackClient}
			_, err := svc.downloadSlackArtifacts(context.Background(), core.SlackInput{
				Attachments: []core.SlackAttachment{test.attachment},
			})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("download error = %v, want %q", err, test.want)
			}
			if !permanentSlackAttachmentError(err) {
				t.Fatalf("invalid attachment was treated as retryable: %v", err)
			}
		})
	}
}

func TestSlackAttachmentPlaceholderResolvesThroughFilesInfo(t *testing.T) {
	cfg := serviceConfig(t)
	const privateURL = "https://files.slack.com/files-pri/T-F/delayed.png"
	slackClient := &fakeSlack{
		files: map[string][]byte{privateURL: testPNG},
		fileInfo: map[string]slackui.HistoryFile{
			"FDELAYED": {
				ID: "FDELAYED", Name: "delayed.png", MediaType: "image/png",
				Size: int64(len(testPNG)), URLPrivate: privateURL,
			},
		},
	}
	svc := &Service{cfg: cfg, slack: slackClient}
	artifacts, err := svc.downloadSlackArtifacts(context.Background(), core.SlackInput{
		Attachments: []core.SlackAttachment{{ID: "FDELAYED", Name: "attachment"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Name != "delayed.png" ||
		artifacts[0].MediaType != "image/png" ||
		string(artifacts[0].Data) != string(testPNG) {
		t.Fatalf("resolved artifacts = %+v", artifacts)
	}
	if len(slackClient.fileInfoRequests) != 1 ||
		slackClient.fileInfoRequests[0] != "FDELAYED" {
		t.Fatalf("files.info requests = %v", slackClient.fileInfoRequests)
	}
}

func TestSlackInputAttachmentsKeepsDelayedFilePlaceholder(t *testing.T) {
	attachments := slackInputAttachments([]slack.File{{
		ID: "FDELAYED", Name: "delayed.png",
	}})
	if len(attachments) != 1 ||
		attachments[0].ID != "FDELAYED" ||
		attachments[0].Name != "delayed.png" ||
		attachments[0].URLPrivate != "" {
		t.Fatalf("delayed file placeholder = %+v", attachments)
	}
}

func TestAppMentionPersistsSlackFileBeforeAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "EvFileMention"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppMentionEvent{
				User: "U123ABC", Channel: "CFILES", TimeStamp: "1700.200",
				Text: "<@U999BOT> fix the bug in this screenshot",
				Files: []slack.File{{
					ID: "F200", Name: "failure.png", Mimetype: "image/png",
					Size:               16,
					URLPrivateDownload: "https://files.slack.com/files-pri/T-F/failure.png",
				}},
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-file-mention", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("acks = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(input.Attachments) != 1 ||
		input.Attachments[0].ID != "F200" ||
		input.Attachments[0].URLPrivate == "" {
		t.Fatalf("persisted attachment = %+v", input.Attachments)
	}
}

func TestAgentRunArtifactRequiresExistingSlackSource(t *testing.T) {
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := &Service{cfg: cfg, store: st, slack: &fakeSlack{}}
	_, err = svc.agentRunArtifacts(context.Background(), core.AgentRun{
		SourceKind: "slack", SourceID: "missing",
	})
	if err == nil || !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("missing source error = %v", err)
	}
}

func TestAgentRunArtifactInheritsScreenshotForThreadMessageFollowup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const privateURL = "https://files.slack.com/files-pri/T-F/failing-check.png"
	slackClient := &fakeSlack{
		files: map[string][]byte{privateURL: testPNG},
		history: []slackui.HistoryMessage{
			{
				Timestamp: "1700.701", ThreadTS: "1700.700", UserID: "U123",
				Text: "1. Use threads.\n2. See image.",
				Files: []slackui.HistoryFile{{
					ID: "FFAIL", Name: "failing-check.png", MediaType: "image/png",
					Size: int64(len(testPNG)), URLPrivate: privateURL,
				}},
			},
		},
	}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slack_thread_caret", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.700", MessageTS: "1700.702",
		UserID: "U123", Text: "^",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit thread followup = %t, %v", created, err)
	}
	artifacts, err := svc.agentRunArtifacts(ctx, core.AgentRun{
		SourceKind: "watch", SourceID: input.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 1 || artifacts[0].Name != "failing-check.png" ||
		string(artifacts[0].Data) != string(testPNG) {
		t.Fatalf("inherited thread artifacts = %+v", artifacts)
	}
}

func TestHistoricalThreadAttachmentsSkipUnsafeFiles(t *testing.T) {
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	attachments := svc.latestHumanThreadAttachments([]slackui.HistoryMessage{
		{
			Timestamp: "1700.100", UserID: "U123",
			Files: []slackui.HistoryFile{
				{
					ID: "FZIP", Name: "archive.zip", MediaType: "application/zip",
					Size: 100, URLPrivate: "https://files.slack.com/files-pri/T-F/archive.zip",
				},
				{
					ID: "FPNG", Name: "failure.png", MediaType: "image/png",
					Size: int64(len(testPNG)), URLPrivate: "https://files.slack.com/files-pri/T-F/failure.png",
				},
				{
					ID: "FBAD", Name: "outside.png", MediaType: "image/png",
					Size: int64(len(testPNG)), URLPrivate: "https://attacker.example/outside.png",
				},
			},
		},
	}, "1700.200")
	if len(attachments) != 1 || attachments[0].ID != "FPNG" ||
		attachments[0].MediaType != "image/png" {
		t.Fatalf("historical attachments = %+v", attachments)
	}
}
