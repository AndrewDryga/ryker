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
	"sort"
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

// ChannelWriteSlots paces Slack writes per channel.
//
// Slack rate-limits chat.postMessage per channel, so one busy incident room
// should not hold up an answer in an unrelated conversation. Each channel gets
// its own interval, and Cooling reports which ones are not ready so the
// scheduler can pick different work rather than wait.
type ChannelWriteSlots struct {
	mu       sync.Mutex
	interval time.Duration
	last     map[string]time.Time
}

func NewChannelWriteSlots(interval time.Duration) *ChannelWriteSlots {
	return &ChannelWriteSlots{interval: interval, last: map[string]time.Time{}}
}

// Cooling lists the channels whose interval has not elapsed. It also drops
// entries that are no longer cooling, so an abandoned channel cannot leak.
func (c *ChannelWriteSlots) Cooling(now time.Time) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var cooling []string
	for channelID, at := range c.last {
		if now.Sub(at) < c.interval {
			cooling = append(cooling, channelID)
			continue
		}
		delete(c.last, channelID)
	}
	sort.Strings(cooling)
	return cooling
}

// Record notes that a channel was just written to.
func (c *ChannelWriteSlots) Record(channelID string, now time.Time) {
	if channelID == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.last[channelID] = now
}

// NextReopen reports how long until the earliest channel is writable again, or
// zero when one already is.
func (c *ChannelWriteSlots) NextReopen(now time.Time) time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	soonest := time.Duration(0)
	for _, at := range c.last {
		if remaining := c.interval - now.Sub(at); remaining > 0 {
			if soonest == 0 || remaining < soonest {
				soonest = remaining
			}
		}
	}
	return soonest
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

// Test accessors. The production paths expose only the decisions
// (ShouldWrite/Record/ForgetIncident); tests need to inspect and age the state.

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

// Reset makes every channel immediately writable. It exists for tests.
func (c *ChannelWriteSlots) Reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.last)
}
