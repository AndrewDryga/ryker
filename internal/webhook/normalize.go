package webhook

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

const signatureWindow = 5 * time.Minute

func Verify(route config.Webhook, header http.Header, body []byte, secret string, now time.Time) error {
	switch route.Auth {
	case "bearer":
		values := header.Values("Authorization")
		if len(values) != 1 || !strings.HasPrefix(values[0], "Bearer ") {
			return errors.New("one Bearer authorization is required")
		}
		presented := strings.TrimPrefix(values[0], "Bearer ")
		if len(presented) != len(secret) || !hmac.Equal([]byte(presented), []byte(secret)) {
			return errors.New("invalid webhook authorization")
		}
		return nil
	case "hmac-sha256":
		timestamps := header.Values("X-Responder-Timestamp")
		signatures := header.Values("X-Responder-Signature")
		if len(timestamps) != 1 || len(signatures) != 1 {
			return errors.New("one timestamp and signature are required")
		}
		deliveryIDs := header.Values("X-Responder-Event-ID")
		if len(deliveryIDs) > 1 {
			return errors.New("at most one delivery ID is accepted")
		}
		deliveryID := ""
		if len(deliveryIDs) == 1 {
			deliveryID = strings.TrimSpace(deliveryIDs[0])
		}
		seconds, err := strconv.ParseInt(timestamps[0], 10, 64)
		if err != nil {
			return errors.New("invalid webhook timestamp")
		}
		signedAt := time.Unix(seconds, 0)
		if signedAt.Before(now.Add(-signatureWindow)) || signedAt.After(now.Add(signatureWindow)) {
			return errors.New("webhook timestamp is outside the replay window")
		}
		presented := strings.TrimPrefix(signatures[0], "sha256=")
		raw, err := hex.DecodeString(presented)
		if err != nil || len(raw) != sha256.Size {
			return errors.New("invalid webhook signature")
		}
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write([]byte(timestamps[0]))
		mac.Write([]byte("."))
		mac.Write([]byte(deliveryID))
		mac.Write([]byte("."))
		mac.Write(body)
		if !hmac.Equal(raw, mac.Sum(nil)) {
			return errors.New("invalid webhook signature")
		}
		return nil
	default:
		return errors.New("unsupported webhook authentication")
	}
}

func Normalize(route config.Webhook, body []byte, receivedAt time.Time) ([]core.Signal, error) {
	switch route.Kind {
	case "grafana":
		return normalizeGrafana(route, body, receivedAt)
	case "generic":
		return normalizeGeneric(route, body, receivedAt)
	default:
		return nil, errors.New("unsupported webhook kind")
	}
}

type grafanaPayload struct {
	Receiver          string            `json:"receiver"`
	Status            string            `json:"status"`
	GroupKey          string            `json:"groupKey"`
	Title             string            `json:"title"`
	Message           string            `json:"message"`
	ExternalURL       string            `json:"externalURL"`
	CommonLabels      map[string]string `json:"commonLabels"`
	CommonAnnotations map[string]string `json:"commonAnnotations"`
	Alerts            []grafanaAlert    `json:"alerts"`
}

type grafanaAlert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     time.Time         `json:"startsAt"`
	EndsAt       time.Time         `json:"endsAt"`
	GeneratorURL string            `json:"generatorURL"`
	Fingerprint  string            `json:"fingerprint"`
	DashboardURL string            `json:"dashboardURL"`
	PanelURL     string            `json:"panelURL"`
}

