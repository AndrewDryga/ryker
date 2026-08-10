package slackui

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/socketmode"
)

type API interface {
	Auth(context.Context) (Identity, error)
	CreateChannel(context.Context, string, bool, string) (Channel, error)
	FindChannelByName(context.Context, string, string) (Channel, error)
	GetChannel(context.Context, string) (Channel, error)
	Invite(context.Context, string, ...string) error
	SetTopic(context.Context, string, string) error
	Post(context.Context, string, string, string, Message) (string, error)
	PostBroadcast(context.Context, string, string, string, Message) (string, error)
	PostEphemeral(context.Context, string, string, Message) error
	Update(context.Context, string, string, Message) error
	Pin(context.Context, string, string) error
	SetStatus(context.Context, string, string, string) error
	SetProgress(context.Context, string, string, string, []string) error
	PublishHome(context.Context, string, Message) error
	JoinChannel(context.Context, string) error
	UserAllowed(context.Context, string, string) (bool, error)
	UserGroupMembers(context.Context, string, string) ([]string, error)
	GetFile(context.Context, string) (HistoryFile, error)
	DownloadFile(context.Context, string, io.Writer) error
	UploadFile(context.Context, string, string, FileUpload) (string, error)
	RecentMessages(context.Context, string, string, string, string, int) ([]HistoryMessage, error)
	FindDeliveryMessage(context.Context, string, string, string) (string, error)
	FindDeliveryFile(context.Context, string, string, string) (string, error)
}

var (
	ErrNotFound         = errors.New("not found")
	ErrSearchIncomplete = errors.New("Slack history search was incomplete")
)

func RetryAfter(err error) (time.Duration, bool) {
	var rateLimited *slack.RateLimitedError
	if !errors.As(err, &rateLimited) || rateLimited.RetryAfter <= 0 {
		return 0, false
	}
	return rateLimited.RetryAfter, true
}

type Identity struct {
	TeamID       string
	BotUserID    string
	BotID        string
	BotName      string
	EnterpriseID string
	BotScopes    []string
}

type PreflightReport struct {
	Identity       Identity
	OperatorCount  int
	InviteCount    int
	SummonChannels int
	WatchChannels  int
}

type Channel struct {
	ID       string
	Name     string
	Creator  string
	Created  time.Time
	Private  bool
	Shared   bool
	Member   bool
	Archived bool
}

type HistoryMessage struct {
	Timestamp string
	ThreadTS  string
	UserID    string
	BotID     string
	Text      string
	Files     []HistoryFile
	Reactions []HistoryReaction
}

type HistoryReaction struct {
	Name    string
	Count   int
	UserIDs []string
}

type HistoryFile struct {
	ID         string
	Name       string
	MediaType  string
	Size       int64
	URLPrivate string
}

type FileUpload struct {
	Filename string
	Title    string
	AltText  string
	Data     []byte
	Message  *Message
}

type Client struct {
	api       *slack.Client
	socket    *socketmode.Client
	connected atomic.Bool
}

func New(botToken, appToken string) *Client {
	api := slack.New(
		botToken,
		slack.OptionAppLevelToken(appToken),
		slack.OptionLog(log.New(discardLogger{}, "", 0)),
		slack.OptionHTTPClient(&http.Client{Timeout: 20 * time.Second}),
	)
	return &Client{api: api, socket: socketmode.New(api)}
}

type discardLogger struct{}

func (discardLogger) Write(data []byte) (int, error) {
	return len(data), nil
}

func (c *Client) Events() <-chan socketmode.Event {
	return c.socket.Events
}

func (c *Client) Ack(request socketmode.Request) error {
	return c.socket.Ack(request)
}

func (c *Client) Run(ctx context.Context) error {
	return c.socket.RunContext(ctx)
}

func (c *Client) Connected() bool {
	return c.connected.Load()
}

func (c *Client) SetConnected(value bool) {
	c.connected.Store(value)
}

func (c *Client) Auth(ctx context.Context) (Identity, error) {
	response, err := c.api.AuthTestContext(ctx)
	if err != nil {
		return Identity{}, err
	}
	return Identity{
		TeamID: response.TeamID, BotUserID: response.UserID,
		BotID: response.BotID, BotName: response.User, EnterpriseID: response.EnterpriseID,
		BotScopes: splitScopes(response.Header.Get("X-OAuth-Scopes")),
	}, nil
}

