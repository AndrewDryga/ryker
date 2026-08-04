package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

type slackFileDelivery struct {
	Filename  string           `json:"filename"`
	Title     string           `json:"title"`
	AltText   string           `json:"alt_text"`
	MediaType string           `json:"media_type"`
	SHA256    string           `json:"sha256"`
	Data      []byte           `json:"data"`
	Message   *slackui.Message `json:"message,omitempty"`
}

func decodeSlackFileDelivery(data []byte) (slackFileDelivery, error) {
	var result slackFileDelivery
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return slackFileDelivery{}, fmt.Errorf("decode Slack file delivery: %w", err)
	}
	if result.Filename == "" || filepath.Base(result.Filename) != result.Filename ||
		len(result.Filename) > 255 || !utf8.ValidString(result.Filename) ||
		result.Title == "" || len(result.Title) > 200 || result.AltText == "" || len(result.AltText) > 1000 ||
		len(result.Data) == 0 || len(result.Data) > 8<<20 || !generatedImageMediaType(result.MediaType) {
		return slackFileDelivery{}, errors.New("Slack file delivery is outside bounds")
	}
	if result.Message != nil {
		encoded, err := slackui.Encode(*result.Message)
		if err != nil {
			return slackFileDelivery{}, fmt.Errorf("encode Slack file message: %w", err)
		}
		message, err := slackui.Decode(encoded)
		if err != nil {
			return slackFileDelivery{}, fmt.Errorf("decode Slack file message: %w", err)
		}
		result.Message = &message
	}
	digest := sha256.Sum256(result.Data)
	if hex.EncodeToString(digest[:]) != result.SHA256 {
		return slackFileDelivery{}, errors.New("Slack file delivery digest mismatch")
	}
	return result, nil
}

func generatedImageMediaType(mediaType string) bool {
	switch mediaType {
	case "image/png", "image/jpeg", "image/webp", "image/gif":
		return true
	default:
		return false
	}
}

func (s *Service) enqueueGeneratedVisuals(
	ctx context.Context,
	keyPrefix string,
	incidentID string,
	episodeID string,
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
	prepared := make([]slackFileDelivery, 0, len(visuals))
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
		if !generatedImageMediaType(artifact.MediaType) || artifact.Bytes <= 0 || artifact.Bytes > int64(s.cfg.Limits.MaxGeneratedVisualBytes) {
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
		file := slackFileDelivery{
			Filename: deliveryVisualFilename(artifact.Name, deliveryID), Title: visual.Title,
			AltText: visual.AltText, MediaType: artifact.MediaType, SHA256: digestHex, Data: fetched.Data,
		}
		if index == 0 && message != nil {
			copy := *message
			if s.sanitizer != nil {
				copy = s.sanitizer.Message(copy)
			}
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
			EpisodeID: episodeID,
			Operation: "file", Kind: "generated_visual", ChannelID: channelID,
			ThreadTS: threadTS, Body: body,
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func deliveryVisualFilename(original, deliveryID string) string {
	ext := strings.ToLower(filepath.Ext(original))
	if ext == ".jpeg" {
		ext = ".jpg"
	}
	base := strings.TrimSuffix(filepath.Base(original), filepath.Ext(original))
	base = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, base)
	base = strings.Trim(strings.ToLower(base), "-")
	if base == "" {
		base = "generated-image"
	}
	suffix := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, deliveryID)
	name := base + "--" + suffix + ext
	if len(name) > 255 {
		name = name[:255-len(ext)] + ext
	}
	return name
}

func permanentSlackFileDeliveryError(err error) bool {
	detail := strings.ToLower(strings.TrimSpace(err.Error()))
	for _, marker := range []string{
		"missing_scope", "not_authed", "invalid_auth", "account_inactive",
		"not_allowed_token_type", "file_uploads_disabled",
	} {
		if strings.Contains(detail, marker) {
			return true
		}
	}
	return false
}

func (s *Service) enqueueGeneratedVisualFailure(
	ctx context.Context,
	delivery core.SlackDelivery,
	file slackFileDelivery,
	detail string,
) error {
	fix := "Slack rejected the upload after the configured retries. Check the app's file-upload access, then ask me to try again."
	if strings.Contains(strings.ToLower(detail), "missing_scope") {
		fix = "This Slack app is missing `files:write`. Apply the current app manifest, reinstall the app in this workspace, then ask me to try again."
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
	return s.postInputMessageAt(
		ctx,
		delivery.ID+"_upload_failed",
		delivery.ChannelID,
		delivery.ThreadTS,
		message,
	)
}
