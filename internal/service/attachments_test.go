package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/publisher"
	"github.com/AndrewDryga/ryker/internal/resultcontract"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskpr"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

var testPNG = []byte{
	0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
	0, 0, 0, 13, 'I', 'H', 'D', 'R',
}

type pullRequestTestPublisher struct {
	context    publisher.PullRequestContext
	repository string
	number     int
}

func (*pullRequestTestPublisher) Enabled() bool { return true }

func (*pullRequestTestPublisher) HeadBranch(core.Incident, core.Publication) (string, error) {
	return "ryker/test", nil
}

func (*pullRequestTestPublisher) Publish(
	context.Context,
	publisher.Request,
) (publisher.Result, error) {
	return publisher.Result{}, nil
}

func (*pullRequestTestPublisher) VerifyPublication(context.Context, core.Publication) error {
	return nil
}

func (f *pullRequestTestPublisher) PullRequestContext(
	_ context.Context,
	repository string,
	number int,
) (publisher.PullRequestContext, error) {
	f.repository = repository
	f.number = number
	return f.context, nil
}

func TestConfiguredPrivatePullRequestBecomesExactAgentArtifact(t *testing.T) {
	cfg := serviceConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"blitz-infra": {GitHubRepository: "theblitzapp/blitz-infra"},
	}
	client := &pullRequestTestPublisher{context: publisher.PullRequestContext{
		Repository: "theblitzapp/blitz-infra", Number: 514,
		URL:   "https://github.com/theblitzapp/blitz-infra/pull/514",
		Title: "Deploy Sentry Symbolicator", Body: "Use MinIO for symbols.",
		State: "open", Author: "trevin", BaseRef: "main", BaseSHA: "base",
		HeadRef: "symbolicator", HeadSHA: "head", ChangedFiles: 3,
		Additions: 41, Deletions: 2,
		Diff:     "diff --git a/sentry.tf b/sentry.tf\n+symbolicator = true\n",
		Comments: []publisher.PullRequestComment{{Author: "andrew", Body: "Connect GCP to Nomad."}},
		Reviews:  []publisher.PullRequestReview{{Author: "reviewer", State: "CHANGES_REQUESTED", Body: "Check access."}},
		ReviewComments: []publisher.PullRequestReviewComment{{
			Author: "reviewer", Body: "Use least privilege.", Path: "sentry.tf", Line: 42, Side: "RIGHT",
		}},
	}}
	svc := &Service{cfg: cfg, publisher: client}

	artifacts, err := svc.augmentAgentRunArtifacts(
		context.Background(),
		"Please review https://github.com/theblitzapp/blitz-infra/pull/514",
		[]coop.InputArtifact{{Name: "screenshot.png", MediaType: "image/png"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if client.repository != "theblitzapp/blitz-infra" || client.number != 514 {
		t.Fatalf("GitHub request = %s#%d", client.repository, client.number)
	}
	if len(artifacts) != 3 || artifacts[1].Name != "github-pr-514.md" ||
		artifacts[1].MediaType != "text/markdown" {
		t.Fatalf("artifacts = %+v", artifacts)
	}
	text := string(artifacts[1].Data)
	for _, want := range []string{
		"Exact authenticated GitHub pull request context",
		"Deploy Sentry Symbolicator", "Connect GCP to Nomad.",
		"CHANGES_REQUESTED", "sentry.tf:42", "Use least privilege.", "+symbolicator = true",
		"untrusted repository content",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("PR artifact missing %q:\n%s", want, text)
		}
	}
	digest := sha256.Sum256(artifacts[1].Data)
	if artifacts[1].SHA256 != hex.EncodeToString(digest[:]) {
		t.Fatalf("artifact digest = %q", artifacts[1].SHA256)
	}
	assertResultContractArtifact(t, artifacts[2])
}

func TestPrivatePullRequestDiscoveryUsesDurableRunContextAndAdvertisesArtifact(t *testing.T) {
	cfg := serviceConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"blitz-infra": {GitHubRepository: "theblitzapp/blitz-infra"},
	}
	client := &pullRequestTestPublisher{context: publisher.PullRequestContext{
		Repository: "theblitzapp/blitz-infra", Number: 514,
		URL:  "https://github.com/theblitzapp/blitz-infra/pull/514",
		Diff: "diff --git a/infra.tf b/infra.tf\n+symbolicator = true\n",
	}}
	svc := &Service{cfg: cfg, publisher: client}

	// The bounded prompt can omit an old thread root. Discovery receives the
	// durable run context too, so the exact PR is not lost during compaction.
	discoveryContext := "current bounded prompt\n" +
		`{"recent_messages":[{"text":"<https://github.com/theblitzapp/blitz-infra/pull/514|PR 514>"}]}`
	artifacts, err := svc.augmentAgentRunArtifacts(
		context.Background(), discoveryContext, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 2 || artifacts[0].Name != "github-pr-514.md" {
		t.Fatalf("artifacts = %+v", artifacts)
	}
	assertResultContractArtifact(t, artifacts[1])
	prompt := taskpr.ArtifactsPrompt(artifacts)
	for _, want := range []string{
		"github-pr-514.md", artifacts[0].SHA256,
		"authenticated snapshot", "stale local branches",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("artifact prompt missing %q:\n%s", want, prompt)
		}
	}
}

