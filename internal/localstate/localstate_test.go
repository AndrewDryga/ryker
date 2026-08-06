package localstate

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/slackui"
)

var base = time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)

func TestSlackHistoryCacheExpiresAndCopies(t *testing.T) {
	cache := NewSlackHistoryCache()
	messages := []slackui.HistoryMessage{{Text: "first"}}
	cache.Put("C1\x00thread", messages, base)

	cached, ok := cache.Get("C1\x00thread", base.Add(time.Minute))
	if !ok || len(cached) != 1 || cached[0].Text != "first" {
		t.Fatalf("cached = %+v ok=%v", cached, ok)
	}
	// A caller must not be able to mutate what another caller will read.
	cached[0].Text = "mutated"
	again, _ := cache.Get("C1\x00thread", base.Add(time.Minute))
	if again[0].Text != "first" {
		t.Fatalf("cache returned an aliased slice: %+v", again)
	}
	// Mutating the slice that was stored must not change the cache either.
	messages[0].Text = "also mutated"
	stored, _ := cache.Get("C1\x00thread", base.Add(time.Minute))
	if stored[0].Text != "first" {
		t.Fatalf("cache aliased the slice it was given: %+v", stored)
	}
	if _, ok := cache.Get("C1\x00thread", base.Add(historyTTL)); ok {
		t.Fatal("entry survived its TTL")
	}
}

func TestSlackHistoryCacheInvalidatesOneChannel(t *testing.T) {
	cache := NewSlackHistoryCache()
	cache.Put("C1\x00a", []slackui.HistoryMessage{{Text: "one"}}, base)
	cache.Put("C2\x00a", []slackui.HistoryMessage{{Text: "two"}}, base)
	cache.InvalidateChannel("C1")
	if _, ok := cache.Get("C1\x00a", base); ok {
		t.Fatal("invalidated channel still cached")
	}
	if _, ok := cache.Get("C2\x00a", base); !ok {
		t.Fatal("unrelated channel was invalidated")
	}
}

func TestSlackHistoryCacheStaysBounded(t *testing.T) {
	cache := NewSlackHistoryCache()
	for index := range historyEntries * 2 {
		cache.Put(string(rune(index))+"\x00k", []slackui.HistoryMessage{{Text: "x"}}, base)
	}
	if got := len(cache.entries); got > historyEntries {
		t.Fatalf("cache grew to %d entries, over its %d bound", got, historyEntries)
	}
}

func TestNativeStatusTrackerSuppressesRepeatsUntilTheInterval(t *testing.T) {
	tracker := NewNativeStatusTracker()
	if !tracker.ShouldWrite("inc@1", "investigating", base) {
		t.Fatal("first status should be written")
	}
	tracker.Record("inc@1", "investigating", base)
	if tracker.ShouldWrite("inc@1", "investigating", base.Add(time.Second)) {
		t.Fatal("identical status inside the interval should be suppressed")
	}
	if !tracker.ShouldWrite("inc@1", "verifying", base.Add(time.Second)) {
		t.Fatal("a changed status should always be written")
	}
	if !tracker.ShouldWrite("inc@1", "investigating", base.Add(statusRepeat)) {
		t.Fatal("status should refresh once the repeat interval elapses")
	}
	tracker.ForgetIncident("inc")
	if _, ok := tracker.TextFor("inc@1"); ok {
		t.Fatal("forgetting an incident left its threads behind")
	}
}

func TestWriteSlotPacesAndReleases(t *testing.T) {
	slot := NewWriteSlot(time.Second)
	if _, ok := slot.Acquire(base); !ok {
		t.Fatal("a fresh slot should be available")
	}
	slot.Release(base)

	wait, ok := slot.Acquire(base.Add(400 * time.Millisecond))
	if ok {
		t.Fatal("slot was available inside its interval")
	}
	if wait != 600*time.Millisecond {
		t.Fatalf("wait = %v, want 600ms", wait)
	}
	if _, ok := slot.Acquire(base.Add(time.Second)); !ok {
		t.Fatal("slot did not reopen after its interval")
	}
	slot.Release(base.Add(time.Second))
}
