package core

import (
	"reflect"
	"testing"
	"time"
)

func TestRemediationTimelineProjectsCanonicalLifecycleOnce(t *testing.T) {
	at := func(minute int) time.Time {
		return time.Date(2026, 8, 1, 10, minute, 0, 0, time.UTC)
	}
	record := RemediationRecord{
		Incident: Incident{
			ID: "inc_1", ChannelID: "CINC", Title: "API errors",
			CreatedAt: at(0), ClosedAt: at(50),
		},
		Signals: []Signal{{
			Route: "grafana", SourceID: "alert_1", Title: "High 5xx",
			Status: SignalResolved, Summary: "5xx exceeded 10%", SourceURL: "https://grafana.example/alert",
			StartsAt: at(1), EndsAt: at(30), ReceivedAt: at(1),
		}},
		AgentRuns: []AgentRun{{
			ID: "run_1", IncidentID: "inc_1", Repository: "infra",
			State: AgentRunCompleted, CreatedAt: at(2), StartedAt: at(3), CompletedAt: at(10),
		}},
		Evidence: []Evidence{{ID: "ev_1", SourceInput: "run_1"}},
		Events: []TimelineEvent{
			{ID: "legacy_alert", Kind: "alert.firing", Title: "High 5xx", CreatedAt: at(1)},
			{ID: "operator", Kind: "operator.message", Title: "Operator asked for a check", CreatedAt: at(4)},
			{ID: "legacy_approval", Kind: "emisar.approval.completed", Title: "Old approval copy", CreatedAt: at(20)},
		},
		Approvals: []EmisarApproval{{
			RequestID: "req_1", RunID: "emisar_run_1", ActionID: "service.restart",
			RunnerRef: "runner-1", Status: "succeeded",
			ApprovalURL: "https://emisar.example/approvals/req_1",
			RunURL:      "https://emisar.example/runs/emisar_run_1",
			CreatedAt:   at(12), TerminalAt: at(20),
		}},
		Publication: Publication{
			IncidentID: "inc_1", Repository: "infra", HeadBranch: "responder/fix",
			State: "published", PRNumber: 42, PRURL: "https://github.example/pull/42",
			CommitSHA: "abc123", CreatedAt: at(35), PublishedAt: at(40),
		},
	}

	first := RemediationTimeline(record)
	second := RemediationTimeline(record)
	if !reflect.DeepEqual(first, second) {
		t.Fatal("remediation projection is not deterministic")
	}
	for index := 1; index < len(first); index++ {
		if first[index].CreatedAt.Before(first[index-1].CreatedAt) {
			t.Fatalf("timeline is not chronological: %+v", first)
		}
	}
	wantIDs := map[string]bool{
		"incident:inc_1:opened":            false,
		"legacy_alert":                     false,
		"signal:grafana:alert_1:resolved":  false,
		"agent-run:run_1":                  false,
		"emisar-run:emisar_run_1:approval": false,
		"emisar-run:emisar_run_1:terminal": false,
		"publication:inc_1:published":      false,
		"incident:inc_1:closed":            false,
	}
	for _, event := range first {
		if _, ok := wantIDs[event.ID]; ok {
			if wantIDs[event.ID] {
				t.Fatalf("duplicate projected event %q", event.ID)
			}
			wantIDs[event.ID] = true
		}
		if event.ID == "legacy_approval" {
			t.Fatalf("legacy duplicate leaked into projection: %+v", event)
		}
		if event.ID == "agent-run:run_1" && !reflect.DeepEqual(event.EvidenceIDs, []string{"ev_1"}) {
			t.Fatalf("agent evidence = %+v", event.EvidenceIDs)
		}
	}
	for id, found := range wantIDs {
		if !found {
			t.Fatalf("missing projected event %q: %+v", id, first)
		}
	}
}
