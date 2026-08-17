package core

import (
	"strings"
	"testing"
)

func TestStandingWorkflowNormalizesAndExplainsComposableBehavior(t *testing.T) {
	workflow, trigger, action, err := NormalizeStandingWorkflow(
		StandingWorkflow{
			Name: "Review and follow Terraform changes",
			Trigger: StandingWorkflowTrigger{
				Event:  "terraform_run",
				States: []string{"planned", "applied", "errored"},
			},
			Steps: []string{
				"review_terraform_plan", "follow_terraform_run",
				"verify_post_apply_health", "diagnose_terraform_failure",
			},
			Delivery: StandingWorkflowDelivery{
				Location:            "source_thread",
				ReplyWhen:           []string{"approval_ready", "terminal_success", "terminal_failure"},
				MentionOperatorWhen: []string{"failure"},
				QuietWhen:           []string{"intermediate", "duplicate"},
				Acknowledge:         ":eyes:",
			},
		},
		"",
		"",
	)
	if err != nil {
		t.Fatal(err)
	}
	if trigger != "terraform_lifecycle" || action != "monitor_terraform_lifecycle" {
		t.Fatalf("legacy identity = %s/%s", trigger, action)
	}
	if workflow.Version != StandingWorkflowVersion || workflow.Delivery.Acknowledge != "eyes" {
		t.Fatalf("normalized workflow = %+v", workflow)
	}

	triggerEffect := StandingWorkflowTriggerEffect(workflow, "app")
	work := strings.ToLower(StandingWorkflowWork(workflow))
	delivery := strings.ToLower(StandingWorkflowDeliveryEffect(workflow))
	for _, want := range []string{
		"App messages about Terraform runs",
		"planned, applied, and errored",
	} {
		if !strings.Contains(triggerEffect, want) {
			t.Errorf("trigger explanation %q does not contain %q", triggerEffect, want)
		}
	}
	for _, want := range []string{
		"reviews the saved plan", "follows the run", "checks the affected systems", "investigates failed applies",
	} {
		if !strings.Contains(work, want) {
			t.Errorf("work explanation %q does not contain %q", work, want)
		}
	}
	for _, want := range []string{
		"adds 👀", "source message's thread", "stays quiet", "tags the rule owner",
	} {
		if !strings.Contains(delivery, want) {
			t.Errorf("delivery explanation %q does not contain %q", delivery, want)
		}
	}
}

func TestStandingWorkflowRejectsStepFromAnotherEvent(t *testing.T) {
	_, _, _, err := NormalizeStandingWorkflow(
		StandingWorkflow{
			Name:     "Unsafe mixed workflow",
			Trigger:  StandingWorkflowTrigger{Event: "deployment"},
			Steps:    []string{"triage_alert"},
			Delivery: StandingWorkflowDelivery{Location: "source_thread"},
		},
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "no supported primary action") {
		t.Fatalf("mixed workflow error = %v", err)
	}
}

func TestStandingWorkflowCanDisableAcknowledgement(t *testing.T) {
	workflow, _, _, err := NormalizeStandingWorkflow(
		StandingWorkflow{
			Name:    "Quiet deployment checks",
			Trigger: StandingWorkflowTrigger{Event: "deployment"},
			Steps:   []string{"verify_deployment"},
			Delivery: StandingWorkflowDelivery{
				Location: "source_thread", Acknowledge: "none",
			},
		},
		"",
		"",
	)
	if err != nil {
		t.Fatal(err)
	}
	if workflow.Delivery.Acknowledge != "none" {
		t.Fatalf("acknowledgement = %q", workflow.Delivery.Acknowledge)
	}
	if delivery := StandingWorkflowDeliveryEffect(workflow); strings.Contains(delivery, "adds") {
		t.Fatalf("disabled acknowledgement leaked into delivery explanation: %q", delivery)
	}
}

// StandingRulePairs is advertised to the model as the pairs that work, so a
// pair it lists that does not compile is worse than not listing it at all: the
// refusal that names them exists to stop the model guessing, and a wrong list
// makes it guess from a menu instead. The two live in one file for this reason;
// this is what stops them drifting apart in it.
func TestEveryAdvertisedStandingRulePairCompiles(t *testing.T) {
	pairs := StandingRulePairs()
	if len(pairs) == 0 {
		t.Fatal("no standing rule pairs are advertised")
	}
	for _, pair := range pairs {
		trigger, action, found := strings.Cut(pair, "/")
		if !found {
			t.Errorf("advertised pair %q is not trigger/action", pair)
			continue
		}
		if _, err := LegacyStandingWorkflow(trigger, action); err != nil {
			t.Errorf("advertised pair %q does not compile: %v", pair, err)
		}
	}
}
