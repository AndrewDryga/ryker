// Package behavioroffer turns a preference, standing-rule or memory offer into
// the value the host would store, and reads back the button that offer becomes.
//
// It is the other half of internal/offerreason. That package owns the words a
// refusal uses; this one owns the checks that produce them, the phrasings that
// decide whether an offer was invited at all, and the payload a confirmation
// click carries. internal/scheduleoffer is the same split already made for
// schedules, and these are its three siblings — they stayed in internal/service
// only because each validator reached the configuration for a team id and a
// repository list.
//
// Everything here is a function of its arguments. Those two configuration
// questions arrive as a Catalog, so a refusal is reproducible from an offer and
// a list of repository names rather than from a running deployment: the reason
// the model was told its offer was wrong can be replayed from the offer alone.
package behavioroffer

import (
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/memory"
	"github.com/AndrewDryga/ryker/internal/offerreason"
	"github.com/AndrewDryga/ryker/internal/schedule"
)

// Catalog is the host's repository configuration, narrowed to the two questions
// an offer validator asks of it: whether a slug names something this deployment
// resolves, and what it would list back when the answer is no.
//
// An interface rather than a slice of names because the two answers are not the
// same set — a repository set naming a primary that is not configured is listed
// and does not resolve — and a validator that flattened them would start
// accepting a repository no later step could check out.
type Catalog interface {
	Configured(name string) bool
	Names() []string
}

// Context is what a validator needs from the offer's surroundings: who is
// offering, where, when, and against which repositories.
type Context struct {
	// ChannelID is the conversation the offer was made in. Empty means the
	// offer arrived somewhere that is not a channel — App Home is the usual
	// one — and every scope that keys off a channel refuses there.
	ChannelID string
	UserID    string
	// InputID becomes the stored row's provenance. It is deliberately not the
	// confirmation payload's SourceRef, which prefers the Slack event id.
	InputID string
	// TeamID keys workspace scope.
	TeamID string
	Now    time.Time
	// Repositories answers the two Catalog questions. A nil Catalog configures
	// nothing, which is what a host with no repositories means.
	Repositories Catalog
}

func (c Context) configured(name string) bool {
	return c.Repositories != nil && c.Repositories.Configured(name)
}

// UnknownRepository refuses a repository this host does not have, and lists the
// ones it does. The model cannot learn a deployment's repositories from the
// conversation, so a refusal that says only "not configured" leaves it to guess
// the same wrong slug again — and it did, on every schedule the blitz host was
// asked for by its own name.
func UnknownRepository(name string, catalog Catalog) error {
	names := []string(nil)
	if catalog != nil {
		names = catalog.Names()
	}
	return offerreason.Field(
		"repository", name,
		"the configured repositories are "+offerreason.List(names),
	)
}

