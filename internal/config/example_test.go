package config

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// exampleOmissions are the settings the example file deliberately does not
// show, with the reason. Everything else must appear, because a setting an
// operator cannot discover may as well not exist.
var exampleOmissions = map[string]string{
	"max_outbox_attempts": "deprecated compatibility alias for the per-queue attempt limits",
}

// The example configuration is the only place most operators will learn a
// setting exists. It drifted to roughly 109 of 150 keys before this test,
// which meant the entire memory, dreaming and feedback surface was invisible.
func TestExampleConfigurationDocumentsEverySetting(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "config", "responder.example.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	documented := documentedKeys(string(body))

	var missing []string
	for _, key := range yamlKeys(reflect.TypeOf(Config{})) {
		if _, omitted := exampleOmissions[key]; omitted {
			continue
		}
		if !documented[key] {
			missing = append(missing, key)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf(
			"config/responder.example.yaml does not document %d setting(s):\n  %s\n"+
				"Add each with a short comment, or list it in exampleOmissions with a reason.",
			len(missing), strings.Join(missing, "\n  "),
		)
	}

	// An omission that no longer exists is stale bookkeeping.
	known := map[string]bool{}
	for _, key := range yamlKeys(reflect.TypeOf(Config{})) {
		known[key] = true
	}
	for key := range exampleOmissions {
		if !known[key] {
			t.Errorf("exampleOmissions lists %q, which is no longer a setting", key)
		}
	}
}

// yamlKeys walks the config structure and returns every yaml key it defines.
func yamlKeys(structType reflect.Type) []string {
	var keys []string
	var walk func(reflect.Type)
	seen := map[reflect.Type]bool{}
	walk = func(current reflect.Type) {
		for current.Kind() == reflect.Pointer || current.Kind() == reflect.Slice ||
			current.Kind() == reflect.Map {
			current = current.Elem()
		}
		if current.Kind() != reflect.Struct || seen[current] {
			return
		}
		seen[current] = true
		for index := range current.NumField() {
			field := current.Field(index)
			tag := strings.Split(field.Tag.Get("yaml"), ",")[0]
			if tag != "" && tag != "-" {
				keys = append(keys, tag)
			}
			walk(field.Type)
		}
	}
	walk(structType)
	return keys
}

// A key counts as documented whether it is set or shown as a commented example
// with an explanation — the latter is the normal convention for optional
// settings and is what an operator actually reads.
var documentedKeyPattern = regexp.MustCompile(`(?m)^\s*(?:#\s*)?([a-z0-9_]+):`)

func documentedKeys(body string) map[string]bool {
	keys := map[string]bool{}
	for _, match := range documentedKeyPattern.FindAllStringSubmatch(body, -1) {
		keys[match[1]] = true
	}
	return keys
}
