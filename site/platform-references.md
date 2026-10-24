# Platform UI references

The homepage keeps Slack and GitHub recognizable through their marks, message structure, composer, pull request tabs, reviews, and diffs. Following the 2026-10-23 refinement, workspace navigation, search, and unrelated controls are removed, and both surfaces share Ryker's graphite, ivory, and mint palette. `assets/platform-ui.css` is restricted to the two application scopes.

- Slack layout and composer: https://slack.com/help/articles/360059928654-How-to-use-Slack--your-quick-start-guide/
- Slack threads: https://slack.com/help/articles/115000769927-Use-threads-to-organize-discussions--Use-threads-to-organize-discussions--
- Slack's supplied mark, unmodified: https://a.slack-edge.com/9cc0056/marketing/img/nav/logo.svg
- GitHub pull request layout: https://github.blog/changelog/2026-01-22-improved-pull-request-files-changed-page-on-by-default/
- GitHub mark, unmodified: https://github.com/primer/octicons/blob/main/icons/mark-github-24.svg
- Octicons license is packaged beside the GitHub mark in `assets/platforms/OCTICONS-LICENSE.txt`.

These are authored, local website animations. No Slack message payload, GitHub repository, or live integration is modified by this presentation work.

## Example audit — 2026-10-23

The eight animated scenarios use fictional names and outcomes. They are marketing examples, not harvested production fixtures or evidence of a live run. The source links below establish the supported behavior and message structure. They are not published with the site.

| Example | Implementation checked | Result of the sweep |
| --- | --- | --- |
| Deployment investigation → PR | `lib/ryker/slack/thread_status_projection.ex`, `lib/ryker/slack/renderer/records.ex`, `lib/ryker/slack/renderer/offers.ex`, `lib/ryker/slack/renderer/task_publication.ex` | Removed the custom spinner/checklist, tool-source badges, branch receipt and invented PR unfurl. Uses native activity wording, ordinary replies, Sources context, the existing Start task action and an updating task card. Its seven stages move through planning, implementation with subtasks, checks, draft publication, CI and merge. The PR opens after the card has had time to develop. The diagnosis identifies stale in-process credentials, which the shown restart-on-template-change fix addresses. |
| Coding | `lib/ryker/slack/task_card_details.ex`, `lib/ryker/slack/renderer/work_cards.ex`, `lib/ryker/slack/renderer/task_publication.ex` | The production renderer supplies the request, all seven stages, subtasks, counts, repository, publication status, authorized controls and Updated footer. The task pauses on Planning for a real input-request choice, the question changes to Answered, and the original card continues through implementation and checks. Open PR and the review/merge handoff appear after CI passes. |
| GitHub review | `lib/ryker/github/client/pull_requests.ex`, `lib/ryker/github/capability_tools/authority.ex`, `lib/ryker/github/renderer.ex` | Kept supported inline review and request-changes behavior. Removed the nonexistent GitHub typing indicator and source badge. A pushed-update comment is a comment, not a fabricated native event; the earlier diff is marked Outdated after the update. |
| Incident | `lib/ryker/slack/renderer/offers.ex`, `lib/ryker/slack/incident_room_card.ex`, `lib/ryker/slack/renderer/work_cards.ex`, `lib/ryker/slack/work_record.ex` | Uses Investigate / Create incident room and an authored pinned-message excerpt with the renderer's incident heading, status, goals and controls. Opening the room replaces the on-call thread instead of copying its messages. Removed fake evidence chips, invitation receipts and the automatically appearing postmortem card. Recovery summary follows an explicit request. The timed recovery check uses the actual event-wait context, which disappears when the check completes. |
| Memory | `lib/ryker/slack/renderer/records.ex`, `lib/ryker/slack/thread_status_projection.ex`, `docs/memory.md` | An explicit request produces the real Remember offer, then the saved memory with scope, kind, source, expiry and Forget memory. A later explicit request produces Guidance and its saved record with Delete guidance. Recall in a new conversation remains an ordinary reply with Sources; the next conversation checks fresh usage. The example does not imply that unconfirmed feedback automatically becomes workspace guidance. |
| Scheduled work | `lib/ryker/slack/renderer/offers.ex`, `lib/ryker/slack/saved_entity.ex`, `lib/ryker/slack/renderer/saved_entity_card.ex`, `lib/ryker/schedules/schedule_cadence.ex` | Replaced the fake confirmation receipt with Schedule this and the saved schedule's real fields, notice and Delete schedule action. Uses a weekday cadence with the actual Berlin-time wording. Tuesday's result returns to the same thread. |
| Standing request | `lib/ryker/slack/renderer/offers.ex`, `lib/ryker/slack/saved_entity.ex`, `lib/ryker/behaviors/standing_rules.ex` | Uses Enable automation, then the saved standing rule and Delete rule. The listener watches Slack messages here; reviewing Terraform plans is its instruction. No invented CI-app filter is claimed. A new plan starts a new thread. Replacement risk comes from the plan's explicit replacement marker. |
| Emisar approval | `lib/ryker/slack/renderer/emisar_review.ex`, `lib/ryker/emisar/approval_status.ex`, `lib/ryker/emisar/review.ex` | Uses Emisar review, Reason, Expected outcome, Command to run, Runner, Status and Open approval. Approval updates that message; the command becomes Executed command only after the run. Removed the invented execution-receipt card. Completion and verification are ordinary separate replies. |

