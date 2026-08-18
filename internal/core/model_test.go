package core

import (
	"encoding/json"
	"testing"
	"time"
)

func TestEvidenceNormalizesScalarDimensions(t *testing.T) {
	var item Evidence
	if err := json.Unmarshal([]byte(`{
		"claim":"capacity is available",
		"observation":"three replicas are ready",
		"source_type":"emisar",
		"source_id":"result-7",
		"source_name":"Emisar",
		"dimensions":{"service":"api","replicas":3,"regional":true}
	}`), &item); err != nil {
		t.Fatal(err)
	}
	if item.SourceID != "result-7" || item.Dimensions["service"] != "api" ||
		item.Dimensions["replicas"] != "3" || item.Dimensions["regional"] != "true" {
		t.Fatalf("evidence = %+v", item)
	}
	if err := json.Unmarshal([]byte(`{
		"claim":"bad","observation":"bad","source_type":"other","source_name":"fixture",
		"dimensions":{"service":{"nested":true}}
	}`), &item); err == nil {
		t.Fatal("nested evidence dimension was accepted")
	}
	if err := json.Unmarshal([]byte(`{
		"claim":"bad","observation":"bad","source_type":"other","source_name":"fixture",
		"invented":true
	}`), &item); err == nil {
		t.Fatal("unknown evidence field was accepted")
	}
}

// A complete target universe is a host attestation, not something a model can
// unlock by describing an inventory as complete in its own result.
func TestEvidenceRejectsAHostOnlyTargetUniverseOnTheWire(t *testing.T) {
	var item Evidence
	if err := json.Unmarshal([]byte(`{
		"claim_id":"scope.target_universe",
		"claim":"the configured production targets",
		"observation":"the inventory enumerated auth and payments",
		"relation":"supports",
		"source_type":"repository",
		"source_name":"production routing inventory",
		"target_universe":["auth","payments"]
	}`), &item); err == nil {
		t.Fatal("model-authored target universe was accepted as host proof")
	}
}

func TestEvidenceAcceptsBoundedLegacySourceAliases(t *testing.T) {
	var item Evidence
	if err := json.Unmarshal([]byte(`{
		"claim":"latency recovered","observation":"the latest probe passed",
		"source":"monitoring","source_ref":"https://monitoring.example.test/check/7",
		"source_time":"2026-08-12T04:20:00Z"
	}`), &item); err != nil {
		t.Fatal(err)
	}
	wantTime := time.Date(2026, 8, 12, 4, 20, 0, 0, time.UTC)
	if item.SourceType != "monitoring" || item.SourceName != "monitoring" ||
		item.SourceURL != "https://monitoring.example.test/check/7" ||
		!item.ObservedAt.Equal(wantTime) {
		t.Fatalf("aliased evidence = %+v", item)
	}
}

func TestAgentMemoryNormalizesScalarTopologyObject(t *testing.T) {
	var memory AgentMemory
	if err := json.Unmarshal([]byte(`{
		"goal":"assess rollout",
		"topology":{"environment":"production","desired_instances":2,"regional":true}
	}`), &memory); err != nil {
		t.Fatal(err)
	}
	want := []string{"desired_instances: 2", "environment: production", "regional: true"}
	if len(memory.Topology) != len(want) {
		t.Fatalf("topology = %#v", memory.Topology)
	}
	for index := range want {
		if memory.Topology[index] != want[index] {
			t.Fatalf("topology = %#v", memory.Topology)
		}
	}
}

// Twelve results in two days were discarded whole because the model wrote the
// evidence confidence as the one-to-three integer the attention assessment
// beside it uses. Each rejection cost a turn to say the same thing again.
func TestEvidenceAcceptsNumericConfidenceAndObservationSynonyms(t *testing.T) {
	for _, testCase := range []struct {
		raw  string
		want string
	}{
		{`3`, "high"}, {`2`, "medium"}, {`1`, "low"},
		{`"high"`, "high"}, {`"low"`, "low"}, {``, ""},
		// A decimal is read as a probability rather than as the band.
		{`0.9`, "high"}, {`0.5`, "medium"}, {`0.1`, "low"},
	} {
		body := `{"claim_id":"c","observation":"o","source_type":"emisar","source_name":"s"`
		if testCase.raw != "" {
			body += `,"confidence":` + testCase.raw
		}
		var item Evidence
		if err := json.Unmarshal([]byte(body+`}`), &item); err != nil {
			t.Fatalf("confidence %s was rejected: %v", testCase.raw, err)
		}
		if item.Confidence != testCase.want {
			t.Fatalf("confidence %s = %q, want %q", testCase.raw, item.Confidence, testCase.want)
		}
	}

	// A confidence that is neither a band nor a number is still refused: the
	// point is to read what the model meant, not to accept anything.
	var rejected Evidence
	if err := json.Unmarshal([]byte(
		`{"claim_id":"c","observation":"o","source_type":"emisar","source_name":"s","confidence":{"level":9}}`,
	), &rejected); err == nil {
		t.Fatal("an unreadable confidence was accepted")
	}

	// The observation is the one part of a record nothing else can supply, and
	// the whole record was being thrown away over the label on that field.
	for _, field := range []string{"summary", "statement"} {
		var item Evidence
		if err := json.Unmarshal([]byte(
			`{"claim_id":"c","`+field+`":"the disk recovered","source_type":"emisar","source_name":"s"}`,
		), &item); err != nil {
			t.Fatalf("evidence carrying %q was rejected: %v", field, err)
		}
		if item.Observation != "the disk recovered" {
			t.Fatalf("%q did not become the observation: %q", field, item.Observation)
		}
	}
}
