package taskaccess

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/ryker/internal/agentprompt"
	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskprompt"
)

type Repository struct {
	Key         string `json:"key"`
	DisplayName string `json:"display_name"`
}

type CreationFailure struct {
	Outcome string
	Message string
}

var (
	// ErrContributorChannelUnconfigured means no operator has established the
	// channel's writable repository boundary. Callers must not replace it with
	// a deployment default: doing so grants a choice the member does not own.
	ErrContributorChannelUnconfigured = errors.New("channel contributor repository is not configured")
	// ErrContributorPolicyUnconfigured means the configured repository is not
	// enabled for member-authored work.
	ErrContributorPolicyUnconfigured = errors.New("channel contributor policy is not configured")
)

func ContributorBoundaryUnavailable(err error) bool {
	return errors.Is(err, ErrContributorChannelUnconfigured) ||
		errors.Is(err, ErrContributorPolicyUnconfigured)
}

func ContributorBoundaryMessage() string {
	return "This channel is not configured for contributor repository work. " +
		"Ask an operator to configure it. No writable task has started."
}

func MemberCreationFailure(err error) (CreationFailure, bool) {
	switch {
	case errors.Is(err, store.ErrMemberTaskCapacity):
		return CreationFailure{
			Outcome: "capacity",
			Message: "*Ryker did not start another engineering task.* You already have the configured " +
				"number of open tasks. Finish or ask an operator to close one, then try again.",
		}, true
	case errors.Is(err, store.ErrMemberTaskRateLimit):
		return CreationFailure{
			Outcome: "rate_limited",
			Message: "*Ryker did not start another engineering task yet.* Wait briefly before starting " +
				"another writable task. No session or working copy was created.",
		}, true
	default:
		return CreationFailure{}, false
	}
}

func ValidateSource(cfg config.Config, title, eventID, repository string) error {
	if title == "" {
		return errors.New("watched work item has no title")
	}
	if eventID == "" {
		return errors.New("watched work item source has no Slack event ID")
	}
	if _, ok := cfg.RepositoryContext(repository); !ok {
		return fmt.Errorf("watched work item names unknown repository %q", repository)
	}
	return nil
}

func UsesContributorAuthority(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
) (bool, error) {
	if !incident.IsEngineeringTask() {
		return false, nil
	}
	creator, err := st.EngineeringTaskCreator(ctx, incident.ID)
	if errors.Is(err, store.ErrNotFound) {
		// Missing provenance must never imply operator authority.
		return true, nil
	}
	if err != nil {
		return false, err
	}
	return !cfg.IsOperator(creator), nil
}

func InitialContributor(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	userID string,
) (bool, error) {
	if !incident.IsEngineeringTask() {
		return false, nil
	}
	if userID != "" {
		return !cfg.IsOperator(userID), nil
	}
	return UsesContributorAuthority(ctx, cfg, st, incident)
}

func SessionPolicy(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	repository config.Repository,
) (string, bool, error) {
	contributor, err := UsesContributorAuthority(ctx, cfg, st, incident)
	if err != nil {
		return "", false, err
	}
	if incident.IsEngineeringTask() {
		return strings.TrimSpace(repository.ContributorPolicy), contributor, nil
	}
	return repository.CoopPolicy, false, nil
}

func Prompt(cfg config.Config, userID, message string) string {
	if !cfg.IsOperator(userID) {
		return taskprompt.Member(userID, message)
	}
	return agentprompt.Operator(userID, message)
}

func MemberRepository(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	channelID string,
) (string, error) {
	configuration, err := st.GetChannelConfiguration(ctx, channelID)
	if errors.Is(err, store.ErrNotFound) {
		return "", ErrContributorChannelUnconfigured
	}
	if err != nil {
		return "", err
	}
	repository, ok := cfg.RepositoryContext(configuration.Repository)
	if !ok || strings.TrimSpace(repository.ContributorPolicy) == "" {
		return "", fmt.Errorf("%w: channel repository %q has no contributor policy",
			ErrContributorPolicyUnconfigured, configuration.Repository)
	}
	return configuration.Repository, nil
}