func (c *Client) Preflight(
	ctx context.Context,
	teamID string,
	operators []string,
	inviteUsers []string,
	summonChannels []string,
	watchChannels []string,
) (PreflightReport, error) {
	identity, err := c.Auth(ctx)
	if err != nil {
		return PreflightReport{}, err
	}
	if identity.TeamID != teamID {
		return PreflightReport{}, fmt.Errorf(
			"bot token belongs to team %q, expected %q", identity.TeamID, teamID,
		)
	}
	if missing := missingBotScopes(identity.BotScopes); len(missing) > 0 {
		return PreflightReport{}, missingBotScopesError(missing)
	}
	for _, operator := range operators {
		allowed, err := c.UserAllowed(ctx, operator, teamID)
		if err != nil {
			return PreflightReport{}, fmt.Errorf("inspect operator %s: %w", operator, err)
		}
		if !allowed {
			return PreflightReport{}, fmt.Errorf(
				"operator %s is not an active full member of workspace %s", operator, teamID,
			)
		}
	}
	for _, inviteUser := range inviteUsers {
		allowed, err := c.UserAllowed(ctx, inviteUser, teamID)
		if err != nil {
			return PreflightReport{}, fmt.Errorf("inspect invite user %s: %w", inviteUser, err)
		}
		if !allowed {
			return PreflightReport{}, fmt.Errorf(
				"invite user %s is not an active full member of workspace %s",
				inviteUser, teamID,
			)
		}
	}
	checkedChannels := make(map[string]bool, len(summonChannels)+len(watchChannels))
	for _, configured := range []struct {
		kind     string
		channels []string
	}{
		{kind: "summon", channels: summonChannels},
		{kind: "watch", channels: watchChannels},
	} {
		for _, channelID := range configured.channels {
			if checkedChannels[channelID] {
				continue
			}
			checkedChannels[channelID] = true
			channel, err := c.api.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{
				ChannelID: channelID,
			})
			if err != nil {
				return PreflightReport{}, fmt.Errorf(
					"inspect %s channel %s: %w", configured.kind, channelID, err,
				)
			}
			if !channel.IsMember {
				return PreflightReport{}, channelMembershipError(
					identity.BotName, configured.kind, channelID, channel.Name,
				)
			}
		}
	}
	info, websocketURL, err := c.socket.OpenContext(ctx)
	if err != nil {
		return PreflightReport{}, fmt.Errorf("open Socket Mode connection: %w", err)
	}
	if info == nil || websocketURL == "" {
		return PreflightReport{}, errors.New("Slack returned no Socket Mode connection")
	}
	if err := dialSocketMode(ctx, websocketURL); err != nil {
		return PreflightReport{}, err
	}
	return PreflightReport{
		Identity: identity, OperatorCount: len(operators),
		InviteCount: len(inviteUsers), SummonChannels: len(summonChannels),
		WatchChannels: len(watchChannels),
	}, nil
}

func missingBotScopesError(missing []string) error {
	return fmt.Errorf(
		"bot token is missing required scopes: %s; apply deploy/slack-app-manifest.yaml and reinstall the app",
		strings.Join(missing, ", "),
	)
}

func channelMembershipError(botName, kind, channelID, channelName string) error {
	bot := "the bot"
	if botName != "" {
		bot = "@" + botName
	}
	channel := channelID
	if channelName != "" {
		channel = "#" + channelName + " (" + channelID + ")"
	}
	invite := "/invite " + bot
	return fmt.Errorf(
		"%s is not a member of %s channel %s; in that Slack channel, run: %s",
		bot, kind, channel, invite,
	)
}

func dialSocketMode(ctx context.Context, websocketURL string) error {
	connection, response, err := websocket.DefaultDialer.DialContext(ctx, websocketURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return fmt.Errorf("connect Socket Mode WebSocket: %w", err)
	}
	if err := connection.Close(); err != nil {
		return fmt.Errorf("close Socket Mode preflight connection: %w", err)
	}
	return nil
}

