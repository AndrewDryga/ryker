package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// DecodeStrictJSON reads exactly one JSON value and rejects unknown fields.
func DecodeStrictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

// RemoveOneUnexpectedClosingDelimiter removes the exact closing byte a JSON
// syntax error identified. Callers must still fully validate the candidate.
func RemoveOneUnexpectedClosingDelimiter(message string, decodeErr error) (string, bool) {
	var syntax *json.SyntaxError
	if !errors.As(decodeErr, &syntax) || syntax.Offset < 1 {
		return "", false
	}
	index := int(syntax.Offset - 1)
	if index >= len(message) || message[index] != '}' && message[index] != ']' {
		return "", false
	}
	return message[:index] + message[index+1:], true
}

// DecodeModelObject decodes a model-authored JSON object strictly, after
// renaming a small table of aliases onto the one real field each of them names.
//
// Strictness is the default on purpose: an invented field is usually an
// invented claim, and quietly dropping it would report work that was never
// done. But rejection is not free. A refused response costs a whole correction
// turn, and the model pays that price for spelling an existing field with an
// obvious synonym — which is not an invented claim, it is a naming difference.
// Rejections of that kind were 11 of the 19 corrections captured in production,
// and every one of them discarded an otherwise usable answer.
//
// An alias earns its place only when it names exactly one real field, so the
// mapping cannot change what the model said. The canonical spelling always
// wins when both are present, and everything still unrecognized is still an
// error.
//
// An alias mapped to the empty string is accepted and discarded. That is for
// host-owned identity a model may state correctly but must never decide — the
// channel a rule binds to, for instance. Dropping such a value is safer than
// both alternatives: honoring it would let a response rebind its own scope,
// and rejecting it throws away the whole answer over a redundant echo.
func DecodeModelObject(data []byte, aliases map[string]string, target any) error {
	if len(aliases) > 0 {
		renamed, err := renameModelAliases(data, aliases)
		if err != nil {
			return err
		}
		data = renamed
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

// renameModelAliases rewrites the object's keys, leaving the value bytes
// untouched. It returns the original input unchanged when no alias is present,
// so the common path neither reorders nor re-encodes anything.
func renameModelAliases(data []byte, aliases map[string]string) ([]byte, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		// Malformed, or not an object at all. Hand it to the strict decoder
		// unchanged so the caller sees the real syntax or type error.
		return data, nil
	}
	found := false
	for alias, canonical := range aliases {
		value, present := fields[alias]
		if !present {
			continue
		}
		found = true
		delete(fields, alias)
		if canonical == "" {
			continue
		}
		if _, taken := fields[canonical]; !taken {
			fields[canonical] = value
		}
	}
	if !found {
		return data, nil
	}
	return json.Marshal(fields)
}
