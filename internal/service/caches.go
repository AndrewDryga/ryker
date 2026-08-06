package service

import (
	"strings"
	"sync"
	"time"

	"github.com/AndrewDryga/responder/internal/slackui"
)

// The service keeps three pieces of process-local state. Each one is a real
// cache or rate limiter rather than durable truth: losing it on restart costs
// an extra Slack read or an extra status write, never correctness. Keeping them
// in dedicated types with their own locks means the service struct no longer
// mixes durable dependencies with mutable coordination state, and each can be
// tested — and later replaced with a durable projection — on its own.

const (
	slackWriteInterval  = 1100 * time.Millisecond
	slackHistoryTTL     = 5 * time.Minute
	slackHistoryEntries = 256
	nativeStatusRepeat  = time.Minute
)

type cachedSlackHistory struct {
	messages  []slackui.HistoryMessage
	expiresAt time.Time
}

// slackHistoryCache bounds repeated channel reads while an episode assembles
// context. Entries are copied in and out so a caller cannot mutate a cached
// slice that another goroutine is reading.
type slackHistoryCache struct {
	mu      sync.Mutex
	entries map[string]cachedSlackHistory
}

func newSlackHistoryCache() *slackHistoryCache {
	return &slackHistoryCache{entries: make(map[string]cachedSlackHistory)}
}

func (c *slackHistoryCache) get(key string, now time.Time) ([]slackui.HistoryMessage, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cached, ok := c.entries[key]
	if !ok {
		return nil, false
	}
	if !now.Before(cached.expiresAt) {
		delete(c.entries, key)
		return nil, false
	}
	return append([]slackui.HistoryMessage(nil), cached.messages...), true
}

func (c *slackHistoryCache) put(
	key string,
	messages []slackui.HistoryMessage,
	now time.Time,
) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.entries) >= slackHistoryEntries {
		for cacheKey, item := range c.entries {
			if now.After(item.expiresAt) {
				delete(c.entries, cacheKey)
			}
		}
		if len(c.entries) >= slackHistoryEntries {
			for cacheKey := range c.entries {
				delete(c.entries, cacheKey)
				break
			}
		}
	}
	c.entries[key] = cachedSlackHistory{
		messages:  append([]slackui.HistoryMessage(nil), messages...),
		expiresAt: now.Add(slackHistoryTTL),
	}
}

// invalidateChannel drops every entry for a channel whose content just changed.
func (c *slackHistoryCache) invalidateChannel(channelID string) {
	if channelID == "" {
		return
	}
	prefix := channelID + "\x00"
	c.mu.Lock()
	defer c.mu.Unlock()
	for key := range c.entries {
		if strings.HasPrefix(key, prefix) {
			delete(c.entries, key)
		}
	}
}

type nativeStatusState struct {
	text string
	at   time.Time
}

// nativeStatusTracker suppresses repeated identical Slack agent-status writes.
// It is advisory: the durable per-thread generation in the delivery ledger, not
// this map, is what keeps a late stale write from replacing a newer clear.
type nativeStatusTracker struct {
	mu    sync.Mutex
	state map[string]nativeStatusState
}

func newNativeStatusTracker() *nativeStatusTracker {
	return &nativeStatusTracker{state: make(map[string]nativeStatusState)}
}

// shouldWrite reports whether status differs from what was last written for
// key, or whether the repeat interval has elapsed.
func (t *nativeStatusTracker) shouldWrite(key, status string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	previous, ok := t.state[key]
	return !ok || previous.text != status || now.Sub(previous.at) >= nativeStatusRepeat
}

func (t *nativeStatusTracker) record(key, status string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.state[key] = nativeStatusState{text: status, at: now}
}

// forgetIncident drops every thread tracked for an incident that is closing.
func (t *nativeStatusTracker) forgetIncident(incidentID string) {
	prefix := incidentID + "@"
	t.mu.Lock()
	defer t.mu.Unlock()
	for key := range t.state {
		if strings.HasPrefix(key, prefix) {
			delete(t.state, key)
		}
	}
}

// writeSlot is the single conservative Slack write slot. Holding it across the
// Slack call is deliberate: Slack rate limits per workspace, so one in-flight
// write at a time is simpler and safer than a token bucket that can burst.
type writeSlot struct {
	mu       sync.Mutex
	interval time.Duration
	last     time.Time
}

func newWriteSlot(interval time.Duration) *writeSlot {
	return &writeSlot{interval: interval}
}

// acquire takes the slot. It returns the remaining cooldown and false when the
// slot is not yet available, having already released it, so the caller can
// defer its scheduler item rather than block a worker.
func (w *writeSlot) acquire(now time.Time) (time.Duration, bool) {
	w.mu.Lock()
	if wait := w.interval - now.Sub(w.last); wait > 0 {
		w.mu.Unlock()
		return wait, false
	}
	return 0, true
}

func (w *writeSlot) release(now time.Time) {
	w.last = now
	w.mu.Unlock()
}

// Test accessors. The production paths deliberately expose only the decisions
// (shouldWrite/record/clear); tests need to inspect and age the state directly.

func (t *nativeStatusTracker) textFor(key string) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	state, ok := t.state[key]
	return state.text, ok
}

func (t *nativeStatusTracker) age(key string, d time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if state, ok := t.state[key]; ok {
		state.at = state.at.Add(-d)
		t.state[key] = state
	}
}

// reset makes the slot immediately available.
func (w *writeSlot) reset() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.last = time.Time{}
}
