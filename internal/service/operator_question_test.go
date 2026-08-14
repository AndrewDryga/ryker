package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// A question the model asked with two choices, in the shape production sends
// it: the operation carries the choices, and the completion is blocked on the
// answer. Harvested from run_36fbd8f0391f996cdd3cc3468e27eea3, which asked
// whether to discard a legacy plan or confirm it.
const askedWithChoices = `{
	"action":"reply",
	"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
	"operations":[
		{"id":"operator-decision","type":"request_operator_input","operator_input":{"question":"Should this legacy production website plan be discarded, or is there a specific reason to update the zero-sized instance group?","choices":["Discard the run","Confirm the run"]}},
		{"id":"complete-review","type":"complete_episode","completion":{"message":"The plan targets an instance group with no instances.","completion":{"status":"blocked","summary":"The plan needs an operator decision.","material_gaps":["operator decision"],"blocker_kind":"operator_input_required","attempts":["Read the plan and the group's size."],"next_action":"Say whether to discard the run."}}}
	]
}`

// askedEpisode is one episode parked on a question, with the buttons its card
// offered and everything a test needs to press one.
type askedEpisode struct {
	svc     *Service
	store   *store.Store
	cfg     config.Config
	slack   *fakeSlack
	episode core.WorkEpisode
	buttons []slackui.Action
}

