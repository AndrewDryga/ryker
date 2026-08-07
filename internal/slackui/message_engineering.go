package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

type ChangesNavigation struct {
	Page          int
	Pages         int
	FirstByte     int64
	LastByte      int64
	TotalBytes    int64
	Digest        string
	PreviousValue string
	NextValue     string
	RefreshValue  string
}

func engineeringTaskCard(
	task core.Incident,
	repositoryName string,
	signals []core.Signal,
	hasCodeChanges bool,
	publication core.Publication,
) Message {
	workflow := workflowStateLabel(task.Workflow)
	if task.Workflow == core.WorkflowProvisioningChannel {
		if task.IsThreadScoped() {
			workflow = "Starting task"
		} else {
			workflow = "Creating working room"
		}
	}
	state := "Open"
	if task.Status == core.IncidentClosed {
		state = "Closed"
	}
	fallback := fmt.Sprintf(
		"Engineering task %s: %s. %s; Responder %s in %s.",
		ShortID(task.ID), escapeSlackText(task.Title), state, workflow,
		escapeSlackText(repositoryName),
	)
	if task.LastError != "" {
		fallback += " Action needed: " + truncateUTF8(escapeSlackText(task.LastError), 500)
	}
	message := Message{
		Text:   truncateUTF8(fallback, 4000),
		Header: truncateUTF8(singleLine(task.Title), 150),
		Sections: []string{
			fmt.Sprintf("*Engineering task: %s*  |  Responder: *%s*", state, workflow),
		},
		Fields: []Field{
			{Label: "Task", Value: ShortID(task.ID)},
			{Label: "Repository", Value: escapeSlackText(repositoryName)},
		},
		Context: []string{
			"Continue in this thread; replies here go to the same isolated task session.",
			"Updated " + task.UpdatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		},
		Actions: incidentActions(task, hasCodeChanges, publication),
	}
	if !task.CreatedAt.IsZero() {
		message.Fields = append(message.Fields, Field{
			Label: "Started", Value: task.CreatedAt.UTC().Format("2006-01-02 15:04 UTC"),
		})
	}
	if task.CoopForkName != "" {
		message.Fields = append(message.Fields, Field{Label: "Fork", Value: "`" + task.CoopForkName + "`"})
	}
	if signal, ok := primarySignal(signals); ok && strings.TrimSpace(signal.Summary) != "" {
		message.Sections = append(
			message.Sections,
			"*Requested change*\n"+truncateUTF8(escapeSlackText(signal.Summary), 1200),
		)
	}
	switch {
	case publication.Published():
		message.Sections = append(message.Sections,
			fmt.Sprintf(
				"*Draft PR ready*\n<%s|Open draft PR #%d>. The reviewed task tree is now "+
					"durable in GitHub. Responder still cannot merge or deploy it.",
				publication.PRURL, publication.PRNumber,
			),
		)
	case publication.NeedsUpdate():
		message.Sections = append(message.Sections,
			fmt.Sprintf(
				"*Draft PR needs an update*\nThe task changed after <%s|draft PR #%d> was "+
					"published. Use *Update draft PR* to review and publish the current task tree.",
				publication.PRURL, publication.PRNumber,
			),
		)
	case publication.State == "failed":
		message.Sections = append(message.Sections,
			"*Draft PR needs attention*\n"+truncateUTF8(
				escapeSlackText(publication.LastError), 800,
			)+"\n\nCorrect the configuration or remote branch issue, then use *Retry draft PR*.",
		)
	case !hasCodeChanges && task.CoopSessionID != "" &&
		task.Workflow != core.WorkflowInvestigating && task.ActiveTurnID == "":
		message.Sections = append(message.Sections,
			"*Delivery state*\nThe isolated task has no code changes. There is nothing to "+
				"inspect, review, or publish yet. Reply in this thread with the exact change "+
				"you want, or close the task if no repository change is needed.",
		)
	case hasCodeChanges && task.Status != core.IncidentClosed &&
		task.Workflow != core.WorkflowInvestigating && task.ActiveTurnID == "":
		message.Sections = append(message.Sections,
			"*Delivery state*\nCode changes are preserved in the isolated fork. Use *View diff* "+
				"to inspect them or *Create draft PR* to run a fresh readiness review and "+
				"publish the exact approved tree for external review.",
		)
	}
	if task.LastError != "" {
		sections := []string{
			message.Sections[0],
			"*Action needed*\n" + truncateUTF8(escapeSlackText(task.LastError), 800),
		}
		message.Sections = append(sections, message.Sections[1:]...)
	}
	return message
}

