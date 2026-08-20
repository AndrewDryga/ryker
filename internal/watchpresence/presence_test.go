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
	// A configured workflow used to turn its acknowledgement into an automatic
	// check mark on ordinary teammate messages. Host presence belongs only to
	// app cards; the model's explicit react action remains the social path for a
	// human message.
	if got := Acknowledgement("message", "white_check_mark"); got != "" {
		t.Fatalf("configured human message acknowledgement = %q", got)
	}
	if got := Acknowledgement("mention", "eyes"); got != "" {
		t.Fatalf("configured mention acknowledgement = %q", got)
	}
	if !LeavesHandledMark(true, false, "reply") ||
		!LeavesHandledMark(true, false, "ignore") ||
		LeavesHandledMark(true, false, "react") ||
		LeavesHandledMark(true, true, "reply") {
		t.Fatal("terminal presence policy does not preserve one unambiguous mark")
	}
}
