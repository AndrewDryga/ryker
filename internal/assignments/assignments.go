// Package assignments owns what a standing assignment means: the brief an
// unattended task works from, the words an operator uses to create one, and the
// sentence that says whether a shadow period has proved anything.
//
// It is a package rather than a corner of internal/service because none of it
// needs a database, a Slack client or a Coop session, and all of it is the part
// worth testing. The service half is the wiring — read the rows, hand them
// here, post what comes back.
package assignments

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/store/standingassignmentstore"
)

// maxExpiry is the longest grant this command will write.
//
// Ninety days is already long for authority nobody re-confirms; the point of an
// expiry is that a forgotten assignment decays rather than running forever, and
// an expiry beyond the horizon anybody plans on is an expiry in name only.
const maxExpiry = 90 * 24 * time.Hour

// defaultExpiry is what an operator gets for not saying. Short enough that a
// first assignment is a trial rather than a standing arrangement.
const defaultExpiry = 14 * 24 * time.Hour

// Objective is the brief the engineering task works from.
//
// It states the change class as a boundary rather than a suggestion, because
// this task runs without anyone watching it start, and the scope the operator
// agreed to is the only thing standing between a narrow fix and a rewrite.
func Objective(assignment core.StandingAssignment, conclusion string) string {
	objective := fmt.Sprintf(
		"A recurring problem in %s was investigated and reached this conclusion:\n\n%s\n\n"+
			"Open a draft pull request that addresses it, limited to a %s change. "+
			"Do not change behaviour beyond that class. If the fix requires anything "+
			"broader, stop and say so instead of widening the change.",
		assignment.Repository, conclusion, assignment.ChangeClass,
	)
	if len(assignment.PathGlobs) > 0 {
		objective += fmt.Sprintf(
			"\n\nOnly these paths are in scope: %v. Touching anything else is out of scope "+
				"for this assignment, however reasonable it looks.",
			assignment.PathGlobs,
		)
	}
	return objective
}

// Evaluation is one gate decision, ready to be written down.
//
// The verdict is derived here rather than at the call site so that the two
// spellings of "the gate said no" — the boolean the gate returns and the word
// the ledger stores — cannot drift apart. The reason is kept exactly as the
// gate produced it: the tally groups refusals by that string to find the one
// that repeats, and a reason decorated per assignment would split one recurring
// refusal into two rarer-looking ones.
func Evaluation(
	assignment core.StandingAssignment,
	inputID string,
	episodeID string,
	signal string,
	eligibility decision.ProactiveEligibility,
) core.StandingAssignmentEvaluation {
	verdict := "declined"
	if eligibility.Eligible {
		verdict = "eligible"
	}
	return core.StandingAssignmentEvaluation{
		AssignmentID: assignment.ID, InputID: inputID, EpisodeID: episodeID,
		Signal: signal, Shadow: assignment.Shadow,
		Verdict: verdict, Reason: eligibility.Reason,
	}
}

// ClaimRefusal turns a store refusal into the sentence the audit records.
//
// The two refusals are the invariants that make unattended work survivable —
// one pull request per issue, and a daily budget — and both are enforced by the
// store rather than by the caller remembering. Naming them here keeps their
// wording beside everything else this feature says about itself, and returns
// empty for anything else so a real failure still surfaces as a failure.
func ClaimRefusal(err error) string {
	switch {
	case errors.Is(err, standingassignmentstore.ErrAlreadyActed):
		return "already acted on this signal"
	case errors.Is(err, standingassignmentstore.ErrBudgetSpent):
		return "daily budget spent"
	default:
		return ""
	}
}

// Task is the headline and the brief for the work an assignment opens.
func Task(assignment core.StandingAssignment, conclusion string) (string, string) {
	return core.BoundedText("Recurring: "+conclusion, 200), Objective(assignment, conclusion)
}

// AuditEvent is the ledger line for anything one assignment did or refused.
//
// One constructor rather than a helper on the service, so the kind, the actor
// and the shape of the detail are written once. An operator reading back "why
// did Responder do nothing" is reading this, and a second spelling of the same
// event is a second thing to search for.
func AuditEvent(assignmentID, inputID, outcome, detail string) core.AuditEvent {
	return core.AuditEvent{
		Kind: "proactive.assignment", ActorID: "responder",
		ObjectID: assignmentID, Outcome: outcome,
		Detail: decision.BoundedField(detail+" · input="+inputID, 500),
	}
}

// EpisodeEvent puts the gate's decision on the episode's own event stream.
//
// This is what makes a shadow period recordable. `responder record-episode`
// builds a replay fixture out of an episode's events and its evidence, and
// nothing else — a decision that lives only in a side table is a decision no
// harvested fixture can ever contain, and the standing-assignments capability
// would stay an acknowledged coverage gap because the history it needs could
// not be recorded rather than because it had not happened yet.
//
// Keyed on the evaluation id, so a retried turn addresses the row it already
// wrote instead of appending the same decision twice.
func EpisodeEvent(evaluation core.StandingAssignmentEvaluation) core.WorkEpisodeEvent {
	payload, err := json.Marshal(map[string]any{
		"assignment_id": evaluation.AssignmentID, "verdict": evaluation.Verdict,
		"reason": evaluation.Reason, "shadow": evaluation.Shadow,
		"signal": evaluation.Signal, "input_id": evaluation.InputID,
	})
	if err != nil {
		payload = json.RawMessage("{}")
	}
	return core.WorkEpisodeEvent{
		Kind: "standing_assignment_evaluated", Actor: "responder",
		IdempotencyKey: "assignment_evaluation:" + evaluation.ID, Payload: payload,
	}
}

