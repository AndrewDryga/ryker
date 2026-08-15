package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackfile"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func (s *Service) enqueueGeneratedVisuals(
	ctx context.Context,
	keyPrefix string,
	incidentID string,
	episodeID string,
	sourceInputID string,
	channelID string,
	threadTS string,
	sessionID string,
	turnID string,
	visuals []core.GeneratedVisual,
	message *slackui.Message,
) error {
	if len(visuals) == 0 {
		return nil
	}
	if len(visuals) > s.cfg.Limits.MaxGeneratedVisuals {
		return errors.New("agent response references too many generated visuals")
	}
	if episodeID != "" {
		if _, err := s.bindEpisodeDestination(
			ctx, episodeID, channelID, threadTS, "visual_response_location",
		); err != nil {
			return err
		}
	}
	turn, err := s.coop.GetTurn(ctx, sessionID, turnID)
	if err != nil {
		return fmt.Errorf("read generated visual metadata: %w", err)
	}
	metadata := make(map[string]coop.OutputArtifact, len(turn.OutputArtifacts)*2)
	for _, artifact := range turn.OutputArtifacts {
		metadata[artifact.ID] = artifact
		metadata[artifact.Name] = artifact
	}
	prepared := make([]slackfile.Delivery, 0, len(visuals))
	seen := make(map[string]bool, len(visuals))
	total := 0
	for index, visual := range visuals {
		visual.Artifact = strings.TrimSpace(visual.Artifact)
		visual.Title = strings.TrimSpace(visual.Title)
		visual.AltText = strings.TrimSpace(visual.AltText)
		artifact, ok := metadata[visual.Artifact]
		if !ok || seen[artifact.ID] {
			return errors.New("agent response references an unknown or duplicate generated visual")
		}
		seen[artifact.ID] = true
		if visual.Title == "" || len(visual.Title) > 200 || visual.AltText == "" || len(visual.AltText) > 1000 {
			return errors.New("generated visual title or alt text is outside bounds")
		}
		if !slackfile.GeneratedImageMediaType(artifact.MediaType) || artifact.Bytes <= 0 || artifact.Bytes > int64(s.cfg.Limits.MaxGeneratedVisualBytes) {
			return errors.New("generated visual metadata is outside configured bounds")
		}
		fetched, err := s.coop.GetOutputArtifact(ctx, sessionID, turnID, artifact.ID)
		if err != nil {
			return fmt.Errorf("fetch generated visual: %w", err)
		}
		digest := sha256.Sum256(fetched.Data)
		digestHex := hex.EncodeToString(digest[:])
		if fetched.MediaType != artifact.MediaType || int64(len(fetched.Data)) != artifact.Bytes || digestHex != artifact.SHA256 {
			return errors.New("generated visual content does not match Coop metadata")
		}
		if total > s.cfg.Limits.MaxGeneratedVisualTotalBytes-len(fetched.Data) {
			return errors.New("generated visuals exceed their configured total bound")
		}
		total += len(fetched.Data)
		deliveryID := fmt.Sprintf("%s_visual_%02d", keyPrefix, index+1)
		file := slackfile.Delivery{
			Filename: slackfile.VisualFilename(artifact.Name, deliveryID), Title: visual.Title,
			AltText: visual.AltText, MediaType: artifact.MediaType, SHA256: digestHex, Data: fetched.Data,
		}
		if index == 0 && message != nil {
			copy := *message
			copy = s.sanitizeMessage(copy)
			file.Message = &copy
		}
		prepared = append(prepared, file)
	}
	for index, file := range prepared {
		body, err := json.Marshal(file)
		if err != nil {
			return err
		}
		_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: fmt.Sprintf("%s_visual_%02d", keyPrefix, index+1), IncidentID: incidentID,
			EpisodeID: episodeID, SourceInputID: sourceInputID,
			Operation: "file", Kind: "generated_visual", ChannelID: channelID,
			ThreadTS: threadTS, Body: body, ResponseRoot: index == 0,
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) enqueueGeneratedVisualFailure(
	ctx context.Context,
	delivery core.SlackDelivery,
	file slackfile.Delivery,
	detail string,
) error {
	fix := "Slack rejected the upload after the configured retries. Check the app's file-upload access, then reply `retry the chart upload`."
	if strings.Contains(strings.ToLower(detail), "missing_scope") {
		fix = "This Slack app is missing `files:write`. Apply the current app manifest, reinstall the app in this workspace, then reply `retry the chart upload`."
	}
	notice := fmt.Sprintf(
		"*Chart could not be attached*\nI generated *%s*, but Slack did not accept the upload. %s",
		file.Title,
		fix,
	)
	message := slackui.Notice(notice)
	if file.Message != nil {
		message = *file.Message
		message.Text = notice + "\n\n" + message.Text
		if message.Markdown != "" {
			message.Markdown = notice + "\n\n" + message.Markdown
		} else {
			message.Sections = append([]string{notice}, message.Sections...)
		}
		message.Context = append(
			message.Context,
			"The analysis completed; only the Slack file delivery failed.",
		)
	}
	body, err := slackui.Encode(s.sanitizeMessage(message))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: delivery.ID + "_upload_failed", IncidentID: delivery.IncidentID,
		EpisodeID: delivery.EpisodeID, AgentRunID: delivery.AgentRunID,
		SourceInputID: delivery.SourceInputID, Operation: "post", Kind: "notice",
		ChannelID: delivery.ChannelID, ThreadTS: delivery.ThreadTS,
		Body: body, ResponseRoot: true,
	})
	return err
}