// requiredBotScopes are the scopes Responder cannot run without. Preflight
// refuses to report a healthy Slack integration when one is absent.
var requiredBotScopes = []string{
	"app_mentions:read",
	"assistant:write",
	"channels:history",
	"channels:manage",
	"channels:read",
	"chat:write",
	"commands",
	"files:read",
	"files:write",
	"groups:history",
	"groups:read",
	"groups:write",
	"im:history",
	"pins:write",
	"reactions:read",
	"reactions:write",
	"usergroups:read",
	"users:read",
}

// optionalBotScopes are requested by deploy/slack-app-manifest.yaml but do not
// fail preflight when the installed app has not granted them.
//
// Adding a scope to a manifest does not add it to a token: the app has to be
// reinstalled by a person, and until then a newer binary is running against an
// older grant. Making channels:join required would turn that ordinary window
// into "Slack: broken" on a deployment where every other Slack capability
// works, which is a false report in the opposite direction. What the absence
// actually costs is one thing — Responder cannot add itself to a public
// channel an operator configured — and the join path says exactly that when it
// happens instead of pretending the room is simply unreachable.
var optionalBotScopes = []string{
	"channels:join",
}

// manifestBotScopes is the full scope list deploy/slack-app-manifest.yaml must
// request, sorted the way the manifest reads. Keeping it derived is what stops
// the manifest and the binary from drifting into disagreement about what this
// app asks for.
func manifestBotScopes() []string {
	return slices.Sorted(slices.Values(slices.Concat(requiredBotScopes, optionalBotScopes)))
}

func (c *Client) DownloadFile(ctx context.Context, downloadURL string, writer io.Writer) error {
	return c.api.GetFileContext(ctx, downloadURL, writer)
}

func (c *Client) UploadFile(ctx context.Context, channel, threadTS string, upload FileUpload) (string, error) {
	var blocks slack.Blocks
	if upload.Message != nil {
		blocks = slack.Blocks{BlockSet: upload.Message.FileBlocks()}
	}
	file, err := c.api.UploadFileContext(ctx, slack.UploadFileParameters{
		Reader: bytes.NewReader(upload.Data), FileSize: len(upload.Data),
		Filename: upload.Filename, Title: upload.Title, AltTxt: upload.AltText,
		Channel: channel, ThreadTimestamp: threadTS, Blocks: blocks,
	})
	if err != nil {
		return "", err
	}
	if file == nil || file.ID == "" {
		return "", errors.New("Slack returned no uploaded file identity")
	}
	return file.ID, nil
}

func (c *Client) GetFile(ctx context.Context, fileID string) (HistoryFile, error) {
	file, _, _, err := c.api.GetFileInfoContext(ctx, fileID, 1, 1)
	if err != nil {
		return HistoryFile{}, err
	}
	if file == nil {
		return HistoryFile{}, errors.New("Slack returned no file information")
	}
	return historyFile(*file), nil
}

func splitScopes(value string) []string {
	var result []string
	for scope := range strings.SplitSeq(value, ",") {
		scope = strings.TrimSpace(scope)
		if scope != "" {
			result = append(result, scope)
		}
	}
	return result
}

func missingBotScopes(granted []string) []string {
	have := make(map[string]bool, len(granted))
	for _, scope := range granted {
		have[scope] = true
	}
	var missing []string
	for _, scope := range requiredBotScopes {
		if !have[scope] {
			missing = append(missing, scope)
		}
	}
	return missing
}

func (c *Client) CreateChannel(ctx context.Context, name string, private bool, teamID string) (Channel, error) {
	channel, err := c.api.CreateConversationContext(ctx, slack.CreateConversationParams{
		ChannelName: name,
		IsPrivate:   private,
		TeamID:      teamID,
	})
	if err != nil {
		return Channel{}, err
	}
	return Channel{
		ID: channel.ID, Name: channel.Name, Creator: channel.Creator,
		Created: time.Unix(int64(channel.Created), 0).UTC(),
		Private: channel.IsPrivate,
		Shared:  channel.IsShared || channel.IsExtShared || channel.IsOrgShared,
	}, nil
}

