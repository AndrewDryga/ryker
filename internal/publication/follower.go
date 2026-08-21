package publication

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// trimError bounds an error for storage beside the followup row.
func trimError(err error) string {
	if err == nil {
		return ""
	}
	return core.BoundedText(err.Error(), 500)
}

func (f *Follower) Process(ctx context.Context) error {
	followup, publication, err := f.followups.Next(ctx, f.now().UTC())
	if err != nil {
		return err
	}
	return f.refresh(ctx, followup, publication, core.SlackInput{}, false)
}

func (f *Follower) Check(
	ctx context.Context,
	input core.SlackInput,
	incident core.Incident,
) error {
	publication, err := f.publications.Get(ctx, incident.ID)
	if err != nil {
		return err
	}
	followup, err := f.followups.Get(ctx, incident.ID)
	if errors.Is(err, core.ErrNotFound) {
		if err := f.followups.Ensure(ctx, incident.ID, f.now().UTC()); err != nil {
			return err
		}
		followup, err = f.followups.Get(ctx, incident.ID)
	}
	if err != nil {
		return err
	}
	return f.refresh(ctx, followup, publication, input, true)
}

func (f *Follower) refresh(
	ctx context.Context,
	followup core.PublicationFollowup,
	publication core.Publication,
	input core.SlackInput,
	manual bool,
) error {
	if !publication.Published() && publication.State != core.PublicationStale {
		return nil
	}
	old := followup
	if f.status == nil || !f.status.Enabled() {
		return f.deferFollowup(
			ctx, old, errors.New("GitHub publication status is unavailable"),
		)
	}
	status, err := f.status.PublicationStatus(ctx, publication)
	if err != nil {
		return f.deferFollowup(ctx, old, err)
	}
	terminal := status.PRState == "merged" || status.PRState == "closed"
	if !terminal && publication.Published() && status.HeadSHA != "" && status.HeadSHA != publication.RemoteSHA {
		_, err := f.publications.MarkStale(
			ctx,
			publication.IncidentID,
			"The draft PR head changed after Responder's last verified publication. "+
				"Run Update draft PR to review and bind the current task tree.",
		)
		return err
	}
	latest, err := f.publications.Get(ctx, publication.IncidentID)
	if err != nil {
		return err
	}
	if latest.PRNumber != publication.PRNumber || latest.PRURL != publication.PRURL ||
		latest.RemoteSHA != publication.RemoteSHA ||
		(!terminal && !latest.Published() && latest.State != core.PublicationStale) {
		return nil
	}
	incident, err := f.incidents.GetIncident(ctx, publication.IncidentID)
	if err != nil {
		return err
	}
	followup.PRState = core.FirstNonempty(status.PRState, "unknown")
	followup.ChecksState = core.FirstNonempty(status.ChecksState, "unknown")
	followup.ChecksTotal = status.ChecksTotal
	followup.ChecksPassed = status.ChecksPassed
	followup.ChecksFailed = status.ChecksFailed
	followup.MergeSHA = status.MergeSHA
	followup.MergedAt = status.MergedAt
	followup.FailureCount = 0
	followup.LastError = ""
	followup.NextCheckAt = f.now().UTC().Add(f.cfg.FollowupInterval)
	if followup.PRState == "merged" || followup.PRState == "closed" {
		followup.NextCheckAt = time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	kind, state, summary := publicationTransition(
		publication, old, followup, status, manual,
		f.cfg.DeliveryCorrelationWindow,
	)
	if !manual && old.LastEventKey == "baseline" {
		followup.LastEventKey = LifecycleKey(
			publication.IncidentID, "baseline", followup.PRState,
			followup.ChecksState, status.HeadSHA, status.MergeSHA,
		)
		kind, state, summary = "", "", ""
	}
	if kind != "" {
		eventKey := LifecycleKey(publication.IncidentID, kind, state, status.HeadSHA, status.MergeSHA)
		followup.LastEventKey = eventKey
		deliveryID := "out_publication_followup_" + eventKey
		if manual {
			deliveryID = "out_publication_followup_manual_" + input.ID
		}
		message := slackui.PublicationLifecycleMessage(
			publication, incident.Title, kind, state, summary, status,
		)
		if err := f.reporter.Enqueue(
			ctx, deliveryID, incident, "publication_followup",
			incident.ConversationThreadTS(), message,
		); err != nil {
			return err
		}
		event := core.PublicationLifecycleEvent{
			ID: eventKey, IncidentID: incident.ID, Kind: kind, State: state,
			Summary: summary, SourceChannelID: input.ChannelID,
			SourceMessageTS: input.MessageTS,
		}
		if _, err := f.followups.SaveTransition(ctx, old, followup, &event); err != nil {
			return err
		}
		f.reporter.RecordTimeline(ctx, core.TimelineEvent{
			ID: "tl_" + eventKey, IncidentID: incident.ID,
			ChannelID: incident.ChannelID, Kind: "publication." + kind,
			ActorID: "github", Title: summary, Detail: publication.PRURL,
		})
		return nil
	}
	_, err = f.followups.SaveTransition(ctx, old, followup, nil)
	return err
}

func (f *Follower) deferFollowup(
	ctx context.Context,
	expected core.PublicationFollowup,
	err error,
) error {
	followup := expected
	followup.FailureCount++
	followup.LastError = trimError(err)
	followup.NextCheckAt = f.now().UTC().Add(
		publicationFollowupBackoff(followup.FailureCount),
	)
	if _, saveErr := f.followups.SaveTransition(ctx, expected, followup, nil); saveErr != nil {
		return saveErr
	}
	return err
}

func publicationTransition(
	publication core.Publication,
	old core.PublicationFollowup,
	current core.PublicationFollowup,
	status core.PublicationLifecycleStatus,
	manual bool,
	correlationWindow time.Duration,
) (string, string, string) {
	terminal := current.PRState == "merged" || current.PRState == "closed"
	if (!publication.Published() && !(publication.State == core.PublicationStale && terminal)) ||
		(status.HeadSHA != "" && status.HeadSHA != publication.RemoteSHA) {
		if !terminal {
			return "", "", ""
		}
	}
	switch {
	case current.PRState == "merged" && old.PRState != "merged":
		return "merged", "succeeded", fmt.Sprintf(
			"PR #%d was merged. I’ll keep this thread linked to matching deployment and Terraform updates for %s.",
			publication.PRNumber, formatTrackingWindow(correlationWindow),
		)
	case current.PRState == "closed" && old.PRState != "closed":
		return "closed", "stopped", fmt.Sprintf(
			"PR #%d was closed without merging. Automatic delivery tracking has stopped.",
			publication.PRNumber,
		)
	case current.ChecksState == "failing" && old.ChecksState != "failing":
		return "checks", "failed", fmt.Sprintf(
			"GitHub checks are failing for PR #%d (%d failed of %d). Open the PR for the exact failures.",
			publication.PRNumber, status.ChecksFailed, status.ChecksTotal,
		)
	case current.ChecksState == "passing" && old.ChecksState != "passing":
		return "checks", "succeeded", fmt.Sprintf(
			"GitHub checks passed for PR #%d (%d of %d). It is ready for review or merge.",
			publication.PRNumber, status.ChecksPassed, status.ChecksTotal,
		)
	case manual:
		return "status", current.PRState, publicationCurrentStatus(
			publication, current, status, correlationWindow,
		)
	default:
		return "", "", ""
	}
}

func publicationCurrentStatus(
	publication core.Publication,
	followup core.PublicationFollowup,
	status core.PublicationLifecycleStatus,
	correlationWindow time.Duration,
) string {
	parts := []string{fmt.Sprintf("PR #%d is %s", publication.PRNumber, followup.PRState)}
	if followup.ChecksState != "none" && followup.ChecksState != "unknown" {
		parts = append(parts, "GitHub checks are "+followup.ChecksState)
	}
	if followup.PRState == "merged" {
		parts = append(parts, "matching delivery and Terraform updates remain linked to this thread for "+formatTrackingWindow(correlationWindow))
	} else if status.Draft {
		parts = append(parts, "it is still a draft")
	}
	return strings.Join(parts, ". ") + "."
}

func formatTrackingWindow(value time.Duration) string {
	if value%(24*time.Hour) == 0 {
		return fmt.Sprintf("%d days", int(value/(24*time.Hour)))
	}
	if value%time.Hour == 0 {
		return fmt.Sprintf("%d hours", int(value/time.Hour))
	}
	return value.Round(time.Minute).String()
}

func publicationFollowupBackoff(failures int) time.Duration {
	delay := time.Minute << min(max(failures-1, 0), 5)
	return min(delay, 30*time.Minute)
}

// LifecycleKey is the stable identity of one lifecycle transition, so the same
// transition observed twice produces one message rather than two.
func LifecycleKey(parts ...string) string {
	digest := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(digest[:12])
}
