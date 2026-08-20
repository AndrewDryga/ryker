package service

import (
	"strings"
	"testing"
)

func TestEveryAgentCanValidateItsResultAgainstTheAttachedSchema(t *testing.T) {
	// The linked production episode accumulated 15 host corrections, while the
	// preceding two days accumulated 745. A model that has a machine-readable
	// contract and a validator must be told to use both before it returns.
	prompt := StructuredResponseInstructions()
	for _, required := range []string{
		"responder-result.schema.json",
		"jv --assert-format --output detailed",
		"/tmp/responder-result.json",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("structured result instructions do not tell the model to use %q", required)
		}
	}
}
