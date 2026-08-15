package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackfile"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/taskpr"
)

const maxAgentInputArtifacts = 4

func (s *Service) downloadSlackArtifacts(
	ctx context.Context,
	input core.SlackInput,
) ([]coop.InputArtifact, error) {
	if len(input.Attachments) == 0 {
		return nil, nil
	}
	if len(input.Attachments) > s.cfg.Limits.MaxSlackFiles {
		return nil, slackfile.InvalidInput(
			"Slack message has %d files; the configured limit is %d",
			len(input.Attachments), s.cfg.Limits.MaxSlackFiles,
		)
	}
	artifacts := make([]coop.InputArtifact, 0, len(input.Attachments))
	total := 0
	for _, attachment := range input.Attachments {
		if attachment.URLPrivate == "" || attachment.MediaType == "" {
			resolved, err := s.slack.GetFile(ctx, attachment.ID)
			if err != nil {
				return nil, fmt.Errorf("resolve Slack file %q: %w", attachment.ID, err)
			}
			attachment = slackfile.Merge(attachment, resolved)
		}
		if attachment.Size < 0 || attachment.Size > int64(s.cfg.Limits.MaxSlackFileBytes) {
			return nil, slackfile.InvalidInput(
				"Slack file %q exceeds the configured %d-byte limit",
				attachment.Name, s.cfg.Limits.MaxSlackFileBytes,
			)
		}
		if err := slackfile.ValidateURL(attachment.URLPrivate); err != nil {
			return nil, slackfile.InvalidInput("Slack file %q: %v", attachment.Name, err)
		}
		mediaType, err := slackfile.CanonicalMediaType(attachment.MediaType)
		if err != nil {
			return nil, slackfile.InvalidInput("Slack file %q: %v", attachment.Name, err)
		}
		writer := slackfile.NewBoundedWriter(s.cfg.Limits.MaxSlackFileBytes)
		if err := s.slack.DownloadFile(ctx, attachment.URLPrivate, writer); err != nil {
			if errors.Is(err, slackfile.ErrTooLarge) {
				return nil, slackfile.InvalidInput(
					"Slack file %q exceeds the configured %d-byte limit",
					attachment.Name, s.cfg.Limits.MaxSlackFileBytes,
				)
			}
			return nil, fmt.Errorf("download Slack file %q: %w", attachment.Name, err)
		}
		data := writer.Bytes()
		if len(data) == 0 {
			return nil, slackfile.InvalidInput("Slack file %q is empty", attachment.Name)
		}
		if total > s.cfg.Limits.MaxSlackFileTotalBytes-len(data) {
			return nil, slackfile.InvalidInput(
				"Slack files exceed the configured %d-byte total limit",
				s.cfg.Limits.MaxSlackFileTotalBytes,
			)
		}
		total += len(data)
		if !slackfile.MatchesMediaType(mediaType, data) {
			return nil, slackfile.InvalidInput(
				"Slack file %q content does not match declared media type %q",
				attachment.Name, mediaType,
			)
		}
		digest := sha256.Sum256(data)
		artifacts = append(artifacts, coop.InputArtifact{
			Name:      slackfile.SafeName(attachment.Name, attachment.ID),
			MediaType: mediaType, SHA256: hex.EncodeToString(digest[:]),
			Data: append([]byte(nil), data...),
		})
	}
	return artifacts, nil
}

func (s *Service) agentRunArtifacts(
	ctx context.Context,
	run core.AgentRun,
) ([]coop.InputArtifact, error) {
	switch run.SourceKind {
	case "watch", "slack":
	default:
		return nil, nil
	}
	if strings.TrimSpace(run.SourceID) == "" {
		return nil, nil
	}
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return nil, fmt.Errorf("load Slack attachment source: %w", err)
	}
	if len(input.Attachments) == 0 && input.ThreadTS != "" {
		history, historyErr := s.recentMessages(
			ctx,
			input.ChannelID,
			input.ThreadTS,
			input.MessageTS,
			"",
			s.cfg.Slack.WatchContext,
		)
		if historyErr != nil {
			return nil, fmt.Errorf("load Slack thread attachment context: %w", historyErr)
		}
		input.Attachments = s.latestHumanThreadAttachments(history, input.MessageTS)
	}
	return s.downloadSlackArtifacts(ctx, input)
}

func (s *Service) augmentAgentRunArtifacts(
	ctx context.Context,
	prompt string,
	artifacts []coop.InputArtifact,
) ([]coop.InputArtifact, error) {
	client, _ := s.publisher.(taskpr.Inspector)
	return taskpr.AugmentArtifacts(
		ctx, prompt, artifacts, maxAgentInputArtifacts, s.cfg.Repositories, client,
	)
}

func (s *Service) latestHumanThreadAttachments(
	history []slackui.HistoryMessage,
	targetTS string,
) []core.SlackAttachment {
	var latest slackui.HistoryMessage
	for _, message := range history {
		if message.Timestamp == "" || message.Timestamp >= targetTS ||
			message.BotID != "" || message.UserID == "" || len(message.Files) == 0 {
			continue
		}
		if latest.Timestamp == "" || message.Timestamp > latest.Timestamp {
			latest = message
		}
	}
	attachments := make([]core.SlackAttachment, 0, min(
		len(latest.Files),
		s.cfg.Limits.MaxSlackFiles,
	))
	var declaredTotal int64
	for _, file := range latest.Files {
		if len(attachments) >= s.cfg.Limits.MaxSlackFiles {
			break
		}
		if file.Size < 0 || file.Size > int64(s.cfg.Limits.MaxSlackFileBytes) {
			continue
		}
		mediaType := file.MediaType
		if mediaType != "" {
			canonical, err := slackfile.CanonicalMediaType(mediaType)
			if err != nil {
				continue
			}
			mediaType = canonical
		}
		if file.URLPrivate != "" {
			if err := slackfile.ValidateURL(file.URLPrivate); err != nil {
				continue
			}
		}
		if declaredTotal > int64(s.cfg.Limits.MaxSlackFileTotalBytes)-file.Size {
			continue
		}
		declaredTotal += file.Size
		attachments = append(attachments, core.SlackAttachment{
			ID: file.ID, Name: file.Name, MediaType: mediaType,
			Size: file.Size, URLPrivate: file.URLPrivate,
		})
	}
	return attachments
}
