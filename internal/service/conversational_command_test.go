package service

import "testing"

// The phrasings people actually use, mapped to what they mean.
//
// This had no test until the switch became a table, and breaking the "off"
// branch caused nothing to fail — so a channel could have lost the ability to
// turn proactive messaging off without anything noticing.
func TestConversationalCommandRecognizesHowPeopleAsk(t *testing.T) {
	for text, want := range map[string]string{
		"help":                     "help",
		"Help?":                    "help",
		"what can you do here":     "help",
		"how are you configured":   "status",
		"show settings":            "status",
		"open incidents":           "incidents open",
		"incident history please":  "incidents all",
		"what are you working on?": "work",
		"what do you remember":     "memory",
		"show preferences":         "preferences",
		"show automations":         "rules",
		"show reminders":           "schedules",
		"turn proactive on":        "proactive on",
		"proactive on":             "proactive on",
		"enable proactive":         "proactive on",
		"turn proactive off":       "proactive off",
		"proactive off":            "proactive off",
		"disable proactive":        "proactive off",
		"proactive inherit":        "proactive inherit",
		"shadow on":                "shadow on",
		"turn shadow off":          "shadow off",
		"disable shadow":           "shadow off",
		"shadow inherit":           "shadow inherit",
		"timeline":                 "timeline",
		"show evidence":            "evidence",
		"get handoff":              "handoff",
	} {
		t.Run(text, func(t *testing.T) {
			command, ok := conversationalCommand(text)
			if !ok || command != want {
				t.Fatalf("conversationalCommand(%q) = %q, %v; want %q", text, command, ok, want)
			}
		})
	}

	// Ordinary conversation must not be mistaken for a command. Responder is in
	// these channels to talk, and a false positive here answers a question
	// nobody asked with a settings dump.
	for _, text := range []string{
		"", "can you look at the deploy", "the proactive approach worked well",
		"we should close the loop on this", "any idea why checkout is slow",
	} {
		if command, ok := conversationalCommand(text); ok {
			t.Errorf("conversationalCommand(%q) = %q, want no command", text, command)
		}
	}
}