func ResolveOfferRepository(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	input core.SlackInput,
	requested string,
) (string, error) {
	requested = strings.TrimSpace(requested)
	if input.Kind == "bot_message" {
		return alertOfferRepository(ctx, cfg, st, input, requested)
	}
	if !cfg.IsOperator(input.UserID) {
		authorized, err := MemberRepository(ctx, cfg, st, input.ChannelID)
		if err != nil {
			return "", err
		}
		switch {
		case requested == "":
			requested = authorized
		case !cfg.RepositoryWithinContext(authorized, requested):
			return "", fmt.Errorf("task repository %q is not authorized for this channel", requested)
		}
		// requested is kept as it stands when it is inside the channel's
		// context: a set resolves to its primary, and the task belongs in the
		// repository the investigation named, not in the name of the set that
		// contains it.
	}
	if requested != "" {
		repository, ok := cfg.RepositoryContext(requested)
		if !ok {
			return "", fmt.Errorf("unknown task repository %q", requested)
		}
		if !cfg.IsOperator(input.UserID) && strings.TrimSpace(repository.ContributorPolicy) == "" {
			return "", fmt.Errorf("repository %q has no contributor policy", requested)
		}
		return requested, nil
	}
	keys := cfg.RepositoryContextKeys()
	if len(keys) == 1 {
		return keys[0], nil
	}
	return "", errors.New("task repository is ambiguous")
}

// alertOfferRepository picks the repository for work offered on an app's
// message, without gating on the app.
//
// The author of an alert is Grafana, which holds no authority of its own to
// check and no ability to answer a question. Whoever clicks the offer is the
// one who is authorized, at click time, by handleWatchTaskOfferAction — an
// operator for anything, a workspace member only within this channel's
// contributor boundary — so the offer side resolves rather than refuses, and
// does not require a contributor policy the clicker may not need.
//
// On 2026-08-16 the member gate ran against the Grafana bot instead: every
// alert investigation of the day was refused the repository it had correctly
// named and asked the bot to choose from a list of one, so no engineering task
// was ever offered.
func alertOfferRepository(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	input core.SlackInput,
	requested string,
) (string, error) {
	if requested != "" {
		if _, ok := cfg.RepositoryContext(requested); ok {
			return requested, nil
		}
	}
	configuration, err := st.GetChannelConfiguration(ctx, input.ChannelID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return "", err
	}
	if err == nil {
		if _, ok := cfg.RepositoryContext(configuration.Repository); ok {
			return configuration.Repository, nil
		}
	}
	if _, ok := cfg.RepositoryContext(cfg.Slack.DefaultRepository); ok {
		return cfg.Slack.DefaultRepository, nil
	}
	if keys := cfg.RepositoryContextKeys(); len(keys) == 1 {
		return keys[0], nil
	}
	return "", errors.New("task repository is ambiguous")
}

func ValidateMemberStart(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	channelID, offeredRepository string,
) error {
	authorized, err := MemberRepository(ctx, cfg, st, channelID)
	if err != nil {
		return err
	}
	if !cfg.RepositoryWithinContext(authorized, offeredRepository) {
		return errors.New("task repository is outside the channel contributor boundary")
	}
	return nil
}

// SingleChoice names the only repository an offer could mean, when the
// configuration leaves exactly one.
//
// A question with one answer is not a question. On 2026-08-16 Ryker asked
// five times, of a Grafana bot, which repository to use out of a list holding
// only `blitz-platform`; every one of those replies could have carried a task
// button instead.
func SingleChoice(cfg config.Config, operator bool, active string) (string, bool) {
	repositories := Repositories(cfg, operator, active)
	if len(repositories) != 1 {
		return "", false
	}
	return repositories[0].Key, true
}

