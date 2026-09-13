package scheduleoffer

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/decision"
)

func TestScheduleActionPayloadRoundTrip(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name    string
		ids     []string
		version int
	}{
		{name: "one proposal keeps the existing payload", ids: []string{"proposal-1"}, version: 2},
		{name: "several proposals use the batch payload", ids: []string{"proposal-1", "proposal-2"}, version: 3},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			encoded, err := EncodeAction(test.ids)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			ids, version, err := DecodeAction(encoded)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if version != test.version || !reflect.DeepEqual(ids, test.ids) {
				t.Fatalf("decoded version=%d ids=%v, want version=%d ids=%v", version, ids, test.version, test.ids)
			}
		})
	}
}

func TestScheduleActionPayloadRejectsInvalidBatches(t *testing.T) {
	t.Parallel()
	tooMany := make([]string, decision.MaxScheduleOffers+1)
	for index := range tooMany {
		tooMany[index] = fmt.Sprintf("proposal-%d", index)
	}
	for _, ids := range [][]string{nil, {""}, {"proposal-1", "proposal-1"}, tooMany} {
		if _, err := EncodeAction(ids); err == nil {
			t.Fatalf("EncodeAction(%v) succeeded", ids)
		}
	}
	for _, payload := range []string{
		`{"version":3,"proposal_ids":["proposal-1"]}`,
		`{"version":3,"proposal_ids":["proposal-1","proposal-1"]}`,
		`{"version":2,"proposal_id":"proposal-1","unexpected":true}`,
	} {
		if _, _, err := DecodeAction(payload); err == nil {
			t.Fatalf("DecodeAction(%s) succeeded", payload)
		}
	}
}

func TestTaskFromOfferNormalizesSharedContext(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.August, 11, 12, 0, 0, 0, time.UTC)
	task, err := TaskFromOffer(core.ScheduleOffer{
		Title: "  Check Zot logs  ", Prompt: "  Verify Zot has no credential failures.  ",
		Repository: " BLITZ-INFRA ", Recurrence: " ONCE ", StartAt: "2026-08-12T15:00:00Z",
		Timezone: " America/Merida ", ExpiresIn: "7d",
	}, TaskContext{TeamID: "T1", ChannelID: "C1", ThreadTS: "123.456", ActorID: "U1", SourceRef: "event-1", Now: now})
	if err != nil {
		t.Fatalf("TaskFromOffer: %v", err)
	}
	if task.Title != "Check Zot logs" || task.Prompt != "Verify Zot has no credential failures." ||
		task.Repository != "blitz-infra" || task.DeliveryChannel != "C1" || task.Recurrence != "once" ||
		task.Timezone != "America/Merida" || task.CatchUp != "latest" {
		t.Fatalf("task was not normalized: %#v", task)
	}
	if want := time.Date(2026, time.August, 12, 15, 0, 0, 0, time.UTC); !task.StartAt.Equal(want) || !task.NextRunAt.Equal(want) {
		t.Fatalf("start=%s next=%s, want %s", task.StartAt, task.NextRunAt, want)
	}
	if want := now.Add(7 * 24 * time.Hour); !task.ExpiresAt.Equal(want) {
		t.Fatalf("expires=%s, want %s", task.ExpiresAt, want)
	}
}

func TestSameDefinitionUsesEffectiveDeliveryChannel(t *testing.T) {
	t.Parallel()
	left := core.ScheduledTask{ChannelID: "C1", Repository: "blitz-infra", Recurrence: "once", Timezone: "America/Merida"}
	right := left
	right.DeliveryChannel = "C1"
	if !SameDefinition(left, right) {
		t.Fatal("same effective delivery channel should match")
	}
	right.Timezone = "UTC"
	if SameDefinition(left, right) {
		t.Fatal("different timezone should not match")
	}
}
