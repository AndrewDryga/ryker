package standingrule

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestMatchExplainsSourceEventAndStateDecisions(t *testing.T) {
	rule := terraformRule("terraform-plans", []string{"planned"})

	tests := []struct {
		name    string
		input   core.SlackInput
		matched bool
		why     string
	}{
		{
			name:    "planned app update matches",
			input:   core.SlackInput{Kind: "bot_message", Text: "Run Planned - Needs Confirmation"},
			matched: true,
			why:     "that is planned",
		},
		{
			name:  "later lifecycle state is skipped",
			input: core.SlackInput{Kind: "bot_message", Text: "Run Applying"},
			why:   "only handles planned; this update is applying",
		},
		{
			name:  "human message is skipped",
			input: core.SlackInput{Kind: "message", Text: "Can you review this Terraform plan?"},
			why:   "watches app messages",
		},
		{
			name:  "unrelated app update is skipped",
			input: core.SlackInput{Kind: "bot_message", Text: "Deployment completed"},
			why:   "watches Terraform run updates",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			matched, why := Match(rule, test.input)
			if matched != test.matched {
				t.Fatalf("matched = %t, want %t (%s)", matched, test.matched, why)
			}
			if !strings.Contains(why, test.why) {
				t.Fatalf("reason %q does not contain %q", why, test.why)
			}
		})
	}
}

func TestEvaluateAccountsForEveryActiveRule(t *testing.T) {
	terraform := terraformRule("terraform-plans", []string{"planned"})
	alertWorkflow, err := core.LegacyStandingWorkflow("operational_alert", "triage_alert")
	if err != nil {
		t.Fatal(err)
	}
	alert := core.StandingRule{
		ID: "alerts", WorkflowName: alertWorkflow.Name, Workflow: alertWorkflow,
		Trigger: "operational_alert", Action: "triage_alert", SourceKind: "app",
	}
	input := core.SlackInput{
		ID: "message-1", Kind: "bot_message", Text: "Run Planned - Needs Confirmation",
	}

	audit := Evaluate(
		[]core.StandingRule{terraform, alert},
		[]core.StandingRule{terraform},
		input,
		core.SlackInput{},
	)
	if audit.Checked != 2 || audit.Matched != 1 || len(audit.Rules) != 2 {
		t.Fatalf("audit = %+v", audit)
	}
	if !audit.Rules[0].Matched || audit.Rules[0].Why == "" ||
		audit.Rules[0].Work == "" || audit.Rules[0].Delivery == "" {
		t.Fatalf("matched rule lacks an explanation: %+v", audit.Rules[0])
	}
	if audit.Rules[1].Matched || !strings.Contains(audit.Rules[1].Why, "operational alerts") {
		t.Fatalf("skipped rule lacks the event mismatch: %+v", audit.Rules[1])
	}
}

func TestNormalizeTerraformLifecycleOfferCompilesWorkflow(t *testing.T) {
	offer, matched := NormalizeTerraformLifecycleOffer(
		core.SlackInput{
			Kind: "mention",
			Text: "Watch Terraform run notifications in this channel and review them.",
		},
		"emisar",
		nil,
	)
	if !matched || offer == nil || offer.Workflow == nil {
		t.Fatalf("offer = %+v, matched = %t", offer, matched)
	}
	if offer.Workflow.Trigger.Event != "terraform_run" ||
		len(offer.Workflow.Steps) < 2 || offer.Workflow.Delivery.Location != "source_thread" {
		t.Fatalf("compiled workflow = %+v", offer.Workflow)
	}
}

func terraformRule(id string, states []string) core.StandingRule {
	workflow, err := core.LegacyStandingWorkflow("terraform_plan", "review_terraform_plan")
	if err != nil {
		panic(err)
	}
	workflow.Trigger.States = states
	return core.StandingRule{
		ID: id, WorkflowName: workflow.Name, Workflow: workflow,
		Trigger: "terraform_plan", Action: "review_terraform_plan", SourceKind: "app",
	}
}