func (c *Client) FindChannelByName(ctx context.Context, name, teamID string) (Channel, error) {
	cursor := ""
	for page := 0; page < 5; page++ {
		channels, next, err := c.api.GetConversationsContext(ctx, &slack.GetConversationsParameters{
			Cursor: cursor, ExcludeArchived: true, Limit: 200,
			Types: []string{"public_channel", "private_channel"}, TeamID: teamID,
		})
		if err != nil {
			return Channel{}, err
		}
		for _, channel := range channels {
			if channel.Name == name {
				return Channel{
					ID: channel.ID, Name: channel.Name, Creator: channel.Creator,
					Created: time.Unix(int64(channel.Created), 0).UTC(),
					Private: channel.IsPrivate,
					Shared:  channel.IsShared || channel.IsExtShared || channel.IsOrgShared,
				}, nil
			}
		}
		cursor = next
		if cursor == "" {
			break
		}
	}
	return Channel{}, errors.New("channel not found")
}

func (c *Client) GetChannel(ctx context.Context, channelID string) (Channel, error) {
	channel, err := c.api.GetConversationInfoContext(ctx, &slack.GetConversationInfoInput{
		ChannelID: channelID,
	})
	if err != nil {
		if strings.Contains(err.Error(), "channel_not_found") {
			return Channel{}, ErrNotFound
		}
		return Channel{}, err
	}
	return Channel{
		ID: channel.ID, Name: channel.Name, Creator: channel.Creator,
		Created:  time.Unix(int64(channel.Created), 0).UTC(),
		Private:  channel.IsPrivate,
		Shared:   channel.IsShared || channel.IsExtShared || channel.IsOrgShared,
		Member:   channel.IsMember,
		Archived: channel.IsArchived,
	}, nil
}

func (c *Client) ListChannels(ctx context.Context, teamID string) ([]Channel, error) {
	cursor := ""
	var result []Channel
	for page := 0; page < 100; page++ {
		channels, next, err := c.api.GetConversationsForUserContext(
			ctx,
			&slack.GetConversationsForUserParameters{
				Cursor: cursor, ExcludeArchived: false, Limit: 200,
				Types: []string{"public_channel", "private_channel"}, TeamID: teamID,
			},
		)
		if err != nil {
			return nil, err
		}
		for _, channel := range channels {
			result = append(result, Channel{
				ID: channel.ID, Name: channel.Name, Creator: channel.Creator,
				Created: time.Unix(int64(channel.Created), 0).UTC(),
				Private: channel.IsPrivate,
				Shared:  channel.IsShared || channel.IsExtShared || channel.IsOrgShared,
				Member:  true, Archived: channel.IsArchived,
			})
		}
		if next == "" {
			return result, nil
		}
		if next == cursor {
			return nil, errors.New("Slack channel listing returned a repeated cursor")
		}
		cursor = next
	}
	return nil, errors.New("Slack channel listing exceeded 100 pages")
}

// JoinChannel adds the bot to a public channel it was configured to watch.
//
// conversations.join is the only self-service door into a room, and it opens
// for public channels only: a private channel needs a member to run /invite,
// and Slack answers method_not_supported_for_channel_type rather than letting
// an app add itself. Callers therefore have to know which kind of channel they
// are looking at before they try, which is why this takes no decision of its
// own beyond treating an existing membership as success.
func (c *Client) JoinChannel(ctx context.Context, channelID string) error {
	if strings.TrimSpace(channelID) == "" {
		return errors.New("joining a channel needs a channel ID")
	}
	_, _, _, err := c.api.JoinConversationContext(ctx, channelID)
	if err != nil && !strings.Contains(err.Error(), "already_in_channel") {
		return err
	}
	return nil
}

// MissingScope reports that Slack refused because the installed app was never
// granted the scope the call needs.
//
// This is the one failure a newer build produces on an older installation:
// deploy/slack-app-manifest.yaml requests a scope, the binary calls the method,
// and the token in the workspace predates the request. Waiting cannot fix it
// and neither can retrying — only a human reinstalling the app can — so the
// distinction has to be legible to the caller rather than folded into "the
// join failed".
func MissingScope(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "missing_scope")
}

func (c *Client) Invite(ctx context.Context, channel string, users ...string) error {
	if len(users) == 0 {
		return nil
	}
	_, err := c.api.InviteUsersToConversationContext(ctx, channel, users...)
	if err != nil && !strings.Contains(err.Error(), "already_in_channel") {
		return err
	}
	return nil
}

func (c *Client) SetTopic(ctx context.Context, channel, topic string) error {
	_, err := c.api.SetTopicOfConversationContext(ctx, channel, truncateUTF8(topic, 250))
	return err
}