The task, input-request, memory, guidance and event-wait examples were rendered through the current production Ryker.Slack.Renderer with fictional scenario inputs. Task states retain the renderer output, including the complete request and stage ledger; the website translates Slack formatting into HTML. Saved-entity values follow SavedEntity and stage wording follows Work.TaskStages. The schedule, rule, incident and approval blocks remain shortened excerpts of their existing message structures. Offer boilerplate is omitted from the website following the requested cleanup. No production renderer or native card design was changed. Website colors remain the user-requested Ryker palette; Slack's real client owns the native colors and spacing.

The unauthenticated Activity dashboard and six decorative feature widgets were removed. Their accompanying feature descriptions and documentation links remain. They no longer imply product screens that do not exist.

GitHub view changes now select and display the corresponding content together; commit/file counts follow the revision. The first failed run is not shown as the current result after rechecks. Static/reduced-motion transcripts retain earlier conversation scenes; transient intermediate card states remain omitted.

Technical references checked for the deployment example:

- [Nomad template change modes](https://developer.hashicorp.com/nomad/docs/job-specification/template#change_mode): restarting a task when its rendered template changes.
- [Prometheus rate](https://prometheus.io/docs/prometheus/latest/querying/functions/#rate): a counter's recent rate rather than its lifetime nonzero value. The YAML test display is a diff excerpt from a larger existing suite.

Earlier realism-pass verification: the public build and all seven focused marketing/brand tests pass. All eight HTML pages have balanced markup and their 428 local references resolve. Browser checks covered the hero through its final deployment reply, task/review/incident outcomes, new-thread boundaries, native schedule/approval states, desktop and 320px layouts, reduced motion, no JavaScript and simulated 200% text. Enlarged GitHub headers can scroll without eliminating the code/review pane. No browser errors were reported. These checks qualify the local website preview, not live Slack/GitHub delivery.


## Card-family coverage — 2026-10-23

| Native family | Homepage treatment |
| --- | --- |
| Engineering offer and confirmation | Hero and coding: Start task becomes the confirmed outcome. |
| Task lifecycle and publication | Hero and coding: one message changes in place; all seven stages remain, with subtasks, checks, PR state, controls and timestamps. |
| Input request | Coding: short choice buttons, Answered outcome, and the task continuing after the answer. |
| Incident offer and room card | Incident: Investigate / Create incident room, pinned investigation goals and actual work controls. |
| Event wait | Incident: the next-check context while waiting for recovery verification. No invented monitoring widget. |
| Memory offer and saved memory | Memory: explicit team request, confirmation, retained value/scope/expiry and Forget memory. |
| Guidance offer and saved guidance | Memory: explicit team instruction, confirmation, scope/expiry and Delete guidance, then use in another thread. |
| Schedule offer and saved schedule | Scheduled work: Schedule this, saved details and Delete schedule, then the due result. |
| Standing-assignment offer and saved rule | Standing requests: Enable automation, saved listener details and Delete rule, then the next matching plan. |
| Emisar review | Approval: pending review, granted review, executed command and Open run. Open approval loses primary emphasis after review. |
| Sources | Ordinary replies cite their supporting evidence. Evidence/progress/goal records do not invent separate cards. |
| Preference and automation-change offers | Audited; they reuse the saved-entity pattern already demonstrated. Extra preference and edit flows would repeat that lesson. |
| Standalone publication offer/review/result | Audited; draft creation and publication status are demonstrated on the current task card and GitHub PR. |
| Slack-post offer | Audited; only relevant when explicitly asking Ryker to post elsewhere, which these stories do not do. |
| Welcome, channel settings/setup, App Home and record views | Configuration and record-management surfaces remain linked from the relevant copy. They do not appear as unsolicited conversation cards. |

The existing native catalog was located in `.agent/tasks/99_done/2026-09-09-redesign-all-slack-cards-and-states-for-consolid/` and consulted without editing its historical source or receipts. Current production renderers and update paths take precedence over older proposed catalog states. `TaskCardWorker.maybe_update/3` updates the original channel/message identity; the examples likewise keep one task message and replace only its contents.

The 21 new source envelopes passed the production renderer and Slack's no-post `blocks.validate` endpoint. Exact message envelopes, SHA-256 receipts and fresh direct Builder links are in the local, unpublished `.ryker/site-card-review/{documents.json,payloads.json,validation.json,previews.md}`. Those checks establish native schema acceptance; the browser checks establish the website presentation. They do not claim live Slack delivery or native Slack visual review.

Final card-pass verification: 3 marketing build tests and 4 brand tests pass; JavaScript syntax and diff whitespace checks pass. The public build contains 8 pages and 28 files, with balanced HTML and 432 resolving local references. Browser review covered task creation and updates, the question/answer handoff, saved memory and guidance, the hero through merge and deployment verification, 320px layouts, reduced motion, no JavaScript and simulated 200% text. The page has no horizontal overflow in those checks and reported no browser errors. The rebuilt preview is served locally at http://localhost:8080/.

## Feedback, automatic alerts and conversation — 2026-10-23

| Story | Current behavior checked | Website treatment |
| --- | --- | --- |
| Learning from feedback | `lib/ryker/behaviors/corrections.ex`, `lib/ryker/work/prompt.ex`, `test/ryker/behaviors/corrections_test.exs` | An explicit reusable correction from the current operator is saved without another confirmation. The exact instruction appears in the real saved-guidance card, scoped to This conversation, with Delete guidance. The next day's review follows it. This is retained guidance, not model retraining or automatic workspace-wide promotion. |
| Automatic Slack alerts | `lib/ryker/admission/prompt.ex`, `lib/ryker/slack/channel_settings.ex`, `site/docs/slack.html#alerts` | A monitoring app posts the alert; Ryker investigates and offers a concrete mitigation before a human asks for anything. The person then requests an incident room and a teammate restores the limit. Four extra seconds and a separate investigation chapter make the initial automatic response readable. Recovery metrics cover the two minutes since the change. |
| Proactive conversation | `lib/ryker/admission/prompt.ex`, `lib/ryker/slack/renderer/channel_setup.ex`, `site/docs/slack.html#speaking` | The copy names the actual Be proactive setting. Two people discuss a linked PR without tagging Ryker; it contributes a specific finding, answers a natural follow-up and continues the exchange. APP identity stays visible. No task or mutation is invented for a request to explain a line. |

The feedback card was generated with the current production renderer. Its exact `{blocks}` envelope passed Slack's no-post schema validator; the collection now contains 22 accepted envelopes. The fresh direct Builder link is named `feedback-saved` in `.ryker/site-card-review/previews.md`, with the corresponding source, payload and hash receipt beside it. No Slack message was posted, and this is not native-client visual proof.

This pass adds two conversations to the existing examples, for ten demos in total. The four work-example tabs wrap into two rows on small screens and retain arrow-key navigation. The saved-feedback card starts at the reply and instruction on narrow screens; its remaining fields are available by scrolling. The linked memory documentation now explains the explicit-correction path and its conversation scope.

Verification: all 3 marketing build tests and 4 public brand tests pass. JavaScript syntax and diff whitespace checks pass. The build contains 8 pages and 28 files, with balanced HTML and 446 resolving local references. Browser checks covered the feedback before/after, saved guidance, automatic alert response and later recovery, proactive conversation and follow-ups, keyboard tabs, 320px layout, and complete reading with reduced motion or JavaScript disabled. No page-wide horizontal overflow or browser errors appeared. This is the rebuilt local static preview at http://localhost:8080/; no runtime integration or public deployment changed.

## Native working indicator — 2026-10-23

The supplied Slack screenshot is the visual reference for all nine Slack examples. Each now uses a 24px Ryker avatar followed by muted “Ryker is working” text, aligned with the message body and placed below the conversation. The bouncing dots, separate composer status strip and changing tool-status labels were removed. Both animation controllers show and retire the row using their existing work intervals, and follow changes inside the app pane. The row is omitted in static and reduced-motion reading.

This is Slack's native working-status treatment, not a Block Kit card. No card envelope, production renderer or integration payload changed, so there is no new Builder preview for this adjustment.

Verification for the indicator change: 3 marketing build tests and 4 public brand tests pass; JavaScript syntax and diff whitespace checks pass. The build has 8 balanced pages, 28 files and 455 resolving local references. Browser review confirmed the shared row's alignment, icon size and text on desktop and at 320px, its removal outside working intervals, and all nine rows remaining hidden with reduced motion or JavaScript disabled. No browser errors appeared. The rebuilt local preview remains on port 8080.

## Ryker, co:op and Emisar — 2026-10-23

The section between the main walkthrough and the examples introduces the three products as a DevOps teammate with its tools. Ryker carries the conversation and work, co:op provides the sandbox and separate working copy, and Emisar controls remote access, approvals and execution records. These boundaries were checked against the current README, `site/docs/index.html#shape`, the getting-started guide and `lib/ryker/work/submission_builder.ex`. The combined alert example describes investigation, preparing and testing a fix, and bringing the findings and draft back to the team; it does not promise automatic merge or deployment.

Artwork follows `brand/README.md`, `brand/ryker/README.md` and the product-family sources they name. All three full avatars use equal 40px boxes beside their product names. The copies in `site/assets/products/` are unchanged from the supplied Protectorate assets:

- `coop.svg` from `../protectorate/profile/assets/coop.svg`, SHA-256 `e0820c42ead08b29315ae48eb6ed046a137149880c7e4d26e9955a22607dc28f`.
- `emisar.png` from `../protectorate/profile/assets/emisar-avatar.png`, SHA-256 `368f73f9899f6161b2605ca174aa39a28954b5606e7f2837cbc5c6cba0c7f8fd`.

The section is static HTML with responsive CSS, readable independently of the demo animations. The product links point to Ryker's architecture explanation and the official co:op and Emisar websites. Browser review confirmed the three-column desktop layout, stacked 320px layout, loaded artwork, readable copy and links, and no horizontal overflow or console errors. The 3 marketing build tests and 4 public brand tests pass. The rebuilt local site contains 8 balanced pages and 30 files, with 458 resolving local references. No runtime integration changed.

## Adversarial polish review — 2026-10-23

Three independent reviewers covered design and typography, documentation and product truth, and frontend correctness, accessibility, security and technical SEO. The first review identified excessive scrolling, small demo text, anonymous mobile playback controls, slow opening feedback and stale public setup/security instructions. A second review checked the implementation; independent final documentation reviews caught the remaining operational and wording errors below. The final design review found no major design issues. These are qualitative review findings, not a measured design percentile.

| Finding | Resolution |
| --- | --- |
| Repeated full-height narratives and everyday demos | The hero has three sections; everyday capabilities share a second example picker. All ten demos and their native cards remain. At the same 1059px review width, the page fell from 12,065px to 7,629px, about 37%. |
| Small evidence and unexplained mobile controls | Slack conversation text is 14px; GitHub discussion is 14px and code is 12px. Chapter names remain visible and wrap on phones. Code has a keyboard-scrollable horizontal region; line numbers stay on one line. |
| Long opening wait and competing scroll/playback behavior | The complete request is present immediately, acknowledgement arrives at 1 second and the finding at 6 seconds. The 82-second story continues through checks, review, human merge and deployment verification. Scrolling the page never seeks playback. |
| Repetitive framing and vague search title | Removed decorative eyebrows and numbered kickers, varied the headings, and named the product in the title and visible lead: an AI teammate for Slack and GitHub. |
| Stale onboarding and security claims | All seven docs were checked against current source: native console sign-in and invitations, private worker model login, explicit environment assignment, database-held repository knowledge, GitHub delivery polling, scoped publication grants, model services, upgrades and migrations. |
| Incomplete setup journey | Added GitHub App permissions/events, a first Slack request and expected outcome, troubleshooting, and current console navigation. Memory docs now begin with saving a decision and learning from feedback. |
| Dangerous bulk-copy operations example | Lifecycle alternatives are a command/purpose table, not one executable code block. Release verification includes its artifact argument. Metrics wording distinguishes anonymous loopback access from signed-in remote access. |
| Overstated intent detection and action outcomes | Slack docs describe contextual interpretation and suggested mitigation/fixes without implying infallible detection or automatic execution. |
| Keyboard, copying and enlarged text | Tabs expose focusable panels and shareable selected URLs without scrolling. Failed copying selects the actual code and announces a neutral fallback. Mobile navigation fits one row at normal text size; breadcrumbs wrap, and the product grid reflows at simulated 200% text. |

Relevant current source contracts include `ConsoleAccess`, `ControlPlane.SignInGate`, `ControlPlane.Router`, `SetupPage`, `RepositoryImport`, `RepositoryKnowledge`, `GitHub.DeliveryPoller`, `GitHub.InstallationTokens`, `CoopFleet.PublicationGrants`, `Publication.Executor` and `scripts/compose.sh`. The website changes do not modify a native Slack payload, renderer, operational integration or deployment.

Technical SEO retains ordinary HTML content, unique page metadata, genuine internal links, a consistent build-time canonical/sitemap inventory and packaged local assets. The descriptive title follows [Google's title guidance](https://developers.google.com/search/docs/appearance/title-link); tab focus follows the [WAI tabs pattern](https://www.w3.org/WAI/ARIA/apg/patterns/tabs/). No speculative schema, generated SEO pages, crawler-policy changes or tracking were added. The launch domain remains unestablished; `site-build.invalid` is local build test data, not a production canonical.

Final verification: 3 build tests, 4 interaction tests and 4 brand tests pass. The three interaction regressions failed on their earlier implementation before being fixed. JavaScript syntax and diff whitespace checks pass. The public build has 8 balanced pages, 30 files and 470 resolving local references. Chrome review covered the homepage at 320, 768, 1024 and 1440px, all seven docs at 320px, desktop docs, keyboard tab/panel navigation, copied-code feedback, direct example links, horizontally scrollable code, no-JavaScript and reduced-motion reading, and simulated 200% text on the homepage and installation guide. The final tested layouts have no page-wide horizontal overflow; the final local preview reports no browser errors.

This qualifies the rebuilt local static site at http://localhost:8080/. It does not establish a fresh installation, live Slack/GitHub delivery, other browser engines, field Web Vitals, public hosting, indexing, rankings or conversion improvement.

## In-place task updates — 2026-10-23

The two website animation players now distinguish live-card edits from new messages. Card contents change without the entrance animation or automatic scrolling; new replies still arrive and explicit chapter selections still navigate. Scroll anchoring is disabled within animated Slack panes so replacing a card state does not move the viewport to another element. Slack and GitHub follow new content independently.

Two regression cases failed against the previous players and now pass. They cover a task update, a new reply, and a later update above that reply. All 9 site build/interaction tests pass. In Chrome, the hero's planning-to-implementation transition retained its 716px scroll position and the mobile coding example retained 769.5px from implementation through review; neither state had the entrance animation. This changes only the local website presentation, not the native card payloads.

## Direct copy and inline citations — 2026-10-23

The product explanation now combines co:op's sandbox, Emisar's remote access and the alert-to-fix workflow in one paragraph. The Ryker description names the work it performs; the coding heading states that it sees multiple repositories at once. The alert story now has Ryker prepare and carry out the rollback after a person approves it in Emisar, then check recovery. This supersedes the earlier example in which a teammate restored the limit.

All example reply citations are embedded in the relevant sentences. `Ryker.Slack.Renderer` passes ordinary prose through Slack Markdown blocks, including inline links; `Records.source_blocks/1` can separately append a Sources context row when linked evidence records are attached. The website now illustrates the inline form. This does not remove the Sources feature from the runtime or change any native card payload, and no new native card design is introduced.

## Underline spacing and missed edits — 2026-10-23

The previous continuous underline was positioned against the link's padded hit area, leaving a measured six-pixel gap below the text bounds. Links now use native text underlining at a three-pixel offset. Their text and arrow share one inline formatting context, so the underline continues through the arrow and follows wrapped lines; the 44-pixel hit area remains. Browser checks covered 320, 768, 1024 and 1440 pixels with no page-wide overflow.

The hero no longer forces a break inside “An extra pair of hands.” The phrase occupies one line at the tested tablet and desktop widths and wraps naturally at 320 pixels. The remaining standing-request wording now says Ryker starts the work when a matching event arrives.

The follow-up sweep confirmed the removed disclaimer/eyebrow copy, old self-hosting slogan, repeated tools paragraph, Sources rows, passive alert and multi-repo headings, and human-requested CI repair remain absent. The nine build/interaction tests still cover task updates staying in place, and the working-text animation still respects reduced motion. This pass changes website typography and copy only.

## Automatic CI correction — 2026-10-23

Removed the human request between failed CI and Ryker's correction. `Publication.Followups.Polls.correction_wakeup?/2` resumes the task when checks fail on its published head, and the focused `followups_test.exs:153` regression passes. The demo now shows the failed check, Ryker's diagnosis and correction, an updated commit, passing checks, then human approval and merge. The 9 site tests pass and Chrome shows Ryker's response directly after the failure. No runtime behavior or native Slack payload changed.
## Browser console captures — 23 October 2026

`assets/console/` contains desktop (1280 × 920 viewport) and phone (320 × 800 viewport) screenshots
of the current console components, rendered from `cee60494f` with public example data.
The request view shows `EpisodePage` and its `Work briefing`; the settings view shows
`SettingsPage` at `/settings/models`. Both use the application's own navigation,
stylesheets, fonts, and artwork. The browser capture produces JPEG assets at
1265 × 909 and 305 × 763 pixels; the HTML declares their actual image dimensions.

The capture used an isolated SQL-sandbox session with the existing `Answers` fixture
helpers. No production conversations, identities, access tokens, or configuration were
used. The checkout-timeout conversation, saved guidance, model configuration and work
records are example content, not a performance benchmark. An HTML snapshot retained
the rendered components and expanded disclosures; its incomplete-installation shortcut
was omitted from the desktop sidebar. No application styles or control labels were
changed. Phone captures frame the briefing and model controls at their native responsive
size. The homepage serves the appropriate capture and links each to the desktop image.

The screenshots explain inspecting the saved briefing and configuring the model; the
surrounding copy also points to actual Instructions, Memory, Channels and Environments
pages. The repeated standalone approval demo was removed. Approval remains part of the
Emisar explanation and the alert example. Native Slack payloads are unchanged.

### Expanded console gallery

The gallery adds the actual Instructions editor and a Learned topic's detail page,
rendered from `5c108f0b1`. Both use an isolated SQL sandbox: `Instructions.save/4`
stores public example guidance, and the existing `Answers` and `Knowledge` fixtures
record a payment-retry topic with its source and update history. No model is called.
The capture retains the application's HTML, styles, labels and controls, with only
the incomplete-installation sidebar shortcut omitted as in the earlier captures.

Desktop images are browser crops of the relevant controls: 1280 × 580 for
Instructions and 1280 × 705 for Memory. Phone images are 375 × 625 captures of
the native responsive pages, positioned at the main-content anchor. The gallery
caps desktop screenshots at 720 CSS pixels wide and phone previews at 320 × 400,
with each image linking to its desktop capture at full resolution. Request and
model screenshots retain their original files. Every panel has a short explanation
and a link to the relevant documentation; keyboard navigation and direct links
use the existing example picker.


## Everyday feature illustrations — 23 October 2026

“Fits the way you work” now pairs its six features with lightweight HTML/SVG
illustrations: a voice clip and reply, a chart attachment, a weekly update,
browser chat, channel participation, and incoming events. These are public
example compositions, not production screenshots or native delivery proof.
The only image assets are the existing supplied Ryker avatar. The illustrations
have image descriptions and contain no focusable or operational controls.

The weekly update follows `Ryker.WeeklyReport.Digest`: plain prose, merged PRs
first, then the PR awaiting review. Its crop uses example titles and counts.
Browser chat follows `ControlPlane.LabPage`’s message, composer, file attachment
and environment arrangement. Channel participation wording comes from
`ControlPlane.ChannelsPage`; the event diagram illustrates configured sources.
The chart is example tool-produced output, not a built-in charting screen.
No native Slack payload, card design, runtime component or integration changed.
