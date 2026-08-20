package investigation

import (
	"encoding/json"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/resultcontract"
)

func TestPublishedSchemaMatchesEveryCanonicalResultOperation(t *testing.T) {
	var document map[string]any
	if err := json.Unmarshal(resultcontract.Schema(), &document); err != nil {
		t.Fatal(err)
	}
	definitions := document["$defs"].(map[string]any)
	operation := definitions["operation"].(map[string]any)
	properties := operation["properties"].(map[string]any)

	expectedPayloads := map[string]string{
		"record_evidence":            "evidence",
		"record_coverage":            "coverage",
		"record_finding":             "finding",
		"report_progress":            "progress",
		"plan_goal":                  "goal",
		"update_goal":                "goal_state",
		"request_operator_input":     "operator_input",
		"wait_external":              "external_wait",
		"record_feedback":            "feedback",
		"request_record":             "record",
		"offer_task":                 "task",
		"request_approval":           "approval",
		"attach_visual":              "visual",
		"update_memory":              "memory",
		"offer_memory":               "memory_offer",
		"offer_preference":           "preference_offer",
		"offer_rule":                 "rule_offer",
		"offer_schedule":             "schedule_offer",
		"record_alert_assessment":    "alert_assessment",
		"record_repository_contents": "repository_contents",
		"offer_grant_promotion":      "grant_promotion",
		"offer_runbook_draft":        "runbook_draft",
		"offer_kb_card":              "kb_card",
		"offer_assignment":           "assignment",
		"complete_episode":           "completion",
	}

	schemaTypes := stringSet(properties["type"].(map[string]any)["enum"].([]any))
	validatorTypes := make([]string, 0, len(resultOperationValidators)-1)
	for operationType := range resultOperationValidators {
		if operationType != "propose_action" {
			validatorTypes = append(validatorTypes, operationType)
		}
	}
	slices.Sort(validatorTypes)
	if !slices.Equal(schemaTypes, validatorTypes) {
		t.Fatalf("schema operation types = %v; host operation types = %v", schemaTypes, validatorTypes)
	}

	payloadProperties := make([]string, 0, len(properties)-2)
	for property := range properties {
		if property != "id" && property != "type" {
			payloadProperties = append(payloadProperties, property)
		}
	}
	slices.Sort(payloadProperties)
	structPayloads := resultOperationJSONFields(t)
	if !slices.Equal(payloadProperties, structPayloads) {
		t.Fatalf("schema payload fields = %v; ResultOperation payload fields = %v", payloadProperties, structPayloads)
	}

	requiredPayloads := map[string]string{}
	for _, rawRule := range operation["allOf"].([]any) {
		rule := rawRule.(map[string]any)
		condition := rule["if"].(map[string]any)
		conditionProperties := condition["properties"].(map[string]any)
		operationType := conditionProperties["type"].(map[string]any)["const"].(string)
		required := rule["then"].(map[string]any)["required"].([]any)
		if len(required) != 1 {
			t.Fatalf("schema condition for %s requires %v", operationType, required)
		}
		requiredPayloads[operationType] = required[0].(string)
	}
	if !reflect.DeepEqual(requiredPayloads, expectedPayloads) {
		t.Fatalf("schema operation/payload map = %v; expected %v", requiredPayloads, expectedPayloads)
	}
}

func stringSet(values []any) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, value.(string))
	}
	slices.Sort(result)
	return result
}

func resultOperationJSONFields(t *testing.T) []string {
	t.Helper()
	typeOfOperation := reflect.TypeOf(ResultOperation{})
	result := make([]string, 0, typeOfOperation.NumField())
	for index := 0; index < typeOfOperation.NumField(); index++ {
		field := typeOfOperation.Field(index)
		name := strings.Split(field.Tag.Get("json"), ",")[0]
		if name == "" || name == "-" || name == "id" || name == "type" || name == "proposal" {
			continue
		}
		result = append(result, name)
	}
	slices.Sort(result)
	return result
}
