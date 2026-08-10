package memorydiff

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/memory"
)

// Change is one field that a committed agent-memory write created, updated, or
// removed. Values are captured at the persistence boundary so operators do not
// need to reconstruct history from a later memory snapshot.
type Change struct {
	Field  string `json:"field"`
	Title  string `json:"title"`
	Kind   string `json:"kind,omitempty"`
	State  string `json:"state"`
	Before string `json:"before,omitempty"`
	After  string `json:"after,omitempty"`
}

// AgentMemory returns a stable, human-readable field diff.
func AgentMemory(before, after core.AgentMemory) []Change {
	changes := make([]Change, 0)
	add := func(field, title, kind, oldValue, newValue string) {
		oldValue = strings.TrimSpace(oldValue)
		newValue = strings.TrimSpace(newValue)
		if oldValue == newValue {
			return
		}
		state := "updated"
		switch {
		case oldValue == "":
			state = "saved"
		case newValue == "":
			state = "removed"
		}
		changes = append(changes, Change{
			Field: field, Title: title, Kind: kind, State: state,
			Before: oldValue, After: newValue,
		})
	}

	add("goal", "Goal", "", before.Goal, after.Goal)
	add("channel_purpose", "Channel purpose", "", before.ChannelPurpose, after.ChannelPurpose)
	add("situation_summary", "Situation summary", "", before.SituationSummary, after.SituationSummary)
	for _, field := range []struct {
		name, title string
		before      []string
		after       []string
	}{
		{"active_topics", "Active topics", before.ActiveTopics, after.ActiveTopics},
		{"open_loops", "Open loops", before.OpenLoops, after.OpenLoops},
		{"topology", "Topology", before.Topology, after.Topology},
		{"decisions", "Decisions", before.Decisions, after.Decisions},
		{"unresolved_questions", "Unresolved questions", before.UnresolvedQuestions, after.UnresolvedQuestions},
		{"evidence_refs", "Evidence references", before.EvidenceRefs, after.EvidenceRefs},
	} {
		add(field.name, field.title, "", strings.Join(field.before, "\n"), strings.Join(field.after, "\n"))
	}

	type knowledgeValue struct {
		title, kind, statement string
	}
	oldKnowledge, newKnowledge := map[string]knowledgeValue{}, map[string]knowledgeValue{}
	order := make([]string, 0, len(before.Knowledge)+len(after.Knowledge))
	seen := map[string]bool{}
	index := func(items []core.KnowledgeItem, target map[string]knowledgeValue) {
		for _, item := range items {
			key := memory.NormalizeGuidanceSubject(item.Subject)
			if key == "" {
				continue
			}
			target[key] = knowledgeValue{item.Subject, item.Kind, item.Statement}
			if !seen[key] {
				seen[key] = true
				order = append(order, key)
			}
		}
	}
	// New ordering matches the operator's latest request. Removed entries follow
	// in their prior order.
	index(after.Knowledge, newKnowledge)
	index(before.Knowledge, oldKnowledge)
	for _, key := range order {
		oldValue, oldOK := oldKnowledge[key]
		newValue, newOK := newKnowledge[key]
		title, kind := newValue.title, newValue.kind
		if !newOK {
			title, kind = oldValue.title, oldValue.kind
		}
		oldComparable, newComparable := knowledgeDisplay(oldValue), knowledgeDisplay(newValue)
		if !oldOK {
			oldComparable = ""
		}
		if !newOK {
			newComparable = ""
		}
		if oldComparable != newComparable {
			add("knowledge:"+key, title, kind, oldComparable, newComparable)
		}
	}
	return changes
}

func knowledgeDisplay(value struct {
	title, kind, statement string
}) string {
	statement := strings.TrimSpace(value.statement)
	kind := strings.TrimSpace(value.kind)
	if statement == "" {
		return kind
	}
	if kind == "" {
		return statement
	}
	return statement + " · " + kind
}
