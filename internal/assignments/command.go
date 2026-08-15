package assignments

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// Repository is the store surface this command family needs, named here so the
// grammar and its refusals stay testable without a database behind them.
type Repository interface {
	Create(ctx context.Context, assignment core.StandingAssignment) (core.StandingAssignment, error)
	Get(ctx context.Context, id string) (core.StandingAssignment, error)
	ListForChannel(ctx context.Context, channelID string, limit int) ([]core.StandingAssignment, error)
	SetEnabled(ctx context.Context, id string, enabled bool) error
	Delete(ctx context.Context, id string) error
	Tally(ctx context.Context, assignmentID string) (core.StandingAssignmentTally, error)
}

// directoryLimit bounds the listing. An operator with more than twenty standing
// assignments in one channel has a different problem than this card can show.
const directoryLimit = 20

// errUsage is the refusal for words that did not form a command. It carries the
// usage text as its message so the caller has one branch rather than two: an
// operator who mistyped and one who typed nothing want the same answer.
var errUsage = errors.New(Usage())

// Result is what a command produced: the message to post, and the audit line if
// it changed something.
type Result struct {
	Message slackui.Message
	Audit   core.AuditEvent
}

// Run executes one `/responder assignments ...` command.
//
// The whole family lives here rather than in the slash dispatcher because every
// branch of it is a decision about scoped authority — what a grant covers, what
// it may not, when it lapses — and none of it needs Slack, Coop or a clock the
// caller does not already have.
func Run(
	ctx context.Context,
	repository Repository,
	args []string,
	input core.SlackInput,
	now time.Time,
) (Result, error) {
	channelID, actorID := input.ChannelID, input.UserID
	if len(args) == 0 {
		return list(ctx, repository, channelID)
	}
	switch args[0] {
	case "list":
		return list(ctx, repository, channelID)
	case "create", "add", "new":
		return create(ctx, repository, args[1:], channelID, actorID, now)
	case "pause", "resume", "delete":
		return manage(ctx, repository, args[0], args[1:], channelID, actorID)
	default:
		return Result{}, errUsage
	}
}

func list(ctx context.Context, repository Repository, channelID string) (Result, error) {
	found, err := repository.ListForChannel(ctx, channelID, directoryLimit)
	if err != nil {
		return Result{}, err
	}
	tallies := make(map[string]core.StandingAssignmentTally, len(found))
	for _, assignment := range found {
		tally, err := repository.Tally(ctx, assignment.ID)
		if err != nil {
			return Result{}, err
		}
		tallies[assignment.ID] = tally
	}
	return Result{Message: slackui.AssignmentDirectoryMessage(found, tallies)}, nil
}

func create(
	ctx context.Context,
	repository Repository,
	args []string,
	channelID string,
	actorID string,
	now time.Time,
) (Result, error) {
	request, err := ParseCreate(args, channelID, actorID, now)
	if err != nil {
		return Result{}, err
	}
	saved, err := repository.Create(ctx, request.Assignment)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Message: slackui.AssignmentSavedMessage(saved),
		Audit: core.AuditEvent{
			Kind: "proactive.assignment", ActorID: actorID, ObjectID: saved.ID,
			Outcome: "created",
			Detail: fmt.Sprintf(
				"shadow · %s in %s · %s · up to %d a day",
				saved.ChangeClass, saved.Repository, saved.SignalPattern, saved.DailyBudget,
			),
		},
	}, nil
}

// manage pauses, resumes or deletes one assignment.
//
// The channel is checked rather than trusted: an id is guessable enough that a
// command typed in the wrong room should not be able to revoke or resume
// authority granted in another one, and the refusal says nothing about whether
// the id exists elsewhere.
func manage(
	ctx context.Context,
	repository Repository,
	verb string,
	args []string,
	channelID string,
	actorID string,
) (Result, error) {
	if len(args) != 1 {
		return Result{}, errUsage
	}
	assignment, err := repository.Get(ctx, args[0])
	if err != nil || assignment.ChannelID != channelID {
		return Result{}, fmt.Errorf(
			"there is no standing assignment `%s` in this channel. "+
				"`/responder assignments` lists the ones there are", args[0],
		)
	}
	past := verb + "d"
	switch verb {
	case "pause":
		err, assignment.Enabled = repository.SetEnabled(ctx, assignment.ID, false), false
	case "resume":
		err, assignment.Enabled, past = repository.SetEnabled(ctx, assignment.ID, true), true, "resumed"
	case "delete":
		err = repository.Delete(ctx, assignment.ID)
	}
	if err != nil {
		return Result{}, err
	}
	return Result{
		Message: slackui.AssignmentChangedMessage(assignment, past),
		Audit: core.AuditEvent{
			Kind: "proactive.assignment", ActorID: actorID, ObjectID: assignment.ID,
			Outcome: past, Detail: assignment.SignalPattern + " in " + assignment.Repository,
		},
	}, nil
}
