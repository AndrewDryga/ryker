package webhook

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

// NormalizeChange reads a kind: change delivery into one ledger row.
//
// identity is the delivery identity the caller already derived — the
// X-Responder-Event-ID header, falling back to the body digest — and NOT a
// field mapped out of the body. That is deliberate and is the security property
// of this route: the HMAC binds the delivery ID into the signature precisely so
// an authenticated payload cannot be replayed under a different dedup identity,
// and a change route that took its identity from the body would step outside
// that binding. The ledger and webhook_events therefore dedupe on exactly the
// same string.
//
// Everything else is optional. A route that maps nothing still records a
// deploy, stamped when it arrived, scoped to the route's own repository — which
// is the smallest useful thing a deploy notification can become, and it needs
// no scripting language to get there.
func NormalizeChange(
	route config.Webhook,
	body []byte,
	identity string,
	receivedAt time.Time,
) (core.ChangeEvent, error) {
	var payload map[string]any
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&payload); err != nil {
		return core.ChangeEvent{}, fmt.Errorf("decode change webhook: %w", err)
	}
	if err := requireEOF(dec); err != nil {
		return core.ChangeEvent{}, err
	}
	rawKind, err := optionalString(payload, route.Change.Kind)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.kind: %w", err)
	}
	kind, err := changeKind(rawKind)
	if err != nil {
		return core.ChangeEvent{}, err
	}
	occurredAt, err := optionalTime(payload, route.Change.OccurredAt)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.occurred_at: %w", err)
	}
	if occurredAt.IsZero() {
		occurredAt = receivedAt
	}
	summary, err := optionalString(payload, route.Change.Summary)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.summary: %w", err)
	}
	actor, err := optionalString(payload, route.Change.Actor)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.actor: %w", err)
	}
	revision, err := optionalString(payload, route.Change.Revision)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.revision: %w", err)
	}
	sourceURLValue, err := optionalString(payload, route.Change.SourceURL)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.source_url: %w", err)
	}
	sourceURL := validSourceURL(sourceURLValue)
	if sourceURLValue != "" && sourceURL == "" {
		return core.ChangeEvent{}, errors.New("change.source_url: value must be an http or https URL")
	}
	services, err := optionalList(payload, route.Change.Services)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.services: %w", err)
	}
	repositories, err := optionalList(payload, route.Change.Repositories)
	if err != nil {
		return core.ChangeEvent{}, fmt.Errorf("change.repositories: %w", err)
	}
	event, ok := changeledger.Record(core.ChangeEvent{
		Source:         changeledger.SourceWebhoookRoot + route.Name,
		SourceIdentity: identity,
		Kind:           kind,
		OccurredAt:     occurredAt,
		Services:       services,
		// The route's own repository is always in scope. It is operator
		// configuration rather than sender-supplied, and without it a route
		// that maps no scope at all would write rows nothing could ever recall.
		Repositories: append(repositories, route.Repository),
		Actor:        actor,
		Summary:      summary,
		SourceRef:    sourceURL,
		Revision:     revision,
	})
	if !ok {
		return core.ChangeEvent{}, errors.New("change webhook is missing a delivery identity")
	}
	return event, nil
}

// changeKind maps what a sender calls a change onto the closed vocabulary the
// prompt explains.
//
// The aliases exist because real payloads say "release", "rollout" and
// "terraform" and none of them is going to change its wording for Responder.
// An unmapped path means deploy, which is what a change webhook almost always
// is; the other members of the vocabulary mostly arrive from the publication
// and Emisar adapters, which do not go through a route at all.
//
// A mapped value that is not recognized is an error rather than a fallback to
// deploy. A typo in a route mapping should stop at ingest where an operator can
// still see the 400, not reach an incident prompt as a deploy that never
// happened.
func changeKind(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	switch normalized {
	case "":
		return changeledger.KindDeploy, nil
	case "deploy", "deployment", "deployed", "release", "released", "rollout":
		return changeledger.KindDeploy, nil
	case "merge", "merged", "pull_request", "pr":
		return changeledger.KindMerge, nil
	case "infra_apply", "apply", "applied", "terraform", "terraform_apply":
		return changeledger.KindInfraApply, nil
	case "flag", "feature_flag", "toggle", "flag_change":
		return changeledger.KindFlag, nil
	case "config", "configuration", "setting", "config_change":
		return changeledger.KindConfig, nil
	default:
		return "", fmt.Errorf("change.kind: unsupported change kind %q", value)
	}
}

// optionalList reads a scalar or an array of scalars from one dot path.
//
// Both shapes because both are ordinary: a deploy notification usually names
// one service and a fan-out release names several, and telling those apart is
// exactly the kind of thing an embedded expression language would be reached
// for. Nested arrays and objects are refused rather than flattened — a mapping
// pointed at the wrong path should say so.
func optionalList(payload map[string]any, path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	value, ok := lookup(payload, path)
	if !ok || value == nil {
		return nil, nil
	}
	if scalar, ok := scalarString(value); ok {
		return []string{scalar}, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, errors.New("value must be a scalar or an array of scalars")
	}
	result := make([]string, 0, len(items))
	for index, item := range items {
		scalar, ok := scalarString(item)
		if !ok {
			return nil, fmt.Errorf("array entry %d must be a scalar", index)
		}
		result = append(result, scalar)
	}
	return result, nil
}
