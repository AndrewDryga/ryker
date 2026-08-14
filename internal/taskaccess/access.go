package taskaccess

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/agentprompt"
	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskprompt"
)

type Repository struct {
	Key         string `json:"key"`
	DisplayName string `json:"display_name"`
}

type CreationFailure struct {
	Outcome string
	Message string
}

func MemberCreationFailure(err error) (CreationFailure, bool) {
	switch {
	case errors.Is(err, store.ErrMemberTaskCapacity):
		return CreationFailure{
			Outcome: "capacity",
			Message: "*Responder did not start another engineering task.* You already have the configured " +
				"number of open tasks. Finish or ask an operator to close one, then try again.",
		}, true
	case errors.Is(err, store.ErrMemberTaskRateLimit):
		return CreationFailure{
			Outcome: "rate_limited",
			Message: "*Responder did not start another engineering task yet.* Wait briefly before starting " +
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
	if contributor {
		return strings.TrimSpace(repository.ContributorPolicy), true, nil
	}
	return repository.CoopPolicy, false, nil
}

func CanSteer(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	userID string,
) (bool, bool, error) {
	contributor, err := UsesContributorAuthority(ctx, cfg, st, incident)
	return contributor, contributor || cfg.IsOperator(userID), err
}

func Prompt(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	incident core.Incident,
	userID, message string,
) (string, error) {
	contributor, err := UsesContributorAuthority(ctx, cfg, st, incident)
	if err != nil {
		return "", err
	}
	if contributor {
		return taskprompt.Member(userID, message), nil
	}
	return agentprompt.Operator(userID, message), nil
}

func MemberRepository(
	ctx context.Context,
	cfg config.Config,
	st *store.Store,
	channelID string,
) (string, error) {
	configuration, err := st.GetChannelConfiguration(ctx, channelID)
	if errors.Is(err, store.ErrNotFound) {
		return "", errors.New("channel has no configured contributor repository")
	}
	if err != nil {
		return "", err
	}
	repository, ok := cfg.RepositoryContext(configuration.Repository)
	if !ok || strings.TrimSpace(repository.ContributorPolicy) == "" {
		return "", fmt.Errorf(
			"channel repository %q has no contributor policy",
			configuration.Repository,
		)
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
	if !cfg.IsOperator(input.UserID) {
		authorized, err := MemberRepository(ctx, cfg, st, input.ChannelID)
		if err != nil {
			return "", err
		}
		if requested != "" && requested != authorized {
			return "", fmt.Errorf("task repository %q is not authorized for this channel", requested)
		}
		requested = authorized
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
	if offeredRepository != authorized {
		return errors.New("task repository is outside the channel contributor boundary")
	}
	return nil
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

func Command(text string) (string, bool) {
	switch strings.TrimSpace(strings.ToLower(text)) {
	case "!respond status":
		return "status", true
	case "!respond update":
		return slackui.ActionUpdate, true
	case "!respond changes":
		return slackui.ActionChanges, true
	case "!respond review":
		return slackui.ActionReview, true
	case "!respond publish":
		return slackui.ActionPublishPR, true
	case "!respond stop":
		return slackui.ActionStop, true
	case "!respond extend":
		return slackui.ActionExtend, true
	case "!respond close":
		return slackui.ActionResolve, true
	case "!respond help":
		return slackui.ActionHelp, true
	default:
		return "", false
	}
}

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