func (c *Client) Post(ctx context.Context, deliveryID, channel, threadTS string, message Message) (string, error) {
	return c.post(ctx, deliveryID, channel, threadTS, message, false)
}

func (c *Client) PostBroadcast(
	ctx context.Context,
	deliveryID string,
	channel string,
	threadTS string,
	message Message,
) (string, error) {
	if threadTS == "" {
		return "", errors.New("Slack broadcast reply requires a thread timestamp")
	}
	return c.post(ctx, deliveryID, channel, threadTS, message, true)
}

func (c *Client) post(
	ctx context.Context,
	deliveryID string,
	channel string,
	threadTS string,
	message Message,
	broadcast bool,
) (string, error) {
	options := []slack.MsgOption{
		slack.MsgOptionText(message.Text, false),
		slack.MsgOptionBlocks(message.Blocks()...),
		slack.MsgOptionDisableLinkUnfurl(),
		slack.MsgOptionDisableMediaUnfurl(),
		slack.MsgOptionMetadata(slack.SlackMetadata{
			EventType:    "responder_delivery",
			EventPayload: map[string]any{"id": deliveryID},
		}),
	}
	if threadTS != "" {
		options = append(options, slack.MsgOptionTS(threadTS))
	}
	if broadcast {
		options = append(options, slack.MsgOptionBroadcast())
	}
	_, timestamp, err := c.api.PostMessageContext(ctx, channel, options...)
	return timestamp, err
}

func (c *Client) PostEphemeral(
	ctx context.Context,
	channel, user string,
	message Message,
) error {
	_, err := c.api.PostEphemeralContext(
		ctx,
		channel,
		user,
		slack.MsgOptionText(message.Text, false),
		slack.MsgOptionBlocks(message.Blocks()...),
		slack.MsgOptionDisableLinkUnfurl(),
		slack.MsgOptionDisableMediaUnfurl(),
	)
	return err
}

func (c *Client) Update(ctx context.Context, channel, timestamp string, message Message) error {
	_, _, _, err := c.api.UpdateMessageContext(
		ctx,
		channel,
		timestamp,
		slack.MsgOptionText(message.Text, false),
		slack.MsgOptionBlocks(message.Blocks()...),
		slack.MsgOptionDisableLinkUnfurl(),
		slack.MsgOptionDisableMediaUnfurl(),
	)
	return err
}

func (c *Client) Pin(ctx context.Context, channel, timestamp string) error {
	err := c.api.AddPinContext(ctx, channel, slack.NewRefToMessage(channel, timestamp))
	if err != nil && !strings.Contains(err.Error(), "already_pinned") {
		return err
	}
	return nil
}

func (c *Client) React(
	ctx context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	err := c.api.AddReactionContext(
		ctx,
		reaction,
		slack.NewRefToMessage(channel, timestamp),
	)
	if err != nil && !strings.Contains(err.Error(), "already_reacted") {
		return err
	}
	return nil
}

func (c *Client) Unreact(
	ctx context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	err := c.api.RemoveReactionContext(
		ctx,
		reaction,
		slack.NewRefToMessage(channel, timestamp),
	)
	if err != nil && !strings.Contains(err.Error(), "no_reaction") {
		return err
	}
	return nil
}

func (c *Client) SetStatus(ctx context.Context, channel, threadTS, status string) error {
	return c.SetProgress(ctx, channel, threadTS, status, nil)
}

func (c *Client) SetProgress(
	ctx context.Context,
	channel string,
	threadTS string,
	status string,
	loadingMessages []string,
) error {
	messages := make([]string, 0, min(len(loadingMessages), 10))
	for _, message := range loadingMessages[:min(len(loadingMessages), 10)] {
		messages = append(messages, truncateUTF8(message, 100))
	}
	return c.api.SetAssistantThreadsStatusContext(ctx, slack.AssistantThreadsSetStatusParameters{
		ChannelID: channel, ThreadTS: threadTS,
		Status: truncateUTF8(status, 100), LoadingMessages: messages,
	})
}

