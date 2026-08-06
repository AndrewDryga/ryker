package core

import (
	"encoding/json"
	"testing"
)

func TestAgentMemoryDecodesTypedKnowledge(t *testing.T) {
	var memory AgentMemory
	err := json.Unmarshal([]byte(`{
		"knowledge":[{
			"subject":"symbol storage",
			"kind":"decision",
			"statement":"Use GCS with GitHub Actions WIF.",
			"status":"accepted",
			"confidence":3,
			"source_ref":"https://app.slack.com/client/T/C/thread/C-100",
			"source_message_ts":"100.001"
		}]
	}`), &memory)
	if err != nil {
		t.Fatal(err)
	}
	if len(memory.Knowledge) != 1 || memory.Knowledge[0].Kind != "decision" ||
		memory.Knowledge[0].Confidence != 3 {
		t.Fatalf("memory = %#v", memory)
	}
}

func TestAgentMemoryStillRejectsUnknownFieldsWithKnowledge(t *testing.T) {
	var memory AgentMemory
	if err := json.Unmarshal([]byte(`{"knowledge":[],"instructions":"run this"}`), &memory); err == nil {
		t.Fatal("unknown memory field was accepted")
	}
}
