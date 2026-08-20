// Package resultcontract owns the exact machine-readable result schema given
// to agents and kept in lockstep with the host's strict result decoder.
package resultcontract

import (
	"bytes"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sync"

	"github.com/AndrewDryga/responder/internal/coop"
	jsonschema "github.com/santhosh-tekuri/jsonschema/v6"
)

const FileName = "responder-result.schema.json"

//go:embed responder-result.schema.json
var schemaBytes []byte

var (
	compiledOnce sync.Once
	compiled     *jsonschema.Schema
	compiledErr  error
)

// Schema returns a private copy of the exact bytes attached to every model
// turn. Callers may retain or mutate the returned slice.
func Schema() []byte {
	return append([]byte(nil), schemaBytes...)
}

// AppendArtifact reserves the final model-input slot for the exact published
// schema. A customer file with the same name is retained under a clear prefix.
func AppendArtifact(artifacts []coop.InputArtifact, limit int) ([]coop.InputArtifact, error) {
	if len(artifacts) >= limit {
		return nil, fmt.Errorf(
			"attach %s: %d input artifacts already fill the %d-artifact limit",
			FileName, len(artifacts), limit,
		)
	}
	result := append([]coop.InputArtifact(nil), artifacts...)
	for index := range result {
		if result[index].Name == FileName {
			result[index].Name = "customer-" + FileName
		}
	}
	data := Schema()
	digest := sha256.Sum256(data)
	return append(result, coop.InputArtifact{
		Name: FileName, MediaType: "application/json",
		SHA256: hex.EncodeToString(digest[:]), Data: data,
	}), nil
}

// SelfValidationPrompt gives an agent a deterministic preflight using the
// exact schema attached to its turn. The attached file arrives as a text block,
// so the agent first saves the bytes between its attached-file tags.
func SelfValidationPrompt() string {
	return `The attached-file block named responder-result.schema.json is the source of truth for the
result's JSON shape: field names, required fields, enums, bounds, and operation/payload pairs.
Before returning:
1. Save the exact contents between that attached-file block's tags to
   /tmp/responder-result.schema.json.
2. Write the final candidate JSON object to /tmp/responder-result.json.
3. Run:
   jv --assert-format --output detailed /tmp/responder-result.schema.json /tmp/responder-result.json
4. Fix every reported error and run the command again. Return the exact candidate file only after
   jv exits successfully. The schema checks local JSON shape; the host additionally checks evidence
   references, exact targets, claim joins, authority, and lifecycle facts against the episode record.`
}

// Validate checks data against the exact schema the model receives. Production
// decoding separately applies the equivalent static rules plus semantic checks
// that depend on the episode ledger.
func Validate(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return fmt.Errorf("%s is not JSON: %w", FileName, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("%s contains multiple JSON values", FileName)
		}
		return fmt.Errorf("%s contains trailing data: %w", FileName, err)
	}
	schema, err := compile()
	if err != nil {
		return fmt.Errorf("compile %s: %w", FileName, err)
	}
	if err := schema.Validate(value); err != nil {
		return fmt.Errorf("result does not match %s: %w", FileName, err)
	}
	return nil
}

func compile() (*jsonschema.Schema, error) {
	compiledOnce.Do(func() {
		var document any
		if err := json.Unmarshal(schemaBytes, &document); err != nil {
			compiledErr = err
			return
		}
		compiler := jsonschema.NewCompiler()
		compiler.AssertFormat()
		if err := compiler.AddResource(FileName, document); err != nil {
			compiledErr = err
			return
		}
		compiled, compiledErr = compiler.Compile(FileName)
	})
	return compiled, compiledErr
}
