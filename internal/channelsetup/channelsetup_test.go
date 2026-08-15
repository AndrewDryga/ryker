package channelsetup

import "testing"

// The wizard opens for somebody who asked it to, and for nobody else.
//
// The table that used to live here mapped phrasings onto slash subcommands and
// ran on every plain channel message an operator sent; it is gone, and the one
// sentence still read from free text carries the guard that keeps it from
// growing back. Somebody can say "we should reconfigure this channel next
// sprint" to a colleague, and the same words in a mention mean the opposite
// thing, so the words alone are never enough.
func TestAnUnaddressedSentenceNeverOpensTheChannelWizard(t *testing.T) {
	asks := []string{
		"configure this channel",
		"please reconfigure this channel for me",
		"set up this channel",
		"setup this channel",
	}
	for _, text := range asks {
		if !ExplicitChannelConfigurationRequest(text, true) {
			t.Errorf("ExplicitChannelConfigurationRequest(%q, addressed) = false", text)
		}
		if ExplicitChannelConfigurationRequest(text, false) {
			t.Errorf(
				"%q opened the wizard without being addressed to Responder", text,
			)
		}
	}

	// Ordinary conversation must not be mistaken for a request, even when it is
	// addressed. Responder is in these channels to talk.
	for _, text := range []string{
		"", "can you look at the deploy", "the proactive approach worked well",
		"shadow traffic is on the new cluster, ignore it",
		"we should close the loop on this", "any idea why checkout is slow",
	} {
		if ExplicitChannelConfigurationRequest(text, true) {
			t.Errorf("%q was read as a request to configure the channel", text)
		}
	}
}