func TestUnconfiguredPullRequestIsNotFetched(t *testing.T) {
	cfg := serviceConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"emisar": {GitHubRepository: "AndrewDryga/emisar"},
	}
	client := &pullRequestTestPublisher{}
	svc := &Service{cfg: cfg, publisher: client}

	artifacts, err := svc.augmentAgentRunArtifacts(
		context.Background(),
		"Review https://github.com/theblitzapp/blitz-infra/pull/514",
		nil,
	)
	if err != nil || len(artifacts) != 1 || client.repository != "" {
		t.Fatalf("unconfigured PR = artifacts %+v request %q error %v", artifacts, client.repository, err)
	}
	assertResultContractArtifact(t, artifacts[0])
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
		`"urgency":1,"confidence":3,"novelty":2,"ownership":2,"contribution":"decision","material":true},` +
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
		len(coopClient.submitArtifacts[0]) != 2 {
		t.Fatalf("submitted artifacts = %#v", coopClient.submitArtifacts)
	}
	artifact := coopClient.submitArtifacts[0][0]
	digest := sha256.Sum256(testPNG)
	if artifact.Name != "bug.png" || artifact.MediaType != "image/png" ||
		artifact.SHA256 != hex.EncodeToString(digest[:]) ||
		string(artifact.Data) != string(testPNG) {
		t.Fatalf("submitted artifact = %+v", artifact)
	}
	assertResultContractArtifact(t, coopClient.submitArtifacts[0][1])
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

