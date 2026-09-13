// Package promptarchive shrinks the copy of a prompt that outlives the turn
// that sent it.
//
// A submitted prompt is the conversation plus the instruction block, and the
// instruction block is the same bytes on every turn: the host assembled it from
// its own constants and can say exactly which ones. The archive keeps the
// conversation — the part that only existed once — and replaces each
// instruction it recognizes with a one-line marker naming what stood there.
//
// ~131 MB/week on blitz, ~60% of it the same instruction block stored a hundred
// and forty times a day. That was the whole reason this package exists, and the
// measured result is smaller than the estimate: 76,772 bytes of instructions
// come out of a full briefing, which is ~50% of one and ~42% of the archive as
// a whole. The gap is the standing-briefing work — six of every ten rows on
// blitz are now delta turns that never carried the instruction block, so there
// was nothing on them left to save.
//
// The elision runs at write time against the exact texts the host holds in
// memory, never over stored text: a marker is placed where a known constant
// matched, so nothing is ever guessed at from the shape of an archived prompt.
package promptarchive

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

// MinBlockBytes is the shortest instruction a block may be and still be
// elided.
//
// Two reasons, and the second is the important one. A marker costs about 130
// bytes, so a block worth eliding has to be worth clearly more than that. And a
// short block is a short string that could occur inside the conversation itself
// — an operator quoting a line of the prompt back at Ryker is a thing that
// happens — and replacing THAT would delete a message rather than an
// instruction. A quarter kilobyte of specific prose is not something a Slack
// message contains by accident.
const MinBlockBytes = 256

// Block is one static instruction text the host assembles into prompts.
//
// Name is the Go symbol that owns the text, so a reader holding a marker can
// grep for the thing that produced it. It is written into the archive and is
// therefore a stable identifier: rename the constant and the old rows still
// name what they elided.
type Block struct {
	Name string
	Text string
}

// Marker is one elided block, read back from an archived prompt.
type Marker struct {
	Version string
	Block   string
	Digest  string
	Bytes   int
}

// The marker is a self-closing host tag. The prefix matches the host's other
// prompt tags (<host-investigation-contract>, <host-tool-transport>) because a
// reader already knows that spelling means "Ryker wrote this"; the self-
// closing form distinguishes it from those, which are open/close pairs holding
// content. Nothing a model writes and nothing Slack carries looks like this.
const (
	markerOpen  = "<host-elided-instructions "
	markerClose = "/>"
)

// Elide replaces every block the prompt actually carries with a marker naming
// it, and returns the prompt otherwise byte-for-byte unchanged.
//
// Longest first, because the instruction texts nest: the watch envelope
// contract contains the result-operations list, and eliding the inner one first
// would leave the outer one unmatched and stored in full.
func Elide(version, prompt string, blocks []Block) string {
	for _, block := range longestFirst(blocks) {
		if len(block.Text) < MinBlockBytes || !strings.Contains(prompt, block.Text) {
			continue
		}
		prompt = strings.ReplaceAll(prompt, block.Text, marker(version, block))
	}
	return prompt
}

// marker renders one block's replacement.
//
// The digest is what makes the marker honest. prompt_version is bumped when the
// CONTRACT changes, not when a sentence in the instructions is reworded, and the
// instructions are reworded most weeks — so "v3" does not pin the text that was
// actually sent, and a reader who reconstructed the block from today's constants
// would be shown words the model never saw. Six bytes of SHA-256 pin it: a
// future reader can prove a candidate reconstruction is the right one instead of
// assuming it.
func marker(version string, block Block) string {
	sum := sha256.Sum256([]byte(block.Text))
	return markerOpen +
		`prompt_version="` + version + `" ` +
		`block="` + block.Name + `" ` +
		`bytes="` + strconv.Itoa(len(block.Text)) + `" ` +
		`sha256="` + hex.EncodeToString(sum[:6]) + `"` + markerClose
}

// Markers reports the blocks an archived prompt says were elided from it, in
// the order they appear.
//
// This parses the host's own typed marker and nothing else. A prompt archived
// before this existed carries none and reads back as an empty list, which is
// what keeps an old row rendering exactly as it always did.
func Markers(prompt string) []Marker {
	found := []Marker{}
	for rest := prompt; ; {
		start := strings.Index(rest, markerOpen)
		if start < 0 {
			return found
		}
		rest = rest[start+len(markerOpen):]
		end := strings.Index(rest, markerClose)
		if end < 0 {
			return found
		}
		found = append(found, parseMarker(rest[:end]))
		rest = rest[end+len(markerClose):]
	}
}

// ElidedBytes is how much instruction text an archived prompt is standing in
// for, which is what lets the trace panel say what the reader is not seeing.
func ElidedBytes(markers []Marker) int {
	total := 0
	for _, item := range markers {
		total += item.Bytes
	}
	return total
}

func parseMarker(attributes string) Marker {
	item := Marker{}
	for _, field := range strings.Fields(attributes) {
		key, value, ok := strings.Cut(field, `="`)
		if !ok {
			continue
		}
		value = strings.TrimSuffix(value, `"`)
		switch key {
		case "prompt_version":
			item.Version = value
		case "block":
			item.Block = value
		case "sha256":
			item.Digest = value
		case "bytes":
			item.Bytes, _ = strconv.Atoi(value)
		}
	}
	return item
}

func longestFirst(blocks []Block) []Block {
	ordered := make([]Block, len(blocks))
	copy(ordered, blocks)
	for i := 1; i < len(ordered); i++ {
		for j := i; j > 0 && len(ordered[j].Text) > len(ordered[j-1].Text); j-- {
			ordered[j], ordered[j-1] = ordered[j-1], ordered[j]
		}
	}
	return ordered
}
