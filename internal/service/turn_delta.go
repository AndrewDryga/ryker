package service

import (
	"context"
	"strings"

	"github.com/AndrewDryga/responder/internal/agentprompt"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/publicationcontext"
	"github.com/AndrewDryga/responder/internal/turndelta"
)

// standingBriefing asks whether this attempt may lean on the briefing already in
// its Coop session instead of restating it.
//
// It must be called BEFORE the run is bound to the resolved session: binding
// overwrites run.SessionID and run.CoopEventSequence with the projection's
// values, which would make every attempt look like it was already sitting at the
// previous terminal. That is the one ordering mistake here that produces a
// wrong DELTA rather than a wrong full briefing.
//
// A store read that fails is a doubt like any other and answers "full briefing".
func (s *Service) standingBriefing(
	ctx context.Context,
	run core.AgentRun,
	session coop.Session,
	generation int,
	eventSequence int64,
	state decisionpkg.WatchTurnState,
) turndelta.Decision {
	attempt, err := s.store.GetEpisodeAttempt(ctx, run.AttemptID)
	if err != nil {
		return turndelta.Decision{Reason: turndelta.ReasonNoStandingBriefing}
	}
	previous, err := s.store.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		return turndelta.Decision{Reason: turndelta.ReasonNoStandingBriefing}
	}
	return turndelta.Decide(
		turndelta.Session{
			ID: session.ID, State: session.State, Preset: session.Policy,
			Generation: generation, Cursor: eventSequence,
		},
		turndelta.Attempt{
			FrozenManifestID:  attempt.ContextManifestID,
			SessionID:         run.SessionID,
			TurnID:            run.CoopTurnID,
			SessionGeneration: run.SessionGeneration,
			Cursor:            run.CoopEventSequence,
			// The fresh-session replay path writes a generation newer than the
			// one this run is bound to and clears the session it will resolve
			// against. The rotation clause catches the cleared session; this
			// catches the intent before the resolution can disagree.
			Replay:  run.SessionGeneration > 0 && state.Generation > run.SessionGeneration,
			Handoff: isSessionHandoffRun(run),
		},
		turndelta.Standing{
			ManifestID: previous.ID,
			Preset:     previous.Preset,
			Prompt:     previous.SubmittedPrompt,
			Contract: turndelta.Contract{
				Prompt:        previous.PromptVersion,
				Investigation: previous.ContractVersion,
				ToolSchema:    previous.ToolSchemaVersion,
			},
			// A manifest is frozen before the submit it describes, so a recorded
			// prompt only means the host meant to send one. The cursor clause in
			// Decide is what proves it arrived; this rules out the manifests
			// written before submitted_prompt existed, whose text nobody has.
			Delivered: strings.TrimSpace(previous.SubmittedPrompt) != "",
		},
		turndelta.Contract{
			Prompt:        responderPromptVersion,
			Investigation: investigationContractVersion,
			ToolSchema:    resultOperationsVersion,
		},
	)
}

// deltaTurnPrompt is the follow-up turn: what arrived, what the host has
// recorded since, and what the host is correcting — and nothing the standing
// briefing already said.
//
// The sections are the ones that change between attempts of one episode. The
// repository set, the capability rules, the tool transport limits and the whole
// instruction block are deliberately absent: they are byte-identical to what the
// session was told when it opened, and restating them is the cost this exists to
// stop paying.
func (s *Service) deltaTurnPrompt(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state decisionpkg.WatchTurnState,
	episode core.WorkEpisode,
	standing turndelta.Decision,
) string {
	host := ""
	if state.Lane != "conversation" {
		host = turndelta.Escalation(boundedOperatorText(state.EscalationReason))
	}
	host += watchDecisionCorrectionPrompt(state.FailureDetail) + agentprompt.Continuation(run)
	return turndelta.Prompt(turndelta.Sections{
		Input:    turndelta.NewInput(input.UserID, boundedOperatorText(input.Text)),
		Contract: WorkEpisodePrompt(episode),
		Episode: []string{
			s.episodeContinuityPrompt(ctx, episode),
			publicationcontext.ActivePrompt(state.ActivePublications),
		},
		Host:     host,
		Standing: standing.StandingPrompt,
	})
}

// standingBriefingOmission records that the briefing was left out and which one
// the turn leaned on.
//
// It travels as an omission because that is exactly what it is — context the
// host assembled and deliberately did not send — and because omissions already
// reach both context_manifests.omissions_json and a context_manifest_refs row
// without a migration. The reference's source_ref carries delta_of:<manifest>,
// so the episode trace can walk a delta back to the briefing behind it rather
// than showing a turn that was apparently told almost nothing.
func standingBriefingOmission(decision turndelta.Decision) core.ContextOmission {
	return core.ContextOmission{
		Kind:      "standing_briefing",
		SourceRef: "delta_of:" + decision.ParentManifestID,
		Reason:    decision.Reason,
	}
}
