package slackfile

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/AndrewDryga/responder/internal/slackui"
)

// Delivery is one generated image on its way to Slack, and the bounds it has to
// be inside to get there.
//
// The whole struct is a refusal surface. It crosses a durable queue as JSON, so
// what comes back out is not necessarily what a turn put in — a filename with a
// path separator, a body eight megabytes larger than the one that was written,
// a digest that no longer matches. Every field is checked on the way out rather
// than trusted on the way in.
type Delivery struct {
	Filename  string           `json:"filename"`
	Title     string           `json:"title"`
	AltText   string           `json:"alt_text"`
	MediaType string           `json:"media_type"`
	SHA256    string           `json:"sha256"`
	Data      []byte           `json:"data"`
	Message   *slackui.Message `json:"message,omitempty"`
}

func DecodeDelivery(data []byte) (Delivery, error) {
	var result Delivery
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return Delivery{}, fmt.Errorf("decode Slack file delivery: %w", err)
	}
	if result.Filename == "" || filepath.Base(result.Filename) != result.Filename ||
		len(result.Filename) > 255 || !utf8.ValidString(result.Filename) ||
		result.Title == "" || len(result.Title) > 200 || result.AltText == "" || len(result.AltText) > 1000 ||
		len(result.Data) == 0 || len(result.Data) > 8<<20 || !GeneratedImageMediaType(result.MediaType) {
		return Delivery{}, errors.New("Slack file delivery is outside bounds")
	}
	if result.Message != nil {
		encoded, err := slackui.Encode(*result.Message)
		if err != nil {
			return Delivery{}, fmt.Errorf("encode Slack file message: %w", err)
		}
		message, err := slackui.Decode(encoded)
		if err != nil {
			return Delivery{}, fmt.Errorf("decode Slack file message: %w", err)
		}
		result.Message = &message
	}
	digest := sha256.Sum256(result.Data)
	if hex.EncodeToString(digest[:]) != result.SHA256 {
		return Delivery{}, errors.New("Slack file delivery digest mismatch")
	}
	return result, nil
}

func GeneratedImageMediaType(mediaType string) bool {
	switch mediaType {
	case "image/png", "image/jpeg", "image/webp", "image/gif":
		return true
	default:
		return false
	}
}

func VisualFilename(original, deliveryID string) string {
	ext := strings.ToLower(filepath.Ext(original))
	if ext == ".jpeg" {
		ext = ".jpg"
	}
	base := strings.TrimSuffix(filepath.Base(original), filepath.Ext(original))
	base = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, base)
	base = strings.Trim(strings.ToLower(base), "-")
	if base == "" {
		base = "generated-image"
	}
	suffix := strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, deliveryID)
	name := base + "--" + suffix + ext
	if len(name) > 255 {
		name = name[:255-len(ext)] + ext
	}
	return name
}

func PermanentDeliveryError(err error) bool {
	detail := strings.ToLower(strings.TrimSpace(err.Error()))
	for _, marker := range []string{
		"missing_scope", "not_authed", "invalid_auth", "account_inactive",
		"not_allowed_token_type", "file_uploads_disabled",
	} {
		if strings.Contains(detail, marker) {
			return true
		}
	}
	return false
}
