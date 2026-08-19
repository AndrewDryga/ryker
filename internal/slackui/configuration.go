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
				"an SRE teammate reasonably would. A configured operator must confirm these settings."
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
			"or in a thread. A configured operator must review and confirm the result.\n\n"
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
			"Repository edits require a confirmed engineering task for the exact repository."
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
			"Automatic creation applies to authenticated app alerts verified as unresolved."
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
		Markdown: "Confirm these settings or start over.\n\n" +
			"This configuration controls participation, repository context, alert escalation, and invitations.",
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
			"Ask `@Emisar` about this channel at any time. A configured operator can " +
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
		return "Read this repository; edits require a confirmed engineering task."
	}
	primary := strings.TrimSpace(repository.PrimaryDisplayName)
	if primary == "" {
		primary = "the primary repository"
	}
	return "Read " + primary + " and its companion repositories; edits require a confirmed engineering task."
}

// ChannelSetupMoved replaces the card an operator left behind when they asked to
// continue somewhere else.
//
// Slack cannot move a message between a channel and a thread, so following the
// operator means a second card exists. This is what becomes of the first one: no
// buttons, and a sentence saying where the setup went. Leaving the question
// standing would give one session two live cards, which is how an operator ends
// up answering question three on the card still showing question two.
func ChannelSetupMoved(intoThread bool) Message {
	place := "in the channel"
	if intoThread {
		place = "in a thread"
	}
	return Message{
		Text:      "Emisar channel setup continues " + place,
		Header:    "Channel setup moved",
		Markdown:  "The rest of this setup continues " + place + ".",
		Temporary: true,
	}
}

func ChannelSetupCancelled() Message {
	return Message{
		Text:      "Emisar channel setup cancelled",
		Header:    "Channel setup cancelled",
		Markdown:  "No channel settings were changed. Emisar will keep using the previous configuration and deployment defaults.",
		Temporary: true,
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
