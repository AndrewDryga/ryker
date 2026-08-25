// Package schedulecontext supplies bounded durable schedule state to model
// turns that discuss recurring work.
package schedulecontext

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
)

const (
	taskLimit   = 8
	promptBytes = 2000
)

// Task is the durable state needed to distinguish an existing scheduled task
// from a request to create one. Store-only ownership fields are omitted.
type Task struct {
	ID              string `json:"id"`
	Title           string `json:"title"`
	Prompt          string `json:"prompt"`
	Repository      string `json:"repository"`
	DeliveryChannel string `json:"delivery_channel_id"`
	ThreadTS        string `json:"thread_ts,omitempty"`
	Recurrence      string `json:"recurrence"`
	LocalTime       string `json:"local_time,omitempty"`
	Timezone        string `json:"timezone,omitempty"`
	CatchUp         string `json:"catch_up,omitempty"`
	Enabled         bool   `json:"enabled"`
	NextRunAt       string `json:"next_run_at,omitempty"`
	LastRunAt       string `json:"last_run_at,omitempty"`
	LastOutcome     string `json:"last_outcome,omitempty"`
	SourceRef       string `json:"source_ref,omitempty"`
}

// Capture returns the current workspace tasks for an operator and the current
// channel's tasks for anyone else. Cadence terms in diagnostic questions are
// enough to include context, but never enough to create a task.
func Capture(
	ctx context.Context,
	repository *schedulestore.Repository,
	input core.SlackInput,
	operator bool,
	include bool,
) ([]Task, error) {
	if !include {
		return nil, nil
	}
	var stored []core.ScheduledTask
	var err error
	if operator {
		stored, err = repository.ListScheduledTasksForTeam(ctx, input.TeamID, taskLimit)
	} else {
		stored, err = repository.ListScheduledTasksForChannel(ctx, input.ChannelID, taskLimit)
	}
	if err != nil {
		return nil, err
	}
	tasks := make([]Task, 0, len(stored))
	for _, task := range stored {
		item := Task{
			ID: task.ID, Title: task.Title,
			Prompt:     core.TruncateUTF8(strings.TrimSpace(task.Prompt), promptBytes),
			Repository: task.Repository, DeliveryChannel: task.DeliveryChannel,
			ThreadTS: task.ThreadTS, Recurrence: task.Recurrence,
			LocalTime: task.LocalTime, Timezone: task.Timezone, CatchUp: task.CatchUp,
			Enabled: task.Enabled, LastOutcome: task.LastOutcome, SourceRef: task.SourceRef,
		}
		if !task.NextRunAt.IsZero() {
			item.NextRunAt = task.NextRunAt.UTC().Format(core.TimestampFormat)
		}
		if !task.LastRunAt.IsZero() {
			item.LastRunAt = task.LastRunAt.UTC().Format(core.TimestampFormat)
		}
		tasks = append(tasks, item)
	}
	return tasks, nil
}

// Prompt renders trusted host state. The stored task prompt remains task prose,
// not new authority for the current turn.
func Prompt(tasks []Task) string {
	if len(tasks) == 0 {
		return ""
	}
	data, err := json.Marshal(tasks)
	if err != nil {
		return ""
	}
	return "\n\n<existing-scheduled-tasks>\n" + string(data) +
		"\n</existing-scheduled-tasks>\nThese are the current durable tasks in this Slack workspace or channel. " +
		"Use them to answer questions about existing automation. Do not offer a duplicate task unless the operator asks to replace or add one."
}
