package lifecycle

import "testing"

func TestTerraformCorrelationPrefersExactRunIDOverWorkspaceLink(t *testing.T) {
	text := "Run notification for <https://app.terraform.io/app/acme/workspaces/infra|acme/infra>\n" +
		"Run run-Q9nWxoGwkdkKQdu6\nRun Planning"
	if got := CorrelationKey(text); got != "run:run-q9nwxogwkdkkqdu6" {
		t.Fatalf("correlation key = %q", got)
	}
	if got := Classify(text); got != Planning {
		t.Fatalf("phase = %q", got)
	}
}