func normalizeGrafana(route config.Webhook, body []byte, receivedAt time.Time) ([]core.Signal, error) {
	var payload grafanaPayload
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode Grafana webhook: %w", err)
	}
	if err := requireEOF(dec); err != nil {
		return nil, err
	}
	if len(payload.Alerts) == 0 {
		return nil, errors.New("Grafana webhook contains no alerts")
	}
	if len(payload.Alerts) > 500 {
		return nil, errors.New("Grafana webhook contains more than 500 alerts")
	}
	result := make([]core.Signal, 0, len(payload.Alerts))
	for index, alert := range payload.Alerts {
		labels := mergeMaps(payload.CommonLabels, alert.Labels)
		annotations := mergeMaps(payload.CommonAnnotations, alert.Annotations)
		status, err := normalizeStatus(firstNonempty(alert.Status, payload.Status))
		if err != nil {
			return nil, fmt.Errorf("alert %d: %w", index, err)
		}
		title := firstNonempty(
			annotations["summary"], annotations["title"], labels["alertname"], payload.Title,
		)
		if strings.TrimSpace(title) == "" {
			return nil, fmt.Errorf("alert %d has no title", index)
		}
		sourceID := alert.Fingerprint
		if sourceID == "" {
			sourceID = stableDigest(route.Name, canonicalMap(labels), alert.StartsAt.UTC().Format(time.RFC3339Nano))
		}
		sourceURL := firstNonempty(alert.PanelURL, alert.DashboardURL, alert.GeneratorURL, payload.ExternalURL)
		if sourceURL != "" {
			if parsed, err := url.Parse(sourceURL); err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
				sourceURL = ""
			}
		}
		signal := core.Signal{
			Route:            route.Name,
			SourceID:         sourceID,
			SourceIncidentID: payload.GroupKey,
			EventID:          stableDigest(sourceID, string(status), alert.EndsAt.UTC().Format(time.RFC3339Nano), canonicalMap(annotations)),
			Repository:       route.Repository,
			Status:           status,
			Title:            trimBounded(title, 500),
			Severity:         trimBounded(firstNonempty(labels["severity"], labels["priority"], labels["level"]), 64),
			Summary:          trimBounded(firstNonempty(annotations["description"], annotations["message"], payload.Message), 4000),
			SourceURL:        trimBounded(sourceURL, 2000),
			Labels:           boundedMap(labels, 64),
			Annotations:      boundedMap(annotations, 64),
			StartsAt:         alert.StartsAt,
			EndsAt:           alert.EndsAt,
			ReceivedAt:       receivedAt.UTC(),
		}
		signal.CorrelationKey = correlationKey(route, signal)
		result = append(result, signal)
	}
	return result, nil
}

func normalizeGeneric(route config.Webhook, body []byte, receivedAt time.Time) ([]core.Signal, error) {
	var payload map[string]any
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode generic webhook: %w", err)
	}
	if err := requireEOF(dec); err != nil {
		return nil, err
	}
	eventID, err := requiredString(payload, route.Mapping.EventID)
	if err != nil {
		return nil, fmt.Errorf("mapping.event_id: %w", err)
	}
	rawStatus, err := requiredString(payload, route.Mapping.Status)
	if err != nil {
		return nil, fmt.Errorf("mapping.status: %w", err)
	}
	status, err := normalizeStatus(rawStatus)
	if err != nil {
		return nil, err
	}
	title, err := requiredString(payload, route.Mapping.Title)
	if err != nil {
		return nil, fmt.Errorf("mapping.title: %w", err)
	}
	incidentID, err := optionalString(payload, route.Mapping.IncidentID)
	if err != nil {
		return nil, fmt.Errorf("mapping.incident_id: %w", err)
	}
	severity, err := optionalString(payload, route.Mapping.Severity)
	if err != nil {
		return nil, fmt.Errorf("mapping.severity: %w", err)
	}
	summary, err := optionalString(payload, route.Mapping.Summary)
	if err != nil {
		return nil, fmt.Errorf("mapping.summary: %w", err)
	}
	sourceURLValue, err := optionalString(payload, route.Mapping.SourceURL)
	if err != nil {
		return nil, fmt.Errorf("mapping.source_url: %w", err)
	}
	sourceURL := validSourceURL(sourceURLValue)
	if sourceURLValue != "" && sourceURL == "" {
		return nil, errors.New("mapping.source_url: value must be an http or https URL")
	}
	labels, err := optionalMap(payload, route.Mapping.Labels)
	if err != nil {
		return nil, fmt.Errorf("mapping.labels: %w", err)
	}
	annotations, err := optionalMap(payload, route.Mapping.Annotations)
	if err != nil {
		return nil, fmt.Errorf("mapping.annotations: %w", err)
	}
	starts, err := optionalTime(payload, route.Mapping.StartsAt)
	if err != nil {
		return nil, fmt.Errorf("mapping.starts_at: %w", err)
	}
	ends, err := optionalTime(payload, route.Mapping.EndsAt)
	if err != nil {
		return nil, fmt.Errorf("mapping.ends_at: %w", err)
	}
	sourceID := firstNonempty(incidentID, eventID)
	signal := core.Signal{
		Route:            route.Name,
		SourceID:         stableDigest(route.Name, sourceID),
		SourceIncidentID: incidentID,
		EventID:          trimBounded(eventID, 500),
		Repository:       route.Repository,
		Status:           status,
		Title:            trimBounded(title, 500),
		Severity:         trimBounded(severity, 64),
		Summary:          trimBounded(summary, 4000),
		SourceURL:        sourceURL,
		Labels:           boundedMap(labels, 64),
		Annotations:      boundedMap(annotations, 64),
		StartsAt:         starts,
		EndsAt:           ends,
		ReceivedAt:       receivedAt.UTC(),
	}
	signal.CorrelationKey = correlationKey(route, signal)
	return []core.Signal{signal}, nil
}

