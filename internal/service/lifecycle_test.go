package service

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestPruneLoggingSkipsTinyEphemeralBatches(t *testing.T) {
	if pruneResultWorthLogging(core.PruneResult{SlackDeliveries: 1}) {
		t.Fatal("single expired delivery produced maintenance log noise")
	}
	if !pruneResultWorthLogging(core.PruneResult{SlackDeliveries: 25}) {
		t.Fatal("large maintenance batch was hidden")
	}
	if !pruneResultWorthLogging(core.PruneResult{MemoryEntries: 1}) {
		t.Fatal("semantic memory pruning was hidden")
	}
}