var (
	preferenceRequestPattern = regexp.MustCompile(
		`(?i)\b(?:always|from now on|going forward|when(?:ever)?\s+i\s+ask|` +
			`prefer(?:ence)?|default\s+to|by\s+default|remember|` +
			`(?:use|us)\s+threads?|answers?[^\n]{0,100}\bthreads?)\b`,
	)
	memoryRequestPattern = regexp.MustCompile(
		`(?i)\b(?:remember|memorize|save this|store this|correct (?:your|the) memory|` +
			`keep (?:this|that|it) in mind|from now on|going forward|always|every time|whenever)\b`,
	)
	incidentRoomReferencePattern = regexp.MustCompile(
		`(?i)\bincident(?:\s+(?:channel|room))?\b`,
	)
	inviteSelfPattern = regexp.MustCompile(
		`(?i)\binvite\s+(?:me|myself)\b`,
	)
	canonicalMemoryRefPattern = regexp.MustCompile(
		`^(?:repo|channel|emisar|service):[A-Za-z0-9._/@:-]{1,180}$`,
	)
	aliasMemorySubjectPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._ /:-]{0,119}$`)
	memoryRevisionPattern     = regexp.MustCompile(`^(?:[A-Fa-f0-9]{7,64}|sha256:[A-Fa-f0-9]{64})$`)
)

// PreferenceRequest reports whether the message asked for a lasting preference.
func PreferenceRequest(text string) bool {
	return preferenceRequestPattern.MatchString(text)
}

// MemoryRequest reports whether the message asked for something to be
// remembered.
func MemoryRequest(text string) bool {
	return memoryRequestPattern.MatchString(text)
}

// ExplicitRequest reports whether the message asked for lasting behaviour of
// any of the three kinds an operator can confirm.
func ExplicitRequest(text string) bool {
	return PreferenceRequest(text) ||
		decision.StandingRuleAssignment(text) || schedule.ExplicitScheduleRequest(text)
}

// IncidentSelfInvite reports a lasting-behaviour request that is really about
// being added to incident rooms.
func IncidentSelfInvite(text string) bool {
	return ExplicitRequest(text) &&
		incidentRoomReferencePattern.MatchString(text) &&
		inviteSelfPattern.MatchString(text)
}

// AffirmativeConfirmation reports whether a reply is a bare yes to the offer
// above it. The list is closed on purpose: anything longer is a sentence with
// content, and confirming an offer on the strength of a word inside it is how a
// question gets read as consent.
func AffirmativeConfirmation(text string) bool {
	normalized := strings.ToLower(strings.TrimSpace(text))
	normalized = strings.TrimRight(normalized, ".!")
	switch normalized {
	case "ok", "okay", "yes", "yes please", "confirm", "confirmed",
		"save it", "remember it", "do it", "sounds good", "sgtm":
		return true
	default:
		return false
	}
}

func containsAnyPhrase(value string, phrases ...string) bool {
	for _, phrase := range phrases {
		if strings.Contains(value, phrase) {
			return true
		}
	}
	return false
}

// NormalizeLocation reads a request to reply in threads or in channel and
// returns the preference offer that answers it, along with the acknowledgement
// that offer is made with.
//
// The host decides this one rather than the model because the vocabulary is
// small and fixed, and a location request answered by prose is a request the
// operator has to make twice.
func NormalizeLocation(
	text string,
	proposed *core.PreferenceOffer,
) (*core.PreferenceOffer, string, bool) {
	if !PreferenceRequest(text) {
		return proposed, "", false
	}
	normalized := decision.NormalizeLocationRequest(text)
	value := ""
	switch {
	case containsAnyPhrase(normalized,
		"follow the conversation", "follow conversation", "follow context",
		"where the conversation is", "wherever the conversation is"):
		value = "follow_context"
	case containsAnyPhrase(normalized,
		"prefer thread", "prefer threads", "prefer reply in thread", "prefer replies in thread",
		"default thread", "default to thread",
		"always use thread", "always reply in thread", "keep replies in thread",
		"use thread", "use threads", "us thread", "us threads",
		"thread by default", "threaded by default"):
		value = "prefer_thread"
	case containsAnyPhrase(normalized,
		"prefer channel", "prefer reply in channel", "prefer replies in channel",
		"default channel", "default to channel",
		"always use channel", "always reply in channel", "keep replies in channel",
		"channel by default", "unthreaded by default"):
		value = "prefer_channel"
	default:
		return proposed, "", false
	}
	scope := "operator"
	switch {
	case containsAnyPhrase(normalized,
		"in this channel", "for this channel", "this channel should", "in here"):
		scope = "channel"
	case containsAnyPhrase(normalized,
		"for everyone", "for everybody", "for the whole team", "team wide",
		"workspace wide", "for the workspace", "for all users"):
		scope = "workspace"
	}
	expiresIn := "90d"
	if proposed != nil && strings.TrimSpace(proposed.ExpiresIn) != "" {
		expiresIn = proposed.ExpiresIn
	}
	offer := &core.PreferenceOffer{
		Scope: scope, Name: "response_location", Value: value, ExpiresIn: expiresIn,
	}
	return offer, locationAcknowledgement(value, scope), true
}

func locationAcknowledgement(value string, scope string) string {
	target := "when replying to you"
	switch scope {
	case "channel":
		target = "in this channel"
	case "workspace":
		target = "across this workspace"
	}
	switch value {
	case "prefer_thread":
		return "Got it. I can prefer threads " + target + ". Confirm below so I remember it."
	case "prefer_channel":
		return "Got it. I can prefer channel replies " + target + ". Confirm below so I remember it."
	default:
		return "Got it. I can follow each conversation's current location " + target +
			". Confirm below so I remember it."
	}
}

// Preference turns a preference offer into the row the host would store, or
// says which field stopped it.
func Preference(
	offer core.PreferenceOffer,
	context Context,
) (core.RykerPreference, time.Duration, error) {
	offer.Scope = strings.ToLower(strings.TrimSpace(offer.Scope))
	offer.Repository = strings.ToLower(strings.TrimSpace(offer.Repository))
	offer.Name = strings.ToLower(strings.TrimSpace(offer.Name))
	offer.Value = strings.ToLower(strings.TrimSpace(offer.Value))
	ttl, err := memory.ParseMemoryTTL(offer.ExpiresIn)
	if err != nil {
		return core.RykerPreference{}, 0, err
	}
	preference := core.RykerPreference{
		ScopeKind: offer.Scope, Name: offer.Name, Value: offer.Value,
		Enabled: true, SourceRef: context.InputID, ActorID: context.UserID,
		ExpiresAt: memory.ExpiryFrom(context.Now, ttl),
	}
	switch offer.Scope {
	case "workspace":
		preference.ScopeKey = context.TeamID
	case "channel":
		if context.ChannelID == "" {
			return core.RykerPreference{}, 0, offerreason.Field(
				"scope", offer.Scope,
				"a channel preference has to come from a Slack channel; "+
					"use operator or workspace scope here",
			)
		}
		preference.ScopeKey = context.ChannelID
	case "repository":
		if !context.configured(offer.Repository) {
			return core.RykerPreference{}, 0,
				UnknownRepository(offer.Repository, context.Repositories)
		}
		preference.ScopeKey = offer.Repository
	case "operator":
		preference.ScopeKey = context.UserID
	default:
		return core.RykerPreference{}, 0, offerreason.Field(
			"scope", offer.Scope,
			"expected operator, channel, repository, or workspace",
		)
	}
	if memory.ContainsSecretLikeValue(preference.Value) {
		// The value is not read back here: it looks like a credential, and a
		// refusal that quotes one has copied it somewhere new.
		return core.RykerPreference{}, 0, errors.New(
			"the preference value looks like a credential and cannot be stored; " +
				"offer the setting, never the secret",
		)
	}
	switch preference.Name {
	case "health_check_depth":
		if preference.Value != "quick" && preference.Value != "standard" &&
			preference.Value != "deep" {
			return core.RykerPreference{}, 0, offerreason.Field(
				"value", preference.Value,
				"health_check_depth expects quick, standard, or deep",
			)
		}
	case "response_detail":
		if preference.Value != "concise" && preference.Value != "standard" &&
			preference.Value != "detailed" {
			return core.RykerPreference{}, 0, offerreason.Field(
				"value", preference.Value,
				"response_detail expects concise, standard, or detailed",
			)
		}
	case "response_location":
		if preference.ScopeKind == "repository" {
			return core.RykerPreference{}, 0, offerreason.Field(
				"scope", preference.ScopeKind,
				"response_location expects operator, channel, or workspace scope",
			)
		}
		if preference.Value != "follow_context" && preference.Value != "prefer_thread" &&
			preference.Value != "prefer_channel" {
			return core.RykerPreference{}, 0, offerreason.Field(
				"value", preference.Value,
				"response_location expects follow_context, prefer_thread, or prefer_channel",
			)
		}
	default:
		return core.RykerPreference{}, 0, offerreason.Field(
			"name", preference.Name,
			"expected health_check_depth, response_detail, or response_location",
		)
	}
	return preference, ttl, nil
}

// Rule turns a standing-rule offer into the row the host would store, or says
// which field stopped it.
func Rule(
	offer core.RuleOffer,
	context Context,
) (core.StandingRule, time.Duration, error) {
	offer.Scope = strings.ToLower(strings.TrimSpace(offer.Scope))
	offer.Repository = strings.ToLower(strings.TrimSpace(offer.Repository))
	offer.Trigger = strings.ToLower(strings.TrimSpace(offer.Trigger))
	offer.Action = strings.ToLower(strings.TrimSpace(offer.Action))
	offer.SourceKind = strings.ToLower(strings.TrimSpace(offer.SourceKind))
	if offer.SourceKind == "" {
		offer.SourceKind = "any"
	}
	ttl, err := memory.ParseMemoryTTL(offer.ExpiresIn)
	if err != nil {
		return core.StandingRule{}, 0, err
	}
	if offer.Scope != "channel" || context.ChannelID == "" ||
		strings.HasPrefix(context.ChannelID, "D") {
		return core.StandingRule{}, 0, offerreason.Field(
			"scope", offer.Scope,
			"expected channel, and a standing rule can only be set up in a "+
				"channel rather than a direct message",
		)
	}
	if !context.configured(offer.Repository) {
		return core.StandingRule{}, 0,
			UnknownRepository(offer.Repository, context.Repositories)
	}
	var proposed core.StandingWorkflow
	if offer.Workflow != nil {
		proposed = *offer.Workflow
	}
	workflow, trigger, action, err := core.NormalizeStandingWorkflow(
		proposed, offer.Trigger, offer.Action,
	)
	if err != nil {
		// core cannot say this itself: internal/offerreason imports core, so the
		// reverse would be a cycle. It exports the pairs, and the refusal is
		// worded here — which is where every other refusal in this family is
		// worded anyway. Without it the model got `standing rule pair
		// "deploy"/"watch_it" is invalid` and no way to learn the four that work.
		return core.StandingRule{}, 0, offerreason.Field(
			"trigger/action", offer.Trigger+"/"+offer.Action,
			"expected one of "+offerreason.List(core.StandingRulePairs())+
				"; or send workflow instead and leave both empty",
		)
	}
	if offer.Workflow != nil &&
		((offer.Trigger != "" && offer.Trigger != trigger) ||
			(offer.Action != "" && offer.Action != action)) {
		return core.StandingRule{}, 0, offerreason.Field(
			"workflow", workflow.Name,
			"it disagrees with trigger "+strconv.Quote(offer.Trigger)+" and action "+
				strconv.Quote(offer.Action)+", which compile to "+strconv.Quote(trigger)+
				" and "+strconv.Quote(action)+"; send the workflow alone",
		)
	}
	rule := core.StandingRule{
		ChannelID: context.ChannelID, Repository: offer.Repository,
		Trigger: trigger, Action: action, SourceKind: offer.SourceKind,
		WorkflowName: workflow.Name, Workflow: workflow,
		Enabled: true, SourceRef: context.InputID, ActorID: context.UserID,
		ExpiresAt: memory.ExpiryFrom(context.Now, ttl),
	}
	if rule.SourceKind != "any" && rule.SourceKind != "human" &&
		rule.SourceKind != "app" {
		return core.StandingRule{}, 0, offerreason.Field(
			"source_kind", rule.SourceKind, "expected any, human, or app",
		)
	}
	return rule, ttl, nil
}

