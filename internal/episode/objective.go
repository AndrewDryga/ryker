package episode

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

func ObjectiveForSlackInput(input core.SlackInput) string {
	text := strings.TrimSpace(core.BoundedText(input.Text, 20<<10))
	if text == "" {
		if len(input.Attachments) > 0 {
			if len(input.Attachments) == 1 {
				return "Inspect an attached file"
			}
			return fmt.Sprintf("Inspect %d attached files", len(input.Attachments))
		}
		switch input.Kind {
		case "bot_message":
			return "Review an app notification"
		case "shortcut":
			return "Investigate a selected Slack message"
		default:
			return "Answer a Slack request"
		}
	}
	text = strings.Join(strings.Fields(text), " ")
	return core.TruncateUTF8WithSuffix(text, 180, "...")
}
