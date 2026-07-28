# Slack app

Responder uses a self-hosted Slack app over Socket Mode. The shipped manifest is complete for the
features the runtime implements: app presentation, bot identity, App Home state, bot scopes, event
subscriptions, the `/responder` command, interactive controls, hosting mode, organization
deployment, Slack MCP, incoming webhooks, and token rotation.

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
   `responder.yaml`. Invite Responder to every configured summon and watch channel.
7. Run `responder bootstrap-coop`, authenticate the configured Coop policy targets, then run
   `responder doctor`. Start `responder serve` only after doctor passes.

When updating an existing app, apply the new manifest. Reinstall when Slack reports that the
updated manifest adds an OAuth scope. The Agent experience adds `assistant:write` and `im:history`,
plus App Home and direct-message events. The `/responder` command, message shortcut, interactive
controls, and subscribed events are delivered over Socket Mode and do not need a public request
URL. The shipped manifest uses Slack's current `agent_view`; applying it to an older
`assistant_view` app performs Slack's irreversible Messages-tab migration.

Slack displays only the manifest's static slash-command usage hint; it does not ask the app for
dynamic subcommand completions. Keep the hint short. Responder provides the full command guide and
read-only discovery buttons after `/responder` or `/responder help`, including a paginated incident
directory with native Slack channel mentions. `/responder turn-limit` reports or changes the
automatic session safety ceiling; detailed arguments remain in the interactive guide because Slack
does not provide app-defined subcommand autocomplete.

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
classified as ignore or threaded reply; a reply can offer an operator-confirmed incident without
creating it. Credible unresolved external-app alerts and explicit human incident requests can create
an incident directly. Static defaults come from `slack.watch_channels`; `/responder proactive`
stores workspace or channel overrides. Current-state questions can use policy-authorized read-only
Emisar investigation before that decision. Slack sends mentioned messages through both event
subscriptions, so Responder admits only `app_mention` for messages containing its bot mention.

The Messages tab is an Agent surface with host-owned suggested prompts and native progress
indicators. Direct messages always start read-only triage even when normal-channel proactive mode
is off. The **Investigate message** shortcut does the same for one selected message.
App Home summarizes current incidents, active sessions, and failed durable work. These surfaces do
not weaken operator authorization or incident-creation rules.

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
| App name | Emisar Responder |
| Short description | Emisar's AI SRE First Responder |
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
