package service

import (
	"context"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
)

// The two titles the same fix was offered under on 2026-08-16: the alert
// stream's wording and the 15:00 whole-platform review's. Both are real, and
// both mean "raise the VA1 Traefik memory cap".
const (
	streamOfferTitle  = "Traefik: raise VA1 ingress memory cap and add oversubscription headroom"
	reviewOfferTitle  = "Increase VA1 Traefik memory headroom"
	unrelatedFixTitle = "BunnyCDN: verify and implement staged hostname TLS"
	// A second alert, so a second stream, a second episode and a second thread.
	// It stays inside the same coverage layers as the checkout fixture — no
	// host, workload or scheduler words — because what is under test is the
	// second offer, not a differently shaped investigation.
	otherAlertText = "CRITICAL alert: ingress error rate is firing above 15 percent."
)

// Six identical Traefik offers on 2026-08-16, none accepted; the sixth came
// from the scheduled health review in another thread, which the episode-scoped
// check could not see.
//
// A4 walks the answers of ONE episode, and the offers that reached that channel
// came from six. A second button for work already on offer is not a second
// choice; it is the same choice, rendered again, beside a button that still
// works — and an operator reading the channel cannot tell which of the two is
// real.
func TestAnOfferOpenInAnotherThreadOfTheChannelIsPointedAtNotRepeated(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CCHANOFFER")
	svc.coop.(*fakeCoop).completeQueue = []string{
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), streamOfferTitle, "repo"),
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), reviewOfferTitle, "repo"),
	}

	first := base
	first.ID, first.EnvelopeID = "chan-offer-1", "env-chan-offer-1"
	first.EventID, first.MessageTS = "event-chan-offer-1", "1720.100"
	firstRun := answerStreamCard(t, svc, st, first)
	posted := alertReplyPosts(slackClient.posts)
	if len(posted) != 1 || !messageOffersEngineeringTask(posted[0].message) {
		t.Fatalf("the first offer did not render a button: %d answers", len(posted))
	}

	// Another alert, so another stream, so another episode and another thread —
	// which is exactly what the scheduled review was.
	second := base
	second.ID, second.EnvelopeID = "chan-offer-2", "env-chan-offer-2"
	second.EventID, second.MessageTS = "event-chan-offer-2", "1720.200"
	second.ReceivedAt = base.ReceivedAt.Add(31 * time.Minute)
	second.Text = otherAlertText
	secondRun := answerStreamCard(t, svc, st, second)
	if secondRun.EpisodeID == firstRun.EpisodeID {
		t.Fatalf(
			"both cards landed on episode %q, so this proves nothing about a second one",
			secondRun.EpisodeID,
		)
	}

	posted = alertReplyPosts(slackClient.posts)
	if len(posted) != 2 {
		t.Fatalf("the second alert was not answered: %d answers", len(posted))
	}
	repeat := posted[1].message
	if messageOffersEngineeringTask(repeat) {
		t.Fatalf("the same fix was offered twice in one channel: %+v", repeat.Actions)
	}
	pointer := strings.Join(repeat.Context, " ")
	if !strings.Contains(pointer, "Already offered") {
		t.Fatalf("the second reply does not point at the open offer: %q", pointer)
	}
	if !strings.Contains(pointer, streamOfferTitle) {
		t.Fatalf("the pointer does not name the task already on offer: %q", pointer)
	}
	// A pointer with no reachable message is worse than a second button: it
	// tells an operator the work is already offered somewhere and leaves them
	// to find it. It has to link the message that carries the live button.
	_, firstReplyTS := sentReplyLocation(t, cfg, first.ID)
	if !strings.Contains(pointer, "/thread/"+first.ChannelID+"-"+firstReplyTS) {
		t.Fatalf(
			"the pointer does not link the message holding the button (ts %s): %q",
			firstReplyTS, pointer,
		)
	}
	if outcomes := watchAuditOutcomes(t, cfg, second.ID); !slices.Contains(
		outcomes, "engineering_task_offer_repeated",
	) {
		t.Fatalf("the repeated offer is not on the trace: %v", outcomes)
	}
}