func askQuestion(t *testing.T, ctx context.Context) askedEpisode {
	t.Helper()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = askedWithChoices
	slack := &fakeSlack{}
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	question := core.SlackInput{
		ID: "slack-question", EnvelopeID: "env-question", EventID: "EvQuestion",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@U999BOT> Apply the plan for the production website.",
	}
	if created, err := st.AdmitSlackInput(ctx, question); err != nil || !created {
		t.Fatalf("admit question = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", question.ID)
	if err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil || episode.State != core.EpisodeWaitingOperator {
		t.Fatalf("episode after a blocked question = %+v, %v", episode, err)
	}

	var buttons []slackui.Action
	for _, post := range slack.posts {
		for _, row := range post.message.Rows {
			for _, action := range row.Actions {
				if action.ID == slackui.ActionOperatorChoice {
					buttons = append(buttons, action)
				}
			}
		}
	}
	if len(buttons) != 2 {
		t.Fatalf("the card offered %d choice buttons, want 2: %+v", len(buttons), slack.posts)
	}
	return askedEpisode{
		svc: svc, store: st, cfg: cfg, slack: slack,
		episode: episode, buttons: buttons,
	}
}

// press builds the interaction Slack sends when a choice button is clicked and
// runs it, along with whatever the press queued behind it.
func (asked askedEpisode) press(
	t *testing.T,
	ctx context.Context,
	button slackui.Action,
	id string,
	userID string,
) {
	t.Helper()
	click := core.SlackInput{
		ID: id, EnvelopeID: "env-" + id, EventID: "interaction:" + id,
		Kind: "action", TeamID: asked.cfg.Slack.TeamID, ChannelID: "CWATCH",
		// The card is the first thing fakeSlack posted, so this is the
		// timestamp its delivery recorded.
		MessageTS: "1700.001", ThreadTS: asked.episode.Destination.ThreadTS,
		UserID:   userID,
		ActionID: slackui.ActionOperatorChoice, ActionValue: button.Value,
	}
	if created, err := asked.store.AdmitSlackInput(ctx, click); err != nil || !created {
		t.Fatalf("admit press = %t, %v", created, err)
	}
	// The press, then the answer it synthesized, which is an ordinary input
	// and takes the ordinary path.
	for range 2 {
		if err := asked.svc.processSlackInput(ctx); err != nil &&
			!strings.Contains(err.Error(), "not found") {
			t.Fatal(err)
		}
	}
	drainSlackDeliveries(t, ctx, asked.svc)
}

func (asked askedEpisode) latestAttempt(t *testing.T, ctx context.Context) core.EpisodeAttempt {
	t.Helper()
	episode, err := asked.store.GetWorkEpisode(ctx, asked.episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	attempt, err := asked.store.GetEpisodeAttempt(ctx, episode.LatestAttemptID)
	if err != nil {
		t.Fatal(err)
	}
	return attempt
}

// Pressing a choice answers the question the same way typing it would have.
//
// The whole design rests on this: the button is an accelerator over the reply
// the operator would otherwise type, so it lands on the same episode, through
// the same waiting_operator resume path, carrying the same words. A press that
// started fresh work instead would silently abandon what the blocked attempt
// had already established — its evidence, its goals, and the question itself.
func TestAPressedChoiceResumesTheEpisodeTheTypedAnswerWouldHave(t *testing.T) {
	ctx := context.Background()
	asked := askQuestion(t, ctx)
	before := len(asked.slack.posts)

	asked.press(t, ctx, asked.buttons[0], "slack-press", "U123ABC")

	attempt := asked.latestAttempt(t, ctx)
	if attempt.Number != 2 {
		t.Fatalf("the press produced attempt %d, want the episode's second", attempt.Number)
	}
	resumed, err := asked.store.GetAgentRun(ctx, attempt.AgentRunID)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.EpisodeID != asked.episode.ID {
		t.Fatalf("the press ran episode %q instead of %q", resumed.EpisodeID, asked.episode.ID)
	}
	// The answer the resumed attempt was given is the text that was on the
	// button. Anything else attributes words to the operator they never read.
	answered, err := asked.store.GetSlackInput(ctx, resumed.SourceID)
	if err != nil {
		t.Fatal(err)
	}
	if answered.Text != "Discard the run" || answered.UserID != "U123ABC" {
		t.Fatalf("the answer reached the model as %q from %q",
			answered.Text, answered.UserID)
	}
	// And the thread says so, because a transcript where a decision was taken
	// and nothing was said is a transcript nobody can audit.
	said := ""
	for _, post := range asked.slack.posts[before:] {
		said += post.message.Text + " " + strings.Join(post.message.Sections, " ")
	}
	if !strings.Contains(said, "Discard the run") {
		t.Errorf("the thread never records what was answered: %q", said)
	}
}

// A press is made in somebody else's name, so only theirs counts.
//
// Typing an answer says who said it. A press says only that a control was
// clicked, and the host is what turns it into "U123ABC answered Discard the
// run" — so a bystander's click would put words in the mouth of the person the
// question was asked of, on a card whose choices are "Discard the run" and
// "Confirm the run". Anyone may still answer by typing, which is exactly the
// freedom this refusal leaves alone.
func TestOnlyTheAskedOperatorsPressAnswersTheQuestion(t *testing.T) {
	ctx := context.Background()
	asked := askQuestion(t, ctx)

	asked.press(t, ctx, asked.buttons[0], "slack-press-bystander", "U456DEF")

	still, err := asked.store.GetWorkEpisode(ctx, asked.episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if still.State != core.EpisodeWaitingOperator {
		t.Fatalf("a bystander's press answered the question: episode is %+v", still)
	}
	if attempt := asked.latestAttempt(t, ctx); attempt.Number != 1 {
		t.Fatalf("a bystander's press started attempt %d", attempt.Number)
	}
	outcomes := auditOutcomes(t, asked.cfg, "slack.operator_choice", "")
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "denied") {
		t.Fatalf("audit trail for the refused press = %v", outcomes)
	}
	// And the person who pressed it is told, privately. A button that visibly
	// does nothing is read as a broken button, and the next thing that happens
	// is somebody pressing it again.
	if len(asked.slack.ephemerals) != 1 ||
		asked.slack.ephemerals[0].user != "U456DEF" ||
		!strings.Contains(asked.slack.ephemerals[0].message.Sections[0], "asked of someone else") {
		t.Fatalf("the refused press was answered with %+v", asked.slack.ephemerals)
	}
}

// The second press on an answered question changes nothing.
//
// Slack leaves the buttons on the card after the first press — nothing takes
// them away — so a second click is not a mistake, it is what the surface
// invites. Admitting it would queue a second attempt against an episode already
// running one, carrying the opposite answer: "Confirm the run" arriving behind
// "Discard the run" on a plan that touches production.
func TestASecondPressOnAnAnsweredQuestionChangesNothing(t *testing.T) {
	ctx := context.Background()
	asked := askQuestion(t, ctx)

	asked.press(t, ctx, asked.buttons[0], "slack-press-first", "U123ABC")
	asked.press(t, ctx, asked.buttons[1], "slack-press-second", "U123ABC")

	if attempt := asked.latestAttempt(t, ctx); attempt.Number != 2 {
		t.Fatalf("two presses produced attempt %d, want one answer and one attempt",
			attempt.Number)
	}
	outcomes := auditOutcomes(t, asked.cfg, "slack.operator_choice", "")
	if len(outcomes) != 2 || !strings.HasPrefix(outcomes[0], "answered") ||
		!strings.HasPrefix(outcomes[1], "already_answered") {
		t.Fatalf("audit trail for two presses = %v", outcomes)
	}
}

// The answer has to be one the card actually offered.
//
// The press carries the answer text, which is what keeps the button and the
// words attributed to the operator identical — and it is why the value cannot
// be taken on trust. A well-formed value naming the right episode and the right
// person, but text no card ever showed, would otherwise be spoken in that
// person's name. The delivered message is the record of what was offered, so
// that is what the press is checked against.
func TestAnAnswerTheCardNeverOfferedIsRefused(t *testing.T) {
	ctx := context.Background()
	asked := askQuestion(t, ctx)

	forged := asked.buttons[0]
	forged.Value = slackui.EncodeOperatorChoice(slackui.OperatorChoice{
		EpisodeID: asked.episode.ID, AskedUser: "U123ABC", Question: 0,
		Answer: "Delete the instance group",
	})
	asked.press(t, ctx, forged, "slack-press-forged", "U123ABC")

	still, err := asked.store.GetWorkEpisode(ctx, asked.episode.ID)
	if err != nil {
		t.Fatal(err)
	}
	if still.State != core.EpisodeWaitingOperator {
		t.Fatalf("an answer nobody was offered resumed the work: %+v", still)
	}
	outcomes := auditOutcomes(t, asked.cfg, "slack.operator_choice", "")
	if len(outcomes) != 1 || !strings.HasPrefix(outcomes[0], "invalid") {
		t.Fatalf("audit trail for the unoffered answer = %v", outcomes)
	}
}

// An old card's button cannot answer the question that replaced it.
//
// Nothing removes the buttons from an answered card, and the work parks on a
// new question a minute later — the model is told to ask up to three, one round
// at a time. Scrolling back and pressing "Discard the run" on the card above
// would then be read as an answer to whatever is being asked now, because the
// press carries a question index and indexes restart at zero every asking. The
// press has to be refused for what it is: an answer already given, on a card
// that has been superseded.
func TestAPressFromASupersededCardCannotAnswerTheNextQuestion(t *testing.T) {
	ctx := context.Background()
	asked := askQuestion(t, ctx)
	asked.press(t, ctx, asked.buttons[0], "slack-press-first", "U123ABC")

	// The resumed attempt asks again, so the episode is waiting once more —
	// on a different question, with a card of its own.
	answered := asked.latestAttempt(t, ctx)
	if err := asked.store.SetWorkEpisodePhase(
		ctx, answered.AgentRunID, core.EpisodeWaitingOperator, "waiting_for_operator",
		"Waiting for your answer", "Which zone should the spare go in?", time.Time{},
	); err != nil {
		t.Fatal(err)
	}

	asked.press(t, ctx, asked.buttons[0], "slack-press-stale", "U123ABC")

	if attempt := asked.latestAttempt(t, ctx); attempt.Number != 2 {
		t.Fatalf("a press on the superseded card started attempt %d", attempt.Number)
	}
	outcomes := auditOutcomes(t, asked.cfg, "slack.operator_choice", "")
	if len(outcomes) != 2 || !strings.HasPrefix(outcomes[1], "already_answered") {
		t.Fatalf("audit trail for the stale press = %v", outcomes)
	}
}
