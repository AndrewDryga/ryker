// Package runreplay classifies failed Coop turns that can safely be replayed.
package runreplay

import (
	"encoding/json"
	"strings"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/provider"
	"github.com/AndrewDryga/responder/internal/retrydelay"
)

// MarkTurnTimeoutReplayed writes the dedicated replay budget without relying
// on aggregate run failures, which also count preparation and revision races.
func MarkTurnTimeoutReplayed(contextJSON []byte) ([]byte, error) {
	return markReplay(contextJSON, "turn_timeout_replays")
}

// MarkTransientSessionReplayed records the one disposable-session rotation a
// provider transport failure receives. Further refusals wait on provider
// backoff instead of creating a new session every few seconds.
func MarkTransientSessionReplayed(contextJSON []byte) ([]byte, error) {
	return markReplay(contextJSON, "transient_session_replays")
}

func markReplay(contextJSON []byte, key string) ([]byte, error) {
	fields := make(map[string]json.RawMessage)
	if len(contextJSON) != 0 {
		if err := json.Unmarshal(contextJSON, &fields); err != nil {
			return nil, err
		}
	}
	if fields == nil {
		fields = make(map[string]json.RawMessage)
	}
	fields[key] = json.RawMessage("1")
	return json.Marshal(fields)
}

const timeoutReplayReason = "The AI turn reached its deadline; retrying the accepted work once"

func Decide(
	run core.AgentRun,
	eventType string,
	turn coop.Turn,
	maximumAttempts int,
) (string, bool) {
	if eventType != "turn.failed" {
		return "", false
	}
	detail := strings.TrimSpace(turn.ErrorDetail)
	// failure_count also includes workspace preparation and revision races. The
	// first actual provider deadline still gets one recovery after those; the
	// exact durable replay reason is the separate timeout budget marker.
	if IsTurnTimeout(turn) && !turnTimeoutReplayed(run.Context) {
		return timeoutReplayReason, true
	}
	if run.Mode == core.AgentRunTriage && IsTransientProviderFailure(turn) &&
		!transientSessionReplayed(run.Context) {
		return "The AI provider dropped the response; retrying in a fresh session", true
	}
	if retrydelay.Exhausted(run.Failures+1, maximumAttempts) {
		return "", false
	}
	if turn.ErrorCode == "acp_cancelled" && detail == "turn cancelled" {
		return "Coop turn was interrupted while Responder was stopping", true
	}
	if turn.ErrorCode == "turn_interrupted" || turn.State == "interrupted" {
		return "Coop restarted under the turn; replaying it in a fresh session", true
	}
	if run.Failures == 0 && turn.ErrorCode == "acp_protocol_error" &&
		strings.Contains(detail, "ACP frame exceeded its bound") {
		return "Coop returned an oversized ACP frame; retrying the turn once", true
	}
	if run.Mode == core.AgentRunTriage && transcriptOverflow(turn) {
		return "Coop ACP transcript exceeded its bound; retrying in a fresh read-only session with narrower evidence queries", true
	}
	if run.Mode == core.AgentRunTriage && run.Failures < 2 && runtimeCleanupFailure(turn) {
		return "Coop could not clean up the agent turn; retrying in a fresh session", true
	}
	if run.Mode != core.AgentRunTriage &&
		turn.ErrorCode == "acp_protocol_error" && provider.Transient(detail) {
		return "The AI provider dropped the response mid-stream; retrying the turn", true
	}
	if TerminalEnvironment(turn) {
		return "", false
	}
	if run.Mode == core.AgentRunTriage && turn.ErrorCode == "acp_process_error" &&
		strings.Contains(strings.ToLower(detail), "acp child closed before its response") &&
		run.Failures < maximumAttempts-1 {
		return "Coop ACP child closed unexpectedly; retrying in a fresh read-only session", true
	}
	return "", false
}

func IsTurnTimeout(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_timeout" || strings.Contains(
		strings.ToLower(strings.TrimSpace(turn.ErrorDetail)), "turn deadline exceeded",
	)
}

func turnTimeoutReplayed(contextJSON []byte) bool {
	var marker struct {
		TurnTimeoutReplays int `json:"turn_timeout_replays"`
	}
	return json.Unmarshal(contextJSON, &marker) == nil && marker.TurnTimeoutReplays > 0
}

func transientSessionReplayed(contextJSON []byte) bool {
	var marker struct {
		TransientSessionReplays int `json:"transient_session_replays"`
	}
	return json.Unmarshal(contextJSON, &marker) == nil && marker.TransientSessionReplays > 0
}

// IsTransientProviderFailure reports a transport-level provider failure whose
// native session may be poisoned even though the accepted work is still valid.
func IsTransientProviderFailure(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_protocol_error" && provider.Transient(turn.ErrorDetail)
}

func FreshSession(turn coop.Turn) bool {
	if TerminalEnvironment(turn) {
		return false
	}
	detail := strings.ToLower(strings.TrimSpace(turn.ErrorDetail))
	return (turn.ErrorCode == "acp_cancelled" && detail == "turn cancelled") ||
		runtimeCleanupFailure(turn) ||
		IsTransientProviderFailure(turn) ||
		(turn.ErrorCode == "acp_process_error" &&
			strings.Contains(detail, "acp child closed before its response")) ||
		transcriptOverflow(turn)
}

func runtimeCleanupFailure(turn coop.Turn) bool {
	if turn.ErrorCode == "session_cleanup_error" {
		return true
	}
	detail := strings.ToLower(strings.TrimSpace(turn.ErrorDetail))
	return strings.Contains(detail, "turn cleanup failed") ||
		strings.Contains(detail, "runtime cleanup failed")
}

func TerminalEnvironment(turn coop.Turn) bool {
	if turn.ErrorCode != "acp_process_error" {
		return false
	}
	detail := strings.ToLower(strings.TrimSpace(turn.ErrorDetail))
	for _, diagnostic := range []string{
		"coop box image is not built",
		"coop runtime storage is full",
		"coop cannot reach the docker runtime",
		"configured coop account is not authenticated",
		"credential is not portable through the turn deadline",
		"provider credential needs sign-in or renewal",
	} {
		if strings.Contains(detail, diagnostic) {
			return true
		}
	}
	return false
}

func transcriptOverflow(turn coop.Turn) bool {
	return turn.ErrorCode == "acp_protocol_error" && strings.Contains(
		strings.ToLower(strings.TrimSpace(turn.ErrorDetail)),
		"acp transcript exceeded its bound",
	)
}