func (c *Client) PublishHome(ctx context.Context, userID string, message Message) error {
	_, err := c.api.PublishViewContext(ctx, slack.PublishViewContextRequest{
		UserID: userID,
		View: slack.HomeTabViewRequest{
			Type:       slack.VTHomeTab,
			Blocks:     slack.Blocks{BlockSet: message.Blocks()},
			CallbackID: "responder_operations_home",
		},
	})
	return describeViewError(err)
}

// describeViewError says which block Slack objected to.
//
// SlackErrorResponse carries Slack's explanation in ResponseMetadata.Messages
// — "invalid block at index 7", and so on — but its Error() returns only the
// bare code. So a rejected App Home surfaced as "invalid_arguments" and nothing
// else, and diagnosing it meant guessing at Block Kit limits one at a time.
// The API already knew the answer; it just was not being read.
func describeViewError(err error) error {
	var response slack.SlackErrorResponse
	if !errors.As(err, &response) {
		return err
	}
	detail := append([]string{}, response.ResponseMetadata.Messages...)
	for _, item := range response.Errors {
		if item.Message != nil {
			detail = append(detail, *item.Message)
		}
	}
	if len(detail) == 0 {
		return err
	}
	return fmt.Errorf("%w: %s", err, strings.Join(detail, "; "))
}

func (c *Client) UserAllowed(ctx context.Context, userID, teamID string) (bool, error) {
	user, err := c.api.GetUserInfoContext(ctx, userID)
	if err != nil {
		return false, err
	}
	if user.TeamID != teamID || user.Deleted || user.IsBot || user.IsAppUser ||
		user.IsRestricted || user.IsUltraRestricted || user.IsStranger {
		return false, nil
	}
	return true, nil
}

// UserTimezone returns Slack's IANA timezone for calendar schedule normalization.
func (c *Client) UserTimezone(ctx context.Context, userID string) (string, error) {
	user, err := c.api.GetUserInfoContext(ctx, userID)
	if err != nil {
		return "", err
	}
	return user.TZ, nil
}

// UserNames returns the workspace's current human-readable labels. Responder
// snapshots them for local diagnostics; dashboard requests never call Slack.
func (c *Client) UserNames(ctx context.Context) (map[string]string, error) {
	users, err := c.api.GetUsersContext(ctx)
	if err != nil {
		return nil, err
	}
	names := make(map[string]string, len(users))
	for _, user := range users {
		name := strings.TrimSpace(user.Profile.DisplayName)
		if name == "" {
			name = strings.TrimSpace(user.Profile.RealName)
		}
		if name == "" {
			name = strings.TrimSpace(user.RealName)
		}
		if name == "" {
			name = strings.TrimSpace(user.Name)
		}
		if user.ID != "" && name != "" {
			names[user.ID] = name
		}
	}
	return names, nil
}

func (c *Client) UserGroupMembers(
	ctx context.Context,
	userGroupID string,
	teamID string,
) ([]string, error) {
	if userGroupID == "" || teamID == "" {
		return nil, errors.New("Slack user group and workspace are required")
	}
	return c.api.GetUserGroupMembersContext(
		ctx,
		userGroupID,
		slack.GetUserGroupMembersOptionTeamID(teamID),
	)
}

