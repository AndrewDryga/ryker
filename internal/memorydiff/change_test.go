package memorydiff

import (
	"reflect"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAgentMemoryReportsOnlyActualFieldChanges(t *testing.T) {
	before := core.AgentMemory{
		Goal:             "Review plans",
		ChannelPurpose:   "Infrastructure operations",
		SituationSummary: "Plan is waiting",
		OpenLoops:        []string{"Review plan", "Check rollout"},
		Knowledge: []core.KnowledgeItem{
			{Subject: "Terraform drift", Kind: "fact", Statement: "Report drift"},
			{Subject: "Old note", Kind: "fact", Statement: "Remove me"},
		},
	}
	after := core.AgentMemory{
		Goal:           "Review and track plans",
		ChannelPurpose: "Infrastructure operations",
		OpenLoops:      []string{"Review plan"},
		Knowledge: []core.KnowledgeItem{
			{Subject: "Terraform drift", Kind: "constraint", Statement: "Do not report drift"},
			{Subject: "Plan versions", Kind: "constraint", Statement: "Show before and after"},
		},
	}

	got := AgentMemory(before, after)
	want := []Change{
		{Field: "goal", Title: "Goal", State: "updated", Before: "Review plans", After: "Review and track plans"},
		{Field: "situation_summary", Title: "Situation summary", State: "removed", Before: "Plan is waiting"},
		{Field: "open_loops", Title: "Open loops", State: "updated", Before: "Review plan\nCheck rollout", After: "Review plan"},
		{Field: "knowledge:terraform_drift", Title: "Terraform drift", Kind: "constraint", State: "updated", Before: "Report drift · fact", After: "Do not report drift · constraint"},
		{Field: "knowledge:plan_versions", Title: "Plan versions", Kind: "constraint", State: "saved", After: "Show before and after · constraint"},
		{Field: "knowledge:old_note", Title: "Old note", Kind: "fact", State: "removed", Before: "Remove me · fact"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diff = %#v\nwant %#v", got, want)
	}
}

func TestAgentMemoryReportsKnowledgeKindOnlyChange(t *testing.T) {
	before := core.AgentMemory{Knowledge: []core.KnowledgeItem{
		{Subject: "Terraform drift", Kind: "fact", Statement: "Do not report drift"},
	}}
	after := core.AgentMemory{Knowledge: []core.KnowledgeItem{
		{Subject: "Terraform drift", Kind: "constraint", Statement: "Do not report drift"},
	}}

	want := []Change{{
		Field: "knowledge:terraform_drift", Title: "Terraform drift", Kind: "constraint",
		State: "updated", Before: "Do not report drift · fact", After: "Do not report drift · constraint",
	}}
	if got := AgentMemory(before, after); !reflect.DeepEqual(got, want) {
		t.Fatalf("diff = %#v\nwant %#v", got, want)
	}
}
