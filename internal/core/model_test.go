package core

import (
	"encoding/json"
	"testing"
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
