// Package resultwire serializes accepted model results for durable storage.
package resultwire

import (
	"encoding/json"

	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// AgentReport persists typed operations without the legacy projections derived
// from them during validation.
func AgentReport(report decision.AgentReport) ([]byte, error) {
	if len(report.Operations) == 0 {
		return json.Marshal(report)
	}
	return json.Marshal(struct {
		Operations []investigation.ResultOperation `json:"operations"`
	}{Operations: report.Operations})
}
