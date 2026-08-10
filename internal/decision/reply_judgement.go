package decision

import "strings"

// What a quality judge is told about a reply before it is asked anything.
//
// The judge was blind to both of the complaints an operator actually filed this
// week. It reads the reply as a rendered Slack message, and that struct carries
// no thread and no channel, so "it was posted in the channel itself and I can't
// even tell why" was not merely missed — it was unrepresentable. And its
// directness criterion asked whether the reply "matches the requested depth",
// which is a taste; "extremely long and watery" is a measurement. This package
// already makes that measurement, against 246 real replies, and a judge that
// re-estimates length by eye is a second opinion. Two bars that disagree are
// worse than one bar, so the numbers below are the runtime's own.

// ReplyJudgement is everything the host can establish about a posted reply
// without a model: how long it ran against the bound its trigger earned,
// whether it ends by handing the question back, and where it landed against
// where it belonged.
type ReplyJudgement struct {
	// Words is the prose a reader has to read — fenced code and table rows
	// excluded, because those are scanned for a value rather than read.
	Words int `json:"reply_words"`
	// WordBound is the ladder's answer for this trigger and lane, and 0 when
	// the trigger asked for depth and waived it.
	WordBound      int  `json:"word_bound,omitempty"`
	OverWordBound  bool `json:"over_word_bound,omitempty"`
	DepthRequested bool `json:"depth_requested,omitempty"`
	// ClosingHandBack is the measured phrase the last substantive sentence ends
	// on, or "" when the closing is a finding.
	ClosingHandBack string `json:"closing_hand_back,omitempty"`
	// PostedIn and AskedFor are "thread", "channel", or "" when unknown. Both
	// are absent from the judge's material when unknown, so a fixture that does
	// not model delivery says nothing about it rather than implying a channel.
	PostedIn   string `json:"posted_in,omitempty"`
	AskedFor   string `json:"operator_asked_for,omitempty"`
	WrongPlace bool   `json:"posted_in_the_wrong_place,omitempty"`
}

// MeasureReply scores a reply with the same functions the runtime enforces, so
// a judge reading the result agrees with the host by construction rather than
// by luck.
//
// postedIn is where the reply actually went; askedFor is where it belonged.
// Either may be "" when the caller does not know. An empty askedFor falls back
// to reading the trigger, because an operator who wrote "reply in thread" has
// already said it once and no fixture should have to say it again.
func MeasureReply(trigger, lane, reply, postedIn, askedFor string) ReplyJudgement {
	reply = strings.TrimSpace(reply)
	result := ReplyJudgement{
		Words:          ProseWordCount(reply),
		WordBound:      ReplyWordBudget(trigger, lane),
		DepthRequested: RequestedDepth(trigger),
		PostedIn:       replyPlacement(postedIn),
		AskedFor:       replyPlacement(askedFor),
	}
	result.OverWordBound = result.WordBound > 0 && result.Words > result.WordBound
	// The same floor the correction applies: below it a caveat is the second
	// half of a two-sentence finding rather than a reply trailing off.
	if result.Words > handBackFloor {
		result.ClosingHandBack = HandBackClosing(reply)
	}
	if result.AskedFor == "" {
		result.AskedFor = ConversationLocationName(RequestedConversationLocation(trigger))
	}
	result.WrongPlace = result.PostedIn != "" && result.AskedFor != "" &&
		result.PostedIn != result.AskedFor
	return result
}

// ConversationLocationName renders a requested location as the word a prompt
// and a fixture both spell the same way.
func ConversationLocationName(location ConversationLocation) string {
	switch location {
	case ConversationLocationThread:
		return "thread"
	case ConversationLocationChannel:
		return "channel"
	default:
		return ""
	}
}

// ValidReplyPlacement reports whether a fixture's placement names somewhere a
// Slack reply can actually land.
//
// "" is allowed and means the fixture does not model delivery. Anything else
// has to be one of the two real destinations, because a misspelled "threaded"
// would read as unknown, the case would quietly stop asserting where the reply
// went, and it would keep passing while proving nothing.
func ValidReplyPlacement(value string) bool {
	return value == "" || value == "thread" || value == "channel"
}

func replyPlacement(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "thread" || value == "channel" {
		return value
	}
	return ""
}