// Entry turns a memory offer into the row the host would store, or says which
// field stopped it.
func Entry(
	offer core.MemoryOffer,
	context Context,
) (core.MemoryEntry, time.Duration, error) {
	offer.Scope = strings.TrimSpace(strings.ToLower(offer.Scope))
	offer.Repository = strings.TrimSpace(strings.ToLower(offer.Repository))
	offer.Subject = strings.TrimSpace(strings.ToLower(offer.Subject))
	offer.Predicate = strings.TrimSpace(strings.ToLower(offer.Predicate))
	offer.Value = strings.TrimSpace(offer.Value)
	offer.Visibility = strings.TrimSpace(strings.ToLower(offer.Visibility))
	offer.SourceRevision = strings.TrimSpace(offer.SourceRevision)
	ttl, err := memory.ParseMemoryTTL(offer.ExpiresIn)
	if err != nil {
		return core.MemoryEntry{}, 0, err
	}
	if context.ChannelID == "" {
		return core.MemoryEntry{}, 0, errors.New("memory requires a Slack channel context")
	}
	if ttl == memory.PermanentTTL && !core.PredicateMayBePermanent(offer.Predicate) {
		return core.MemoryEntry{}, 0, offerreason.Field(
			"expires_in", offer.ExpiresIn,
			"expected 7d, 30d, 90d, or 365d, because predicate "+
				strconv.Quote(offer.Predicate)+" describes a system that can change "+
				"without telling Ryker; only a guidance predicate may be permanent",
		)
	}
	entry := core.MemoryEntry{
		ScopeKind: offer.Scope, SubjectKey: offer.Subject, Predicate: offer.Predicate,
		Value: offer.Value, SourceRevision: offer.SourceRevision,
		VisibilityKind: offer.Visibility, ExpiresAt: memory.ExpiryFrom(context.Now, ttl),
		SourceRef: context.InputID, ActorID: context.UserID,
	}
	if offer.Predicate == "guidance" {
		entry.SubjectKey = memory.NormalizeGuidanceSubject(entry.SubjectKey)
		entry.Value = strings.Join(strings.Fields(entry.Value), " ")
		entry.SourceRevision = ""
	}
	switch offer.Scope {
	case "workspace":
		entry.ScopeKey = context.TeamID
	case "channel":
		entry.ScopeKey = context.ChannelID
	case "repository":
		if !context.configured(offer.Repository) {
			return core.MemoryEntry{}, 0,
				UnknownRepository(offer.Repository, context.Repositories)
		}
		entry.ScopeKey = offer.Repository
	default:
		return core.MemoryEntry{}, 0, offerreason.Field(
			"scope", offer.Scope, "expected channel, repository, or workspace",
		)
	}
	switch offer.Visibility {
	case "workspace":
		entry.VisibilityID = context.TeamID
	case "channel":
		entry.VisibilityID = context.ChannelID
	case "operator":
		entry.VisibilityID = context.UserID
	default:
		return core.MemoryEntry{}, 0, offerreason.Field(
			"visibility", offer.Visibility,
			"expected channel, operator, or workspace",
		)
	}
	if err := ValidateEntryValue(&entry, context.Repositories); err != nil {
		return core.MemoryEntry{}, 0, err
	}
	if entry.SourceRevision != "" &&
		!memoryRevisionPattern.MatchString(entry.SourceRevision) {
		return core.MemoryEntry{}, 0, offerreason.Field(
			"source_revision", entry.SourceRevision,
			"expected an immutable Git revision or a sha256: digest, "+
				"or leave it empty",
		)
	}
	return entry, ttl, nil
}

