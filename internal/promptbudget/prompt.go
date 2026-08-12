// Package promptbudget assembles a Coop prompt without cutting through a
// structured section. Required head and tail sections are always retained;
// optional context is removed only as complete named units.
package promptbudget

import (
	"errors"
	"strings"
)

type Section struct {
	Name   string
	Text   string
	Reason string
}

// Assemble removes optional sections in the supplied order until the prompt
// fits. It refuses an impossible prompt instead of handing malformed JSON or
// XML to a byte-slicing transport backstop.
func Assemble(limit int, head, tail string, optional ...Section) (string, []Section, error) {
	if limit < 1 {
		return "", nil, errors.New("prompt byte limit is required")
	}
	kept := append([]Section(nil), optional...)
	var omitted []Section
	build := func() string {
		var output strings.Builder
		output.WriteString(head)
		for _, section := range kept {
			output.WriteString(section.Text)
		}
		output.WriteString(tail)
		return output.String()
	}
	for {
		prompt := build()
		if len(prompt) <= limit {
			return prompt, omitted, nil
		}
		if len(kept) == 0 {
			return "", omitted, errors.New("required prompt sections exceed the Coop turn limit")
		}
		omitted = append(omitted, kept[0])
		kept = kept[1:]
	}
}