func MemoryReviewMessage(item core.MemoryReviewItem, entries []core.MemoryEntry) Message {
	header := "Review saved memory"
	intro := "This saved memory has not been used recently. Keep it if it is still useful, or forget it."
	if item.Kind == "duplicate" {
		header = "Possible duplicate memory"
		intro = "These entries remember the same guidance in the same scope. Merge them to keep the newest copy, or keep them separate."
	}
	message := Message{
		Text:     header + ". " + item.Reason,
		Header:   header,
		Sections: []string{intro},
		Context: []string{
			"This review never changes memory until you choose an action. Fresh evidence and current repository state still take precedence over anything kept.",
		},
	}
	for index, entry := range entries {
		lastUsed := "never recalled"
		if !entry.LastRecalledAt.IsZero() {
			lastUsed = "last used " + entry.LastRecalledAt.UTC().Format("2006-01-02")
		}
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%d. %s*\n> %s\n%s · %s · expires %s",
			index+1,
			escapeSlackText(strings.ReplaceAll(entry.SubjectKey, "_", " ")),
			escapeSlackText(entry.Value),
			guidanceEntryScopeLabel(entry),
			lastUsed,
			entry.ExpiresAt.UTC().Format("2006-01-02"),
		))
	}
	if item.Kind == "duplicate" {
		message.Actions = []Action{
			{ID: ActionMergeMemoryReview, Label: "Merge copies", Value: item.ID, Style: "primary", Confirm: "Keep the newest copy and permanently remove the redundant copies?"},
			{ID: ActionDismissMemoryReview, Label: "Keep separate", Value: item.ID},
		}
	} else {
		message.Actions = []Action{
			{ID: ActionKeepMemoryReview, Label: "Keep it", Value: item.ID, Style: "primary"},
			{ID: ActionForgetMemoryReview, Label: "Forget it", Value: item.ID, Style: "danger", Confirm: "Permanently forget this saved memory?"},
		}
	}
	return message
}

func MemoryReviewCompleteMessage(action string, remaining int) Message {
	result := "Memory kept."
	switch action {
	case "forget":
		result = "Memory forgotten."
	case "merge":
		result = "Duplicate copies merged."
	case "dismiss":
		result = "Entries kept separately."
	}
	message := Message{
		Text:     result,
		Header:   "Memory review complete",
		Sections: []string{result},
	}
	if remaining > 0 {
		message.Context = []string{fmt.Sprintf("%d memory review item(s) remain.", remaining)}
		message.Actions = []Action{{ID: ActionReviewMemory, Label: "Review next", Value: "next"}}
	}
	return message
}

func PublicationMessage(publication core.Publication, updated bool) Message {
	action := "created"
	header := "Draft PR ready"
	if updated {
		action = "updated"
		header = "Draft PR updated"
	}
	return Message{
		Text: fmt.Sprintf(
			"Responder %s draft PR #%d for this engineering task: %s",
			action, publication.PRNumber, publication.PRURL,
		),
		Header: header,
		Sections: []string{
			fmt.Sprintf(
				"<%s|Open draft PR #%d>\n\nThe branch contains the exact tree approved by "+
					"the latest Coop readiness review. Publication used lease protection, so "+
					"Responder would refuse to overwrite an unexpected remote change.",
				publication.PRURL, publication.PRNumber,
			),
		},
		Context: []string{
			"Draft only. Responder did not merge, deploy, sign, or change infrastructure.",
		},
		Actions: []Action{
			{ID: ActionViewPR, Label: "Open PR", Value: publication.IncidentID, URL: publication.PRURL},
			{ID: ActionCheckDelivery, Label: "Check delivery", Value: publication.IncidentID},
		},
	}
}