// ValidateEntryValue checks what a memory entry's predicate requires of its
// subject and value, and normalizes the one subject the host derives itself.
//
// It is exported separately from Entry because two paths reach a memory entry
// without an offer in front of it: operator feedback promoted to guidance, and
// knowledge learned from repository contents.
func ValidateEntryValue(entry *core.MemoryEntry, catalog Catalog) error {
	// Named one at a time: "subject and value are required" sent the model back
	// to re-send both when only one of them was blank.
	if entry.SubjectKey == "" {
		return offerreason.Field("subject", "", "name what the memory is about")
	}
	if entry.Value == "" {
		return offerreason.Field("value", "", "state what is true about the subject")
	}
	if strings.ContainsAny(entry.SubjectKey+entry.Value, "\r\n\t") ||
		memory.ContainsSecretLikeValue(entry.SubjectKey) || memory.ContainsSecretLikeValue(entry.Value) {
		return errors.New("memory cannot contain multiline text or credential-like values")
	}
	switch entry.Predicate {
	case "alias_of":
		if !aliasMemorySubjectPattern.MatchString(entry.SubjectKey) ||
			!canonicalMemoryRefPattern.MatchString(entry.Value) {
			return errors.New(
				"alias_of requires a normalized alias and canonical repo:, channel:, emisar:, or service: reference",
			)
		}
	case "repository_for_channel":
		if entry.ScopeKind != "channel" {
			return errors.New("repository_for_channel requires channel scope")
		}
		if entry.VisibilityKind == "operator" {
			return errors.New(
				"repository_for_channel visibility must be channel or workspace",
			)
		}
		if catalog == nil || !catalog.Configured(entry.Value) {
			return UnknownRepository(entry.Value, catalog)
		}
		entry.SubjectKey = "channel:" + entry.ScopeKey
	case "evidence_route":
		if !canonicalMemoryRefPattern.MatchString(entry.SubjectKey) ||
			!canonicalMemoryRefPattern.MatchString(entry.Value) {
			return errors.New(
				"evidence_route requires canonical repo:, channel:, emisar:, or service: references",
			)
		}
	case "entity_relationship_correction":
		relation, target, ok := strings.Cut(entry.Value, "=")
		if !ok || !canonicalMemoryRefPattern.MatchString(entry.SubjectKey) ||
			!canonicalMemoryRefPattern.MatchString(target) {
			return errors.New(
				"entity_relationship_correction requires canonical subject and relation=canonical-target",
			)
		}
		switch relation {
		case "runtime_identity_of", "replacement_of", "member_of", "depends_on":
		default:
			return errors.New(
				"relationship must be runtime_identity_of, replacement_of, member_of, or depends_on",
			)
		}
	case "guidance":
		if !aliasMemorySubjectPattern.MatchString(entry.SubjectKey) {
			return errors.New(
				"guidance requires a short normalized topic such as communication_style",
			)
		}
		if len(entry.Value) > 1000 {
			return errors.New("guidance must be 1000 characters or fewer")
		}
	default:
		return errors.New(
			"predicate must be alias_of, repository_for_channel, evidence_route, entity_relationship_correction, or guidance",
		)
	}
	return nil
}

