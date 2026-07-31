# Emisar Slack app

The Responder service powers the self-hosted **Emisar** Slack app over Socket Mode. Slack users see
the app and bot as `Emisar` and mention it as `@Emisar`; the existing `/responder` command remains
the stable administrative control surface. The shipped manifest is complete for the features the
runtime implements: app presentation, bot identity, App Home state, bot scopes, event
subscriptions, interactive controls, hosting mode, organization deployment, Slack MCP, incoming
webhooks, and token rotation.

## Create the app

1. Open [Slack app management](https://api.slack.com/apps), choose **Create New App**, then
   **From an app manifest**.
2. Select the dedicated workspace, paste `deploy/slack-app-manifest.yaml`, review it, and create
   the app. Slack validates the manifest before applying it.
3. On **Basic Information**, upload `deploy/slack-app-icon.png` as the app icon. Slack's manifest
   schema does not expose an icon field, so this is a separate one-time setting.
4. Under **App-Level Tokens**, generate a token with `connections:write`. Store the resulting
   `xapp-` token as `SLACK_APP_TOKEN`.
5. Install the app to the workspace and store its `xoxb-` token as `SLACK_BOT_TOKEN`.
6. Put the workspace, operator, invite-user, summon-channel, and watch-channel IDs into
   `responder.yaml`. Invite `@Emisar` to every configured summon and watch channel.
7. Run `responder bootstrap-coop`, authenticate the configured Coop policy targets, then run
   `responder doctor`. Start `responder serve` only after doctor passes.

When updating an existing app, apply the new manifest. This changes the app and bot display names
to `Emisar`; it does not rename the `/responder` command or any durable internal identifiers.
Reinstall when Slack reports that the updated manifest adds an OAuth scope. The Agent experience
adds `assistant:write` and `im:history`, while conversational channel setup uses
bounded `conversations.list` membership reconciliation and `usergroups:read` to validate and expand
explicitly selected incident audiences. Lightweight acknowledgements use `reactions:write`;
`reactions:read` plus the `reaction_added` and `reaction_removed` events let Emisar understand
feedback on its own messages in later conversation turns. Reaction events never start work or
authorize an action by themselves.
Screenshot and document analysis uses `files:read`; after adding that scope, reinstall the app
before running `responder doctor`. The command, message shortcut, interactive controls, and
subscribed events are delivered over Socket Mode and do not need a public request URL. The shipped
manifest uses Slack's current `agent_view`; applying it to an older `assistant_view` app performs
Slack's irreversible Messages-tab migration.

Slack messages may include up to four bounded Slack-hosted files per turn. Responder supports PNG,
JPEG, WebP, and GIF screenshots; UTF-8 text, Markdown, CSV, JSON, and YAML; and PDF documents.
Defaults cap each file and the whole turn at 8 MiB. The ordered worker downloads a private Slack
URL with the bot token, verifies the Slack host, declared type, detected content, size, and SHA-256
digest, and submits a typed read-only artifact to Coop. Private URLs and bytes never enter model
prompts, Slack output, compact summaries, or long-term memory. Responder retains only bounded
Slack metadata under normal operational-data retention; Coop removes the binary payload when the
turn becomes terminal. Unsupported or misleading content fails closed with a user-visible retry
message and does not start repository work.

Slack displays only the manifest's static slash-command usage hint; it does not ask the app for
dynamic subcommand completions. Keep the hint short. Responder provides the full command guide and
read-only discovery buttons after `/responder` or `/responder help`, including a paginated incident
directory with native Slack channel mentions. `/responder turn-limit` reports or changes the
automatic session safety ceiling; detailed arguments remain in the interactive guide because Slack
does not provide app-defined subcommand autocomplete.

Inviting `@Emisar` to a channel first offers safe mention-only and proactive defaults plus a
**Customize** path. Customize starts a four-question setup conversation. A configured operator chooses
mention-only, proactive, or shadow participation; a configured repository; app-alert escalation;
and the incident audience. Answers may be replies in the setup thread or top-level messages from
the setup initiator while the 30-minute session is active. The final card shows the normalized
typed configuration and safety boundary. No setting changes until an operator selects **Save
configuration**. Slack user mentions are membership-checked, user groups are resolved through
Slack, and action payloads contain only the stored setup ID.

The conversational surface is primary. Operators can ask `@Emisar how are you configured here?`,
`show open incidents`, `show preferences`, `enable proactive mode`, or `reconfigure this channel`.
The host maps supported phrases to the same deterministic handlers used by `/responder`; the slash
command remains a compatibility and recovery surface rather than a second configuration system.

The icon is the 512 by 512 Emisar mark on its native `#0A0B0D` background. Its SHA-256 checksum is:

```text
ba84d1bc32f415feac4f916384075d29180f02010efbd66694b2f60c31574661
```

Do not add additional scopes, event subscriptions, commands, shortcuts, App Home tabs, or Slack
agent surfaces speculatively. Slack reviews must be able to exercise every requested capability,
and `responder doctor` treats the scope list in the manifest as the runtime contract.

The `message.channels` and `message.groups` subscriptions let Responder participate throughout a
created incident room and triage configured operational feeds. Configured incident operators do not
need to mention the bot in incident rooms. Human messages in effectively proactive channels are
classified as ignore or a reply that follows the human's channel or thread location; a reply can
offer an operator-confirmed incident without creating it. Credible unresolved external-app alerts
and explicit human incident requests can create an incident directly. Static defaults come from
`slack.watch_channels`; `/responder proactive`
stores workspace or channel overrides. Current-state questions can use policy-authorized read-only
Emisar investigation before that decision. Slack sends mentioned messages through both event
subscriptions, so Responder admits only `app_mention` for messages containing its bot mention.

Operators can ask Responder to remember only typed behavior. A supported preference changes
investigation depth or response detail; a supported standing rule subscribes one channel to
read-only Terraform-plan review, deployment verification, or alert triage. Responder first renders
the normalized behavior, scope, expiry, source filter, and safety boundary for confirmation.
`/responder preferences` and `/responder rules` provide state-aware management. Matching rules can
operate when broad proactive triage is off, but always reply in the source thread and never create
an incident or authorize a mutation. Intermediate HCP Terraform `Run Planning` cards remain silent;
review starts only from a planned/saved update or explicit plan output, and requires exact plan
evidence rather than an inferred repository diff.

The Messages tab is an Agent surface with host-owned suggested prompts and native progress
indicators. Direct messages always start read-only triage even when normal-channel proactive mode
is off. The **Investigate message** shortcut does the same for one selected message.
App Home summarizes current incidents, active sessions, failed durable work, current channel
situations, and the commitments Emisar owes the team. `/responder work` exposes the same active
commitments. These surfaces do not weaken operator authorization or incident-creation rules.

An explicit repository-change request can return a **Start engineering task** confirmation.
Approval by a configured full-member operator starts an engineering task in the source Slack thread
and creates an isolated writable Coop fork; the rest of the shared channel remains read-only. The
task path can edit, test, and commit repository files under Coop policy, but cannot merge, push,
deploy, sign, or mutate infrastructure. Replies in that thread continue the same task without an
`@mention`.

The public and private channel archive, unarchive, and deletion subscriptions keep incident-room
lifecycle state durable. Responder blocks an open incident when its room is archived or deleted,
preserves the channel identity, Coop session, fork, and audit history, and stops attempting Slack
delivery. Unarchiving restores the room. A periodic `conversations.info` check repairs missed archive
events; `channel_not_found` is recorded as unavailable rather than treated as proof of deletion.

## Production profile

The current app is production-ready for a dedicated, single-workspace deployment or a controlled
unlisted pilot. Its public support facts are:

| Field | Value |
| --- | --- |
| App name | Emisar |
| Bot display name | Emisar |
| Short description | AI SRE first responder for evidence-backed investigation and governed operations |
| Support | https://emisar.dev/support |
| Support email | support@emisar.dev |
| Privacy policy | https://emisar.dev/privacy |
| Security | https://emisar.dev/security |
| Pricing | https://emisar.dev/pricing |
| Language | English |

Keep Slack tokens in the service's secret environment, never in the manifest or repository. Add at
least one Slack app collaborator, use a separate development app and workspace, and exercise
installation, mention replies, explicit incident requests, incident-offer controls, restart
recovery, and uninstallation before a production rollout.

## Marketplace boundary

The current app must not be submitted to the public Slack Marketplace. Slack does not accept
Socket Mode apps in the Marketplace and requires HTTP request URLs for published apps. Responder
also intentionally has one configured workspace and static operator-managed tokens; it does not
yet implement a public OAuth installation and onboarding lifecycle.

Complete these items before adding an `app_directory` section to the manifest:

1. Add HTTPS endpoints for Events API and interactive payloads, including Slack signing-secret
   verification, timestamp replay protection, fast acknowledgement, durable processing, and
   idempotency. Disable Socket Mode after production HTTP delivery is proven.
2. Add OAuth v2 installation with `state` verification, per-workspace encrypted token storage,
   installation updates, revocation and uninstall handling, and a multi-workspace tenancy model.
3. Publish a Responder-specific installation landing page and post-install onboarding path. The
   existing Emisar home page is not a substitute for an app installation page.
4. Add the manifest `app_directory` fields only when their landing, privacy, support, language,
   pricing, and optional direct-install URLs are live and accurate.
5. Prepare production Slack screenshots at 1600 by 1000 pixels, scope-by-scope justifications,
   AI model and data-retention disclosures, reviewer instructions, and external-workspace install
   evidence required by Slack.

References:

- [Slack app manifest reference](https://docs.slack.dev/reference/app-manifest/)
- [Slack Socket Mode requirements](https://docs.slack.dev/apis/events-api/using-socket-mode/)
- [Slack HTTP and Socket Mode comparison](https://docs.slack.dev/apis/events-api/comparing-http-socket-mode/)
- [Slack Marketplace guidelines](https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements/)
