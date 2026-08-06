package slackui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// RepositoryChoice describes a human-facing code-context option. A set is a
// read context spanning a primary repository and policy-owned companions; it
// is not itself a Git repository.
type RepositoryChoice struct {
	Key                string
	DisplayName        string
	PrimaryDisplayName string
	Set                bool
	Default            bool
}

func ChannelSetupQuestion(
	channelName string,
	session core.ConfigurationSession,
	repositories []RepositoryChoice,
) Message {
	channel := "this channel"
	if channelName != "" {
		channel = "#" + channelName
	}
	intro := ""
	question := ""
	var actions []Action
	switch session.Step {
	case "participation":
		if session.Initiator == "" && session.Draft.ActorID == "" {
			question = "**How should I work in " + channel + "?**\n\n" +
				"I can start immediately with conservative defaults: answer direct requests, " +
				"use `" + session.Draft.Repository + "` for code context, keep app-alert " +
				"triage in place, and invite no additional people to incident rooms.\n\n" +
				"Choose **Be proactive** if I should also follow the channel and contribute when " +
				"an SRE teammate reasonably would. Nothing is saved until a configured operator " +
				"chooses an option."
			return Message{
				Text:     "Configure Emisar for " + channel,
				Header:   "Emisar joined " + channel,
				Markdown: question,
				Actions: []Action{
					{
						ID: ActionSetupQuickMentions, Label: "Use safe defaults",
						Value: session.ID, Style: "primary",
					},
					{
						ID: ActionSetupQuickProactive, Label: "Be proactive",
						Value: session.ID,
					},
					{
						ID: ActionSetupCustomize, Label: "Customize",
						Value: session.ID,
					},
				},
			}
		}
		intro = "I can configure how Emisar participates in " + channel + ". " +
			"Use a button or reply naturally. I’ll continue wherever you answer: in the channel " +
			"or in a thread. Only configured operators can answer. Nothing is saved until you " +
			"review and confirm it.\n\n"
		question = "**1 of 4 - When should I participate?**\n\n" +
			"- **Mentions only:** answer direct mentions and explicit requests.\n" +
			"- **Proactive:** read channel context and reply when an SRE teammate reasonably would.\n" +
			"- **Shadow:** evaluate messages and retain audit evidence without posting."
		actions = []Action{
			setupChoiceAction(ActionSetupMentions, "Mentions only", session.ID,
				session.Draft.Participation == "mentions"),
			setupChoiceAction(ActionSetupProactive, "Proactive", session.ID,
				session.Draft.Participation == "proactive"),
			setupChoiceAction(ActionSetupShadow, "Shadow", session.ID,
				session.Draft.Participation == "shadow"),
		}
	case "repository":
		question = "**2 of 4 - What code should I use for this channel?**\n\n" +
			"A **multi-repository context** lets Emisar read its primary repository and the " +
			"configured read-only companion repositories. A **single repository** limits the " +
			"channel's default code context to that repository.\n\n" +
			"This choice does not grant write access. If code needs to change, Emisar will name " +
			"the exact repository and ask you to confirm that engineering task."
		orderedRepositories := append([]RepositoryChoice(nil), repositories...)
		sort.SliceStable(orderedRepositories, func(i, j int) bool {
			if orderedRepositories[i].Set != orderedRepositories[j].Set {
				return orderedRepositories[i].Set
			}
			return orderedRepositories[i].DisplayName < orderedRepositories[j].DisplayName
		})
		for _, repository := range orderedRepositories {
			label := repositoryChoiceLabel(repository)
			actions = append(actions, setupChoiceAction(
				ActionSetupRepository+repository.Key, label, session.ID,
				session.Draft.Repository == repository.Key,
			))
		}
	case "alerts":
		question = "**3 of 4 - What should happen when an app posts a credible unresolved alert?**\n\n" +
			"Human questions never create incidents automatically. Automatic creation applies only " +
			"to authenticated Slack app alerts that the evidence check classifies as unresolved."
		actions = []Action{
			setupChoiceAction(ActionSetupAlertReply, "Reply here", session.ID,
				session.Draft.AlertPolicy == "reply"),
			setupChoiceAction(ActionSetupAlertOffer, "Offer incident", session.ID,
				session.Draft.AlertPolicy == "offer"),
			setupChoiceAction(ActionSetupAlertAutomatic, "Automatic incident", session.ID,
				session.Draft.AlertPolicy == "automatic"),
		}
	case "audience":
		question = "**4 of 4 - Who else should join incident rooms from this channel?**\n\n" +
			"Configured operators are always invited.\n\n" +
			"Choose **No additional invitees**, or reply with Slack member and user-group " +
			"mentions to invite them too. Emisar validates every member and expands user groups " +
			"before saving."
		actions = []Action{
			setupChoiceAction(ActionSetupOperatorsOnly, "No additional invitees", session.ID,
				len(session.Draft.InviteUsers) == 0 &&
					len(session.Draft.InviteUserGroups) == 0),
		}
	default:
		question = "Reply with the next setup choice."
	}
	markdown := question
	if intro != "" {
		markdown = intro + question
	}
	return Message{
		Text:     "Configure Emisar for " + channel,
		Header:   "Configure Emisar for " + channel,
		Markdown: markdown,
		Actions:  actions,
	}
}