func PublicationLifecycleMessage(
	publication core.Publication,
	taskTitle string,
	kind string,
	state string,
	summary string,
	status core.PublicationLifecycleStatus,
) Message {
	header := "Delivery update"
	switch kind {
	case "merged":
		header = "PR merged"
	case "checks":
		if state == "succeeded" {
			header = "Checks passed"
		} else {
			header = "Checks need attention"
		}
	case "closed":
		header = "PR closed"
	case "terraform":
		header = "Terraform update"
	case "deployment":
		header = "Deployment update"
	}
	context := []string{"Task: " + escapeSlackText(taskTitle)}
	if status.MergeSHA != "" {
		context = append(context, "Merge commit: `"+escapeSlackText(shortSHA(status.MergeSHA))+"`")
	}
	return Message{
		Text:     header + " for PR #" + fmt.Sprint(publication.PRNumber) + ": " + summary,
		Header:   header,
		Sections: []string{summary},
		Context:  context,
		Actions: []Action{
			{ID: ActionViewPR, Label: "Open PR", Value: publication.IncidentID, URL: publication.PRURL},
			{ID: ActionCheckDelivery, Label: "Refresh status", Value: publication.IncidentID},
		},
	}
}

func WithEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
) Message {
	return withEngineeringTaskOffer(
		message, taskTitle, sourceInputID, repositoryLabel,
		"Start task",
	)
}

func WithSuggestedEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
) Message {
	return withEngineeringTaskOffer(
		message, taskTitle, sourceInputID, repositoryLabel,
		"Prepare code fix",
	)
}

func WithPullRequestReview(message Message, sourceInputID string) Message {
	message.Actions = append(message.Actions, Action{
		ID: ActionReviewPullRequest, Label: "Review PR", Value: sourceInputID,
		Confirm: "Review the exact PR diff, discussion, risks, and missing work? This is read-only.",
	})
	return message
}

func withEngineeringTaskOffer(
	message Message,
	taskTitle string,
	sourceInputID string,
	repositoryLabel string,
	label string,
) Message {
	if taskTitle = strings.TrimSpace(taskTitle); taskTitle != "" {
		message.Sections = append(message.Sections, fmt.Sprintf(
			"*%s*\nRepository: %s",
			escapeSlackText(taskTitle), repositoryLabel,
		))
	}
	message.Actions = append(message.Actions, Action{
		ID: ActionStartTask, Label: label, Value: sourceInputID,
		Style: "primary",
		Confirm: "Start this task for " + repositoryLabel +
			" in an isolated working copy? Emisar may edit, test, and commit there, but cannot merge or deploy.",
	})
	return message
}

func ChangesMessage(
	incident core.Incident,
	summary string,
	patch []byte,
	navigation ChangesNavigation,
) Message {
	context := "The fork remains isolated. No merge, signing, push, or deployment occurred."
	if incident.CoopForkName != "" {
		context = "Fork `" + incident.CoopForkName + "`. No merge, signing, push, or deployment occurred."
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	var markdown strings.Builder
	markdown.WriteString(summary)
	if navigation.TotalBytes > 0 {
		page := max(navigation.Page, 1)
		pages := max(navigation.Pages, 1)
		markdown.WriteString(fmt.Sprintf(
			"\n\n*Patch page %d of %d* · bytes %d-%d of %d",
			page,
			pages,
			navigation.FirstByte+1,
			navigation.LastByte,
			navigation.TotalBytes,
		))
		if len(navigation.Digest) >= 12 {
			markdown.WriteString(" · snapshot `" + safeInlineCode(navigation.Digest[:12]) + "`")
		}
	}
	if len(patch) > 0 {
		diff := strings.ToValidUTF8(string(patch), "\uFFFD")
		diff = strings.ReplaceAll(diff, "```", "` ` `")
		markdown.WriteString("\n\n```diff\n")
		markdown.WriteString(diff)
		markdown.WriteString("\n```")
	} else if navigation.TotalBytes == 0 {
		markdown.WriteString(
			"\n\n_No tracked text patch is available. Untracked or binary files may still " +
				"appear in the change summary._",
		)
	}
	message := Message{
		Text:     "Code changes for " + work + " " + ShortID(incident.ID) + ": " + summary,
		Header:   "Code changes",
		Markdown: truncateMarkdown(markdown.String(), 12000),
		Context:  []string{context},
	}
	if navigation.PreviousValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesPrevious, Label: "Previous page",
			Value: navigation.PreviousValue,
		})
	}
	if navigation.NextValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesNext, Label: "Next page",
			Value: navigation.NextValue,
		})
	}
	if navigation.RefreshValue != "" {
		message.Actions = append(message.Actions, Action{
			ID: ActionChangesRefresh, Label: "Refresh diff",
			Value: navigation.RefreshValue,
		})
	}
	return message
}

