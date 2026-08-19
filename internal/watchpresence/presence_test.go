package watchpresence

import "testing"

func TestWatchedAppPresenceDoesNotDependOnAStandingRule(t *testing.T) {
	if got := Acknowledgement("bot_message", ""); got != Working {
		t.Fatalf("default app acknowledgement = %q", got)
	}
	if got := Acknowledgement("bot_message", "mag"); got != "mag" {
		t.Fatalf("custom acknowledgement = %q", got)
	}
	if got := Acknowledgement("message", ""); got != "" {
		t.Fatalf("human message acknowledgement = %q", got)
	}
	if !LeavesHandledMark(true, false, "reply") ||
		!LeavesHandledMark(true, false, "ignore") ||
		LeavesHandledMark(true, false, "react") ||
		LeavesHandledMark(true, true, "reply") {
		t.Fatal("terminal presence policy does not preserve one unambiguous mark")
	}
}
