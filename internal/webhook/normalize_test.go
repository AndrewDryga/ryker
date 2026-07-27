package webhook

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

func TestNormalizeGrafanaCorrelatesRelatedAlerts(t *testing.T) {
	route := config.Webhook{
		Name: "grafana", Kind: "grafana", Repository: "infra",
		GroupByLabels: []string{"cluster", "service"},
	}
	body := []byte(`{
	  "status":"firing",
	  "groupKey":"{}:{cluster=\"va1\",service=\"api\"}",
	  "commonLabels":{"cluster":"va1","service":"api","severity":"critical"},
	  "alerts":[
	    {"status":"firing","labels":{"alertname":"HighErrors"},"annotations":{"summary":"API error rate"},"startsAt":"2026-07-27T01:00:00Z","fingerprint":"abc"},
	    {"status":"firing","labels":{"alertname":"Readiness"},"annotations":{"summary":"API readiness"},"startsAt":"2026-07-27T01:01:00Z","fingerprint":"def"}
	  ]
	}`)
	signals, err := Normalize(route, body, time.Date(2026, 7, 27, 1, 2, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if len(signals) != 2 || signals[0].CorrelationKey != signals[1].CorrelationKey {
		t.Fatalf("signals were not correlated: %+v", signals)
	}
	if signals[0].Status != core.SignalFiring || signals[0].Severity != "critical" {
		t.Fatalf("signal = %+v", signals[0])
	}
}

func TestNormalizeGrafanaResolvedKeepsSignalIdentity(t *testing.T) {
	route := config.Webhook{Name: "grafana", Kind: "grafana", Repository: "infra"}
	firing := []byte(`{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Disk"},"annotations":{"summary":"Disk full"},"startsAt":"2026-07-27T01:00:00Z","fingerprint":"same"}]}`)
	resolved := []byte(`{"status":"resolved","alerts":[{"status":"resolved","labels":{"alertname":"Disk"},"annotations":{"summary":"Disk full"},"startsAt":"2026-07-27T01:00:00Z","endsAt":"2026-07-27T01:10:00Z","fingerprint":"same"}]}`)
	first, err := Normalize(route, firing, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	second, err := Normalize(route, resolved, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if first[0].SourceID != second[0].SourceID || second[0].Status != core.SignalResolved {
		t.Fatalf("identity changed: %+v %+v", first[0], second[0])
	}
}

func TestNormalizeGenericUsesOnlyConfiguredFields(t *testing.T) {
	route := config.Webhook{
		Name: "custom", Kind: "generic", Repository: "app", GroupByLabels: []string{"service"},
		Mapping: config.GenericMapping{
			EventID: "event.id", IncidentID: "incident.id", Status: "incident.state",
			Title: "incident.title", Severity: "incident.severity", Summary: "message",
			Labels: "labels", SourceURL: "incident.url",
		},
	}
	body := []byte(`{"event":{"id":"evt-1"},"incident":{"id":"upstream-7","state":"open","title":"Checkout unavailable","severity":"p1","url":"https://status.example/i/7"},"message":"timeouts","labels":{"service":"checkout"},"ignored":{"secret":"no"}}`)
	signals, err := Normalize(route, body, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(signals) != 1 || signals[0].SourceIncidentID != "upstream-7" ||
		signals[0].Title != "Checkout unavailable" || signals[0].Summary != "timeouts" {
		t.Fatalf("signal = %+v", signals)
	}
}

func TestNormalizeGenericRejectsMappedObjectsAndUnsafeURLs(t *testing.T) {
	route := config.Webhook{
		Name: "custom", Kind: "generic", Repository: "app",
		Mapping: config.GenericMapping{
			EventID: "event.id", Status: "incident.status", Title: "incident.title",
			Summary: "incident.summary", SourceURL: "incident.url",
		},
	}
	for name, body := range map[string]string{
		"object summary": `{"event":{"id":"1"},"incident":{"status":"firing","title":"x","summary":{"raw":"x"}}}`,
		"unsafe URL":     `{"event":{"id":"1"},"incident":{"status":"firing","title":"x","url":"file:///etc/passwd"}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Normalize(route, []byte(body), time.Now()); err == nil {
				t.Fatal("invalid mapped value was accepted")
			}
		})
	}
}

func TestVerifyBearerAndHMAC(t *testing.T) {
	now := time.Unix(1785130000, 0)
	bearer := config.Webhook{Auth: "bearer"}
	header := http.Header{"Authorization": {"Bearer secret"}}
	if err := Verify(bearer, header, nil, "secret", now); err != nil {
		t.Fatal(err)
	}
	header.Set("Authorization", "Bearer wrong")
	if err := Verify(bearer, header, nil, "secret", now); err == nil {
		t.Fatal("wrong bearer accepted")
	}

	body := []byte(`{"ok":true}`)
	stamp := strconv.FormatInt(now.Unix(), 10)
	deliveryID := "delivery-1"
	mac := hmac.New(sha256.New, []byte("hook-secret"))
	mac.Write([]byte(stamp + "." + deliveryID + "."))
	mac.Write(body)
	hmacHeader := http.Header{
		"X-Responder-Timestamp": {stamp},
		"X-Responder-Signature": {"sha256=" + hex.EncodeToString(mac.Sum(nil))},
	}
	hmacHeader.Set("X-Responder-Event-ID", deliveryID)
	if err := Verify(config.Webhook{Auth: "hmac-sha256"}, hmacHeader, body, "hook-secret", now); err != nil {
		t.Fatal(err)
	}
	if err := Verify(config.Webhook{Auth: "hmac-sha256"}, hmacHeader, body, "hook-secret", now.Add(10*time.Minute)); err == nil {
		t.Fatal("stale HMAC accepted")
	}
	hmacHeader.Set("X-Responder-Event-ID", "delivery-2")
	if err := Verify(config.Webhook{Auth: "hmac-sha256"}, hmacHeader, body, "hook-secret", now); err == nil {
		t.Fatal("unsigned delivery ID change accepted")
	}
}

func TestNormalizeRejectsUnknownStatusAndMultipleDocuments(t *testing.T) {
	route := config.Webhook{
		Name: "custom", Kind: "generic", Repository: "app",
		Mapping: config.GenericMapping{EventID: "id", Status: "status", Title: "title"},
	}
	if _, err := Normalize(route, []byte(`{"id":"1","status":"maybe","title":"x"}`), time.Now()); err == nil {
		t.Fatal("unknown status accepted")
	}
	if _, err := Normalize(route, []byte(`{"id":"1","status":"open","title":"x"} {}`), time.Now()); err == nil {
		t.Fatal("multiple values accepted")
	}
}
