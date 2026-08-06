package feedback

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestStoreRecordsDeduplicatesAndWithdrawsFeedback(t *testing.T) {
	stateDir := t.TempDir()
	store, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	item := Item{
		ID: "feedback-1", WorkspaceID: "T1", ChannelID: "C1", UserID: "U1",
		Source: "explicit_message", Category: "ux", Sentiment: "suggestion",
		Summary: "Show progress sooner", Details: "The reply looked stuck.",
		Context: []ContextMessage{{MessageTS: "1.0", Text: "It looks stuck"}},
	}
	if _, err := store.Record(context.Background(), item); err != nil {
		t.Fatal(err)
	}
	item.Summary = "Keep the progress indicator visible"
	if _, err := store.Record(context.Background(), item); err != nil {
		t.Fatal(err)
	}
	items, err := store.ListOpen(context.Background(), "T1", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Summary != item.Summary {
		t.Fatalf("items = %#v", items)
	}
	if err := store.Withdraw(context.Background(), item.ID); err != nil {
		t.Fatal(err)
	}
	items, err = store.ListOpen(context.Background(), "T1", 20)
	if err != nil || len(items) != 0 {
		t.Fatalf("items = %#v, err = %v", items, err)
	}
	if _, err := store.Record(context.Background(), item); err != nil {
		t.Fatal(err)
	}
	items, err = store.ListOpen(context.Background(), "T2", 20)
	if err != nil || len(items) != 0 {
		t.Fatalf("workspace isolation: items = %#v, err = %v", items, err)
	}
	if filepath.Base(filepath.Join(stateDir, "feedback.db")) != "feedback.db" {
		t.Fatal("unexpected feedback database path")
	}
	info, err := os.Stat(filepath.Join(stateDir, "feedback.db"))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("feedback database permissions = %o, want 600", got)
	}
}
