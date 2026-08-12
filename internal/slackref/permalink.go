// Package slackref parses Slack-owned message references without performing
// network access or making authorization decisions.
package slackref

import (
	"html"
	"net/url"
	"regexp"
	"strings"
)

var (
	slackURLPattern       = regexp.MustCompile(`https://[^<>\s|]+`)
	slackChannelIDPattern = regexp.MustCompile(`^[CG][A-Z0-9]+$`)
	slackTimestampPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+$`)
)

type Reference struct {
	Host      string
	ChannelID string
	ThreadTS  string
	MessageTS string
}

// Parse extracts the stable coordinates from Slack's archive link. The
// visible link label is deliberately ignored: it is untrusted text, while the
// path and query are the coordinates Slack itself resolves.
func Parse(text string) (Reference, bool) {
	text = html.UnescapeString(text)
	for _, raw := range slackURLPattern.FindAllString(text, -1) {
		parsed, err := url.Parse(raw)
		if err != nil || !strings.HasSuffix(strings.ToLower(parsed.Hostname()), ".slack.com") {
			continue
		}
		parts := strings.Split(strings.Trim(parsed.EscapedPath(), "/"), "/")
		if len(parts) != 3 || parts[0] != "archives" ||
			!slackChannelIDPattern.MatchString(parts[1]) ||
			!strings.HasPrefix(parts[2], "p") {
			continue
		}
		messageTS, ok := pathTimestamp(strings.TrimPrefix(parts[2], "p"))
		if !ok {
			continue
		}
		query := parsed.Query()
		if cid := query.Get("cid"); cid != "" && cid != parts[1] {
			continue
		}
		threadTS := query.Get("thread_ts")
		if threadTS == "" {
			threadTS = messageTS
		} else if !slackTimestampPattern.MatchString(threadTS) {
			continue
		}
		return Reference{
			Host:      strings.ToLower(parsed.Hostname()),
			ChannelID: parts[1], ThreadTS: threadTS, MessageTS: messageTS,
		}, true
	}
	return Reference{}, false
}

func pathTimestamp(value string) (string, bool) {
	if len(value) <= 6 {
		return "", false
	}
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return "", false
		}
	}
	return value[:len(value)-6] + "." + value[len(value)-6:], true
}