func ReviewMessage(incident core.Incident, summary string, publishable bool) Message {
	state := "Not ready for review"
	if publishable {
		state = "Ready for external review"
	}
	work := "incident"
	if incident.IsEngineeringTask() {
		work = "engineering task"
	}
	message := Message{
		Text:     state + " for " + work + " " + ShortID(incident.ID),
		Header:   state,
		Sections: []string{summary},
		Context:  []string{"No branch was pushed and no pull request was created."},
	}
	if publishable && incident.IsEngineeringTask() {
		message.Context = []string{"The reviewed tree is pinned. Creating a draft PR will not merge or deploy it."}
		message.Actions = []Action{{
			ID: ActionPublishPR, Label: "Create draft PR", Value: incident.ID, Style: "primary",
			Confirm: "Run a fresh readiness review, publish the exact approved tree on a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
		}}
	} else if !publishable && incident.IsEngineeringTask() {
		message.Context = []string{
			"The isolated change is preserved. Retry after transient repository movement, or ask Emisar to fix a persistent blocker.",
		}
		message.Actions = []Action{
			{
				ID: ActionPublishPR, Label: "Retry draft PR", Value: incident.ID, Style: "primary",
				Confirm: "Run a fresh readiness review and create a draft pull request if the exact reviewed tree is safe to publish? This cannot merge or deploy.",
			},
			{ID: ActionRepairReview, Label: "Fix blocker", Value: incident.ID},
		}
	}
	return message
}

func WithEngineeringTaskDelivery(
	message Message,
	incident core.Incident,
	hasCodeChanges bool,
	publication core.Publication,
) Message {
	if !incident.IsEngineeringTask() {
		return message
	}
	if !hasCodeChanges {
		message.Context = append(
			message.Context,
			"No code changes were produced. There is no diff or draft PR to deliver.",
		)
		return message
	}
	context := "Changes are preserved in the isolated task fork. View the diff, then create a draft PR for external review."
	publish := Action{
		ID: ActionPublishPR, Label: "Create draft PR", Value: incident.ID, Style: "primary",
		Confirm: "Run Coop's readiness review, publish the exact approved tree on a Responder-owned branch, and create a draft pull request? This cannot merge or deploy.",
	}
	if publication.HasPR() {
		context = fmt.Sprintf(
			"The task changed after draft PR #%d was published. View the diff, then update the draft PR with the current reviewed tree.",
			publication.PRNumber,
		)
		publish.Label = "Update draft PR"
		publish.Confirm = "Run a fresh Coop readiness review and update the existing Responder draft PR using lease-protected branch publication? This cannot merge or deploy."
	}
	message.Context = append(message.Context, context)
	message.Actions = append(message.Actions,
		Action{ID: ActionChanges, Label: "View diff", Value: incident.ID}, publish,
	)
	if publication.HasPR() {
		message.Actions = append(message.Actions, Action{
			ID: ActionViewPR, Label: "Open PR", Value: incident.ID, URL: publication.PRURL,
		})
	}
	return message
}