// The other half: work that is not the work already on offer still gets its own
// button, in the same channel and within the same window.
//
// Two of the day's real blitz-infra tasks — the Traefik cap raise and the
// BunnyCDN TLS staging — share a repository and nothing else. Suppressing the
// second would be worse than the repeat this changes: the repeat wasted a
// click, and this would lose the work.
func TestADifferentFixInTheSameRepositoryStillGetsItsOwnOffer(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, slackClient, svc, base := streamFixture(t, "CDIFFFIX")
	svc.coop.(*fakeCoop).completeQueue = []string{
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), reviewOfferTitle, "repo"),
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), unrelatedFixTitle, "repo"),
	}

	first := base
	first.ID, first.EnvelopeID = "diff-fix-1", "env-diff-fix-1"
	first.EventID, first.MessageTS = "event-diff-fix-1", "1721.100"
	answerStreamCard(t, svc, st, first)

	second := base
	second.ID, second.EnvelopeID = "diff-fix-2", "env-diff-fix-2"
	second.EventID, second.MessageTS = "event-diff-fix-2", "1721.200"
	second.ReceivedAt = base.ReceivedAt.Add(12 * time.Minute)
	second.Text = otherAlertText
	answerStreamCard(t, svc, st, second)

	posted := alertReplyPosts(slackClient.posts)
	if len(posted) != 2 {
		t.Fatalf("the second alert was not answered: %d answers", len(posted))
	}
	if !messageOffersEngineeringTask(posted[1].message) {
		t.Fatalf(
			"different work in the same repository lost its button: context %v",
			posted[1].message.Context,
		)
	}
}

// An offer somebody took up is not still on offer.
//
// "Already offered — open it" would send an operator to a button that now
// refuses the click, on a message whose task is already running. The channel
// answers "has this been offered" from its own reply records, so the check that
// it has not since been ACCEPTED is the half that record cannot hold, and it
// applies to another episode's offer exactly as it does to this one's.
func TestAnAcceptedOfferIsNotPointedAtAsStillOpen(t *testing.T) {
	ctx := context.Background()
	observedAt := time.Now().UTC().Format(time.RFC3339)
	cfg, st, slackClient, svc, base := streamFixture(t, "CACCEPTED")
	svc.coop.(*fakeCoop).completeQueue = []string{
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), streamOfferTitle, "repo"),
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), reviewOfferTitle, "repo"),
	}

	first := base
	first.ID, first.EnvelopeID = "accepted-1", "env-accepted-1"
	first.EventID, first.MessageTS = "event-accepted-1", "1723.100"
	answerStreamCard(t, svc, st, first)

	offerThreadTS, offerMessageTS := sentReplyLocation(t, cfg, first.ID)
	click := core.SlackInput{
		ID: "accepted-click", EnvelopeID: "env-accepted-click",
		EventID: "event-accepted-click", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: first.ChannelID, ThreadTS: offerThreadTS, MessageTS: offerMessageTS,
		UserID: "U123ABC", ActionID: slackui.ActionStartTask, ActionValue: first.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, click); err != nil || !created {
		t.Fatalf("admit the click = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 1 {
		t.Fatalf("the click started %d tasks: %v", len(incidents), err)
	}

	second := base
	second.ID, second.EnvelopeID = "accepted-2", "env-accepted-2"
	second.EventID, second.MessageTS = "event-accepted-2", "1723.200"
	second.ReceivedAt = base.ReceivedAt.Add(19 * time.Minute)
	second.Text = otherAlertText
	answerStreamCard(t, svc, st, second)

	posted := alertReplyPosts(slackClient.posts)
	if len(posted) != 2 {
		t.Fatalf("the second alert was not answered: %d answers", len(posted))
	}
	if !messageOffersEngineeringTask(posted[1].message) {
		t.Fatalf(
			"an accepted offer was pointed at as if it were still open: context %v",
			posted[1].message.Context,
		)
	}
}

