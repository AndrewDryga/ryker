# Slack experience

## Incident room

Each incident occurrence receives:

1. a deterministic channel named `inc-MMDD-title-incidentid`;
2. a concise topic with the incident identity;
3. invited configured responders;
4. one pinned root card;
5. one Coop session and isolated fork.

The root card is the authoritative incident snapshot. It shows:

- plain-language alert and Responder states;
- severity, firing/total signals, repository, lifecycle times, and isolated fork;
- the latest alert summary and a validated alert-source link with its hostname visible when supplied;
- a prominent action-needed section when work is blocked;
- only controls that are valid for the current lifecycle state.

The top-level fallback text carries the same essential status for notifications and screen readers.
Responder updates this message in place and alternates card writes with thread delivery so a busy
conversation cannot leave the pinned snapshot stale.

All conversation happens as replies to the card. Agent tool output, hidden reasoning, token
streaming, raw webhook refreshes, and raw patches are not relayed. Incoming alert changes update
the pinned card and are passed to the agent; completed turns, fork summaries, review evidence, and
failures have distinct headings. Long output is bounded and visibly truncated.

When enabled, Slack's native assistant status appears immediately after accepted operator input and
is refreshed during a long active turn. Slack clears it when the reply posts. Parked and blocked
state remains on the card rather than using a misleading persistent typing indicator.

## Manual summon

In a configured summon channel:

```text
@Responder investigate production checkout errors
```

The user must be an allowlisted full workspace member. Responder replies that the incident was
accepted, creates the dedicated room using `slack.default_repository`, then posts a durable
`Incident room ready` reply linking the new channel after configured responders are invited and the
topic and root pin are ready. If the open-incident limit is full, it replies in the summon thread
with the action required instead of silently dropping the request.

## Controls

Card buttons change with state rather than presenting actions that cannot succeed:

- provisioning or holding: **Close incident**;
- active turn: **Stop turn**, **View changes**, **Extend budget**;
- waiting for input: **Get update**, **View changes**, **Review fix**, **Close incident**;
- budget blocked: **Extend budget**, **View changes**, **Review fix**, **Close incident**;
- closed: read-only **View changes**, **Review fix**.

- **Get update** asks the agent for verified facts, hypothesis, changes, blockers, and next action.
- **View changes** reads Coop's typed fork summary. It does not paste raw patches into Slack.
- **Review fix** runs Coop's review gate and reports publishability and findings.
- **Stop turn** cancels only the active turn. The session, queue, and fork remain.
- **Extend budget** adds the configured turn allowance to support long-running collaboration.
- **Close incident** closes the Coop session and preserves the fork.
The exact whole-message command equivalents, including less-common budget and help controls, are:

```text
!respond status
!respond update
!respond changes
!respond review
!respond stop
!respond extend
!respond close
!respond help
```

Natural-language approximations do not execute controls. A message such as “maybe stop after this”
is an operator turn, not a cancellation.

## Authorization

Workspace membership is not authorization. Responder requires both:

- the Slack user ID is listed in `slack.operators`;
- Slack reports a current full member in `slack.team_id`.

Bots, app users, deleted users, guests, restricted users, strangers, and external Slack Connect
members cannot steer a session. Foreign-source channel events are dropped before persistence.
Denied actions are audited and receive a short explanation in the incident thread when possible.

Buttons are also bound to the incident ID, channel, and root message timestamp. Stale or copied
controls are rejected.

## Failure behavior

Once a root card exists, incident failures are visible there and in accessible fallback text. A
failed or cancelled turn posts a concise thread message explaining what stopped, that the fork and
evidence remain, and how to continue. Failures before channel or root creation remain visible
through `responder status`, `responder failures`, metrics, and service logs. Manual capacity
rejection is also posted in the summon thread.

Active-session capacity puts an admitted incident into holding. The separate open-incident limit
rejects new occurrences before channel creation; webhook work remains retryable and manual summons
receive a direct explanation. Webhook admission remains durable during a temporary Slack or Coop
outage, while `/readyz` reports the disconnected dependency.

Closing is non-destructive. Responder never archives the channel, deletes the fork, or merges work.
