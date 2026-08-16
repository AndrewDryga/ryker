// Package alertstream compares what an alert stream has already told a channel
// with what it is about to tell it again.
//
// One Grafana stream posted seven cards in ninety minutes on 2026-08-16 and
// drew five replies into one thread, each restating the same verdict over the
// same coverage with the same recommended action, and each doing it in
// different words. Two of them said only that a node had crossed back over the
// same line. Nothing anywhere compared a new assessment with the one already
// posted — and nothing could, because a reply is prose and prose never repeats
// itself exactly.
//
// This package holds no state and reaches nothing: no store, no Slack, no
// clock. It takes a decision and returns what that decision DECIDES. The host
// does the reading, the writing and the suppressing, so a suppression is
// reproducible from the two results alone.
package alertstream

import (
	"encoding/json"
	"slices"
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

// ReplyPosted is the durable record of an answer this stream has already given:
// what it decided, where it landed, and which card produced it.
//
// It is an episode fact rather than a projection. The signature is what the
// next card is compared against; SourceInputID is how the host finds out
// whether the offer that reply carried is still open, since an offer's button
// lives on the message that carried it.
type ReplyPosted struct {
	Signature Signature `json:"signature"`
	// DeliveryID is the outbox family the reply was written to, kept for the
	// trace rather than for any decision made here.
	DeliveryID    string `json:"delivery_id,omitempty"`
	SourceInputID string `json:"source_input_id,omitempty"`
	PostedAt      string `json:"posted_at,omitempty"`
	Verdict       string `json:"verdict,omitempty"`
	// Action is the assessment's immediate_action, bounded, and it is the one
	// free-text field kept: the next turn is told what it recommended so it can
	// judge whether the recommendation has changed. It is deliberately absent
	// from Signature for the same reason it is kept here — it is prose, and
	// prose is what the comparison must not depend on.
	Action string `json:"action,omitempty"`
	// OfferRepository and OfferTitle are the RESOLVED engineering offer this
	// reply rendered a button for, as opposed to Signature.OfferRepository,
	// which is what the model named.
	OfferRepository string `json:"offer_repository,omitempty"`
	OfferTitle      string `json:"offer_title,omitempty"`
}

// DecodeReplies reads a stream's recorded answers, newest first, and reports
// how many it could not read.
//
// A record this host cannot decode is a comparison it cannot make, and the safe
// answer to "has anything changed" is yes — so an unreadable record is dropped
// rather than guessed at, which posts. The count is returned so the caller can
// say so rather than silently comparing against fewer answers than exist.
func DecodeReplies(payloads []json.RawMessage) ([]ReplyPosted, int) {
	replies := make([]ReplyPosted, 0, len(payloads))
	unreadable := 0
	for _, payload := range payloads {
		var reply ReplyPosted
		if err := json.Unmarshal(payload, &reply); err != nil {
			unreadable++
			continue
		}
		replies = append(replies, reply)
	}
	return replies, unreadable
}

// OpenOfferCandidates narrows a stream's answers to the ones that put a button
// on this exact repository, excluding the card being answered now.
//
// Whether those offers are still open is a question for the store — an accepted
// task and an undelivered reply both close one — and this is the part that
// needs no database to reproduce.
func OpenOfferCandidates(
	replies []ReplyPosted,
	repository string,
	excludeSourceInputID string,
) []ReplyPosted {
	var candidates []ReplyPosted
	for _, reply := range replies {
		if strings.TrimSpace(reply.OfferTitle) == "" ||
			reply.OfferRepository != repository ||
			strings.TrimSpace(reply.SourceInputID) == "" ||
			reply.SourceInputID == excludeSourceInputID {
			continue
		}
		candidates = append(candidates, reply)
	}
	return candidates
}

// Signature is what an alert reply DECIDES, stripped of wording, so two replies
// can be compared for whether the decision changed.
//
// Free-text fields are deliberately excluded: the five replies on 2026-08-16
// differed in every sentence and in nothing that mattered. The impact line, the
// cause prose, the immediate action and the message itself are all absent for
// that reason — including the recommended action, which was reworded twice
// while recommending the identical change.
type Signature struct {
	AlertVerdict      string `json:"alert_verdict,omitempty"`
	CauseStatus       string `json:"cause_status,omitempty"`
	CompletionStatus  string `json:"completion_status,omitempty"`
	CompletionVerdict string `json:"completion_verdict,omitempty"`
	// Layers is the sorted "layer=status" of every coverage layer that is not
	// well. A healthy layer is the absence of news, and listing it would make
	// "the change layer was checked this time too" read as a changed decision.
	Layers []string `json:"layers,omitempty"`
	// Unexplained and Explained count the typed findings by status. A finding
	// moving from unexplained to explained is the single most useful thing an
	// update can say, and it is invisible in every other field here.
	Unexplained int `json:"unexplained,omitempty"`
	Explained   int `json:"explained,omitempty"`
	// OfferRepository is what the model named, not what the host resolved:
	// this is a comparison of decisions, and the host's resolution is the same
	// function of the same channel on every card.
	OfferRepository string `json:"offer_repository,omitempty"`
	OfferPresent    bool   `json:"offer_present,omitempty"`
}

// unwellCoverage names the coverage states that carry news. Coverage is
// recorded for every layer the turn looked at, so comparing all of them would
// make a wider investigation read as a changed conclusion.
func unwellCoverage(status string) bool {
	switch status {
	case "degraded", "unhealthy", "unknown":
		return true
	default:
		return false
	}
}

func SignatureOf(decision decisionpkg.WatchDecision) Signature {
	signature := Signature{
		OfferPresent:    strings.TrimSpace(decision.TaskTitle) != "",
		OfferRepository: normalized(decision.TaskRepository),
	}
	if decision.AlertAssessment != nil {
		signature.AlertVerdict = normalized(decision.AlertAssessment.Verdict)
		signature.CauseStatus = normalized(decision.AlertAssessment.CauseStatus)
	}
	if decision.Completion != nil {
		signature.CompletionStatus = normalized(decision.Completion.Status)
		signature.CompletionVerdict = normalized(decision.Completion.Verdict)
	}
	for _, coverage := range decision.Coverage {
		status := normalized(coverage.Status)
		layer := normalized(coverage.Layer)
		if layer == "" || !unwellCoverage(status) {
			continue
		}
		if entry := layer + "=" + status; !slices.Contains(signature.Layers, entry) {
			signature.Layers = append(signature.Layers, entry)
		}
	}
	slices.Sort(signature.Layers)
	for _, finding := range decision.Findings {
		switch normalized(finding.Status) {
		case "explained":
			signature.Explained++
		default:
			signature.Unexplained++
		}
	}
	return signature
}

func (a Signature) Equal(b Signature) bool {
	return a.AlertVerdict == b.AlertVerdict &&
		a.CauseStatus == b.CauseStatus &&
		a.CompletionStatus == b.CompletionStatus &&
		a.CompletionVerdict == b.CompletionVerdict &&
		a.Unexplained == b.Unexplained &&
		a.Explained == b.Explained &&
		a.OfferRepository == b.OfferRepository &&
		a.OfferPresent == b.OfferPresent &&
		slices.Equal(a.Layers, b.Layers)
}

// Change names, in one bounded line, what moved between two signatures.
//
// A suppression nobody can debug becomes a suppression nobody trusts, and the
// first question asked about a missing reply is always "compared with what".
// The answer belongs on the trace beside the decision it explains.
func (a Signature) Change(previous Signature) string {
	var parts []string
	note := func(field, from, to string) {
		if from != to {
			parts = append(parts, field+" "+placeholder(from)+"→"+placeholder(to))
		}
	}
	note("verdict", previous.AlertVerdict, a.AlertVerdict)
	note("cause", previous.CauseStatus, a.CauseStatus)
	note("completion", previous.CompletionStatus, a.CompletionStatus)
	note("outcome", previous.CompletionVerdict, a.CompletionVerdict)
	if !slices.Equal(previous.Layers, a.Layers) {
		note("layers", strings.Join(previous.Layers, ","), strings.Join(a.Layers, ","))
	}
	if previous.Unexplained != a.Unexplained || previous.Explained != a.Explained {
		parts = append(parts, "findings "+
			findingCount(previous)+"→"+findingCount(a))
	}
	if previous.OfferPresent != a.OfferPresent ||
		previous.OfferRepository != a.OfferRepository {
		note("offer", offerLabel(previous), offerLabel(a))
	}
	if len(parts) == 0 {
		return "nothing in the typed decision moved"
	}
	return core.BoundedText(strings.Join(parts, "; "), 400)
}

func findingCount(signature Signature) string {
	return strconv.Itoa(signature.Unexplained) + " unexplained/" +
		strconv.Itoa(signature.Explained) + " explained"
}

func offerLabel(signature Signature) string {
	if !signature.OfferPresent {
		return ""
	}
	return core.FirstNonempty(signature.OfferRepository, "a task")
}

// placeholder keeps an empty side of a transition legible. "verdict →not_issue"
// reads as a formatting bug; "verdict none→not_issue" reads as what happened.
func placeholder(value string) string {
	return core.FirstNonempty(value, "none")
}

func normalized(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