// And a repository nobody has offered this fix in is a different offer, however
// alike the two titles read.
func TestADifferentRepositoryStillGetsItsOwnOffer(t *testing.T) {
	observedAt := time.Now().UTC().Format(time.RFC3339)
	_, st, slackClient, svc, base := streamFixtureOn(
		t, twoRepositoryConfig(t), "CDIFFREPO",
	)
	svc.coop.(*fakeCoop).completeQueue = []string{
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), streamOfferTitle, "repo"),
		withTaskOffer(t, confirmedAlertReplyResult(observedAt), reviewOfferTitle, "infra"),
	}

	first := base
	first.ID, first.EnvelopeID = "diff-repo-1", "env-diff-repo-1"
	first.EventID, first.MessageTS = "event-diff-repo-1", "1722.100"
	answerStreamCard(t, svc, st, first)

	second := base
	second.ID, second.EnvelopeID = "diff-repo-2", "env-diff-repo-2"
	second.EventID, second.MessageTS = "event-diff-repo-2", "1722.200"
	second.ReceivedAt = base.ReceivedAt.Add(12 * time.Minute)
	second.Text = otherAlertText
	answerStreamCard(t, svc, st, second)

	posted := alertReplyPosts(slackClient.posts)
	if len(posted) != 2 {
		t.Fatalf("the second alert was not answered: %d answers", len(posted))
	}
	if !messageOffersEngineeringTask(posted[1].message) {
		t.Fatalf(
			"the same fix in another repository lost its button: context %v",
			posted[1].message.Context,
		)
	}
}

// twoRepositoryConfig is the deployment shape this dedup has to survive: a
// channel whose alerts can be answered with work in either of two
// repositories.
func twoRepositoryConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := serviceConfig(t)
	infra := cfg.Repositories["repo"]
	infra.DisplayName = "Infrastructure"
	cfg.Repositories["infra"] = infra
	return cfg
}

// withTaskOffer puts one named engineering offer on a reply fixture, the way
// every alert reply of 2026-08-16 carried one.
func withTaskOffer(t *testing.T, body, title, repository string) string {
	t.Helper()
	body = rewriteFixture(t, body,
		`"dimensions":{"repository":"repo","environment":"production","revision":"current"}`,
		`"dimensions":{"repository":`+strconv.Quote(repository)+`,"environment":"production","revision":"current"}`,
	)
	return rewriteFixture(t, body,
		`{"id":"complete","type":"complete_episode"`,
		`{"id":"offer-fix","type":"offer_task","task":{"kind":"engineering","title":`+
			strconv.Quote(title)+`,"repository":`+strconv.Quote(repository)+
			`}},{"id":"complete","type":"complete_episode"`,
	)
}

// sentReplyLocation is where an answer actually landed — the thread it went
// into and the message that carries its button — read the way the pointer's
// permalink is built and the way a click is checked against the offer.
func sentReplyLocation(
	t *testing.T,
	cfg config.Config,
	sourceInputID string,
) (threadTS, messageTS string) {
	t.Helper()
	located := streamColumn(t, cfg, `
		SELECT thread_ts || ' ' || message_ts FROM slack_deliveries
		WHERE source_input_id = ? AND operation = 'post' AND response_root = 1
		  AND state = 'sent' AND message_ts != ''
		ORDER BY created_at DESC, id DESC LIMIT 1`, sourceInputID)
	if len(located) != 1 {
		t.Fatalf("input %s posted %d root answers", sourceInputID, len(located))
	}
	threadTS, messageTS, _ = strings.Cut(located[0], " ")
	return threadTS, messageTS
}
