package service

import (
	"context"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// Asking for a handoff in words gets the host's record, not the model's memory
// of it.
//
// `/responder handoff` was deleted with the rest of the slash surface, and the
// obvious replacement — let the model write the summary when somebody asks for
// one — is the wrong one. The four reports are the durable account of what
// happened: who was paged, which evidence was cited, what the coverage gaps
// were. A model writing that from its own context writes a plausible account of
// what it remembers, and a handoff is exactly the document an operator reads
// instead of the record. So the model classifies the ask and emits
// request_record, and the host renders the same document the card's Record menu
// renders, from the same store rows, through the same renderer.
func TestARequestedHandoffIsTheHostsRecordNotModelProse(t *testing.T) {
	ctx := context.Background()
	st, svc, slackClient, incident := reportFixture(t, ctx, nil)

	run, admitted, err := st.QueueAgentRun(ctx, core.AgentRun{
		ID: "run_record_request", Mode: core.AgentRunIncident,
		IncidentID: incident.ID, ChannelID: incident.ChannelID,
		SourceKind: "slack", SourceID: "input_record_request",
		UserID: "U123ABC", Repository: "repo", Prompt: "give me a handoff summary",
	})
	if err != nil || !admitted {
		t.Fatalf("queue run = %t, %v", admitted, err)
	}

	if err := svc.publishRequestedRecord(ctx, run.ID, investigation.ResultOperation{
		ID: "record-1", Type: "request_record",
		Record: &investigation.RecordRequestOperation{Kind: "handoff"},
	}); err != nil {
		t.Fatalf("publish the requested handoff: %v", err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("requested handoff posts = %+v, want exactly one", slackClient.posts)
	}
	posted := slackClient.posts[0]
	if posted.channel != incident.ChannelID {
		t.Fatalf("the handoff went to %q, not to the work's room %q",
			posted.channel, incident.ChannelID)
	}
	rendered := renderedSlackMessage(posted.message)
	// The heading the host's renderer writes, and a line that exists only
	// because this fixture recorded it. Neither could come from the turn.
	if !strings.Contains(rendered, "handoff") && !strings.Contains(rendered, "Handoff") {
		t.Fatalf("the reply is not the handoff report: %s", rendered)
	}
	if !strings.Contains(rendered, "API errors") {
		t.Fatalf("the handoff does not read the durable record: %s", rendered)
	}
}

// A record request names one of four documents, and nothing else.
//
// An unrecognised kind renders nothing at all, so accepting it would drop the
// answer in silence — the operator asked for a summary and got no reply and no
// reason. The rejection quotes the set so the correction turn has somewhere to
// go.
func TestARecordRequestForSomethingUnrenderableIsRefusedWithTheSet(t *testing.T) {
	for kind, wantErr := range map[string]bool{
		"timeline":   false,
		"evidence":   false,
		"handoff":    false,
		"postmortem": false,
		"":           true,
		"summary":    true,
		"status":     true,
	} {
		operation := investigation.ResultOperation{
			ID: "record-1", Type: "request_record",
			Record: &investigation.RecordRequestOperation{Kind: kind},
		}
		err := operation.Validate()
		if wantErr && err == nil {
			t.Errorf("record kind %q was accepted", kind)
		}
		if !wantErr && err != nil {
			t.Errorf("record kind %q was refused: %v", kind, err)
		}
		if wantErr && err != nil && !strings.Contains(err.Error(), "handoff") {
			t.Errorf("record kind %q was refused without naming the set: %v", kind, err)
		}
	}
}