// MaxAge is how long a behaviour confirmation button stays clickable. One
// constant for all four buttons: a preference, a rule, a memory and a schedule
// offer all go stale for the same reason, and two constants meant one of them
// could drift.
const MaxAge = 24 * time.Hour

// maxPayloadBytes is Slack's limit on an action value, minus room for the
// characters it escapes. An offer that does not fit is not made at all — a
// button carrying a truncated payload is a button that fails when pressed.
const maxPayloadBytes = 1900

// Envelope is what every behaviour confirmation carries besides its offer: the
// version that says whether this host can read it at all, the conversation the
// offer belongs to, the input it came from, and when it was made.
//
// Embedded rather than repeated, so the five checks a press is measured against
// are read from one place. The JSON is unchanged: an anonymous struct's fields
// are promoted, so each payload still encodes version, channel_id, source_ref,
// issued_at and offer, in that order.
type Envelope struct {
	Version   int       `json:"version"`
	ChannelID string    `json:"channel_id"`
	SourceRef string    `json:"source_ref"`
	IssuedAt  time.Time `json:"issued_at"`
}

// Click describes this press for classification against offerreason's causes.
func (e Envelope) Click(decodeErr error, inputChannel string, now time.Time) offerreason.Click {
	return offerreason.Click{
		DecodeErr: decodeErr, Version: e.Version, PayloadChannel: e.ChannelID,
		InputChannel: inputChannel, SourceRef: e.SourceRef, IssuedAt: e.IssuedAt,
		Now: now, MaxAge: MaxAge,
	}
}