func (c *Client) RecentMessages(
	ctx context.Context,
	channel string,
	threadTS string,
	targetTS string,
	sinceTS string,
	limit int,
) ([]HistoryMessage, error) {
	if channel == "" || limit < 1 || limit > 100 {
		return nil, errors.New("Slack history requires a channel and limit between 1 and 100")
	}
	var messages []slack.Message
	if threadTS != "" {
		const pageSize = 200
		const maxPages = 50
		cursor := ""
		for page := 0; page < maxPages; page++ {
			result, hasMore, next, err := c.api.GetConversationRepliesContext(
				ctx,
				&slack.GetConversationRepliesParameters{
					ChannelID: channel,
					Timestamp: threadTS,
					Cursor:    cursor,
					Latest:    targetTS,
					Oldest:    sinceTS,
					Inclusive: targetTS != "",
					Limit:     pageSize,
				},
			)
			if err != nil {
				return nil, err
			}
			messages = append(messages, result...)
			if next == "" {
				if hasMore {
					return nil, errors.New(
						"Slack thread history is incomplete and has no continuation cursor",
					)
				}
				break
			}
			if next == cursor {
				return nil, errors.New("Slack thread history returned a repeated cursor")
			}
			cursor = next
			if page == maxPages-1 {
				return nil, fmt.Errorf(
					"Slack thread exceeds the bounded %d-message history scan",
					pageSize*maxPages,
				)
			}
		}
	} else {
		result, err := c.api.GetConversationHistoryContext(
			ctx,
			&slack.GetConversationHistoryParameters{
				ChannelID: channel,
				Latest:    targetTS,
				Oldest:    sinceTS,
				Inclusive: targetTS != "",
				Limit:     limit,
			},
		)
		if err != nil {
			return nil, err
		}
		messages = result.Messages
	}
	history := make([]HistoryMessage, 0, len(messages))
	for _, message := range messages {
		files := historyFiles(message.Files)
		text := NormalizedMessageText(message)
		if message.Timestamp == "" || (text == "" && len(files) == 0) {
			continue
		}
		history = append(history, HistoryMessage{
			Timestamp: message.Timestamp,
			ThreadTS:  message.ThreadTimestamp,
			UserID:    message.User,
			BotID:     message.BotID,
			Text:      text,
			Files:     files,
			Reactions: historyReactions(message.Reactions),
		})
	}
	if threadTS != "" {
		history = selectThreadHistory(history, threadTS, limit)
	}
	return history, nil
}

func historyReactions(reactions []slack.ItemReaction) []HistoryReaction {
	const (
		maxReactionTypes = 20
		maxReactionUsers = 20
	)
	result := make([]HistoryReaction, 0, min(len(reactions), maxReactionTypes))
	for _, reaction := range reactions {
		name := strings.TrimSpace(reaction.Name)
		if name == "" {
			continue
		}
		users := reaction.Users
		if len(users) > maxReactionUsers {
			users = users[:maxReactionUsers]
		}
		result = append(result, HistoryReaction{
			Name: name, Count: reaction.Count,
			UserIDs: append([]string(nil), users...),
		})
		if len(result) == maxReactionTypes {
			break
		}
	}
	return result
}

// NormalizedMessageText preserves the visible content of Slack messages whose
// top-level text is empty, including legacy attachments and Block Kit blocks.
func NormalizedMessageText(message slack.Message) string {
	parts := make([]string, 0, 8)
	seen := make(map[string]struct{})
	add := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		if _, exists := seen[value]; exists {
			return
		}
		seen[value] = struct{}{}
		parts = append(parts, value)
	}
	add(message.Text)
	for _, attachment := range message.Attachments {
		before := len(parts)
		add(attachment.Pretext)
		if attachment.Title != "" && attachment.TitleLink != "" {
			add("<" + attachment.TitleLink + "|" + attachment.Title + ">")
		} else {
			add(attachment.Title)
		}
		add(attachment.Text)
		for _, field := range attachment.Fields {
			if field.Title != "" && field.Value != "" {
				add(field.Title + ": " + field.Value)
			} else {
				add(firstNonemptyString(field.Title, field.Value))
			}
		}
		for _, block := range attachment.Blocks.BlockSet {
			addHistoryBlockText(block, add)
		}
		if len(parts) == before {
			add(attachment.Fallback)
		}
	}
	for _, block := range message.Blocks.BlockSet {
		addHistoryBlockText(block, add)
	}
	return strings.Join(parts, "\n")
}

func addHistoryBlockText(block slack.Block, add func(string)) {
	switch value := block.(type) {
	case *slack.SectionBlock:
		if value.Text != nil {
			add(value.Text.Text)
		}
		for _, field := range value.Fields {
			if field != nil {
				add(field.Text)
			}
		}
	case *slack.HeaderBlock:
		if value.Text != nil {
			add(value.Text.Text)
		}
	case *slack.MarkdownBlock:
		add(value.Text)
	case *slack.ContextBlock:
		for _, element := range value.ContextElements.Elements {
			switch item := element.(type) {
			case *slack.TextBlockObject:
				add(item.Text)
			case *slack.ImageBlockElement:
				add(item.AltText)
			}
		}
	case *slack.ImageBlock:
		if value.Title != nil {
			add(value.Title.Text)
		}
		add(value.AltText)
	}
}

