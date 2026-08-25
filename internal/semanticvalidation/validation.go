// Package semanticvalidation reconciles Coop's durable semantic-candidate
// state with the caller-owned validator that understands frozen external data.
package semanticvalidation

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/decision"
)

const maxViolationBytes = 3500

type client interface {
	AcceptTurnCandidate(context.Context, string, string, string, string) (coop.Turn, error)
	RejectTurnCandidate(context.Context, string, string, string, string, []string) (coop.Turn, error)
}

type Request struct {
	RunID     string
	SessionID string
	TurnID    string
	Turn      coop.Turn
}

// Resolve validates one unpublished candidate, records the caller's exact
// accept/reject decision in Coop, and reconciles a decision that committed
// before its HTTP response was lost. validate returns a violation for a
// correctable semantic refusal, or an error when validation itself could not
// complete.
func Resolve(
	ctx context.Context,
	coopClient any,
	req Request,
	validate func(coop.Turn) (violation string, err error),
	onReject func(string),
) error {
	turn := req.Turn
	if turn.ValidationCandidateSHA256 != "" {
		switch turn.State {
		case "completed":
			digest := sha256.Sum256([]byte(turn.AssistantMessage))
			if turn.ValidationReceipt != "" &&
				turn.ValidationCandidateSHA256 == hex.EncodeToString(digest[:]) {
				return nil
			}
		case "queued", "failed":
			if turn.ValidationAttempt > 0 && turn.ValidationError != "" {
				return nil
			}
		}
	}
	if turn.State != "awaiting_validation" || turn.Candidate == nil ||
		turn.Candidate.SHA256 == "" || turn.Candidate.Message == "" {
		return errors.New("Coop semantic candidate is missing its exact message or digest")
	}
	client, ok := coopClient.(client)
	if !ok {
		return errors.New("Coop client does not support semantic candidate validation")
	}
	candidateTurn := turn
	candidateTurn.AssistantMessage = turn.Candidate.Message
	violation, err := validate(candidateTurn)
	if err != nil {
		return err
	}
	if violation != "" {
		detail := decision.BoundedField(violation, maxViolationBytes)
		_, err := client.RejectTurnCandidate(
			ctx,
			fmt.Sprintf("semantic-reject:%s:%d:%s", req.RunID, turn.Candidate.Attempt, turn.Candidate.SHA256),
			req.SessionID, req.TurnID, turn.Candidate.SHA256, []string{detail},
		)
		if err == nil && onReject != nil {
			onReject(detail)
		}
		return err
	}
	accepted, err := client.AcceptTurnCandidate(
		ctx,
		fmt.Sprintf("semantic-accept:%s:%d:%s", req.RunID, turn.Candidate.Attempt, turn.Candidate.SHA256),
		req.SessionID, req.TurnID, turn.Candidate.SHA256,
	)
	if err != nil {
		return err
	}
	if accepted.State != "completed" || accepted.ValidationReceipt == "" ||
		accepted.AssistantMessage != turn.Candidate.Message {
		return errors.New("Coop did not return an exact semantic acceptance receipt")
	}
	return nil
}
