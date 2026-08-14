package slackui

import (
	"context"
	"errors"
	"strings"

	"github.com/slack-go/slack"
)

// canvasTitleLimit bounds the document's name. Slack states no limit for it,
// and the titles Responder generates carry an incident title a person typed —
// which is unbounded. 250 is the length past which no title is being read.
const canvasTitleLimit = 250

// CreateCanvas publishes a long-form report as a canvas and answers with the
// URL a reader can open.
//
// Three calls, because Slack splits one document across three methods and none
// of them can be skipped:
//
//   - canvases.create makes the canvas. Its whole response is an id.
//   - files.info is the only place the canvas's URL is stated. A canvas is a
//     file — canvases.create answers with a file id — and no Slack
//     documentation gives a permalink that could be assembled from that id, so
//     Responder asks for the URL rather than guessing at one. A guessed link
//     that 404s is worse than no canvas at all, because the card would still
//     claim the report is over there.
//   - canvases.access.set is what makes the document readable by the room that
//     asked for it. Without it the canvas belongs to the bot alone and every
//     link to it opens a closed door.
//
// Any failure is the caller's cue to post the report as a message instead, so a
// half-made canvas is deleted on the way out rather than left in the workspace
// as a document nobody can reach. The delete is best-effort: it is tidying, and
// failing to tidy is not a reason to fail the report a second time.
func (c *Client) CreateCanvas(
	ctx context.Context,
	channelID string,
	title string,
	markdown string,
) (string, error) {
	if strings.TrimSpace(channelID) == "" {
		return "", errors.New("a canvas needs a channel that can read it")
	}
	if strings.TrimSpace(markdown) == "" {
		return "", errors.New("a canvas needs a document to hold")
	}
	canvasID, err := c.api.CreateCanvasContext(ctx, truncateUTF8(title, canvasTitleLimit),
		slack.DocumentContent{Type: "markdown", Markdown: markdown})
	if err != nil {
		return "", err
	}
	if canvasID == "" {
		return "", errors.New("Slack created a canvas without giving it an ID")
	}
	if err := c.api.SetCanvasAccessContext(ctx, slack.SetCanvasAccessParams{
		CanvasID: canvasID, AccessLevel: "read", ChannelIDs: []string{channelID},
	}); err != nil {
		c.discardCanvas(ctx, canvasID)
		return "", err
	}
	file, _, _, err := c.api.GetFileInfoContext(ctx, canvasID, 1, 1)
	if err != nil {
		c.discardCanvas(ctx, canvasID)
		return "", err
	}
	if file == nil || strings.TrimSpace(file.Permalink) == "" {
		c.discardCanvas(ctx, canvasID)
		return "", errors.New("Slack did not report a link to the canvas it created")
	}
	return file.Permalink, nil
}

func (c *Client) discardCanvas(ctx context.Context, canvasID string) {
	_ = c.api.DeleteCanvasContext(ctx, canvasID)
}