// AuditDetail annotates the audit line for the one case a reader would
// otherwise misread.
//
// A decline reads the same whether the assignment was shadowed or not — it
// refused either way. An eligible verdict does not: without the note, an
// operator reading "eligible" in the log goes looking for the pull request it
// implies, and there is none.
func AuditDetail(assignment core.StandingAssignment, reason string) string {
	if assignment.Shadow {
		return reason + " · shadow, so nothing was opened"
	}
	return reason
}

// Request is a create command an operator typed, normalized.
type Request struct {
	Assignment core.StandingAssignment
}

// Usage is the help for the whole family. It lives here rather than in the
// slash package's usage table so that the grammar and its documentation cannot
// drift apart while sitting in two files.
func Usage() string {
	return "*Manage standing assignments for this channel.*\n\n" +
		"`/responder assignments` lists them with what each has decided so far. " +
		"`/responder assignments pause <id>`, `resume <id>` and `delete <id>` manage one.\n\n" +
		"`/responder assignments create repo=<repository> class=<" +
		strings.Join(core.StandingAssignmentChangeClasses, "|") + "> " +
		"budget=<1-20> days=<1-90> paths=<glob,glob> signal=<words to watch for>`\n\n" +
		"A standing assignment is scoped authority to open a pull request without a " +
		"per-action click. Every one is created in shadow: it is evaluated by the real " +
		"gate — the signal must match, have recurred three times in fourteen days, and " +
		"have reached a decision-ready conclusion backed by evidence — and the verdict is " +
		"recorded, but nothing opens a task, creates a branch, or writes to GitHub. " +
		"Read the tally before asking for the flag to be cleared."
}

// ParseCreate turns the words an operator typed into a scoped grant.
//
// key=value rather than positional arguments: every field here is a bound on
// unattended work, and an operator who miscounted positions would be granting
// something other than what they read back. Unknown keys are refused rather
// than ignored for the same reason — a typo in `paths=` that silently became no
// path restriction is a repository-wide grant nobody asked for.
func ParseCreate(
	args []string,
	channelID string,
	actorID string,
	now time.Time,
) (Request, error) {
	assignment := core.StandingAssignment{
		ChannelID: channelID, ActorID: actorID, DailyBudget: 1, Shadow: true,
		ExpiresAt: now.Add(defaultExpiry),
	}
	var signal []string
	for index, arg := range args {
		key, value, found := strings.Cut(arg, "=")
		if !found {
			// Everything after signal= is the pattern, so an operator can write
			// words the way they read them in the channel.
			if len(signal) > 0 {
				signal = append(signal, arg)
				continue
			}
			return Request{}, fmt.Errorf(
				"`%s` is not `key=value`; every field of an assignment is a bound on "+
					"unattended work, so none of them are positional", arg,
			)
		}
		if err := applyField(&assignment, &signal, key, value, now); err != nil {
			return Request{}, err
		}
		_ = index
	}
	assignment.SignalPattern = strings.Join(signal, " ")
	if strings.TrimSpace(assignment.SignalPattern) == "" {
		return Request{}, errors.New(
			"an assignment needs `signal=<words>` naming what it watches for; without it " +
				"the grant covers every message in the channel",
		)
	}
	return Request{Assignment: assignment}, nil
}

func applyField(
	assignment *core.StandingAssignment,
	signal *[]string,
	key string,
	value string,
	now time.Time,
) error {
	switch key {
	case "repo", "repository":
		assignment.Repository = value
	case "class", "change":
		assignment.ChangeClass = value
	case "budget":
		budget, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("`budget=%s` is not a number of pull requests a day", value)
		}
		assignment.DailyBudget = budget
	case "days":
		days, err := strconv.Atoi(value)
		if err != nil || days < 1 {
			return fmt.Errorf("`days=%s` is not a number of days this grant lasts", value)
		}
		expiry := time.Duration(days) * 24 * time.Hour
		if expiry > maxExpiry {
			return errors.New(
				"a standing assignment lasts at most 90 days; authority nobody " +
					"re-confirms is authority nobody is deciding about",
			)
		}
		assignment.ExpiresAt = now.Add(expiry)
	case "paths", "path":
		for _, glob := range strings.Split(value, ",") {
			if trimmed := strings.TrimSpace(glob); trimmed != "" {
				assignment.PathGlobs = append(assignment.PathGlobs, trimmed)
			}
		}
	case "signal", "signals":
		*signal = append(*signal, value)
	default:
		return fmt.Errorf(
			"`%s=` is not a field of a standing assignment. A key this command does not "+
				"know is a bound it did not apply, so it refuses rather than granting "+
				"something wider than what was typed", key,
		)
	}
	return nil
}
