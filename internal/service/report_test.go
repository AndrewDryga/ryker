package service

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestAgentReportStrictSchemaAndLegacyCompatibility(t *testing.T) {
	report, structured, err := parseAgentReport("A concise legacy answer.")
	if err != nil || structured || report.Message != "A concise legacy answer." {
		t.Fatalf("legacy = %+v, %v, %v", report, structured, err)
	}
	report, structured, err = parseAgentReport(`{
	  "message":"Current state is degraded.",
	  "evidence":[],
	  "coverage":[],
	  "memory":{},
	  "proposals":[]
	}`)
	if err != nil || !structured || report.Message != "Current state is degraded." {
		t.Fatalf("structured = %+v, %v, %v", report, structured, err)
	}
	for name, input := range map[string]string{
		"empty message": `{"message":"","evidence":[]}`,
		"two values":    `{"message":"answer"} {"message":"other"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := parseAgentReport(input); err == nil {
				t.Fatal("invalid structured report was accepted")
			}
		})
	}
}

func TestAgentReportPreservesMessageWhenOptionalEnvelopeIsMalformed(t *testing.T) {
	report, structured, err := parseAgentReport(
		`{"message":"The database is healthy.","evidence":{"unexpected":"shape"}}`,
	)
	if err != nil || structured || report.Message != "The database is healthy." {
		t.Fatalf("degraded envelope = %+v, %v, %v", report, structured, err)
	}
	if len(report.Evidence) != 0 {
		t.Fatalf("malformed evidence escaped recovery: %+v", report.Evidence)
	}
}

func TestAgentReportExtractsFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := "I’m inspecting declared and live state." +
		"The audit is converging; I’m running validation now." +
		`{"message":"**Audit complete:** no repository change was needed.",` +
		`"evidence":[{"claim":"Packs match","observation":"Nine declared packs are live",` +
		`"source_type":"emisar","source_name":"list_packs"}],` +
		`"coverage":[{"layer":"runtime","status":"healthy"}],"memory":{},"proposals":[]}`
	report, structured, err := parseAgentReport(output)
	if err != nil || !structured {
		t.Fatalf("progress-prefixed report = %+v, %v, %v", report, structured, err)
	}
	if report.Message != "**Audit complete:** no repository change was needed." ||
		len(report.Evidence) != 1 || len(report.Coverage) != 1 {
		t.Fatalf("extracted report = %+v", report)
	}
}

func TestAgentReportRecoversMessageFromMalformedFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := `I’m checking the repository.{"message":"Audit complete","tool_output":"secret"}`
	report, structured, err := parseAgentReport(output)
	if err != nil || structured || report.Message != "Audit complete" {
		t.Fatalf("recovered progress-prefixed report = %+v structured:%v err:%v",
			report, structured, err)
	}
}

func TestStructuredEvidenceAndCoverageEnumsAreHostValidated(t *testing.T) {
	evidence := sanitizeEvidence([]core.Evidence{{
		Claim: "A claim", Observation: "An observation",
		SourceType: "shell", SourceName: "tool",
		Confidence: "certain",
		SourceURL:  "https://user:secret@example.test/path?token=secret",
	}}, "", "C1", "slack_1")
	if len(evidence) != 1 || evidence[0].SourceType != "other" ||
		evidence[0].Confidence != "" || evidence[0].SourceURL != "" {
		t.Fatalf("evidence = %+v", evidence)
	}
	coverage := sanitizeCoverage([]core.Coverage{
		{Layer: "scheduler", Status: "healthy"},
		{Layer: "everything", Status: "perfect"},
	}, "", "C1", "slack_1")
	if len(coverage) != 1 || coverage[0].Layer != "scheduler" {
		t.Fatalf("coverage = %+v", coverage)
	}
}

func TestStructuredResponsePolicyOwnsFormattingAndActionCatalog(t *testing.T) {
	service := &Service{}
	policy := service.structuredResponsePolicy()
	for _, required := range []string{
		"Return exactly one JSON object",
		"Slack-supported standard Markdown",
		"No actions are configured",
		"Never invent a source",
	} {
		if !strings.Contains(policy, required) {
			t.Fatalf("policy lacks %q:\n%s", required, policy)
		}
	}
}
