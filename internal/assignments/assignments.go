// Package assignments owns what a standing assignment means: the bounds an
// offer must name, the normalized grant an operator confirms, the brief an
// unattended task works from, and the sentence that says whether a shadow
// period has proved anything.
//
// It is a package rather than a corner of internal/service because none of it
// needs a database, a Slack client or a Coop session, and all of it is the part
// worth testing. The service half is the wiring — read the rows, hand them
// here, post what comes back.
//
// It imports no presentation, and that is now load-bearing rather than tidy:
// internal/investigation validates offer_assignment through ValidateOffer here,
// so the rule a model reads in a correction is literally the rule the
// operator's confirmation click will be measured against. Two copies of a
// bound is two chances for an offer to be accepted at result time and refused
// at confirm time for a reason nobody was ever told.
package assignments

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/standingassignmentstore"
)

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
//
// It takes the gate's two values rather than internal/decision's
// ProactiveEligibility because this package is now imported by
// internal/investigation, and internal/decision imports internal/investigation
// through the evidence policy. The eligibility struct is exactly a bool and a
// string, so nothing is lost but the name, and what is bought is that the
// operation contract can reach the offer validator at all.
func Evaluation(
	assignment core.StandingAssignment,
	inputID string,
	episodeID string,
	signal string,
	eligible bool,
	reason string,
) core.StandingAssignmentEvaluation {
	verdict := "declined"
	if eligible {
		verdict = "eligible"
	}
	return core.StandingAssignmentEvaluation{
		AssignmentID: assignment.ID, InputID: inputID, EpisodeID: episodeID,
		Signal: signal, Shadow: assignment.Shadow,
		Verdict: verdict, Reason: reason,
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
		Detail: core.BoundedText(detail+" · input="+inputID, 500),
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

// Usage is the help for the whole family. It lives here rather than in the
// slash package's usage table so that the grammar and its documentation cannot
// drift apart while sitting in two files.
//
// Creation is not in it, and the sentence that replaces it is doing work.
// `create` was a nine-key `key=value` line an operator had to compose without
// ever seeing what it would produce, and every key in it was a bound on
// unattended pull-request authority; a miscounted `paths=` was a
// repository-wide grant that read as a narrow one. Asking in words and reading
// the normalized bounds off a card is not a nicer spelling of that command, it
// is the only spelling where the operator confirms the thing that gets stored.
func Usage() string {
	return "*Manage standing assignments for this channel.*\n\n" +
		"`/responder assignments` lists them with what each has decided so far. " +
		"`/responder assignments pause <id>`, `resume <id>` and `delete <id>` manage one.\n\n" +
		CreationPointer + "\n\n" +
		"A standing assignment is scoped authority to open a pull request without a " +
		"per-action click. Every one is created in shadow: it is evaluated by the real " +
		"gate — the signal must match, have recurred three times in fourteen days, and " +
		"have reached a decision-ready conclusion backed by evidence — and the verdict is " +
		"recorded, but nothing opens a task, creates a branch, or writes to GitHub. " +
		"Read the tally before asking for the flag to be cleared."
}

// CreationPointer is what `/responder assignments create` answers with.
//
// It names the surface AND gives the sentence, because the retired verb's
// replacement is a conversation and an operator who has only ever typed
// `create repo=... class=...` has no reason to guess that plain English reaches
// further than the grammar did. Every bound the command took is in the example,
// so the pointer doubles as the documentation the key list used to be.
const CreationPointer = "*Ask for it in the channel instead.* Say what you want watched and " +
	"what may change — \"review every terraform plan in AndrewDryga/responder and open PRs " +
	"for drift, 2 a day, for 30 days\" — and Responder shows you the exact normalized " +
	"bounds on a confirmation card before anything is granted."
