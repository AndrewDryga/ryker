package slackui

import (
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// AssignmentDirectoryMessage lists the standing assignments in a channel and
// what each of them has decided so far.
//
// Every row leads with the grant and ends with the tally, in that order,
// because those are the two questions in sequence: what did I agree to, and has
// it earned the agreement. Standing rules learned the second half the expensive
// way — a rule with 64 fires read as productive and had ignored every one of
// them — and this is the same question about a bigger grant.
//
// The rows carry no buttons. Pause, resume and delete are typed subcommands
// rather than controls because a button that grants or revokes autonomous
// pull-request authority sits one mis-click from the thing this whole shadow
// period exists to be careful about, and the id is already on the row.
func AssignmentDirectoryMessage(
	assignmentList []core.StandingAssignment,
	tallies map[string]core.StandingAssignmentTally,
) Message {
	message := Message{
		Text: "Responder has " +
			countLabel(len(assignmentList), "standing assignment") + " in this channel.",
		Header:    "Standing assignments for this channel",
		Temporary: true,
	}
	if len(assignmentList) == 0 {
		message.Sections = []string{
			"No standing assignments are configured in this channel.",
			"A standing assignment is scoped authority to open a pull request without a " +
				"per-action click: one signal, one repository, one class of change, a daily " +
				"budget and an expiry. Ask for one in your own words — \"watch for renovate " +
				"failures here and open dependency PRs, 2 a day, for 30 days\" — and Responder " +
				"will show you the exact normalized bounds to confirm.",
		}
		message.Context = []string{
			"Every assignment is created in shadow: it is evaluated by the real gate and " +
				"records what it would have done, and opens nothing.",
		}
		return message
	}
	message.Context = []string{fmt.Sprintf(
		"%s here · each records what it would have done, and opens nothing while shadowed.",
		countLabel(len(assignmentList), "standing assignment"),
	)}
	entries := make([]directoryEntry, 0, len(assignmentList))
	for _, assignment := range assignmentList {
		entries = append(entries, directoryEntry{
			Text: "*" + assignment.SignalPattern + "* — " +
				strings.ReplaceAll(assignment.ChangeClass, "_", " ") +
				" in `" + assignment.Repository + "`\n" +
				joinFacts([]string{
					assignmentState(assignment),
					"`" + assignment.ID + "`",
					fmt.Sprintf("up to %d a day", assignment.DailyBudget),
					assignmentPathFact(assignment),
					expiryFact(assignment.ExpiresAt),
				}) + "\n_" + AssignmentWorth(tallies[assignment.ID]) + "_",
		})
	}
	return directoryCard(message, entries, "newest first.")
}

// assignmentState says what the row can do right now, and shadow is stated
// first because it is the difference between a grant and a rehearsal.
func assignmentState(assignment core.StandingAssignment) string {
	switch {
	case !assignment.Enabled:
		return "paused"
	case assignment.Shadow:
		return "shadow, opens nothing"
	default:
		return "live, may open a pull request"
	}
}

func assignmentPathFact(assignment core.StandingAssignment) string {
	if len(assignment.PathGlobs) == 0 {
		return "whole repository"
	}
	return "paths " + strings.Join(assignment.PathGlobs, ", ")
}

// assignmentOfferContext is the boundary line every assignment card carries.
//
// Both halves are load-bearing. Nothing exists until the button is pressed —
// which is the claim the whole offer discipline rests on — and what the button
// creates is still shadowed, because an operator reading "scoped authority to
// open pull requests" and pressing a primary-styled button is entitled to know
// that the first thing it does is rehearse rather than act.
const assignmentOfferContext = "Nothing is granted yet. Confirming creates this in shadow: " +
	"it is evaluated by the real gate and records what it would have done, and opens nothing " +
	"until the shadow flag is cleared as a separate decision."

// WithAssignmentOffer asks an operator to grant one standing assignment, and
// shows them the grant rather than the request.
//
// Every fact on this card is the NORMALIZED value — the repository as it will
// be stored, the change class as the allowlist spells it, the daily budget and
// the expiry the host filled in when the sentence did not say, the path globs
// after the empty ones were dropped. That is the entire reason this card
// replaced a typed `create` command: the old grammar asked an operator to
// compose nine key=value bounds and then confirmed the ones they typed, so a
// miscounted `paths=` was a repository-wide grant that read as a narrow one.
// Here the operator confirms the row.
//
// One control, and it is a confirmation with a dialog. Declining is not
// pressing it.
func WithAssignmentOffer(
	message Message,
	assignment core.StandingAssignment,
	expiryDays int,
	actionValue string,
	rationale string,
) Message {
	quote := "Let me watch for this and open the pull requests myself."
	if text := externalText(rationale); text != "" {
		quote = text
	}
	class := strings.ReplaceAll(assignment.ChangeClass, "_", " ")
	return offerCard(message, assignmentOfferContext, offerProposal{
		Quote: quote,
		// The expiry is a duration here and a date on every other assignment
		// surface, and that is deliberate: this card is read before the grant
		// exists, so a date would be the date it would have expired had the
		// button been pressed the instant it was posted. The row records the
		// instant; the operator agrees to the span.
		Facts: joinFacts([]string{
			"Watches *" + externalText(assignment.SignalPattern) + "* in this channel",
			"Repository `" + safeInlineCode(assignment.Repository) + "`",
			"Change class " + externalText(class),
			fmt.Sprintf("up to %d a day", assignment.DailyBudget),
			assignmentPathFact(assignment),
			fmt.Sprintf("expires %d days after confirmation", expiryDays),
			"shadow, opens nothing",
		}),
		Actions: []Action{{
			ID:    ActionConfirmAssignmentOffer,
			Label: "Grant this assignment",
			Value: actionValue,
			Style: "primary",
			Confirm: "Let Responder decide, without asking again, whether to open a " + class +
				" pull request in " + assignment.Repository + "? It is created in shadow and " +
				"opens nothing until that is cleared.",
		}},
	})
}

// AssignmentSavedMessage is the receipt for a grant that was just written.
//
// It restates the scope rather than confirming an action, because the operator
// is agreeing once to work that will happen without them, and the only moment
// they can check what they agreed to is this one.
func AssignmentSavedMessage(assignment core.StandingAssignment) Message {
	return receiptCard(
		"Standing assignment saved for "+assignment.SignalPattern+".",
		"Saved, in shadow.",
		"When a signal matching *"+assignment.SignalPattern+"* concludes an investigation in "+
			"this channel, Responder will decide whether it would open a "+
			strings.ReplaceAll(assignment.ChangeClass, "_", " ")+
			" pull request in `"+assignment.Repository+"` — and record the answer without "+
			"opening anything.",
		[]string{
			"`" + assignment.ID + "`",
			fmt.Sprintf("up to %d a day", assignment.DailyBudget),
			assignmentPathFact(assignment),
			expiryFact(assignment.ExpiresAt),
			"Read `/responder assignments` after a few signals to see what it decided.",
		},
	)
}

// AssignmentOperatorOnly refuses an assignment confirmation from an actor who
// is not on the configured operator list. It says nothing was granted because
// that is the fact they need before deciding whether to try again.
const AssignmentOperatorOnly = "*Only configured Responder operators can grant a standing " +
	"assignment.* Nothing was granted."

// AssignmentMembershipRequired refuses an operator whose Slack account is not
// an active full workspace member and names that distinct remedy.
const AssignmentMembershipRequired = "*This Slack account cannot grant a standing assignment.* " +
	"Active full workspace membership is required. Nothing was granted."

const AssignmentConfirmationStale = "*This confirmation is invalid or stale.* Nothing was " +
	"granted. Ask again in the channel and use the new confirmation button."

// AssignmentRefusedNotice is what an operator reads when the host can no longer
// normalize the bounds it offered — an offer written by an older binary against
// a class or a range this one no longer allows.
const AssignmentRefusedNotice = "*Responder refused this.* The bounds it offered are not ones " +
	"it can grant now. Nothing was granted; ask again and confirm the new card."

const AssignmentGrantFailed = "*Responder could not create this standing assignment.* "

// AssignmentChangedMessage is the receipt for pausing, resuming or deleting
// one.
func AssignmentChangedMessage(assignment core.StandingAssignment, verb string) Message {
	return receiptCard(
		"Standing assignment "+verb+".",
		"Done.",
		"The assignment watching *"+assignment.SignalPattern+"* in `"+
			assignment.Repository+"` is "+verb+".",
		[]string{"`" + assignment.ID + "`", assignmentState(assignment)},
	)
}

// AssignmentWorth is the one line that says whether a shadow period has proved
// anything.
//
// Modelled on the sentence standing rules gained on 2026-08-09 for the same
// reason: a bare count cannot answer "should this be granted". A rule that had
// fired 64 times read as busy and useful, and every recorded outcome of it was
// 'ignore'. So this leads with what the evaluations produced and says plainly
// when they produced nothing worth granting for.
func AssignmentWorth(tally core.StandingAssignmentTally) string {
	if tally.Evaluated == 0 {
		return "No signal has reached this assignment yet, so there is nothing to judge it on"
	}
	worth := fmt.Sprintf(
		"Evaluated %d signals · would have opened %d, refused %d",
		tally.Evaluated, tally.Eligible, tally.Declined,
	)
	if tally.TopDeclineCount > 1 {
		worth += fmt.Sprintf(
			" · most often because %s (%d times)", tally.TopDecline, tally.TopDeclineCount,
		)
	}
	switch {
	case tally.Eligible == 0:
		worth += " · it has never reached the bar, so granting it would change nothing yet"
	case !tally.LastEligible.IsZero():
		worth += " · last would have acted " +
			tally.LastEligible.UTC().Format("2006-01-02 15:04 UTC")
	}
	return worth
}