func requireEOF(dec *json.Decoder) error {
	var extra any
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("webhook body contains more than one JSON value")
		}
		return fmt.Errorf("decode trailing webhook data: %w", err)
	}
	return nil
}

func normalizeStatus(value string) (core.SignalStatus, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "firing", "alerting", "active", "open", "triggered":
		return core.SignalFiring, nil
	case "resolved", "ok", "closed", "normal", "recovered":
		return core.SignalResolved, nil
	default:
		return "", fmt.Errorf("unsupported alert status %q", value)
	}
}

func correlationKey(route config.Webhook, signal core.Signal) string {
	if signal.SourceIncidentID != "" {
		return stableDigest(route.Name, route.Repository, "incident", signal.SourceIncidentID)
	}
	parts := []string{route.Name, route.Repository}
	found := false
	for _, label := range route.GroupByLabels {
		value := signal.Labels[label]
		if value != "" {
			found = true
		}
		parts = append(parts, label, value)
	}
	if !found {
		parts = append(parts, "source", signal.SourceID)
	}
	return stableDigest(parts...)
}

func stableDigest(parts ...string) string {
	digest := sha256.New()
	for _, part := range parts {
		digest.Write([]byte(strconv.Itoa(len(part))))
		digest.Write([]byte{':'})
		digest.Write([]byte(part))
	}
	return hex.EncodeToString(digest.Sum(nil))
}

func canonicalMap(values map[string]string) string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(strconv.Itoa(len(key)))
		builder.WriteByte(':')
		builder.WriteString(key)
		value := values[key]
		builder.WriteString(strconv.Itoa(len(value)))
		builder.WriteByte(':')
		builder.WriteString(value)
	}
	return builder.String()
}

func mergeMaps(first, second map[string]string) map[string]string {
	result := make(map[string]string, len(first)+len(second))
	for key, value := range first {
		result[key] = value
	}
	for key, value := range second {
		result[key] = value
	}
	return result
}

func boundedMap(values map[string]string, limit int) map[string]string {
	if len(values) == 0 {
		return nil
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if len(keys) > limit {
		keys = keys[:limit]
	}
	result := make(map[string]string, len(keys))
	for _, key := range keys {
		result[trimBounded(key, 128)] = trimBounded(values[key], 1000)
	}
	return result
}

func trimBounded(value string, limit int) string {
	value = strings.TrimSpace(strings.ReplaceAll(value, "\x00", ""))
	return core.TruncateUTF8(value, limit)
}

func firstNonempty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func lookup(payload map[string]any, path string) (any, bool) {
	if path == "" {
		return nil, false
	}
	var current any = payload
	for _, part := range strings.Split(path, ".") {
		object, ok := current.(map[string]any)
		if !ok {
			return nil, false
		}
		current, ok = object[part]
		if !ok {
			return nil, false
		}
	}
	return current, true
}

func requiredString(payload map[string]any, path string) (string, error) {
	value, ok := lookup(payload, path)
	if !ok {
		return "", errors.New("value is missing")
	}
	result, ok := scalarString(value)
	if !ok || strings.TrimSpace(result) == "" {
		return "", errors.New("value must be a nonempty scalar")
	}
	return result, nil
}

func optionalString(payload map[string]any, path string) (string, error) {
	if path == "" {
		return "", nil
	}
	value, ok := lookup(payload, path)
	if !ok || value == nil {
		return "", nil
	}
	result, ok := scalarString(value)
	if !ok {
		return "", errors.New("value must be a scalar")
	}
	return result, nil
}

func scalarString(value any) (string, bool) {
	switch typed := value.(type) {
	case string:
		return typed, true
	case json.Number:
		return typed.String(), true
	case bool:
		return strconv.FormatBool(typed), true
	default:
		return "", false
	}
}

func optionalMap(payload map[string]any, path string) (map[string]string, error) {
	if path == "" {
		return nil, nil
	}
	value, ok := lookup(payload, path)
	if !ok || value == nil {
		return nil, nil
	}
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("value must be an object")
	}
	result := make(map[string]string, len(raw))
	for key, value := range raw {
		scalar, ok := scalarString(value)
		if !ok {
			return nil, fmt.Errorf("object value %q must be a scalar", key)
		}
		result[key] = scalar
	}
	return result, nil
}

func optionalTime(payload map[string]any, path string) (time.Time, error) {
	value, err := optionalString(payload, path)
	if err != nil || value == "" {
		return time.Time{}, err
	}
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, errors.New("value must be RFC3339")
	}
	return parsed, nil
}

func validSourceURL(value string) string {
	if value == "" {
		return ""
	}
	parsed, err := url.Parse(value)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return ""
	}
	return trimBounded(value, 2000)
}
