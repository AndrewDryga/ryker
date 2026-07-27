# Slack experience

## Incident room

Each incident occurrence receives:

1. a deterministic channel named `inc-MMDD-title-incidentid`;
2. a concise topic with the incident identity;
3. invited configured responders;
4. one pinned root card;
5. one Coop session and isolated fork.

The root card always shows alert status, Responder workflow, severity, firing/total signals,
repository binding, last update, and any actionable error. It is updated in place.

All conversation happens as replies to that card. Agent tool output, hidden reasoning, token
streaming, and raw patches are not relayed. A completed turn produces one bounded response split
into readable Slack sections. Long output is truncated with a visible marker.

When enabled, Slack's native assistant thread status shows `Investigating` or `Waiting for input`.
The card remains the authoritative state if native status is unavailable.

## Manual summon

In a configured summon channel:

```text
@Responder investigate production checkout errors
```

The user must be an allowlisted full workspace member. Responder replies that the incident was
accepted, then creates the dedicated room using `slack.default_repository`. If the open-incident
limit is full, it replies in the summon thread with the action required instead of silently
dropping the request.

## Controls

Buttons on the card:

- **Get update** asks the agent for verified facts, hypothesis, changes, blockers, and next action.
- **Changes** reads Coop's typed fork summary. It does not paste raw patches into Slack.
- **Review fix** runs Coop's review gate and reports publishability and findings.
- **Stop turn** cancels only the active turn. The session, queue, and fork remain.
- **Extend budget** adds the configured turn allowance to support long-running collaboration.
- **Close incident** closes the Coop session and preserves the fork.
- **Controls** prints the command reference.

The exact whole-message command equivalents are:

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

Once a root card exists, incident failures are visible there. Failures before channel or root
creation remain visible through `responder status`, `responder failures`, metrics, and service
logs. Manual capacity rejection is also posted in the summon thread.

Active-session capacity puts an admitted incident into holding. The separate open-incident limit
rejects new occurrences before channel creation; webhook work remains retryable and manual summons
receive a direct explanation. Webhook admission remains durable during a temporary Slack or Coop
outage, while `/readyz` reports the disconnected dependency.

Closing is non-destructive. Responder never archives the channel, deletes the fork, or merges work.