func firstNonemptyString(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func historyFiles(files []slack.File) []HistoryFile {
	result := make([]HistoryFile, 0, len(files))
	for _, file := range files {
		if file.ID == "" {
			continue
		}
		result = append(result, historyFile(file))
	}
	return result
}

func historyFile(file slack.File) HistoryFile {
	privateURL := file.URLPrivateDownload
	if privateURL == "" {
		privateURL = file.URLPrivate
	}
	return HistoryFile{
		ID: file.ID, Name: file.Name, MediaType: file.Mimetype,
		Size: int64(file.Size), URLPrivate: privateURL,
	}
}

func selectThreadHistory(
	history []HistoryMessage,
	threadTS string,
	limit int,
) []HistoryMessage {
	if len(history) <= limit {
		return history
	}
	root := -1
	for index := range history {
		if history[index].Timestamp == threadTS {
			root = index
			break
		}
	}
	if root < 0 || limit == 1 {
		return slices.Clone(history[len(history)-limit:])
	}
	result := make([]HistoryMessage, 0, limit)
	result = append(result, history[root])
	for _, message := range history[len(history)-(limit-1):] {
		if message.Timestamp != threadTS {
			result = append(result, message)
		}
	}
	if len(result) > limit {
		result = append(result[:1], result[len(result)-(limit-1):]...)
	}
	return result
}

func (c *Client) FindDeliveryMessage(
	ctx context.Context,
	channel string,
	threadTS string,
	deliveryID string,
) (string, error) {
	if threadTS != "" {
		cursor := ""
		for page := 0; page < 5; page++ {
			messages, _, next, err := c.api.GetConversationRepliesContext(
				ctx, &slack.GetConversationRepliesParameters{
					ChannelID: channel, Timestamp: threadTS, Cursor: cursor,
					Limit: 100, IncludeAllMetadata: true,
				},
			)
			if err != nil {
				return "", err
			}
			if timestamp := findMetadataMessage(messages, deliveryID); timestamp != "" {
				return timestamp, nil
			}
			cursor = next
			if cursor == "" {
				return "", ErrNotFound
			}
		}
		return "", ErrSearchIncomplete
	}
	cursor := ""
	for page := 0; page < 5; page++ {
		response, err := c.api.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{
			ChannelID: channel, Cursor: cursor, Limit: 100, IncludeAllMetadata: true,
		})
		if err != nil {
			return "", err
		}
		if timestamp := findMetadataMessage(response.Messages, deliveryID); timestamp != "" {
			return timestamp, nil
		}
		cursor = response.ResponseMetaData.NextCursor
		if cursor == "" {
			return "", ErrNotFound
		}
	}
	return "", ErrSearchIncomplete
}

func (c *Client) FindDeliveryFile(ctx context.Context, channel, threadTS, filename string) (string, error) {
	find := func(messages []slack.Message) string {
		for _, message := range messages {
			for _, file := range message.Files {
				if file.Name == filename {
					return file.ID
				}
			}
		}
		return ""
	}
	if threadTS != "" {
		cursor := ""
		for page := 0; page < 5; page++ {
			messages, _, next, err := c.api.GetConversationRepliesContext(ctx, &slack.GetConversationRepliesParameters{
				ChannelID: channel, Timestamp: threadTS, Cursor: cursor, Limit: 100,
			})
			if err != nil {
				return "", err
			}
			if id := find(messages); id != "" {
				return id, nil
			}
			cursor = next
			if cursor == "" {
				return "", ErrNotFound
			}
		}
		return "", ErrSearchIncomplete
	}
	cursor := ""
	for page := 0; page < 5; page++ {
		response, err := c.api.GetConversationHistoryContext(ctx, &slack.GetConversationHistoryParameters{ChannelID: channel, Cursor: cursor, Limit: 100})
		if err != nil {
			return "", err
		}
		if id := find(response.Messages); id != "" {
			return id, nil
		}
		cursor = response.ResponseMetaData.NextCursor
		if cursor == "" {
			return "", ErrNotFound
		}
	}
	return "", ErrSearchIncomplete
}

func findMetadataMessage(messages []slack.Message, deliveryID string) string {
	for _, message := range messages {
		if (message.Metadata.EventType == "responder_delivery" ||
			message.Metadata.EventType == "responder_outbox") &&
			fmt.Sprint(message.Metadata.EventPayload["id"]) == deliveryID {
			return message.Timestamp
		}
	}
	return ""
}
