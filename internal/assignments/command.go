package assignments

import (
	"context"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
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

// Result is what a command produced: what to render, and the audit line if it
// changed something.
//
// It carries values rather than a rendered card so this package never imports
// the presentation layer. That was a convenience while `create` lived here, and
// it stopped being one the moment internal/investigation needed the same
// validator the confirmation click is measured against — a domain package the
// operation contract imports must not drag Slack rendering in behind it.
type Result struct {
	Directory []core.StandingAssignment
	Tallies   map[string]core.StandingAssignmentTally
	// Changed and Verb are set only by pause, resume and delete. An empty Verb
	// means this result is the directory.
	Changed core.StandingAssignment
	Verb    string
	Audit   core.AuditEvent
}

// Run executes one `/responder assignments ...` command.
//
// The whole family lives here rather than in the slash dispatcher because every
// branch of it is a decision about scoped authority — what a grant covers, what
// it may not, when it lapses — and none of it needs Slack, Coop or a clock the
// caller does not already have.
//
// `create` is not a branch any more. It is the one verb in this family that
// GRANTED authority rather than reading or revoking it, and it is now the
// offer_assignment operation: an operator says what they want watched, the host
// normalizes the bounds, and a confirmation card shows the normalized grant
// before anything exists. The verb still answers — it points at that
// conversation — because an operator who typed a command that worked last week
// did not typo, and "unknown subcommand" would tell them they did.
func Run(
	ctx context.Context,
	repository Repository,
	args []string,
	input core.SlackInput,
) (Result, error) {
	channelID, actorID := input.ChannelID, input.UserID
	if len(args) == 0 {
		return list(ctx, repository, channelID)
	}
	switch args[0] {
	case "list":
		return list(ctx, repository, channelID)
	case "create", "add", "new":
		return Result{}, errors.New(
			"`/responder assignments " + args[0] + "` is gone. " + CreationPointer,
		)
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
	return Result{Directory: found, Tallies: tallies}, nil
}

// CreatedAudit is the ledger line for a confirmed offer.
//
// It lives here rather than at the confirmation's call site so the sentence an
// operator reads back — what class, in which repository, watching what, how
// often — is written once and stays beside everything else this feature says
// about itself. "shadow" leads it because that is the difference between a
// grant and a rehearsal.
func CreatedAudit(assignment core.StandingAssignment, actorID string) core.AuditEvent {
	return core.AuditEvent{
		Kind: "proactive.assignment", ActorID: actorID, ObjectID: assignment.ID,
		Outcome: "created",
		Detail: fmt.Sprintf(
			"shadow · %s in %s · %s · up to %d a day",
			assignment.ChangeClass, assignment.Repository,
			assignment.SignalPattern, assignment.DailyBudget,
		),
	}
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
		Changed: assignment, Verb: past,
		Audit: core.AuditEvent{
			Kind: "proactive.assignment", ActorID: actorID, ObjectID: assignment.ID,
			Outcome: past, Detail: assignment.SignalPattern + " in " + assignment.Repository,
		},
	}, nil
}
