package service

import "github.com/AndrewDryga/responder/internal/slackui"

// unpacedSlack returns the Slack client behind the channel-write pacer.
//
// A few Slack capabilities are not on slackui.API and are reached by type
// assertion instead, so a caller degrades gracefully when the client cannot do
// it. The pacer is a wrapper, so asserting against it would find nothing and
// every one of those paths would silently turn itself off — reactions would
// stop, channel membership would stop reconciling, and each would look exactly
// like a client that does not support them.
//
// Looking past the pacer is safe precisely because of what is reachable this
// way. Reactions, a channel listing and a user's timezone are workspace-tier or
// read methods; none of them spends the per-channel message-posting budget the
// pacer meters. TestSlackOptionalCapabilitiesDoNotBypassPacing holds that line:
// a capability added here has to be named, which is the moment to ask whether
// it posts.
func unpacedSlack(api slackui.API) slackui.API {
	if wrapper, ok := api.(interface{ Unwrap() slackui.API }); ok {
		return wrapper.Unwrap()
	}
	return api
}
