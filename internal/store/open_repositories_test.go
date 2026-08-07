package store

import (
	"context"
	"path/filepath"
	"testing"
)

// Every constructor must produce a usable store.
//
// This exists because one did not. The extracted repositories were wired in
// Open only, so every command that opens read-only — record-episode,
// correction-rate, promote-fixtures, audit-result-protocol — received a store
// with nil Memory, Intelligence, Behavior and Schedules. record-episode did not
// fail cleanly either: it sat at zero CPU until it was killed, which reads as a
// slow database rather than a nil pointer.
//
// Nothing caught it because no test opened a database read-only and then used a
// repository. Checking the fields are non-nil is not enough — a nil repository
// with a nil db would satisfy that — so each one is actually called.
func TestEveryConstructorWiresTheRepositories(t *testing.T) {
	ctx := context.Background()
	dir := filepath.Join(t.TempDir(), "state")
	migrated := openAt(t, dir)
	migrated.Close()

	for _, tc := range []struct {
		name string
		open func() (*Store, error)
	}{
		{"Open", func() (*Store, error) { return Open(dir) }},
		{"OpenCurrent", func() (*Store, error) { return OpenCurrent(dir) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st, err := tc.open()
			if err != nil {
				t.Fatalf("%s: %v", tc.name, err)
			}
			defer st.Close()

			// Checked before calling, because an unwired repository does not
			// fail cleanly: the call hangs at zero CPU rather than panicking,
			// which is how this reached production looking like a slow query.
			// The nil check turns that into a legible failure; the calls below
			// still prove the handle behind each field actually works.
			for name, wired := range map[string]bool{
				"Intelligence": st.Intelligence != nil,
				"Memory":       st.Memory != nil,
				"Behavior":     st.Behavior != nil,
				"Schedules":    st.Schedules != nil,
			} {
				if !wired {
					t.Fatalf("%s left store.%s nil", tc.name, name)
				}
			}
			if _, err := st.Intelligence.ListEpisodeEvidence(ctx, "episode_absent", 10); err != nil {
				t.Fatalf("Intelligence unusable after %s: %v", tc.name, err)
			}
			if _, err := st.Memory.ListMemoryForContext(
				ctx, "T1", "C1", "repo", "U1", 10,
			); err != nil {
				t.Fatalf("Memory unusable after %s: %v", tc.name, err)
			}
			if _, err := st.Behavior.ListPreferencesForContext(
				ctx, "T1", "C1", "repo", "U1", true, 10,
			); err != nil {
				t.Fatalf("Behavior unusable after %s: %v", tc.name, err)
			}
			if _, err := st.Schedules.ListScheduledTasksForChannel(ctx, "C1", 10); err != nil {
				t.Fatalf("Schedules unusable after %s: %v", tc.name, err)
			}
		})
	}
}
