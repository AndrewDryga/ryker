defmodule Ryker.ControlPlane.PageHelp do
  @moduledoc """
  "How this page works": the help every control-plane page carries, keyed by
  the route that serves it, and the one panel the shell renders it in.

  Andrew, 2026-09-25: how to use a page had been one line of small print
  under a few lists ("To open one, ask Ryker in the alert's Slack thread…")
  and nothing on the rest. He asked for help on every page that teaches
  without getting in the way, and longer than a hint. Each page's help says
  what the page shows, what can be done there, how Ryker uses it, what to do
  when something looks wrong and how to ask Ryker for it in chat or Slack,
  in plain words for someone who has never seen Ryker. `PageHelpTest` holds
  every routed page to having help and keeps Ryker's internal words out.

  An integration page's help explains each word its state can show, from the
  same account the pages read (`Integrations.meanings/1`), so the help can
  never describe a state the page does not show.

  Andrew, 2026-09-26: the help "should not be collapsible like that"; one
  button opens or hides the whole side panel, and the browser remembers
  which. The panel is the help as it is, beside the page from 1280px wide
  and over it below that, and the button sits at the top right of every
  page. Whether it shows is the browser's choice, kept on `<html>` as
  `data-page-help` (`page-help-early.js` before the first paint,
  `page-help.mjs` after), so both are rendered closed here.
  """
  use Phoenix.Component

  alias Ryker.ControlPlane.{Components, Integrations}

  @type section :: %{heading: String.t(), paragraphs: [String.t()]}
  @type t :: %{title: String.t(), sections: [section()]}

  # Every live route in `WebRouter`, as it writes them, with the help its
  # page shows. Two routes that render one page share its help.
  @routes [
    {"/", :activity},
    {"/activity", :activity},
    {"/timeline/:ref", :timeline},
    {"/conversations", :chat},
    {"/conversations/:id", :chat},
    {"/incident-rooms", :incident_rooms},
    {"/incident-rooms/:ref", :incident_room},
    {"/failures", :failures},
    {"/failures/:kind/:ref", :failure},
    {"/usage", :usage},
    {"/environments", :environments},
    {"/channels", :channels},
    {"/channels/:workspace/:channel", :channel},
    {"/repositories", :repositories},
    {"/repositories/:ref", :repositories},
    {"/working-copies", :working_copies},
    {"/rules", :rules},
    {"/schedules", :schedules},
    {"/schedules/:ref", :schedule},
    {"/follow-ups", :follow_ups},
    {"/instructions", :instructions},
    {"/memory", :facts},
    {"/memory/learned", :learned},
    {"/memory/findings", :findings},
    {"/memory/learning", :learning},
    {"/memory/feedback", :feedback},
    {"/memory/feedback/fix", :improvement},
    {"/integrations", :integrations},
    {"/integrations/slack", :slack},
    {"/integrations/github", :github},
    {"/integrations/emisar", :emisar},
    {"/integrations/webhooks", :webhooks},
    {"/settings", :settings},
    {"/settings/models", :models},
    {"/settings/retention", :retention},
    {"/settings/prices", :prices},
    {"/settings/report", :report},
    {"/settings/advanced", :advanced},
    {"/setup", :setup},
    # A page of one form shares the help of the list it adds to or edits.
    {"/repositories/new", :repositories},
    {"/environments/new", :environments},
    {"/environments/:ref/edit", :environments},
    {"/settings/prices/new", :prices},
    {"/settings/prices/:item/edit", :prices},
    {"/integrations/emisar/new", :emisar},
    {"/integrations/emisar/:ref/edit", :emisar},
    {"/integrations/webhooks/credentials/new", :webhooks},
    {"/integrations/webhooks/sources/new", :webhooks},
    {"/integrations/webhooks/sources/:item/edit", :webhooks}
  ]

  @patterns Enum.map(@routes, fn {route, page} -> {String.split(route, "/", trim: true), page} end)

  @doc "The routes that have help, written the way the route map writes them."
  @spec routes() :: [String.t()]
  def routes, do: Enum.map(@routes, &elem(&1, 0))

  @doc """
  The help for the page at `path`, a request path as the browser sent it;
  nil for a path no page is routed to.
  """
  @spec for_path(String.t()) :: t() | nil
  def for_path(path) when is_binary(path) do
    segments = path |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true)

    Enum.find_value(@patterns, fn {pattern, page} ->
      if matches?(pattern, segments), do: help(page)
    end)
  end

  defp matches?([], []), do: true
  defp matches?([":" <> _param | pattern], [_value | rest]), do: matches?(pattern, rest)
  defp matches?([segment | pattern], [segment | rest]), do: matches?(pattern, rest)
  defp matches?(_pattern, _segments), do: false

  attr(:path, :string, required: true, doc: "The page's path, without its query")

  @doc """
  The page's help and the one button that shows or hides it, both rendered
  closed. Renders nothing for a path without help.
  """
  def panel(assigns) do
    assigns = assign(assigns, :help, for_path(assigns.path))

    ~H"""
    <button
      :if={@help}
      type="button"
      id="page-help-toggle"
      class="page-help-toggle"
      phx-hook="PageHelp"
      aria-controls="page-help"
      aria-expanded="false"
      aria-label="Show help"
      data-page-help-toggle
    ><Components.icon name={:help} class="page-help-show" /><Components.icon
      name={:close}
      class="page-help-hide"
    /></button>
    <aside :if={@help} id="page-help" class="page-help" aria-label={@help.title}>
      <h2 class="page-help-title">{@help.title}</h2>
      <section :for={section <- @help.sections} class="page-help-section">
        <h3>{section.heading}</h3>
        <p :for={paragraph <- section.paragraphs}>{paragraph}</p>
      </section>
    </aside>
    """
  end

  defp help(:activity) do
    page("How Activity works", [
      {"What this page shows",
       [
         "Every request people made of Ryker, and what Ryker did about it. A request is a Slack message, a chat message, a GitHub event or an alert from another tool.",
         "Rows are grouped by day, newest first. Each row says where the request came from and where it stands."
       ]},
      {"Find a request",
       [
         "The counts at the top say how many requests the list holds, how many are in progress and how many need you. Each of the last two opens its view. Search matches message text and repositories.",
         "All, Needs you, In progress and Finished narrow the list. + Filter adds a filter, such as a repository or a model."
       ]},
      {"Open a request",
       [
         "Click a row to open its timeline: every step Ryker took, from reading the message to sending the answer, and what it cost."
       ]},
      {"When something looks wrong",
       [
         "Needs you lists work that is blocked or waiting for a person. Open it to see why. Work Ryker could not finish on its own is also on Failures, with what you can do.",
         "If no worker can take work, the Workers section under the list says so. Requests wait until a worker is back."
       ]},
      {"Ask Ryker",
       [
         "Mention @Ryker in a Slack channel it is in, or write to it in Chat. The request shows up here within seconds."
       ]}
    ])
  end

  defp help(:timeline) do
    page("How a timeline works", [
      {"What this page shows",
       [
         "One request from start to finish: the message that started it, how Ryker decided what to do, the work it did and the answer it sent. Steps are in the order they happened.",
         "A message Ryker answered, reacted to or left alone without starting work has its own page like this. It shows the message, how Ryker decided what to do and what it sent, then the rest of its thread."
       ]},
      {"Read the steps",
       [
         "Each message goes through four stages: Intake, Routing, Work and Answer. Open a card to see its details, such as the exact request Ryker sent to the model and the answer it got back.",
         "Every card has a # link to itself, so you can share the exact step."
       ]},
      {"After the answer",
       [
         "Learning shows what Ryker learned from these messages in the background, with its prompt, answer and cost. Cleanup shows how the worker's session was closed and its working copy removed or kept.",
         "Reviews come last: each time someone checked how the request ended, with the note they left. Mark ending reviewed at the top adds one."
       ]},
      {"The summary at the top",
       [
         "The top says where the request stands, how long it took and what it cost. A cost marked ≈ includes an estimate. Next action says what the request is waiting for, if anything."
       ]},
      {"When something looks wrong",
       [
         "If the work is blocked, Next action links to its recovery page, which says what stopped and whether a retry should work.",
         "Retry work and Close as no longer needed ask you to confirm first. Nothing runs until you do."
       ]}
    ])
  end

  defp help(:chat) do
    page("How Chat works", [
      {"What Chat is",
       [
         "Chat is a direct conversation with Ryker, without Slack. Ryker can do the same things here as in a Slack channel: answer questions, investigate, change code, remember things and set up schedules.",
         "Each conversation works in one environment, which sets the repositories and Emisar account its work may use. A new conversation starts in the default environment; you can choose another one under the message box, and work already started keeps the one it began in."
       ]},
      {"Start a conversation",
       [
         "Type a message and press Send, or ⌘ / Ctrl + Enter. Choosing an example fills the box without sending it. Nothing is saved until you send the first message.",
         "You can attach up to two files, 8 MiB in total: images, PDFs, and text files such as logs, CSV, JSON or YAML."
       ]},
      {"Follow the work",
       [
         "While Ryker works, its progress shows under your message. The Timeline link on each message opens everything Ryker did for it, in a new tab.",
         "You can edit or delete your own messages, and react to Ryker's replies with emoji, as in Slack."
       ]},
      {"When something looks wrong",
       [
         "If the work behind a message stops, the message offers Retry and Inspect cause. If Chat is still getting ready, a notice takes the place of the message box and says what it is waiting for."
       ]}
    ])
  end

  defp help(:incident_rooms) do
    page("How incident rooms work", [
      {"What an incident room is",
       [
         "A Slack channel Ryker creates to work on one incident with your team. Ryker invites the responders, investigates in the room and posts what it finds there."
       ]},
      {"Open a room",
       [
         "Ask Ryker in the alert's Slack thread: “Open an incident room for this.” Ryker offers the room and creates it once you confirm. When Ryker investigates an alert, it may offer one itself: choose Create incident room.",
         "A channel can also open a room for every alert. Type /ryker status in the channel and choose Configure channel to set that."
       ]},
      {"What the states mean",
       [
         "Setting up: Ryker is creating the channel and inviting people. Open: the room is in use. Needs attention: setup stopped before it finished. Closed: the room's channel was deleted, and its history stays here."
       ]},
      {"Find a room",
       [
         "Search by title, repository or channel ID, and filter by state. Open a room to see Ryker's latest update, its investigation and any code change it proposed."
       ]},
      {"When something looks wrong",
       [
         "A room that needs attention links to what stopped, on Failures. Continuing its setup picks up at the step that stopped and never creates a second channel."
       ]}
    ])
  end

  defp help(:incident_room) do
    page("How an incident room works", [
      {"What this page shows",
       [
         "One incident room: Ryker's latest update, the Slack channel, what the investigation recorded and what happened to the channel. The page updates on its own as the room changes."
       ]},
      {"The investigation",
       [
         "People and Ryker work on the incident in the room's Slack channel, and Ryker posts its progress there. Investigation lists the evidence and findings it recorded; Open the timeline shows every step.",
         "If Ryker proposed a fix, Code change shows its pull request and where it stands."
       ]},
      {"When the channel changes",
       [
         "If the channel is archived, the investigation pauses until someone unarchives it. If the channel is deleted, the room closes and Ryker says so in the alert's thread.",
         "A reply Ryker still owed the room goes to that thread instead."
       ]},
      {"When something looks wrong",
       [
         "If setting up the room stopped, See what stopped opens it on Failures with what you can do. Continuing picks up at the step that stopped and never posts twice."
       ]}
    ])
  end

  defp help(:failures) do
    page("How failures work", [
      {"What this page shows",
       [
         "Work Ryker could not finish on its own, newest first. Affects people lists what someone is still waiting for, such as a reply or a Slack update. Housekeeping lists cleanup nobody is waiting on."
       ]},
      {"Read a row",
       [
         "Each row says what stopped, who it affects and why Ryker stopped trying. Its state says whether a retry should work: Retry should work, Needs you, Fix needed first, Retry won't help or Retrying on its own."
       ]},
      {"Fix it",
       [
         "A row has a button only when pressing it can help, and the button asks you to confirm before anything runs. When something else has to change first, the row links to where to change it.",
         "Open a row for the whole story: what happened, what it affects, what Ryker tried and each thing you can do."
       ]},
      {"How items leave the list",
       [
         "A failure leaves the list once the work finishes, whether after your retry or on its own. Ryker retries most things several times before it lists them here."
       ]}
    ])
  end

  defp help(:failure) do
    page("How a failure page works", [
      {"What this page shows",
       [
         "One thing Ryker could not finish on its own. What happened says what stopped and why. What it affects says who is waiting on it. What Ryker tried lists what it already did."
       ]},
      {"What you can do",
       [
         "Each option says what it does and whether it should work, with the recommended one first. Leave it says what happens if nobody acts.",
         "A retry asks you to confirm before it runs. Nothing happens until you do."
       ]},
      {"When a retry won't help",
       [
         "If something has to change first, such as a token or Ryker's place in a Slack channel, the page links to where to change it. Fix that, then come back and retry.",
         "Technical details hold the error codes, for support."
       ]},
      {"After it is fixed",
       [
         "Once the work finishes, it leaves Failures. The request's timeline shows what happened next."
       ]}
    ])
  end

  defp help(:usage) do
    page("How usage and cost work", [
      {"What this page shows",
       [
         "How much work Ryker ran and what it cost, over the last 24 hours, 7 days, 30 days or all time. It covers every model call: routing messages, replies, investigations, tasks and background learning.",
         "It opens on live work, like Activity. All work adds evaluation runs."
       ]},
      {"Read the tables",
       [
         "The top figures show cost, requests, runs and tokens. The tables break the same numbers down by model, channel, repository, kind of work and person.",
         "Click a row to see the requests behind it on Activity."
       ]},
      {"How cost is counted",
       [
         "Cost is what the model provider reported. When a provider reports tokens but no cost, Ryker estimates it from the prices saved in Settings, Model prices, and lists the ones it used under Rates used for estimates. Not measured means nothing was reported."
       ]},
      {"When something looks wrong",
       [
         "A high cost usually comes from one model or one kind of work, and the tables show which. To use a different model for a kind of work, change it in Settings, Models."
       ]}
    ])
  end

  defp help(:environments) do
    page("How environments work", [
      {"What an environment is",
       [
         "Where Ryker works: the repositories work there may use and, if you have one, an Emisar account. Slack channels, webhook sources and Chat conversations each work in one environment."
       ]},
      {"Repositories",
       [
         "Work can read every repository in its environment. Each one is read only or read and write: a task that changes code changes one that is read and write, the default repository unless it picks another. The default repository is always read and write.",
         "Adding a repository puts it in the default environment, read and write, and creates Default when there is none."
       ]},
      {"Emisar",
       [
         "With an Emisar account, work here can send the actions it wants to run, such as a restart, to Emisar, where a person approves each one. Without one, Ryker can only tell you what to run."
       ]},
      {"The default environment",
       [
         "A new Chat conversation starts in the default environment, and every channel without its own choice works there. To make another one the default, open it and tick Default environment."
       ]},
      {"Add, change or remove",
       [
         "Open an environment from anywhere on its row to change it on a page of its own. There you set its name, description, repositories and what work may do in each, its Emisar account and whether it is the default. Add an environment opens the same form, empty. Save returns to the list.",
         "Remove environment is the last part of an environment's page. It asks first, and is refused while channels or webhook sources still use the environment."
       ]}
    ])
  end

  defp help(:channels) do
    page("How channels work", [
      {"What this page shows",
       [
         "The Slack channels Ryker is in, and how it takes part in each: when it replies, which environment its work uses and when it was last active."
       ]},
      {"Add a channel",
       [
         "Invite Ryker to a Slack channel with /invite @Ryker. The channel shows up here, and Ryker posts a welcome message there with a Customize button for its setup."
       ]},
      {"How Ryker takes part",
       [
         "Replies when mentioned: Ryker answers when someone writes @Ryker. Joins relevant conversations: it also replies when it can clearly help. Watches quietly: it reads and learns, but never replies.",
         "New channels, under Slack at the top of this page, says how a channel Ryker joins takes part until it makes its own choice. Change opens it on the Slack page."
       ]},
      {"Change a channel",
       [
         "Open a channel to change how Ryker takes part there, what it does with alerts and which environment its work uses. Each choice saves as soon as you make it.",
         "In Slack, type /ryker status in the channel and choose Configure channel to change the same settings there."
       ]},
      {"Find a channel",
       [
         "In use lists the channels Ryker is in; All adds the ones it left or never joined. Search matches a channel's name, workspace or environment.",
         "Connected: Ryker is in the channel. Disconnected: it left or was removed. Not connected: it was never invited. Deleted: the channel is gone from Slack. Incident open: an incident there is still open."
       ]}
    ])
  end

  defp help(:channel) do
    page("How this channel works", [
      {"What this page shows",
       [
         "Everything about one Slack channel: how Ryker takes part, the environment its work uses, the channel's own instructions and what applies here. Recent work, schedules and usage follow."
       ]},
      {"How Ryker takes part",
       [
         "Conversations says when Ryker replies here, Alerts what it does when an alert is posted, and Environment which repositories and Emisar account its work may use. No environment means Ryker works here without code and cannot act on running systems.",
         "Each choice saves as soon as you make it, and a small Saved beside it confirms it. Ryker's welcome message in the channel changes with it."
       ]},
      {"Instructions and what applies",
       [
         "This channel's instructions add to the global ones, here only. What applies here lists the rules, saved instructions and facts Ryker uses in this channel, and where each comes from."
       ]},
      {"Ask Ryker in the channel",
       [
         "To add a rule, tell Ryker in the channel: “When someone posts a Terraform plan here, review it for risky changes.” To add a schedule: “Every Monday at 09:00 Berlin time, summarize open incidents here.”",
         "Ryker shows what it will save and saves it only after you confirm."
       ]},
      {"Change it from Slack",
       [
         "The same settings can be changed in the channel: type /ryker status and choose Configure channel. Ryker answers only you, and this page shows the change."
       ]}
    ])
  end

  defp help(:repositories) do
    page("How repositories work", [
      {"What this page shows",
       [
         "The code Ryker can read and change. Each repository is Ready, Setting up, Not fully added or Needs attention, with the environments it is in and where it was used. Open one from anywhere on its row to see everything about it and what you can do."
       ]},
      {"Add and remove repositories",
       [
         "Connect GitHub first. Add repositories then opens a page that lists what the Ryker GitHub App can reach, and Refresh lists it again. Each one you add joins the default environment, so work there can use it at once. You can also add new ones automatically when the App gets access to them.",
         "Remove repository, the last part of a repository's page, takes it out of every environment, stops its setup and deletes the copy of its code Ryker keeps. Ryker asks first. Past requests stay, and you can add it again later."
       ]},
      {"Knowledge",
       [
         "Once a repository is set up, a model reads it and writes what Ryker knows about it. That covers what it is for, its parts, how to build, test and ship it, and where to look. Every later task there starts from it. Ryker keeps only the paths that exist and the commands its files show. Ryker keeps it itself and writes nothing to the repository; read it on the repository's page.",
         "Once a day Ryker checks again. It rewrites the knowledge when a README, AGENTS.md, CLAUDE.md, a build file or a CI workflow changed, or a week after its last write once any code changed. Refresh knowledge, on the repository's page, rewrites it now."
       ]},
      {"Who can ask for work",
       [
         "Anyone with write access to an added repository can ask Ryker to work there. GitHub checks that access on every request."
       ]},
      {"When something looks wrong",
       [
         "Needs attention says what stopped, such as GitHub access that was removed. Fix the cause, then press Retry setup on the repository's page.",
         "Not fully added means adding it stopped before it finished. Add it again, on the repository's page, finishes it."
       ]}
    ])
  end

  defp help(:working_copies) do
    page("How working copies work", [
      {"What this page shows",
       [
         "A working copy is a checkout of a repository that Ryker makes while a task works on code. This page lists them, the space they take on each worker and what cleanup does next."
       ]},
      {"Cleanup",
       [
         "Ryker removes a copy on its own once that is safe. It keeps a copy with uncommitted changes, or with commits that were never merged, so no work is lost.",
         "Ready for cleanup, when there is any, lists what goes next, oldest first. Removed lists the copies cleanup already removed."
       ]},
      {"When cleanup needs you",
       [
         "Cleanup needs attention means Ryker stopped for the reason shown. Resume cleanup tries the same step again. Discard unmerged throws away commits that were never merged, and keeps uncommitted changes.",
         "Both ask you to confirm first."
       ]},
      {"Storage",
       [
         "Each worker reports its space: how much is in use, how much can be freed and how much it is allowed. A worker that is full stops taking new copies until space frees up."
       ]}
    ])
  end

  defp help(:rules) do
    page("How rules work", [
      {"What a rule is",
       [
         "A rule tells Ryker to act when something happens in a channel, such as a new Terraform plan, a deployment, an alert, or a GitHub, Slack or webhook event.",
         "When a message sets off a rule, Ryker decides whether to reply, react or start work."
       ]},
      {"Add a rule",
       [
         "Tell Ryker in the channel: “When someone posts a Terraform plan here, review it for risky changes.” Ryker shows the rule and saves it only after you confirm."
       ]},
      {"Current and past",
       [
         "Current lists the rules that are on or paused. Past lists the ones that expired, were deleted or were replaced by a newer rule. A rule's row says when it stops."
       ]},
      {"Pause, resume or delete",
       [
         "Pause stops a rule without losing it, and Resume turns it back on. Delete ends it for good, but its history stays. Each asks you to confirm first."
       ]},
      {"See what a rule did",
       [
         "Recent matches lists the latest messages that set off a rule and what Ryker did, with a link to each request."
       ]}
    ])
  end

  defp help(:schedules) do
    page("How schedules work", [
      {"What a schedule is",
       [
         "A task Ryker runs at a set time, once or on repeat, such as a Monday summary of open incidents. Results go to the conversation or thread where it was set up."
       ]},
      {"Add a schedule",
       [
         "Tell Ryker, in the place where the results should go: “Every Monday at 09:00 Berlin time, summarize unresolved incidents in this channel.” Ryker shows the schedule and saves it after you confirm."
       ]},
      {"Change a schedule",
       [
         "Open a schedule from anywhere on its row. Run now starts one extra run and leaves the schedule as it is. Pause stops new runs until you resume it. Delete schedule, at the bottom of its page, ends it for good and keeps its past runs. Each asks you to confirm.",
         "To change what it does or when, ask Ryker in the conversation where it was set up."
       ]},
      {"Current and past",
       [
         "Current lists schedules that are on or paused. Past lists the ones that are done, expired or deleted. A one-time schedule is done after it runs."
       ]},
      {"When something looks wrong",
       [
         "A row that says failed to start means Ryker could not begin a run; it tries again on its own. Open the schedule to see each run and the request behind it."
       ]}
    ])
  end

  defp help(:schedule) do
    page("How this schedule works", [
      {"What this page shows",
       [
         "One schedule: how often it runs, where the results go, which repository it uses and what it may do, then every run, newest first."
       ]},
      {"What it may do",
       [
         "Read only: the runs only look. Can change the repository: a run may change code. Can run approved operations: a run may carry out actions a person approves in Emisar."
       ]},
      {"Controls",
       [
         "Run now starts one extra run. Pause and Resume stop and restart new runs. Delete schedule, at the bottom of the page, ends it for good, and its runs stay listed. Each asks you to confirm first."
       ]},
      {"Runs",
       [
         "Each run starts its own request; open it to see what Ryker did. Missed means a run could not start within 15 minutes of its time. The next run still starts on time."
       ]},
      {"Change it",
       [
         "To change what the schedule asks for or when it runs, ask Ryker in the conversation where it was set up. Ryker shows the new schedule for you to confirm."
       ]}
    ])
  end

  defp help(:follow_ups) do
    page("How follow-ups work", [
      {"What a follow-up is",
       [
         "Work Ryker paused on purpose. It waits for a set time or for something to happen, such as a pull request being merged, then picks the same request back up."
       ]},
      {"Where they come from",
       [
         "Ryker adds follow-ups on its own when work has to wait. You can also ask it, in the conversation: “Check again tomorrow morning.”"
       ]},
      {"Read a row",
       [
         "Each row says what it waits for, the request it continues and when Ryker checks again or gives up. Current lists what is waiting. Past lists what resumed, passed its deadline or was cancelled."
       ]},
      {"Stop one",
       [
         "This page only shows follow-ups. To stop one, open the request it continues and choose Close as no longer needed."
       ]}
    ])
  end

  defp help(:instructions) do
    page("How instructions work", [
      {"What instructions are",
       [
         "Instructions tell Ryker how to work, in your own words. Ryker follows them in every reply, investigation and task. They never give it permission to do more."
       ]},
      {"For every conversation",
       [
         "Write what should apply everywhere, up to 2,000 characters, and press Save. Ryker uses the change from its next step; work already running keeps what it started with.",
         "For example: “Keep replies concise. Separate observed facts from guesses.”"
       ]},
      {"For one channel",
       [
         "A channel's own instructions add to these, in that channel only. Where the two disagree, the channel's win. Add them on the channel's page."
       ]},
      {"Saved from conversations",
       [
         "Preferences and guidance are what people asked Ryker to keep in mind, such as “Remember to keep incident updates short.” Ryker shows what it will save and keeps it only after you confirm.",
         "Each one stops after the time chosen when it was saved. Pause, Resume and Delete ask you to confirm first."
       ]}
    ])
  end

  defp help(:facts) do
    page("How facts work", [
      {"What a fact is",
       [
         "Something a person asked Ryker to remember, such as what a service is called or which repository holds it. Ryker uses facts as context in later work, never as permission to act."
       ]},
      {"Add a fact",
       [
         "Tell Ryker in chat or Slack: “Remember that pay-gw is the payments gateway.” Ryker shows what it will save and saves it after you confirm.",
         "A fact applies everywhere, to one repository or in one channel. The row says which."
       ]},
      {"Review and forget",
       [
         "Needs review lists facts Ryker has not used in a while and facts saved more than once. Keep, edit, merge or forget each one.",
         "Forget stops Ryker using a fact and erases it. Every change asks you to confirm first."
       ]},
      {"Ask Ryker",
       [
         "In a Slack channel, ask Ryker “What do you remember here?” to see the facts it would use there."
       ]}
    ])
  end

  defp help(:learned) do
    page("How learned topics work", [
      {"What this page shows",
       [
         "What Ryker learned by reading conversations. Topics hold what it knows about a subject, with the messages it learned from. Conversation summaries hold where each conversation stands."
       ]},
      {"Where it comes from",
       [
         "Ryker reads the conversations it can see in the background, even when it does not reply. It updates a topic when it learns something new, and keeps every earlier version in the topic's history."
       ]},
      {"How Ryker uses it",
       [
         "Ryker recalls topics and summaries as context for later requests, so it can pick up where a conversation stopped. Nothing here gives it permission to act."
       ]},
      {"When something looks wrong",
       [
         "A topic marked Not used lost a message it learned from, so Ryker stopped using it. Point at Not used to see why.",
         "Open a topic from anywhere on its row. Relearn rebuilds it from messages you choose that still exist, with the learning settings in place now, and keeps its update history. Forget topic, at the bottom of its page, stops Ryker using it for good."
       ]},
      {"Read a topic's history",
       [
         "A topic's page lists every update, newest first, with the message Ryker learned it from.",
         "How this was learned opens the learning pass on the Timeline, with the exact request Ryker sent, the answer it got and what it cost."
       ]}
    ])
  end

  defp help(:findings) do
    page("How findings work", [
      {"What a finding is",
       [
         "A conclusion Ryker reached while investigating a problem, saved with the evidence behind it. Ryker writes findings itself."
       ]},
      {"What the states mean",
       [
         "Explained: the evidence shows why it happened. Expected and Out of scope come with Ryker's reason. Not explained yet: the question is still open. Point at a state to see what it means."
       ]},
      {"Settle a finding",
       [
         "Mark explained settles a finding Ryker could not explain once you know why it happened. Forget is for a finding that is wrong or no longer matters.",
         "Either way Ryker stops using the finding in later requests. It stays in the investigation's history and here, marked as such. Each asks you to confirm first and can't be undone."
       ]},
      {"Find a finding",
       [
         "The counts at the top say how many findings there are and how many are not explained yet. Search matches what a finding concluded, why, and where it applies."
       ]},
      {"Check the evidence",
       [
         "Open a finding's evidence to see what supports it, and Open investigation for the work behind it. Evidence that has expired says so."
       ]}
    ])
  end

  defp help(:feedback) do
    page("How feedback works", [
      {"What feedback is",
       [
         "What people told Ryker about its answers in Slack and Chat, kept with the request each answer belongs to. Nobody has to fill anything in: Ryker notices it.",
         "It is a reaction on one of Ryker's messages, or asking the same thing again soon after an answer. It is changing or deleting a message after Ryker answered it, or how the person felt about the answer judging by their next message. Your reviews of how requests ended are here too."
       ]},
      {"The kinds, frustrated first",
       [
         "Frustrated covers anyone frustrated or angry with an answer, and a thumbs down or a similar reaction. Asked again and Edited or deleted come next, then Neutral, Satisfied and your reviews. Point at a state to see what it means."
       ]},
      {"Find what went wrong",
       [
         "Open a row to see the request's timeline: the message, what Ryker understood, what it did and what it answered. The request's own page lists its feedback in a chapter of its own.",
         "The table by day shows whether something got worse. Open a kind to see all of it, newest first, and search for words in a reason or a request."
       ]},
      {"How long it is kept",
       [
         "Feedback is kept as long as prompts and replies are, set on the Data retention page."
       ]}
    ])
  end

  defp help(:improvement) do
    page("How What to fix works", [
      {"What is here",
       [
         "Each request someone was unhappy with is listed once, however much feedback it got. They were frustrated or angry, or reacted with a thumbs down or a similar emoji. They asked the same thing again, or changed or deleted their message after the answer. Or you reviewed a request that was stopped. Last 7 days, under the counts, says what the past week brought: the requests found, by what Ryker made of them, and how many were accepted or dismissed.",
         "Ryker reads each one itself, with the learning models, while background learning is on. It waits until the request is done and a few minutes pass without new feedback. It says whose fault it was, where it went wrong, what went wrong and what it should have done, and how sure it is. It never changes anything."
       ]},
      {"What the kinds mean",
       [
         "Host bug: Ryker's own code let the model down, such as a missing tool or a good answer that was mishandled. Prompt bug: the model did what its instructions said, and they led it wrong. Model mistake: the instructions were enough and the model still got it wrong. Not a problem: the answer was reasonable. Unclear: the evidence does not say.",
         "Ryker needs the person's words to read. When there are none, such as when an alert started the request or the person deleted their messages, the row says why and it is not analyzed."
       ]},
      {"Decide",
       [
         "Accept one to keep it as an eval case: Ryker keeps the messages it rests on, so the case outlives them. Dismiss one that is not worth it. Both ask first, and you can change your mind from the Accepted and Dismissed views. A GitHub request is analyzed too, but cannot be kept as an eval case yet: an eval case replays Slack and Chat messages.",
         "Download eval cases gives every accepted case as a world scenario for testdata/scenarios, with what went wrong and what is still to fill in. mix ryker.eval_cases --output DIR writes the same files."
       ]},
      {"How long it is kept",
       [
         "A request here is kept as long as prompts and replies are. An accepted case is kept as long as routing examples are, while you keep them for training. Forgetting or deleting a message it quotes erases it at once."
       ]}
    ])
  end

  defp help(:learning) do
    page("How background learning works", [
      {"What learning is",
       [
         "Ryker reads conversations in the background and keeps what it learned up to date on the Learned page. Learning never sends a reply."
       ]},
      {"Turn it on or off",
       [
         "The switch at the top of this list turns learning on at once; turning it off asks first. While it is off, new messages wait and nothing Ryker already learned is lost.",
         "The same switch runs the self-analysis of requests people were unhappy with, on Feedback › What to fix."
       ]},
      {"Recent passes",
       [
         "Each pass reads new messages from one conversation. Finding nothing to change is a normal outcome. Filter by outcome to see what changed.",
         "Open a batch to see its attempts. Each attempt opens on the Timeline beside the messages it read, with its prompt, the answer, tokens and cost."
       ]},
      {"When learning needs you",
       [
         "Needs attention lists conversations where learning stopped, such as after it used all its tries. Review one to see what happened and what you can do: Grant one more start tries the same messages once more, and Drop batch stops trying to learn from them.",
         "When it stopped on a learned topic that lost its messages, relearn that topic or forget it first. If learning can't start, the page links to the settings it is missing."
       ]}
    ])
  end

  defp help(:integrations) do
    page("How integrations work", [
      {"What this page shows",
       [
         "The services Ryker works through, each with where it stands and one next step."
       ]},
      {"What each one gives Ryker",
       [
         "Slack is where Ryker reads and replies. GitHub lets it read code and open pull requests. Emisar lets it carry out fixes after a person approves them. Webhooks let tools such as Grafana send it alerts."
       ]},
      {"Connect or change one",
       [
         "Connect, Set up and Manage open the service's own page. Each page checks what you paste before saving it.",
         "Disconnecting asks first, and keeps channels, repositories and history."
       ]},
      {"When something looks wrong",
       [
         "A service that needs repair says so here. Open its page to see what failed and fix it there."
       ]}
    ])
  end

  defp help(:slack) do
    page("How the Slack connection works", [
      {"Connect Slack",
       [
         "Paste the app token (xapp-…) and bot token (xoxb-…) from your Slack app and press Verify Slack. Ryker checks them and finds the workspace and its bot.",
         "Then choose who can manage Ryker to finish connecting."
       ]},
      {"Who can manage Ryker",
       [
         "These people can change Ryker's settings from Slack, such as a channel's setup or a new rule. The workspace's admins and owners can too, unless you turn that off; if Slack does not say who they are, Ryker does not let them in.",
         "New tokens for the same workspace keep the people you chose, and Slack stays on. Tokens for another workspace switch Slack off until you choose people there."
       ]},
      {"New channels and incident rooms",
       [
         "New channels sets when Ryker replies in a channel that has not chosen for itself: only when mentioned, also when it can clearly help, or never. Incident rooms sets how room channels are named and whether they are private."
       ]},
      {"What the states mean", [Integrations.meanings(:slack)]},
      {"When something looks wrong",
       [
         "If Slack is missing permissions, the error lists them. Add them to your Slack app, reinstall it in the workspace, then verify again.",
         "Replace the tokens only when they changed in your Slack app. Disconnect asks first, and keeps channels, instructions and history."
       ]}
    ])
  end

  defp help(:github) do
    page("How the GitHub connection works", [
      {"What GitHub gives Ryker",
       [
         "Ryker reads your code and opens pull requests through a GitHub App, so GitHub decides what it can reach. GitHub also checks each person's access on every request."
       ]},
      {"Connect the App",
       [
         "Enter the App ID and the private key (.pem) from the App's settings in GitHub, then press Verify GitHub App. Leave the webhook secret empty and Ryker creates one.",
         "Paste the callback URL shown here into the App's webhook settings, so GitHub can tell Ryker what changes."
       ]},
      {"Pull requests",
       [
         "Let Ryker open pull requests decides whether Ryker pushes a branch and opens a pull request when its work changes code. You can set how branches are named and who commits."
       ]},
      {"What the states mean", [Integrations.meanings(:github)]},
      {"When something looks wrong",
       [
         "Repairing the App keeps the repositories as they are. Add repositories on the Repositories page."
       ]}
    ])
  end

  defp help(:emisar) do
    page("How the Emisar connection works", [
      {"What Emisar does",
       [
         "Emisar lets Ryker act on your running systems, such as restarting a service or rolling back a deploy. A person approves each risky action in Emisar before it runs; Ryker never approves for anyone."
       ]},
      {"Connect an account",
       [
         "Create an agent API key in Emisar under AI agents, then connect it with Add account. Ryker checks the key with Emisar, then stores it encrypted and starts watching the account for approval decisions. The first account serves every environment that has none."
       ]},
      {"Accounts and environments",
       [
         "Each environment uses at most one account; choose it on the Environments page. Open an account from anywhere on its row to pause it, which stops sending it new work. Its history stays."
       ]},
      {"What the states mean", [Integrations.meanings(:emisar)]},
      {"When something looks wrong",
       [
         "If approval monitoring is off, tasks waiting on an approval stop and show on Failures. Turn it back on from the account's page, where you can also replace a key that changed.",
         "An account that tasks still use cannot be removed; pause it instead."
       ]}
    ])
  end

  defp help(:webhooks) do
    page("How webhooks work", [
      {"What webhooks do",
       [
         "Webhooks let other systems, such as Grafana, send alerts and events to Ryker. Each sender is a source with its own address. Its work goes to the conversation and environment you choose."
       ]},
      {"Set up a sender",
       [
         "First create a signing credential: senders sign each request with its secret, so Ryker knows it is theirs. Then add a webhook source, choose its credential and where its work goes.",
         "Open a source from anywhere on its row to see its address and give it to the sender. Remove source is at the bottom of that page."
       ]},
      {"Check a payload",
       [
         "Paste one delivery under Check a payload to see the events Ryker would record. Nothing is saved or sent.",
         "Group by labels treats events with the same values for those labels as one ongoing situation."
       ]},
      {"What the states mean", [Integrations.meanings(:webhooks)]},
      {"When something looks wrong",
       [
         "A credential that a source still uses cannot be deleted. Change or remove that source first."
       ]}
    ])
  end

  defp help(:settings) do
    page("How settings work", [
      {"What this page shows",
       [
         "The settings that decide how Ryker itself runs, each with what it sets and what it is set to now: models, data retention, model prices, the weekly report and advanced settings."
       ]},
      {"Change a setting",
       [
         "Open a setting to change it on its own page. Each page saves on its own, and asks first before a change that deletes data."
       ]},
      {"Where services are connected",
       [
         "Slack, GitHub, Emisar and webhooks are connected under Integrations, not here."
       ]}
    ])
  end

  defp help(:models) do
    page("How model settings work", [
      {"What this page sets",
       [
         "The model, reasoning effort and account for each kind of work: routing each message, conversation, standard and deep work, code changes, scheduled runs, incident rooms and learning.",
         "A change reaches new work within seconds."
       ]},
      {"Fallbacks",
       [
         "Ryker uses the first model of each kind of work. A fallback is used only when the one above it hits a usage limit or its sign-in stops working. Move up and Move down set the order.",
         "Conversation, Standard and Deep work use the same accounts in the same order, because a request can move between them. Their models and efforts can differ."
       ]},
      {"Models and accounts",
       [
         "The models offered are those with a price under Model prices, so a Claude model appears once its price is saved there, written like claude:claude-opus-4-6.",
         "Ryker cannot see which accounts the worker has signed in, so Model accounts lists them, one per row. Sign one in first with scripts/compose.sh model-login claude@work, then add it there with Add account. An account a model still runs on cannot be removed until that model uses another. If a model uses an account that is not signed in, the worker keeps the models saved before, and this page says why."
       ]},
      {"Choosing",
       [
         "Usage & cost shows what each kind of work costs, so you can see where a different model would matter. A model that no price covers shows its cost as not priced; Add a price opens Model prices.",
         "Local routing model tries a small model you run yourself, such as one in Ollama, on each routing prompt after the provider model has decided. Usage & cost shows how often it would have decided the same. Routing never waits for it and always uses the provider model's decision."
       ]},
      {"Saving",
       [
         "Each section saves on its own with Save changes, and a draft survives a refresh. If someone else saved in the meantime, the page shows what is saved now before you save over it."
       ]}
    ])
  end

  defp help(:retention) do
    page("How data retention works", [
      {"What this page sets",
       [
         "How long Ryker keeps each kind of data: prompts, replies and tool activity; finished work; request history; the audit trail; conversation memory; and, when you keep them, routing examples for training. Older data is deleted on its own."
       ]},
      {"Shortening a limit",
       [
         "A shorter limit deletes older data, so Ryker asks you to confirm first. Deleted data cannot be brought back.",
         "Shorter limits also leave less to inspect later: an old request may no longer show its full prompt."
       ]},
      {"Keep the order",
       [
         "Prompts, replies and tool activity may not be kept longer than finished work, finished work not longer than request history, and that not longer than the audit trail. The page says when limits are out of order."
       ]},
      {"Routing examples for training",
       [
         "With Keep routing examples for training on, Ryker keeps a copy of each routing decision once its outcome is known. A copy holds the exact prompt, the model's answer, the decision, how the request turned out and the cost. Credentials, and the part of a link after the question mark, are taken out first.",
         "Copies stay for their own limit, a year unless you change it, after the prompts above are deleted. Turning it off deletes every copy, so Ryker asks first. Deleting a message or a channel, or forgetting what Ryker learned from a message, removes it from every copy at once. Download routing examples saves them as a JSON Lines file for fine-tuning a model."
       ]}
    ])
  end

  defp help(:prices) do
    page("How model prices work", [
      {"What this page holds",
       [
         "What each model costs per million tokens, for input, cached input, output and reasoning, with the day a price starts and where it came from."
       ]},
      {"Where prices show up",
       [
         "The Models page warns about a model that no price covers. When a provider reports tokens but no cost, Usage & cost shows an estimate and lists the rates it used."
       ]},
      {"Add or remove a price",
       [
         "Add price opens a form on a page of its own, and each price opens its own from anywhere on its row. Save returns to the list.",
         "Remove price, at the bottom of a price's page, asks first: that model's cost then shows as not priced."
       ]}
    ])
  end

  defp help(:report) do
    page("How the weekly report works", [
      {"What it says",
       [
         "Once a week Ryker posts how its week went in one Slack channel. It says what people asked and what became of it, how they took its answers, and what self-analysis found. It also says how often its answers needed correcting, what it learned, which failures leave someone waiting, and what its model calls cost.",
         "Each number stands beside last week's, each part links to the page with the rest, and a part with nothing to say says None."
       ]},
      {"Where the numbers come from",
       [
         "Ryker counts them from what it has on record. No model writes the report, so it cannot say anything the records do not hold.",
         "A report covers the seven days before it is sent. It names a request, a topic or a diagnosis only when it came from a public channel, and a fact only when the whole workspace can use it. The rest is counted and linked, not quoted."
       ]},
      {"When it posts",
       [
         "At the day and time you choose, once a week. Turning it on never posts at once: the first report goes out at the next day and time.",
         "If Ryker was down at that time, it posts the report when it is back. After a long outage it posts one report, not one for every week it missed."
       ]},
      {"Preview",
       [
         "Preview this week's report shows what a report sent now would say, from the seven days before now. Nothing is posted."
       ]},
      {"When something looks wrong",
       [
         "Invite Ryker to the channel before turning the report on. If Slack refuses the post, it shows on Failures, where Post the report again sends the same report to the same channel."
       ]}
    ])
  end

  defp help(:advanced) do
    page("How advanced settings work", [
      {"What this page shows",
       [
         "Where Ryker's work runs and what each kind of work may do. A worker is a machine that runs the model and its tools in isolation.",
         "The bundled worker is set up for you, so most installations never change anything here."
       ]},
      {"Code and settings for each job",
       [
         "Ryker selects the code and settings for each job. When a job uses a repository, the worker fetches its code into an isolated working copy.",
         "Choose models on the Models page. Workers need no policy files."
       ]},
      {"Tasks that change code",
       [
         "Tasks that change code says whether Ryker can change code right now. When it cannot, it says what is missing and how to check the installation."
       ]},
      {"What is running",
       [
         "Show what is loaded lists what the running Ryker actually uses, for support and troubleshooting. Nothing there can be changed; a saved setting shows there once it is applied.",
         "Its integrations show the same state as their own pages, with whether the running Ryker loaded them under Details."
       ]},
      {"When something looks wrong",
       [
         "When requests wait because no worker can take them, start here. Then check Working copies, where a full worker stops taking new work."
       ]}
    ])
  end

  defp help(:setup) do
    page("How setup works", [
      {"What setup does",
       [
         "Setup walks you through what Ryker needs, one step at a time: connect Slack and GitHub, add repositories, invite Ryker to a channel, choose that channel's environment and send a real request."
       ]},
      {"Steps check themselves off",
       [
         "Only the current step is open, with what it needs and one button. Ryker notices the Slack steps on its own, such as being invited or replying, and checks them off."
       ]},
      {"Emisar is recommended",
       [
         "Emisar is optional but recommended. With it, Ryker can carry out fixes on running systems after a person approves them. Without it, Ryker can only tell you what to run."
       ]},
      {"After setup",
       [
         "Once every step is done, mention @Ryker in the channel or open Chat. You can change each step later on its own page."
       ]}
    ])
  end

  defp page(title, sections) do
    %{
      title: title,
      sections:
        Enum.map(sections, fn {heading, paragraphs} ->
          %{heading: heading, paragraphs: paragraphs}
        end)
    }
  end
end
