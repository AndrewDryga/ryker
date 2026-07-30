package slackui

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestChannelSetupQuestionOffersTypedChoices(t *testing.T) {
	session := core.ConfigurationSession{
		ID:        "cfg_123",
		Step:      "participation",
		Initiator: "UOPERATOR",
		Draft: core.ChannelConfiguration{
			Participation: "proactive",
		},
	}
	message := ChannelSetupQuestion("infra", session, []string{"emisar", "portal"})
	if len(message.Actions) != 3 {
		t.Fatalf("participation actions = %+v", message.Actions)
	}
	if message.Actions[0].ID != ActionSetupMentions ||
		message.Actions[1].ID != ActionSetupProactive ||
		message.Actions[1].Style != "primary" ||
		message.Actions[2].ID != ActionSetupShadow {
		t.Fatalf("participation actions = %+v", message.Actions)
	}
	for _, action := range message.Actions {
		if action.Value != session.ID {
			t.Fatalf("action does not carry session ID: %+v", action)
		}
	}

	session.Step = "repository"
	message = ChannelSetupQuestion("infra", session, []string{"emisar", "portal"})
	if len(message.Actions) != 3 ||
		message.Actions[0].ID != ActionSetupDefaultRepo ||
		message.Actions[1].ID != ActionSetupRepository+"emisar" ||
		message.Actions[2].ID != ActionSetupRepository+"portal" {
		t.Fatalf("repository actions = %+v", message.Actions)
	}

	session.Step = "alerts"
	message = ChannelSetupQuestion("infra", session, nil)
	if len(message.Actions) != 3 ||
		message.Actions[0].ID != ActionSetupAlertReply ||
		message.Actions[1].ID != ActionSetupAlertOffer ||
		message.Actions[2].ID != ActionSetupAlertAutomatic {
		t.Fatalf("alert actions = %+v", message.Actions)
	}

	session.Step = "audience"
	message = ChannelSetupQuestion("infra", session, nil)
	if len(message.Actions) != 1 ||
		message.Actions[0].ID != ActionSetupOperatorsOnly ||
		message.Actions[0].Label != "No additional invitees" {
		t.Fatalf("audience actions = %+v", message.Actions)
	}
}

func TestChannelJoinSetupOffersImmediateDefaultsOrCustomization(t *testing.T) {
	session := core.ConfigurationSession{
		ID:   "cfg_join",
		Step: "participation",
		Draft: core.ChannelConfiguration{
			Participation: "mentions",
			Repository:    "emisar",
			AlertPolicy:   "reply",
		},
	}
	message := ChannelSetupQuestion("infra", session, []string{"emisar"})
	if len(message.Actions) != 3 ||
		message.Actions[0].ID != ActionSetupQuickMentions ||
		message.Actions[1].ID != ActionSetupQuickProactive ||
		message.Actions[2].ID != ActionSetupCustomize {
		t.Fatalf("quick onboarding actions = %+v", message.Actions)
	}
	if message.Actions[0].Style != "primary" {
		t.Fatalf("safe defaults must be primary: %+v", message.Actions[0])
	}
}

func TestChannelSetupChoiceButtonsRenderAcrossActionBlocks(t *testing.T) {
	message := ChannelSetupQuestion("infra", core.ConfigurationSession{
		ID:   "cfg_123",
		Step: "repository",
	}, []string{"a", "b", "c", "d", "e"})
	blocks := message.Blocks()
	actionBlocks := 0
	for _, block := range blocks {
		if block.BlockType() == "actions" {
			actionBlocks++
		}
	}
	if actionBlocks != 2 {
		t.Fatalf("action blocks = %d, want 2; blocks = %+v", actionBlocks, blocks)
	}
}
