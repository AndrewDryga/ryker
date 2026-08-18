package lifecycle

import "testing"

func TestTerraformCorrelationPrefersExactRunIDOverWorkspaceLink(t *testing.T) {
	text := "Run notification for <https://app.terraform.io/app/acme/workspaces/infra|acme/infra>\n" +
		"Run run-Q9nWxoGwkdkKQdu6\n" +
		"<https://app.terraform.io/app/acme/workspaces/infra/runs/run-Q9nWxoGwkdkKQdu6|Open run>\nRun Planning"
	if got := CorrelationKey(text); got != "run:run-q9nwxogwkdkkqdu6" {
		t.Fatalf("correlation key = %q", got)
	}
	if got := Classify(text); got != Planning {
		t.Fatalf("phase = %q", got)
	}
	if got := CanonicalProviderURL(text); got != "https://app.terraform.io/app/acme/workspaces/infra/runs/run-Q9nWxoGwkdkKQdu6" {
		t.Fatalf("canonical provider URL = %q", got)
	}
}

func TestApprovalReadyTerraformLinkRejectsAWorkspaceOnlyURL(t *testing.T) {
	text := "Run notification for <https://app.terraform.io/app/acme/workspaces/infra|acme/infra>\n" +
		"Run run-Q9nWxoGwkdkKQdu6\nRun Planned - Needs Confirmation"
	if got := CanonicalProviderURL(text); got != "" {
		t.Fatalf("workspace URL %q was accepted as the exact approval-ready run", got)
	}
}

func TestApprovalReadyTerraformLinkMustMatchTheCorrelatedRun(t *testing.T) {
	text := "Run run-right\n" +
		"https://app.terraform.io/app/acme/workspaces/infra/runs/run-wrong\n" +
		"https://app.terraform.io/app/acme/workspaces/infra/runs/run-right"
	if got := CanonicalProviderURL(text); got != "https://app.terraform.io/app/acme/workspaces/infra/runs/run-right" {
		t.Fatalf("canonical provider URL = %q", got)
	}
	if got := CanonicalProviderURL("Run run-right\nhttps://app.terraform.io/app/acme/workspaces/infra/runs/run-wrong"); got != "" {
		t.Fatalf("URL for another run was accepted: %q", got)
	}
}

func TestApprovalReadyTerraformLinkDropsURLMetadataAndRejectsCredentials(t *testing.T) {
	if got := CanonicalProviderURL(
		"Run run-right\nhttps://app.terraform.io/app/acme/workspaces/infra/runs/run-right?utm_source=slack#details",
	); got != "https://app.terraform.io/app/acme/workspaces/infra/runs/run-right" {
		t.Fatalf("canonical provider URL retained metadata: %q", got)
	}
	if got := CanonicalProviderURL(
		"Run run-right\nhttps://user:secret@app.terraform.io/app/acme/workspaces/infra/runs/run-right",
	); got != "" {
		t.Fatalf("credential-bearing URL was accepted: %q", got)
	}
}
