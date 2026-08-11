package mentioncontext

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

const RequestWindow = 5 * time.Minute

type HistoryLoader func(
	context.Context,
	string,
	string,
	string,
	string,
	int,
) ([]slackui.HistoryMessage, error)

func IsBareMention(input core.SlackInput, botUserID string) bool {
	text := strings.TrimSpace(strings.ReplaceAll(input.Text, "<@"+botUserID+">", ""))
	return input.Kind == "mention" && botUserID != "" && text == "" && len(input.Attachments) == 0
}

// Resolve treats a bare mention as a nudge for the immediately preceding
// message only when the same person wrote both. It does not reach past another
// participant or revive old channel conversation.
func Resolve(
	ctx context.Context,
	input core.SlackInput,
	botUserID string,
	limit int,
	historyLoader HistoryLoader,
) (core.SlackInput, bool, error) {
	history, err := historyLoader(ctx, input.ChannelID, "", input.MessageTS, "", limit)
	if err != nil {
		return core.SlackInput{}, false, err
	}
	currentAt := messageTime(input.MessageTS, input.ReceivedAt)
	var previous slackui.HistoryMessage
	var previousAt time.Time
	for _, message := range history {
		observedAt := messageTime(message.Timestamp, time.Time{})
		if observedAt.IsZero() || (!currentAt.IsZero() && !observedAt.Before(currentAt)) {
			continue
		}
		if previousAt.IsZero() || observedAt.After(previousAt) {
			previous = message
			previousAt = observedAt
		}
	}
	text := strings.TrimSpace(strings.ReplaceAll(previous.Text, "<@"+botUserID+">", ""))
	if previousAt.IsZero() ||
		(!currentAt.IsZero() && currentAt.Sub(previousAt) > RequestWindow) ||
		previous.BotID != "" || previous.UserID != input.UserID ||
		(text == "" && len(previous.Files) == 0) {
		return core.SlackInput{}, false, nil
	}
	attachments := make([]core.SlackAttachment, 0, len(previous.Files))
	for _, file := range previous.Files {
		attachments = append(attachments, core.SlackAttachment{
			ID: file.ID, Name: file.Name, MediaType: file.MediaType,
			Size: file.Size, URLPrivate: file.URLPrivate,
		})
	}
	return core.SlackInput{
		Kind: "message", TeamID: input.TeamID, ChannelID: input.ChannelID,
		MessageTS: previous.Timestamp, UserID: previous.UserID, Text: previous.Text,
		Attachments: attachments, Reactions: reactions(previous.Reactions),
		ReceivedAt: previousAt,
	}, true, nil
}

func Apply(input core.SlackInput, request *core.SlackInput) core.SlackInput {
	if request == nil {
		return input
	}
	input.Text = request.Text
	input.Attachments = append([]core.SlackAttachment(nil), request.Attachments...)
	input.Reactions = append([]core.SlackReaction(nil), request.Reactions...)
	return input
}

func messageTime(timestamp string, fallback time.Time) time.Time {
	seconds, fraction, found := strings.Cut(strings.TrimSpace(timestamp), ".")
	if !found {
		return fallback
	}
	unixSeconds, err := strconv.ParseInt(seconds, 10, 64)
	if err != nil {
		return fallback
	}
	fraction = (fraction + "000000000")[:9]
	nanoseconds, err := strconv.ParseInt(fraction, 10, 64)
	if err != nil {
		return fallback
	}
	return time.Unix(unixSeconds, nanoseconds).UTC()
}

func reactions(values []slackui.HistoryReaction) []core.SlackReaction {
	result := make([]core.SlackReaction, 0, len(values))
	for _, value := range values {
		result = append(result, core.SlackReaction{
			Name: value.Name, Count: value.Count,
			UserIDs: append([]string(nil), value.UserIDs...),
		})
	}
	return result
}
