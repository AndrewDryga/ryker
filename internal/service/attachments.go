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

// RejectedAttachment is a Slack file the host would not hand to the model, and
// the reason, in the words the model is given.
//
// It exists because the alternative killed a turn. On 2026-08-16 a teammate
// reported a payments problem in a watched channel and attached a screenshot
// whose bytes were not the image/png it declared; the download refused it, the
// refusal was one error for the whole message, and both callers turned that
// into a failed run that posted nothing. The words were answerable without the
// picture. Nobody read them.
//
// Reason is written as a clause, not a sentence, so it reads inside the note
// the prompt renders: "the file's contents are not a valid image/png, so it was
// not attached." Every one of them names the field or the number that was
// wrong — "invalid" on its own tells the model nothing it can act on.
type RejectedAttachment struct {
	Name      string
	MediaType string
	Reason    string
}

// unreadableAttachmentsPrompt hands the refusals back as context rather than as
// a dead end: what was dropped, what was wrong with it, and the instruction to
// answer anyway and say so.
func unreadableAttachmentsPrompt(rejected []RejectedAttachment) string {
	var prompt strings.Builder
	for _, item := range rejected {
		fmt.Fprintf(
			&prompt,
			"\n\n<host-unreadable-attachment name=%q declared=%q>%s, so it was not "+
				"attached. Answer from the message text and the rest of the context, and "+
				"say plainly that you could not read the attachment and what you would "+
				"need instead.</host-unreadable-attachment>",
			item.Name, item.MediaType, item.Reason,
		)
	}
	return prompt.String()
}

// rejectAttachment records one refusal against the name and declaration the
// person actually sent, bounded because both came from outside.
func rejectAttachment(
	attachment core.SlackAttachment,
	format string,
	args ...any,
) RejectedAttachment {
	return RejectedAttachment{
		Name:      slackfile.SafeName(attachment.Name, attachment.ID),
		MediaType: core.TruncateUTF8(strings.TrimSpace(attachment.MediaType), 100),
		Reason:    fmt.Sprintf(format, args...),
	}
}

// downloadSlackArtifacts returns the files it could attach and, separately, the
// ones it refused.
//
// The split is the whole point. A content or policy problem with one file is a
// fact about that file, and the error return is reserved for the failures a
// later attempt might not have — a Slack API that is down, a download that dies
// mid-stream. slackfile.PermanentInputError draws that line already: everything
// it would call permanent becomes a note here, and everything else still fails
// the run so the retry path can do its job.
func (s *Service) downloadSlackArtifacts(
	ctx context.Context,
	input core.SlackInput,
) ([]coop.InputArtifact, []RejectedAttachment, error) {
	if len(input.Attachments) == 0 {
		return nil, nil, nil
	}
	attachments := input.Attachments
	var rejected []RejectedAttachment
	if len(attachments) > s.cfg.Limits.MaxSlackFiles {
		// Named individually, but only so many: the note goes into a budgeted
		// prompt, and every one of these carries the true total anyway. The
		// bound is the same limit, so the whole section stays under twice it.
		overflow := attachments[s.cfg.Limits.MaxSlackFiles:]
		for _, attachment := range overflow[:min(len(overflow), s.cfg.Limits.MaxSlackFiles)] {
			rejected = append(rejected, rejectAttachment(
				attachment,
				"the message carries %d files and the configured limit is %d",
				len(attachments), s.cfg.Limits.MaxSlackFiles,
			))
		}
		attachments = attachments[:s.cfg.Limits.MaxSlackFiles]
	}
	artifacts := make([]coop.InputArtifact, 0, len(attachments))
	total := 0
	for _, attachment := range attachments {
		if attachment.URLPrivate == "" || attachment.MediaType == "" {
			resolved, err := s.slack.GetFile(ctx, attachment.ID)
			if err != nil {
				return nil, nil, fmt.Errorf("resolve Slack file %q: %w", attachment.ID, err)
			}
			attachment = slackfile.Merge(attachment, resolved)
		}
		if attachment.Size < 0 || attachment.Size > int64(s.cfg.Limits.MaxSlackFileBytes) {
			rejected = append(rejected, rejectAttachment(
				attachment, "the file is %d bytes and exceeds the configured %d-byte limit",
				attachment.Size, s.cfg.Limits.MaxSlackFileBytes,
			))
			continue
		}
		if err := slackfile.ValidateURL(attachment.URLPrivate); err != nil {
			rejected = append(rejected, rejectAttachment(attachment, "its %v", err))
			continue
		}
		mediaType, err := slackfile.CanonicalMediaType(attachment.MediaType)
		if err != nil {
			rejected = append(rejected, rejectAttachment(attachment, "its %v", err))
			continue
		}
		writer := slackfile.NewBoundedWriter(s.cfg.Limits.MaxSlackFileBytes)
		if err := s.slack.DownloadFile(ctx, attachment.URLPrivate, writer); err != nil {
			if errors.Is(err, slackfile.ErrTooLarge) {
				rejected = append(rejected, rejectAttachment(
					attachment, "the download exceeds the configured %d-byte limit",
					s.cfg.Limits.MaxSlackFileBytes,
				))
				continue
			}
			return nil, nil, fmt.Errorf("download Slack file %q: %w", attachment.Name, err)
		}
		data := writer.Bytes()
		if len(data) == 0 {
			rejected = append(rejected, rejectAttachment(attachment, "the file is empty"))
			continue
		}
		if total > s.cfg.Limits.MaxSlackFileTotalBytes-len(data) {
			rejected = append(rejected, rejectAttachment(
				attachment, "the files together exceed the configured %d-byte total limit",
				s.cfg.Limits.MaxSlackFileTotalBytes,
			))
			continue
		}
		if !slackfile.MatchesMediaType(mediaType, data) {
			rejected = append(rejected, rejectAttachment(
				attachment, "the file's contents are not a valid %s", mediaType,
			))
			continue
		}
		total += len(data)
		digest := sha256.Sum256(data)
		artifacts = append(artifacts, coop.InputArtifact{
			Name:      slackfile.SafeName(attachment.Name, attachment.ID),
			MediaType: mediaType, SHA256: hex.EncodeToString(digest[:]),
			Data: append([]byte(nil), data...),
		})
	}
	return artifacts, rejected, nil
}

func (s *Service) agentRunArtifacts(
	ctx context.Context,
	run core.AgentRun,
) ([]coop.InputArtifact, []RejectedAttachment, error) {
	switch run.SourceKind {
	case "watch", "slack":
	default:
		return nil, nil, nil
	}
	if strings.TrimSpace(run.SourceID) == "" {
		return nil, nil, nil
	}
	input, err := s.store.GetSlackInput(ctx, run.SourceID)
	if err != nil {
		return nil, nil, fmt.Errorf("load Slack attachment source: %w", err)
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
			return nil, nil, fmt.Errorf("load Slack thread attachment context: %w", historyErr)
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
