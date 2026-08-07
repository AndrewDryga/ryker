// Package localstate holds the service's process-local coordination state.
//
// None of it is durable truth. Losing any of it on restart costs an extra
// Slack read or an extra status write, never correctness: the durable delivery
// ledger and its per-thread generations are what actually order Slack output.
// Keeping these here means the service struct carries its durable dependencies
// and this package carries the mutable coordination, each piece with its own
// lock and its own tests.
package localstate

import (
	"strings"
	"sync"
	"sync/atomic"
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
	SlackWriteInterval = 1100 * time.Millisecond
	historyTTL         = 5 * time.Minute
	historyEntries     = 256
	statusRepeat       = time.Minute
)

type cachedSlackHistory struct {
	messages  []slackui.HistoryMessage
	expiresAt time.Time
}

// SlackHistoryCache bounds repeated channel reads while an episode assembles
// context. Entries are copied in and out so a caller cannot mutate a cached
// slice that another goroutine is reading.
type SlackHistoryCache struct {
	mu      sync.Mutex
	entries map[string]cachedSlackHistory
}

func NewSlackHistoryCache() *SlackHistoryCache {
	return &SlackHistoryCache{entries: make(map[string]cachedSlackHistory)}
}

func (c *SlackHistoryCache) Get(key string, now time.Time) ([]slackui.HistoryMessage, bool) {
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

func (c *SlackHistoryCache) Put(
	key string,
	messages []slackui.HistoryMessage,
	now time.Time,
) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.entries) >= historyEntries {
		for cacheKey, item := range c.entries {
			if now.After(item.expiresAt) {
				delete(c.entries, cacheKey)
			}
		}
		if len(c.entries) >= historyEntries {
			for cacheKey := range c.entries {
				delete(c.entries, cacheKey)
				break
			}
		}
	}
	c.entries[key] = cachedSlackHistory{
		messages:  append([]slackui.HistoryMessage(nil), messages...),
		expiresAt: now.Add(historyTTL),
	}
}

// InvalidateChannel drops every entry for a channel whose content just changed.
func (c *SlackHistoryCache) InvalidateChannel(channelID string) {
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

// NativeStatusTracker suppresses repeated identical Slack agent-status writes.
// It is advisory: the durable per-thread generation in the delivery ledger, not
// this map, is what keeps a late stale write from replacing a newer clear.
type NativeStatusTracker struct {
	mu    sync.Mutex
	state map[string]nativeStatusState
}

func NewNativeStatusTracker() *NativeStatusTracker {
	return &NativeStatusTracker{state: make(map[string]nativeStatusState)}
}

// ShouldWrite reports whether status differs from what was last written for
// key, or whether the repeat interval has elapsed.
func (t *NativeStatusTracker) ShouldWrite(key, status string, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	previous, ok := t.state[key]
	return !ok || previous.text != status || now.Sub(previous.at) >= statusRepeat
}

func (t *NativeStatusTracker) Record(key, status string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.state[key] = nativeStatusState{text: status, at: now}
}

// ForgetIncident drops every thread tracked for an incident that is closing.
func (t *NativeStatusTracker) ForgetIncident(incidentID string) {
	prefix := incidentID + "@"
	t.mu.Lock()
	defer t.mu.Unlock()
	for key := range t.state {
		if strings.HasPrefix(key, prefix) {
			delete(t.state, key)
		}
	}
}

// WriteSlot is the single conservative Slack write slot. Holding it across the
// Slack call is deliberate: Slack rate limits per workspace, so one in-flight
// write at a time is simpler and safer than a token bucket that can burst.
type WriteSlot struct {
	mu       sync.Mutex
	interval time.Duration
	last     time.Time
}

func NewWriteSlot(interval time.Duration) *WriteSlot {
	return &WriteSlot{interval: interval}
}

// Acquire takes the slot. It returns the remaining cooldown and false when the
// slot is not yet available, having already released it, so the caller can
// defer its scheduler item rather than block a worker.
func (w *WriteSlot) Acquire(now time.Time) (time.Duration, bool) {
	w.mu.Lock()
	if wait := w.interval - now.Sub(w.last); wait > 0 {
		w.mu.Unlock()
		return wait, false
	}
	return 0, true
}

func (w *WriteSlot) Release(now time.Time) {
	w.last = now
	w.mu.Unlock()
}

// Test accessors. The production paths deliberately expose only the decisions
// (shouldWrite/record/clear); tests need to inspect and age the state directly.

func (t *NativeStatusTracker) TextFor(key string) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	state, ok := t.state[key]
	return state.text, ok
}

func (t *NativeStatusTracker) Age(key string, d time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if state, ok := t.state[key]; ok {
		state.at = state.at.Add(-d)
		t.state[key] = state
	}
}

// Reset makes the slot immediately available.
func (w *WriteSlot) Reset() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.last = time.Time{}
}

// PromptTruncation counts prompts the Coop transport had to elide and the
// largest prompt composed. Elision cuts the middle out of a prompt, so it can
// slice through structured context: this is a correctness signal, not a
// statistic, and it is process-local because the durable record of what the
// model actually saw is the context manifest, not this counter.
type PromptTruncation struct {
	total    atomic.Uint64
	maxBytes atomic.Uint64
}

// Record notes one elided prompt of originalBytes.
func (p *PromptTruncation) Record(originalBytes int) {
	p.total.Add(1)
	for {
		current := p.maxBytes.Load()
		if uint64(originalBytes) <= current ||
			p.maxBytes.CompareAndSwap(current, uint64(originalBytes)) {
			return
		}
	}
}

// Snapshot reports the count and the largest prompt seen.
func (p *PromptTruncation) Snapshot() (total, maxBytes uint64) {
	return p.total.Load(), p.maxBytes.Load()
}