func Repositories(cfg config.Config, operator bool, active string) []Repository {
	names := cfg.RepositoryContextKeys()
	if !operator {
		names = []string{active}
	}
	repositories := make([]Repository, 0, len(names))
	for _, name := range names {
		repository, ok := cfg.RepositoryContext(name)
		if !ok || !operator && strings.TrimSpace(repository.ContributorPolicy) == "" {
			continue
		}
		displayName := strings.TrimSpace(repository.DisplayName)
		if displayName == "" {
			displayName = name
		}
		repositories = append(repositories, Repository{Key: name, DisplayName: displayName})
	}
	return repositories
}

func Label(cfg config.Config, name string) string {
	repository, ok := cfg.RepositoryContext(name)
	if !ok {
		return "`" + name + "`"
	}
	displayName := strings.TrimSpace(repository.DisplayName)
	if displayName == "" || displayName == name {
		return "`" + name + "`"
	}
	return displayName + " (`" + name + "`)"
}

func Choices(cfg config.Config, operator bool, active string) []string {
	repositories := Repositories(cfg, operator, active)
	choices := make([]string, 0, len(repositories))
	for _, repository := range repositories {
		choices = append(choices, Label(cfg, repository.Key))
	}
	return choices
}

func RepositoryQuestion(message string, choices []string) string {
	message = strings.TrimSpace(message)
	if message != "" {
		message += "\n\n"
	}
	return message + "Which configured repository should I use for this engineering task: " +
		strings.Join(choices, ", ") + "? No writable task has been started."
}

func Create(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	repository, sourceID, title, summary, userID, channelID, threadTS string,
	targets ...core.PullRequestTarget,
) (core.Incident, bool, error) {
	configured, ok := cfg.RepositoryContext(repository)
	if !ok {
		return core.Incident{}, false, fmt.Errorf("unknown task repository %q", repository)
	}
	if cfg.IsOperator(userID) {
		return st.CreateEngineeringTask(
			ctx, repository, sourceID, title, summary, userID, channelID, threadTS,
			cfg.Limits.MaxOpenIncidents, targets...,
		)
	}
	if strings.TrimSpace(configured.ContributorPolicy) == "" {
		return core.Incident{}, false, fmt.Errorf("repository %q has no contributor policy", repository)
	}
	return st.CreateMemberEngineeringTask(
		ctx, repository, sourceID, title, summary, userID, channelID, threadTS,
		cfg.Limits.MaxOpenIncidents-cfg.Limits.ReservedOperatorOpenSlots,
		cfg.Limits.MaxOpenEngineeringTasksPerMember,
		cfg.Limits.EngineeringTaskCreationCooldown.Duration,
		targets...,
	)
}

// MemberControlAllowed says which controls a workspace member who is not a
// configured operator may run on a contributor task.
//
// It used to gate a second caller: an unadvertised `!respond <verb>` router
// that read every message in a task thread. That router is gone — a message in
// a thread is a conversation, and a control is a button on the card above it —
// so this now answers only for clicks.
func MemberControlAllowed(control string) bool {
	switch slackui.BaseActionID(control) {
	case "status", slackui.ActionHelp, slackui.ActionUpdate,
		slackui.ActionChanges, slackui.ActionChangesPrevious,
		slackui.ActionChangesNext, slackui.ActionChangesRefresh,
		// Putting a diff away changes nothing about the work. Whoever was
		// allowed to open it is allowed to close it, or the room fills with
		// diffs only an operator can clear.
		slackui.ActionCloseDiff,
		slackui.ActionReview, slackui.ActionRepairReview,
		slackui.ActionViewPR, slackui.ActionCheckDelivery,
		slackui.ActionFullRequest, slackui.ActionTurnReceipt, slackui.ActionExtend:
		return true
	default:
		return false
	}
}

func PublicationRefusal(
	cfg config.Config,
	incident core.Incident,
	userID string,
	trustedControlPlane bool,
) string {
	if !incident.IsEngineeringTask() {
		return "*Draft PR publication is available for engineering tasks only.* " +
			"Incident investigations remain read-only unless an operator starts an explicit writable task."
	}
	if !trustedControlPlane && !cfg.IsOperator(userID) {
		return "*A configured operator must publish this draft pull request.* The contributor task, " +
			"review state, and isolated working copy were left unchanged."
	}
	return ""
}