// A payments report with a screenshot went unanswered on 2026-08-16 because the
// screenshot's bytes did not match its declared type. One unreadable file
// returned one error for the whole message, both callers turned that into a
// failed run, and the words — answerable without the picture — were never read
// by anything. The audit outcome was failed_silent, nothing was posted, and the
// person solved it themselves twelve minutes later.
//
// A file the host will not attach is a note the model is handed, never the end
// of the turn.
func TestAnUnreadableAttachmentIsNotedRatherThanFatal(t *testing.T) {
	cfg := serviceConfig(t)
	const readableURL = "https://files.slack.com/files-pri/T-F/bug.png"
	const unreadableURL = "https://files.slack.com/files-pri/T-F/image.png"
	slackClient := &fakeSlack{files: map[string][]byte{
		readableURL:   testPNG,
		unreadableURL: []byte("<!doctype html><html>expired</html>"),
	}}
	svc := &Service{cfg: cfg, slack: slackClient}

	artifacts, rejected, err := svc.downloadSlackArtifacts(
		context.Background(),
		core.SlackInput{Attachments: []core.SlackAttachment{
			{
				ID: "FGOOD", Name: "bug.png", MediaType: "image/png",
				Size: int64(len(testPNG)), URLPrivate: readableURL,
			},
			{
				ID: "FBAD", Name: "image.png", MediaType: "image/png",
				Size: 35, URLPrivate: unreadableURL,
			},
		}},
	)
	if err != nil {
		t.Fatalf("one unreadable attachment failed the whole turn: %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].Name != "bug.png" ||
		string(artifacts[0].Data) != string(testPNG) {
		t.Fatalf("readable artifact was lost with the unreadable one: %+v", artifacts)
	}
	if len(rejected) != 1 || rejected[0].Name != "image.png" ||
		rejected[0].MediaType != "image/png" ||
		!strings.Contains(rejected[0].Reason, "image/png") {
		t.Fatalf("rejections = %+v", rejected)
	}
}

// The note is worth nothing if the model never sees it: the reply has to say it
// could not read the picture, and it can only say that if the prompt told it.
func TestTheUnreadableAttachmentReachesThePrompt(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	const privateURL = "https://files.slack.com/files-pri/T123-F123/image.png?origin=event"
	slackClient := &fakeSlack{files: map[string][]byte{
		privateURL: []byte("<!doctype html><html>expired</html>"),
	}}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
		BotName: "Emisar",
	}
	input := core.SlackInput{
		ID: "slack-unreadable-attachment", EnvelopeID: "env-unreadable-attachment",
		EventID: "EvUnreadableAttachment", Kind: "direct", TeamID: cfg.Slack.TeamID,
		ChannelID: "DOPERATOR", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "there are issues atm with payments, I just made a new account and tried to pay",
		Attachments: []core.SlackAttachment{{
			ID: "F123", Name: "image.png", MediaType: "image/png",
			Size: 35, URLPrivate: privateURL,
		}},
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit unreadable-attachment input = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d; the unreadable file killed the turn", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	for _, want := range []string{
		`<host-unreadable-attachment name="image.png" declared="image/png">`,
		"not a valid image/png",
		"could not read the attachment",
	} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt does not name the dropped attachment (%q):\n%s", want, prompt)
		}
	}
	if len(coopClient.submitArtifacts) != 1 || len(coopClient.submitArtifacts[0]) != 1 {
		t.Fatalf("unreadable bytes were attached anyway: %#v", coopClient.submitArtifacts)
	}
	assertResultContractArtifact(t, coopClient.submitArtifacts[0][0])
}

func assertResultContractArtifact(t *testing.T, artifact coop.InputArtifact) {
	t.Helper()
	if artifact.Name != resultcontract.FileName ||
		artifact.MediaType != "application/json" ||
		string(artifact.Data) != string(resultcontract.Schema()) {
		t.Fatalf("result contract artifact = name %q media %q bytes %d", artifact.Name, artifact.MediaType, len(artifact.Data))
	}
	digest := sha256.Sum256(artifact.Data)
	if artifact.SHA256 != hex.EncodeToString(digest[:]) {
		t.Fatalf("result contract digest = %q", artifact.SHA256)
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
			data: testPNG, want: "not a valid application/pdf",
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
			artifacts, rejected, err := svc.downloadSlackArtifacts(
				context.Background(),
				core.SlackInput{Attachments: []core.SlackAttachment{test.attachment}},
			)
			// Superseded on 2026-08-16. Each of these used to be a
			// slackfile.InvalidInput that ended the run; the file is still
			// refused, but the refusal is now a sentence the model reads.
			if err != nil {
				t.Fatalf("refusing one file failed the turn: %v", err)
			}
			if len(artifacts) != 0 {
				t.Fatalf("refused file was attached anyway: %+v", artifacts)
			}
			if len(rejected) != 1 || rejected[0].Name != test.attachment.Name ||
				!strings.Contains(rejected[0].Reason, test.want) {
				t.Fatalf("rejection = %+v, want a reason naming %q", rejected, test.want)
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
	artifacts, rejected, err := svc.downloadSlackArtifacts(context.Background(), core.SlackInput{
		Attachments: []core.SlackAttachment{{ID: "FDELAYED", Name: "attachment"}},
	})
	if err != nil || len(rejected) != 0 {
		t.Fatalf("resolved file was refused: %+v, %v", rejected, err)
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
	_, _, err = svc.agentRunArtifacts(context.Background(), core.AgentRun{
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
	artifacts, rejected, err := svc.agentRunArtifacts(ctx, core.AgentRun{
		SourceKind: "watch", SourceID: input.ID,
	})
	if err != nil || len(rejected) != 0 {
		t.Fatalf("inherited screenshot was refused: %+v, %v", rejected, err)
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