func setupChoiceAction(id, label, sessionID string, selected bool) Action {
	action := Action{ID: id, Label: label, Value: sessionID}
	if selected {
		action.Style = "primary"
	}
	return action
}

func ChannelSetupConfirmation(
	channelName string,
	session core.ConfigurationSession,
	repository RepositoryChoice,
) Message {
	channel := "this channel"
	if channelName != "" {
		channel = "#" + channelName
	}
	users := "Configured operators only"
	if len(session.Draft.InviteUsers) > 0 {
		items := make([]string, 0, len(session.Draft.InviteUsers))
		for _, user := range session.Draft.InviteUsers {
			items = append(items, "<@"+user+">")
		}
		users += " plus " + strings.Join(items, ", ")
	}
	if len(session.Draft.InviteUserGroups) > 0 {
		items := make([]string, 0, len(session.Draft.InviteUserGroups))
		for _, group := range session.Draft.InviteUserGroups {
			items = append(items, "<!subteam^"+group+">")
		}
		users += " and " + strings.Join(items, ", ")
	}
	return Message{
		Text:   "Review Emisar configuration for " + channel,
		Header: "Review channel behavior",
		Markdown: "Nothing is saved yet. Confirm the typed settings below, or start over.\n\n" +
			"**Safety boundary:** this config controls listening, repository context, alert " +
			"escalation, and invitations. It does not authorize repository edits, approvals, " +
			"deployments, or infrastructure changes.",
		Fields: []Field{
			{Label: "Participation", Value: setupParticipationLabel(session.Draft.Participation)},
			{Label: "Code context", Value: repositoryChoiceSummary(repository)},
			{Label: "Repository access", Value: repositoryAccessSummary(repository)},
			{Label: "App alerts", Value: setupAlertLabel(session.Draft.AlertPolicy)},
			{Label: "Incident audience", Value: users},
		},
		Context: []string{
			fmt.Sprintf("Setup expires at %s.", session.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC")),
		},
		Actions: []Action{
			{ID: ActionSaveChannelConfig, Label: "Save configuration", Value: session.ID, Style: "primary"},
			{ID: ActionRestartChannelSetup, Label: "Start over", Value: session.ID},
			{
				ID: ActionCancelChannelSetup, Label: "Cancel", Value: session.ID, Style: "danger",
				Confirm: "Cancel this setup? No channel settings will be changed.",
			},
		},
	}
}

func ChannelSetupSaved(
	channelName string,
	configuration core.ChannelConfiguration,
	repository RepositoryChoice,
) Message {
	channel := "this channel"
	if channelName != "" {
		channel = "#" + channelName
	}
	audience := "Configured operators only"
	if count := len(configuration.InviteUsers); count > 0 {
		audience += fmt.Sprintf(" plus %d selected member(s)", count)
	}
	if count := len(configuration.InviteUserGroups); count > 0 {
		audience += fmt.Sprintf(" and %d Slack user group(s)", count)
	}
	return Message{
		Text:   "Emisar configuration saved for " + channel,
		Header: "Channel behavior saved",
		Markdown: "Emisar is now configured for " + channel + ".\n\n" +
			"- **Participation:** " + setupParticipationLabel(configuration.Participation) + "\n" +
			"- **Code context:** " + repositoryChoiceSummary(repository) + "\n" +
			"- **Repository access:** " + repositoryAccessSummary(repository) + "\n" +
			"- **App alerts:** " + setupAlertLabel(configuration.AlertPolicy) + "\n" +
			"- **Incident audience:** " + audience + "\n\n" +
			"Ask `@Emisar how are you configured here?` at any time. A configured operator can " +
			"say `@Emisar reconfigure this channel` to run this setup again.",
	}
}

func repositoryChoiceLabel(repository RepositoryChoice) string {
	label := strings.TrimSpace(repository.DisplayName)
	if label == "" {
		label = repository.Key
	}
	if repository.Set {
		label += " (multi-repo)"
	}
	return label
}

func repositoryChoiceSummary(repository RepositoryChoice) string {
	label := repositoryChoiceLabel(repository)
	if repository.Key == "" {
		return "`unknown`"
	}
	return label + " (`" + repository.Key + "`)"
}

func repositoryAccessSummary(repository RepositoryChoice) string {
	if !repository.Set {
		return "This repository only; any code change still requires a confirmed engineering task."
	}
	primary := strings.TrimSpace(repository.PrimaryDisplayName)
	if primary == "" {
		primary = "the primary repository"
	}
	return "Read " + primary + " plus its configured read-only companions. " +
		"An engineering task can edit only the exact repository named on its confirmation card."
}

func ChannelSetupCancelled() Message {
	return Message{
		Text:     "Emisar channel setup cancelled",
		Header:   "Channel setup cancelled",
		Markdown: "No channel settings were changed. Emisar will keep using the previous configuration and deployment defaults.",
	}
}

func setupParticipationLabel(value string) string {
	switch value {
	case "proactive":
		return "Proactive participation"
	case "shadow":
		return "Shadow evaluation"
	default:
		return "Mentions only"
	}
}

func setupAlertLabel(value string) string {
	switch value {
	case "automatic":
		return "Automatically create an incident for credible unresolved app alerts"
	case "offer":
		return "Reply and offer an incident"
	default:
		return "Reply in place without offering an incident"
	}
}
