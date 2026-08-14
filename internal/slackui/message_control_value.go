package slackui

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"slices"

	"github.com/AndrewDryga/responder/internal/coop"
)

// This file is the other half of a control: the renderer writes an action's
// value, and something later has to read it back. Both halves live here for the
// same reason the overflow option codec does — an encoding known in one package
// and decoded in another is an encoding that can drift, and the way that fails
// is a button that routes to the wrong work rather than a compile error.

// ChangesPatchPageBytes is one page of a diff.
const ChangesPatchPageBytes = 7000

// ChangesCursor is a diff pager's position, carried in the button that moves
// it. The digest binds a page to the patch it was cut from, so a stale Next
// press cannot page into a diff that has since been rewritten.
type ChangesCursor struct {
	IncidentID string `json:"i"`
	Offset     int64  `json:"o"`
	Digest     string `json:"d,omitempty"`
}

func EncodeChangesCursor(cursor ChangesCursor) string {
	data, err := json.Marshal(cursor)
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func DecodeChangesCursor(value string) (ChangesCursor, bool) {
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || len(data) > 1024 {
		return ChangesCursor{}, false
	}
	var cursor ChangesCursor
	if err := json.Unmarshal(data, &cursor); err != nil ||
		cursor.IncidentID == "" || cursor.Offset < 0 ||
		(cursor.Digest != "" && len(cursor.Digest) != sha256.Size*2) {
		return ChangesCursor{}, false
	}
	return cursor, true
}

// ActionIncidentID reads which work a control acts on out of its value.
//
// Most controls carry the id and nothing else. The ones that carry more — a
// publication generation, a pager position, which view of the ask was asked for
// — each pack it differently, and this is the single place that knows all of
// them. A caller that read the value raw instead would look an incident up
// under a string that was never an id, which is how the diff pager's buttons
// were answered "this control is no longer valid".
func ActionIncidentID(actionID string, value string) (string, bool) {
	switch actionID {
	case ActionChanges:
		return value, value != ""
	case ActionPublishPR:
		incidentID, _, _ := DecodePublicationActionValue(value)
		return incidentID, incidentID != ""
	case ActionFullRequest:
		incidentID := legacyFullRequestIncidentID(value)
		return incidentID, incidentID != ""
	case ActionChangesPrevious, ActionChangesNext, ActionChangesRefresh:
		cursor, ok := DecodeChangesCursor(value)
		return cursor.IncidentID, ok
	default:
		return value, value != ""
	}
}

// MessageOffersControl asks whether a rendered message still carries the
// control that was pressed.
//
// It looks everywhere a control can be rendered, not only at the bottom row. A
// card puts a control in a Row and its read-only options behind ⋯, and scanning
// Actions alone judged both of those stale.
//
// Full request matches on its id alone. The card stopped rendering it — the
// request is always on the card now — but cards expanded in place before that
// carry a button whose value the ledger never recorded, and requiring an exact
// match would refuse those clicks instead of re-rendering the card they are
// sitting on. Every other control keeps exact matching, which is what makes a
// superseded publication button harmless.
func MessageOffersControl(message Message, actionID, value string) bool {
	match := func(action Action) bool {
		if action.ID != actionID {
			return false
		}
		return action.Value == value || actionID == ActionFullRequest
	}
	if slices.ContainsFunc(message.Actions, match) ||
		slices.ContainsFunc(message.Overflow, match) {
		return true
	}
	for _, row := range message.Rows {
		if slices.ContainsFunc(row.Actions, match) ||
			slices.ContainsFunc(row.Overflow, match) {
			return true
		}
	}
	return false
}

// NewChangesNavigation states where a diff pager is, in pages a person counts
// from one, and mints the cursors its three buttons carry.
func NewChangesNavigation(incidentID string, changes coop.Changes) ChangesNavigation {
	total := changes.PatchBytes
	pages := 1
	page := 1
	if total > 0 {
		pages = int((total + ChangesPatchPageBytes - 1) / ChangesPatchPageBytes)
		page = int(changes.PatchOffset/ChangesPatchPageBytes) + 1
	}
	navigation := ChangesNavigation{
		Page: page, Pages: pages,
		FirstByte: changes.PatchOffset, LastByte: changes.PatchNextOffset,
		TotalBytes: total, Digest: changes.PatchDigest,
		RefreshValue: EncodeChangesCursor(ChangesCursor{
			IncidentID: incidentID, Offset: 0, Digest: changes.PatchDigest,
		}),
	}
	if changes.PatchOffset > 0 {
		navigation.PreviousValue = EncodeChangesCursor(ChangesCursor{
			IncidentID: incidentID,
			Offset:     max(int64(0), changes.PatchOffset-ChangesPatchPageBytes),
			Digest:     changes.PatchDigest,
		})
	}
	if changes.PatchHasMore {
		navigation.NextValue = EncodeChangesCursor(ChangesCursor{
			IncidentID: incidentID,
			Offset:     changes.PatchNextOffset,
			Digest:     changes.PatchDigest,
		})
	}
	return navigation
}
