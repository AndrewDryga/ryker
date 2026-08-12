package promptbudget

import (
	"strings"
	"testing"
)

func TestAssembleDropsOnlyWholeNamedSections(t *testing.T) {
	prompt, omitted, err := Assemble(20, "HEAD", "TAIL",
		Section{Name: "old", Text: "<old>123456</old>", Reason: "old context"},
		Section{Name: "new", Text: "<new>x</new>", Reason: "new context"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if prompt != "HEAD<new>x</new>TAIL" || len(omitted) != 1 || omitted[0].Name != "old" {
		t.Fatalf("assembled = %q, omitted = %+v", prompt, omitted)
	}
	if strings.Contains(prompt, "123456") {
		t.Fatal("dropped section leaked into the prompt")
	}
}

func TestAssembleRefusesOversizedRequiredContract(t *testing.T) {
	if _, _, err := Assemble(4, "HEAD", "TAIL"); err == nil {
		t.Fatal("oversized required sections were sliced")
	}
}