// Issue is the envelope a host stamps on an offer it is about to post.
type Issue struct {
	ChannelID string
	SourceRef string
	At        time.Time
}

func (i Issue) envelope() Envelope {
	return Envelope{
		Version: 1, ChannelID: i.ChannelID, SourceRef: i.SourceRef, IssuedAt: i.At,
	}
}

type PreferencePayload struct {
	Envelope
	Offer core.PreferenceOffer `json:"offer"`
}

type RulePayload struct {
	Envelope
	Offer core.RuleOffer `json:"offer"`
}

type MemoryPayload struct {
	Envelope
	Offer core.MemoryOffer `json:"offer"`
}

// The three Encode functions below mint a confirmation button's value. Each
// reports false rather than an error because the caller's only answer to either
// failure is the same one — do not offer it — and an offer that cannot be
// encoded is not a refusal the model can act on.

// EncodePreference mints the button a preference offer becomes.
func EncodePreference(issue Issue, offer core.PreferenceOffer) (string, bool) {
	return encode(PreferencePayload{Envelope: issue.envelope(), Offer: offer})
}

// EncodeRule mints the button a standing-rule offer becomes.
func EncodeRule(issue Issue, offer core.RuleOffer) (string, bool) {
	return encode(RulePayload{Envelope: issue.envelope(), Offer: offer})
}

// EncodeMemory mints the button a memory offer becomes.
func EncodeMemory(issue Issue, offer core.MemoryOffer) (string, bool) {
	return encode(MemoryPayload{Envelope: issue.envelope(), Offer: offer})
}

func encode(payload any) (string, bool) {
	encoded, err := json.Marshal(payload)
	if err != nil || len(encoded) > maxPayloadBytes {
		return "", false
	}
	return string(encoded), true
}

// The three Decode functions below read a press back. The decode error is
// returned rather than acted on: it is one of the five things offerreason.Click
// weighs, and a caller that dropped it here would report an unreadable button
// as some other cause.

// DecodePreference reads back the button a preference offer became.
func DecodePreference(value string) (PreferencePayload, error) {
	var payload PreferencePayload
	return payload, decision.DecodeStrictJSON([]byte(value), &payload)
}

// DecodeRule reads back the button a standing-rule offer became.
func DecodeRule(value string) (RulePayload, error) {
	var payload RulePayload
	return payload, decision.DecodeStrictJSON([]byte(value), &payload)
}

// DecodeMemory reads back the button a memory offer became.
func DecodeMemory(value string) (MemoryPayload, error) {
	var payload MemoryPayload
	return payload, decision.DecodeStrictJSON([]byte(value), &payload)
}
