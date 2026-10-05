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
    {"/timeline/:id", :timeline},
    {"/conversations", :chat},
    {"/conversations/:id", :chat},
    {"/incident-rooms", :incident_rooms},
    {"/incident-rooms/:slug", :incident_room},
    {"/failures", :failures},
    {"/failures/:kind/:id", :failure},
    {"/usage", :usage},
    {"/environments", :environments},
    {"/channels", :channels},
    {"/channels/:workspace/:channel", :channel},
    {"/repositories", :repositories},
    {"/repositories/:ref", :repositories},
    {"/working-copies", :working_copies},
    {"/rules", :rules},
    {"/schedules", :schedules},
    {"/schedules/:id", :schedule},
    {"/follow-ups", :follow_ups},
    {"/instructions", :instructions},
    {"/memory", :facts},
    {"/memory/learned", :learned},
    {"/memory/findings", :findings},
    {"/memory/people", :people},
    {"/memory/learning", :learning},
    {"/feedback", :feedback},
    {"/feedback/fix", :improvement},
    {"/integrations", :integrations},
    {"/integrations/slack", :slack},
    {"/integrations/github", :github},
    {"/integrations/emisar", :emisar},
    {"/integrations/webhooks", :webhooks},
    {"/settings", :settings},
    {"/settings/models", :models},
    {"/settings/models/local-routing", :local_routing},
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
         "Every request people made of Ryker and what Ryker did with it. A request can be a Slack message, a Chat message, a GitHub event or an alert from another tool."
       ]},
      {"Find a request",
       [
         "The counts at the top open the requests in progress and the ones that need you. Search matches message text and repository names.",
         "All, Needs you, In progress and Finished narrow the list, and + Filter adds a filter such as a repository or a model."
       ]},
      {"Open a request",
       [
         "Click a row to open its timeline. It shows every step from reading the message to sending the answer, and what each step cost."
       ]},
      {"When something looks wrong",
       [
         "Needs you lists work that is blocked or waiting for a person; open a row to see why. Work Ryker gave up on is also on Failures, with what you can do about it.",
         "If no worker can take work, the Workers section under the list says so, and requests wait until a worker is back."
       ]},
      {"Ask Ryker",
       [
         "Mention @Ryker in a Slack channel it's in, or write to it in Chat. The request appears here within seconds."
       ]}
    ])
  end

  defp help(:timeline) do
    page("How a timeline works", [
      {"What this page shows",
       [
         "One request from start to finish: the message that started it, how Ryker decided what to do, the work it did and the answer it sent.",
         "A message Ryker answered, reacted to or left alone without starting work gets a page like this too, followed by the rest of its thread."
       ]},
      {"Read the steps",
       [
         "Each message goes through Intake, Routing, Work and Answer. Open a card for its details, including the exact request Ryker sent to the model and the answer it got.",
         "Use a card's # link to share that exact step."
       ]},
      {"After the answer",
       [
         "Learning shows what Ryker learned from these messages in the background, with the prompt, answer and cost. Cleanup shows how the worker's session ended and whether its working copy was kept.",
         "Feedback comes last: what people said about the answers and how someone rated the request. Once a request is finished, the page asks how it went, and Needs work sends it to Self-improvement."
       ]},
      {"The summary at the top",
       [
         "The top shows where the request stands, how long it took and what it cost; a cost marked ≈ includes an estimate. Next action says what the request is waiting for, if anything."
       ]},
      {"When something looks wrong",
       [
         "If the work is blocked, Next action links to its recovery page, which says what stopped and whether a retry should work.",
         "Retry work and Close as no longer needed both ask before they run."
       ]}
    ])
  end

  defp help(:chat) do
    page("How Chat works", [
      {"What Chat is",
       [
         "A direct conversation with Ryker outside Slack. Ryker can do everything here that it does in a Slack channel: answer questions, investigate, change code, remember things and set up schedules.",
         "Each conversation works in one environment, which decides the repositories and Emisar account its work can use. New conversations start in the default environment, and you can pick another under the message box."
       ]},
      {"Start a conversation",
       [
         "Type a message and press Send or ⌘/Ctrl + Enter. Picking an example only fills the box, and nothing is saved until you send.",
         "You can attach up to two files, 8 MiB in total: images, PDFs and text files such as logs, CSV, JSON or YAML. Ryker transcribes voice recordings and videos up to five minutes long."
       ]},
      {"Follow the work",
       [
         "Ryker's progress shows under your message while it works. The Timeline link on each message opens everything Ryker did for it in a new tab.",
         "You can edit or delete your own messages and react to Ryker's replies with emoji, as in Slack."
       ]},
      {"When something looks wrong",
       [
         "If the work behind a message stops, the message offers Retry and Inspect cause. While Chat is still getting ready, a notice replaces the message box and says what it's waiting for."
       ]}
    ])
  end

  defp help(:incident_rooms) do
    page("How incident rooms work", [
      {"What an incident room is",
       [
         "A Slack channel Ryker creates to work through one incident with your team. Ryker invites the responders, investigates in the channel and posts what it finds there."
       ]},
      {"Open a room",
       [
         "Ask Ryker in the alert's Slack thread: \"Open an incident room for this.\" Ryker offers the room and creates it once you confirm. When Ryker investigates an alert, it may offer a room itself.",
         "A channel can also open a room for every alert. To turn that on, type /ryker status in the channel and choose Configure channel."
       ]},
      {"What the states mean",
       [
         "Setting up means Ryker is creating the channel and inviting people, and Open means the room is in use. Needs attention means setup stopped partway. A closed room keeps its history here."
       ]},
      {"Find a room",
       [
         "Search by title, repository or channel ID, or filter by state. A room's page shows Ryker's latest update, the whole story and any code change it proposed."
       ]},
      {"When something looks wrong",
       [
         "A room that needs attention links to what stopped on Failures. Continuing its setup resumes at the step that stopped and reuses the channel it already made."
       ]}
    ])
  end

  defp help(:incident_room) do
    page("How an incident room works", [
      {"What this page shows",
       [
         "One incident room as an incident report: how long it has been open, what started it, where Ryker stands and what it found.",
         "The timeline tells the story oldest first: the alert, the room's setup, what people and Ryker said in the channel, what Ryker recorded and what Slack reported. The page updates by itself."
       ]},
      {"The investigation",
       [
         "People and Ryker work on the incident in the room's Slack channel. Every step of the investigation opens the request's own timeline, with each model call.",
         "If Ryker proposed a fix, Code change shows the pull request and its status."
       ]},
      {"Closing a room",
       [
         "Close room stops Ryker's investigation and posts a closing note in the channel and in the alert thread. After that Ryker won't answer in the channel.",
         "The channel stays in Slack; archive it there when you're done with it. The room's history stays here, and a closed room can't be reopened."
       ]},
      {"When the channel changes",
       [
         "If the channel is archived, Ryker pauses until someone restores it. If Ryker can't find the channel, add Ryker back or close the room.",
         "If the channel is deleted, the room closes and Ryker says so in the alert thread, along with any reply it still owed the room."
       ]},
      {"When something looks wrong",
       [
         "If setting up the room stopped, See what stopped opens it on Failures with what you can do. Continuing resumes at the step that stopped and posts nothing twice."
       ]}
    ])
  end

  defp help(:failures) do
    page("How failures work", [
      {"What this page shows",
       [
         "Work Ryker couldn't finish by itself, newest first. Affects people lists what someone is still waiting for, such as a reply or a Slack update, and Housekeeping lists cleanup nobody is waiting on."
       ]},
      {"Read a row",
       [
         "Each row says what stopped, who it affects and why Ryker gave up. Its state says whether a retry should help: Retry should work, Needs you, Fix needed first, Retry won't help or Retrying on its own."
       ]},
      {"Fix it",
       [
         "A row has a button only when pressing it can help, and the button asks before anything runs. When something else has to change first, the row links to where you change it.",
         "Open a row for the whole story: what happened, what it affects, what Ryker tried and what you can do."
       ]},
      {"How items leave the list",
       [
         "Ryker retries most things several times before listing them here. A failure leaves the list when the work finishes, after your retry or by itself, or when you leave it as it is."
       ]}
    ])
  end

  defp help(:failure) do
    page("How a failure page works", [
      {"What this page shows",
       [
         "One piece of work Ryker couldn't finish by itself. What happened lists what stopped and why, who is waiting on it and what Ryker already tried."
       ]},
      {"What you can do",
       [
         "Each option says what it does and whether it should work, with the recommended one first. Leave it says what happens if nobody acts.",
         "A retry asks you to confirm before it runs."
       ]},
      {"When a retry won't help",
       [
         "If something has to change first, like a token or Ryker's access to a Slack channel, the page links to where you change it. Fix that, then retry.",
         "Leave it hides the failure from Failures while it keeps failing the same way. Ryker's own retries don't bring it back; failing some other way does."
       ]},
      {"After it is fixed",
       [
         "Once the work finishes, the failure leaves the list, and the request's timeline shows what happened next."
       ]}
    ])
  end

  defp help(:usage) do
    page("How usage and cost work", [
      {"What this page shows",
       [
         "How much work Ryker ran and what it cost over the last 24 hours, 7 days, 30 days or all time. It counts every model call: routing, replies, investigations, tasks and background learning.",
         "It opens on live work, like Activity; All work adds evaluation runs."
       ]},
      {"Read the tables",
       [
         "The figures at the top show cost, requests, runs and tokens, and the tables split them by account, model, channel, repository, kind of work and user.",
         "Click a row to see the requests behind it on Activity."
       ]},
      {"How cost is counted",
       [
         "Cost is what the model provider reported. If a provider reports tokens but no cost, Ryker estimates it from the prices in Settings › Model prices and lists the rates under Rates used for estimates. Not measured means nothing was reported."
       ]},
      {"When something looks wrong",
       [
         "A high cost usually comes from one model or one kind of work, and the tables show which. To use a different model for a kind of work, change it in Settings › Models."
       ]}
    ])
  end

  defp help(:environments) do
    page("How environments work", [
      {"What an environment is",
       [
         "An environment is where Ryker works: the repositories its work can use and, optionally, an Emisar account. Each Slack channel, webhook source and Chat conversation works in one environment."
       ]},
      {"Repositories",
       [
         "Work can read every repository in its environment, and each repository is read only or read and write. A task that changes code uses a read and write repository, the default one unless it picks another.",
         "The default repository is always read and write. A repository you add joins no environment: choose it here for work to use it."
       ]},
      {"Emisar",
       [
         "With an Emisar account, work here can ask Emisar to run actions such as a restart, and a person approves each one there. Without an account, Ryker can only tell you what to run."
       ]},
      {"The default environment",
       [
         "New Chat conversations, and channels that haven't picked an environment, use the default one. To change the default, open another environment and tick Default environment."
       ]},
      {"Add, change or remove",
       [
         "Click an environment's row to edit it on its own page: its name, description, repositories and what work may do in each, its Emisar account and whether it's the default.",
         "Remove environment, at the bottom of that page, asks first. It's refused while channels or webhook sources still use the environment."
       ]}
    ])
  end

  defp help(:channels) do
    page("How channels work", [
      {"What this page shows",
       [
         "The Slack channels Ryker is in and how it takes part in each: when it replies, which environment its work uses and when it was last active."
       ]},
      {"Add a channel",
       [
         "Invite Ryker with /invite @Ryker. The channel appears here, and Ryker posts a welcome message in it with a Customize button for its setup."
       ]},
      {"How Ryker takes part",
       [
         "With Replies when mentioned, Ryker answers only when someone writes @Ryker. Joins relevant conversations also lets it reply when it can clearly help, and Watches quietly has it read and learn without replying.",
         "New channels, under Slack at the top of this page, sets how Ryker takes part in a channel it joins until that channel makes its own choice."
       ]},
      {"Change a channel",
       [
         "Open a channel to change how Ryker takes part there, what it does with alerts and which environment its work uses. Each choice saves as soon as you make it.",
         "You can change the same settings in Slack: type /ryker status in the channel and choose Configure channel."
       ]},
      {"Find a channel",
       [
         "In use lists the channels Ryker is in, and All adds the ones it left or never joined. Search matches a channel's name, workspace or environment.",
         "Connected means Ryker is in the channel, Disconnected that it left or was removed, and Not connected that it was never invited. Deleted means the channel is gone from Slack."
       ]}
    ])
  end

  defp help(:channel) do
    page("How this channel works", [
      {"What this page shows",
       [
         "Everything about one Slack channel: its settings, the environment its work uses, its own instructions and what applies here, then recent work, schedules and usage. Click the channel's name to open it in Slack."
       ]},
      {"Channel settings",
       [
         "Conversations sets when Ryker replies here, Alerts what it does with posted alerts, and Environment which repositories and Emisar account its work can use. With no environment, Ryker can't use code or act on running systems here.",
         "Each choice saves as soon as you make it, and Ryker's welcome message in the channel updates to match."
       ]},
      {"Instructions and what applies",
       [
         "This channel's instructions add to the instructions for every conversation, which you change on the Instructions page. What applies here lists the rules, saved instructions and facts Ryker uses in this channel, and where each one comes from."
       ]},
      {"Ask Ryker in the channel",
       [
         "To add a rule, tell Ryker in the channel something like \"When someone posts a Terraform plan here, review it for risky changes.\" For a schedule: \"Every Monday at 09:00 Berlin time, summarize open incidents here.\"",
         "Ryker shows what it will save and waits for you to confirm."
       ]},
      {"Change it from Slack",
       [
         "In the channel, type /ryker status and choose Configure channel to change the same settings. Only you see Ryker's answer, and the change shows up here."
       ]}
    ])
  end

  defp help(:repositories) do
    page("How repositories work", [
      {"What this page shows",
       [
         "The code Ryker can read and change. Each repository shows whether it's Ready, Setting up, Not fully added or Needs attention, which environments it's in and where it was used."
       ]},
      {"Add and remove repositories",
       [
         "Connect GitHub first. Add repositories lists what the Ryker GitHub App can reach. Work uses a repository once you choose it in an environment. You can also have new ones added automatically when the App gets access.",
         "Remove repository, at the bottom of a repository's page, takes it out of every environment, stops its setup and deletes Ryker's copy of its code. It asks first, past requests stay, and you can add it again."
       ]},
      {"Knowledge",
       [
         "Once a repository is set up, a model reads it and writes down what it's for, its parts, how to build, test and ship it, and where to look. Every later task there starts from that.",
         "Ryker keeps only paths that exist and commands the files show, and writes nothing to the repository. It checks daily and rewrites the notes after the README, AGENTS.md, CLAUDE.md, a build file or CI changes, or weekly after other code changes."
       ]},
      {"Who can ask for work",
       [
         "Anyone with write access to an added repository can ask Ryker to work there, and GitHub checks that access on every request."
       ]},
      {"When something looks wrong",
       [
         "Needs attention says what stopped, such as removed GitHub access. Fix the cause, then press Retry setup on the repository's page.",
         "Not fully added means adding stopped before it finished, and Add it again on the repository's page finishes it."
       ]}
    ])
  end

  defp help(:working_copies) do
    page("How working copies work", [
      {"What this page shows",
       [
         "A working copy is a checkout Ryker makes when a task works on code. This page lists them, how much space they take on each worker and what cleanup does next."
       ]},
      {"Cleanup",
       [
         "Ryker removes a copy once that's safe. It keeps copies with uncommitted changes or with commits that were never merged, so no work is lost.",
         "Ready for cleanup lists what goes next, oldest first, and Removed lists what cleanup already removed."
       ]},
      {"When cleanup needs you",
       [
         "Cleanup needs attention means Ryker stopped for the reason shown. Resume cleanup retries the same step, and Discard unmerged throws away commits that were never merged but keeps uncommitted changes. Both ask first."
       ]},
      {"Storage",
       [
         "Each worker reports how much space is in use, how much can be freed and how much it is allowed. A full worker takes no new copies until space frees up."
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
         "Tell Ryker in the channel, for example: \"When someone posts a Terraform plan here, review it for risky changes.\" Ryker shows the rule and saves it once you confirm."
       ]},
      {"Current and past",
       [
         "Current lists rules that are on or paused. Past lists the ones that expired, were deleted or were replaced by a newer rule, and each row says when its rule stops."
       ]},
      {"Pause, resume or delete",
       [
         "Pause stops a rule without losing it, and Resume turns it back on. Delete removes it for good and keeps its history. All three ask first."
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
         "A task Ryker runs at a set time, once or repeatedly, such as a Monday summary of open incidents. Results go to the conversation or thread where the schedule was set up."
       ]},
      {"Add a schedule",
       [
         "Ask Ryker where the results should go, for example: \"Every Monday at 09:00 Berlin time, summarize unresolved incidents in this channel.\" Ryker shows the schedule and saves it once you confirm."
       ]},
      {"Change a schedule",
       [
         "Click a schedule's row to open it. Run now adds one extra run, Pause stops new runs until you resume, and Delete schedule ends it but keeps its past runs. Each asks first.",
         "To change what it does or when, ask Ryker in the conversation where it was set up."
       ]},
      {"Current and past",
       [
         "Current lists schedules that are on or paused. Past lists the ones that finished, expired or were deleted; a one-time schedule finishes after its run."
       ]},
      {"When something looks wrong",
       [
         "Failed to start means Ryker couldn't begin a run, and it tries again by itself. Open the schedule to see each run and the request behind it."
       ]}
    ])
  end

  defp help(:schedule) do
    page("How this schedule works", [
      {"What this page shows",
       [
         "One schedule: how often it runs, where the results go, which repository it uses and what it may do, followed by every run, newest first."
       ]},
      {"What it may do",
       [
         "With Read only, a run only looks. Can change the repository lets a run change code, and Can run approved operations lets it carry out actions a person approves in Emisar."
       ]},
      {"Controls",
       [
         "Run now starts one extra run, and Pause and Resume stop and restart new runs. Delete schedule, at the bottom of the page, ends it for good and keeps its runs listed. Each asks first."
       ]},
      {"Runs",
       [
         "Each run starts its own request, which you can open to see what Ryker did. Missed means a run couldn't start within 15 minutes of its time; the next run still starts on time."
       ]},
      {"Change it",
       [
         "To change what the schedule asks for or when it runs, ask Ryker in the conversation where it was set up. Ryker shows the new version for you to confirm."
       ]}
    ])
  end

  defp help(:follow_ups) do
    page("How follow-ups work", [
      {"What a follow-up is",
       [
         "Work Ryker paused on purpose. It waits for a set time or for something to happen, like a pull request being merged, and then continues the same request."
       ]},
      {"Where they come from",
       [
         "Ryker adds follow-ups by itself when work has to wait. You can also ask for one in the conversation, for example \"Check again tomorrow morning.\""
       ]},
      {"Read a row",
       [
         "Each row says what it's waiting for, which request it continues and when Ryker checks again or gives up. Current lists what's waiting, and Past lists what resumed, timed out or was cancelled."
       ]},
      {"Stop one",
       [
         "To stop a follow-up, open the request it continues and choose Close as no longer needed."
       ]}
    ])
  end

  defp help(:instructions) do
    page("How instructions work", [
      {"What instructions are",
       [
         "Instructions tell Ryker how to work, in your own words, and it follows them in every reply, investigation and task. They can't give it permission to do more."
       ]},
      {"For every conversation",
       [
         "Write what should apply everywhere, up to 2,000 characters, and press Save. Ryker picks up the change at its next step, and work already running keeps the instructions it started with.",
         "For example: \"Keep replies concise. Separate observed facts from guesses.\""
       ]},
      {"For one channel",
       [
         "A channel's own instructions add to these in that channel only, and win where the two disagree. Add them on the channel's page."
       ]},
      {"Saved from conversations",
       [
         "Preferences and guidance are things people asked Ryker to keep in mind, such as \"Remember to keep incident updates short.\" Ryker shows what it will save and keeps it once you confirm.",
         "Each one expires after the time chosen when it was saved. Pause, Resume and Delete ask first."
       ]}
    ])
  end

  defp help(:facts) do
    page("How facts work", [
      {"What a fact is",
       [
         "Something a person asked Ryker to remember, such as what a service is called or which repository holds it. Ryker uses facts as context in later work; they don't give it permission to act."
       ]},
      {"Add a fact",
       [
         "Tell Ryker in Chat or Slack: \"Remember that pay-gw is the payments gateway.\" Ryker shows what it will save and saves it once you confirm.",
         "A fact applies everywhere, to one repository or to one channel."
       ]},
      {"Review and forget",
       [
         "Needs review lists facts Ryker hasn't used in a while and facts saved more than once. You can keep, edit, merge or forget each one.",
         "Forget erases a fact so Ryker stops using it. Every change asks first."
       ]},
      {"Ask Ryker",
       [
         "In a Slack channel, ask Ryker \"What do you remember here?\" to see the facts it would use there."
       ]}
    ])
  end

  defp help(:learned) do
    page("How learned topics work", [
      {"What this page shows",
       [
         "What Ryker learned by reading conversations. A topic holds what it knows about one subject and the messages it learned it from; a conversation summary says where that conversation stands."
       ]},
      {"Where it comes from",
       [
         "Ryker reads the conversations it can see in the background, including ones it doesn't reply in. It updates a topic when it learns something new and keeps every earlier version in the topic's history."
       ]},
      {"How Ryker uses it",
       [
         "Ryker recalls topics and summaries as context for later requests, so it can pick up where a conversation left off. None of it gives Ryker permission to act."
       ]},
      {"When something looks wrong",
       [
         "Not used means a topic lost a message it learned from, so Ryker stopped using it; hover over Not used to see why.",
         "Relearn, on a topic's page, rebuilds it from messages you choose with the current learning settings and keeps its history. Forget topic, at the bottom of the page, stops Ryker using it for good."
       ]},
      {"Read a topic's history",
       [
         "A topic's page lists every update, newest first, with the message it came from.",
         "How this was learned opens the learning pass on the Timeline, with the exact request Ryker sent, the answer and the cost."
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
         "Explained means the evidence shows why it happened. Expected and Out of scope come with Ryker's reason, and Not explained yet means the question is still open."
       ]},
      {"Find a finding",
       [
         "The counts at the top show how many findings there are and how many aren't explained yet. The buttons next to the search show one kind at a time, and search matches what a finding concluded, why and where it applies."
       ]},
      {"Open a finding",
       [
         "A finding's page shows everything Ryker concluded, why, where it applies, the evidence and the investigation that reached it. Evidence that has expired is marked."
       ]},
      {"Settle a finding",
       [
         "Mark explained settles a finding Ryker couldn't explain, once you know why it happened. Forget finding is for one that's wrong or no longer matters.",
         "Either way Ryker stops using the finding in later requests, and it stays here and in the investigation's history. Both ask first and can't be undone."
       ]}
    ])
  end

  defp help(:people) do
    page("How People works", [
      {"What Ryker learns",
       [
         "While reading conversations in the background, Ryker notices what people say about themselves: a birthday, the name they go by, their time zone, a favourite show. Nobody approves it, so it's listed here.",
         "It keeps only what people say about themselves, never what someone says about someone else, and nothing sensitive such as health or beliefs. Apps and bots teach it nothing."
       ]},
      {"How Ryker uses it",
       [
         "Only when that person is the one asking, to be considerate, like wishing them a happy birthday or using the name they prefer. It isn't evidence or permission, and Ryker doesn't share it with anyone else.",
         "Something said in a direct message or a private channel is used only there."
       ]},
      {"Forgetting",
       [
         "A person can tell Ryker to forget something, and editing or deleting a message forgets what it taught. Deleting a Slack channel forgets what was said in it.",
         "Open a person to see what Ryker knows and where each thing was said. Forget removes one thing, and Forget this person removes all of it; only what they say later is learned again."
       ]},
      {"How long it is kept",
       [
         "Until it's forgotten. A birthday is worth remembering longer than the conversation it came up in is kept."
       ]}
    ])
  end

  defp help(:feedback) do
    page("How feedback works", [
      {"What feedback is",
       [
         "What people told Ryker about its answers in Slack and Chat, kept with the request each answer belongs to. Nobody fills anything in; Ryker notices it.",
         "Feedback can be a reaction on one of Ryker's messages or the same question asked again soon after an answer. It can also be a message changed or deleted after the answer, or the tone of the person's next message."
       ]},
      {"The kinds, frustrated first",
       [
         "Frustrated covers anyone frustrated or angry with an answer, and thumbs down and similar reactions. Then come Asked again and Edited or deleted, then Neutral, Satisfied and your reviews of finished requests."
       ]},
      {"Find what went wrong",
       [
         "Open a row to see the request's timeline: the message, what Ryker understood, what it did and what it answered. The request's own page lists its feedback in a section of its own.",
         "By day, at the top, shows whether things got worse, one bar per day with negative at the bottom and positive on top. Open a kind to see all of it, newest first, and search its reasons."
       ]},
      {"Negative and positive",
       [
         "Negative shows frustrated people, repeated questions and messages changed or deleted after an answer. Positive shows people who said or showed that an answer helped, and All shows everything."
       ]},
      {"How long it is kept",
       [
         "Feedback is kept as long as prompts and replies, which you set on the Data retention page."
       ]}
    ])
  end

  defp help(:improvement) do
    page("How What to fix works", [
      {"What is here",
       [
         "Each request someone was unhappy with, listed once however much feedback it got. They were frustrated or angry, reacted with a thumbs down, asked the same thing again, or changed or deleted their message after the answer.",
         "Requests you reviewed as stopped are here too. Last 7 days, under the counts, sums up the week: the requests found, what Ryker made of them and how many were accepted or dismissed."
       ]},
      {"How Ryker reads them",
       [
         "While background learning is on, Ryker reads each request with the learning models once it's done and a few minutes pass without new feedback. It says whose fault it was, what went wrong and where, what it should have done and how sure it is.",
         "A request without the person's words, such as one an alert started, says why it wasn't analyzed. The analysis changes nothing by itself."
       ]},
      {"What the kinds mean",
       [
         "Host bug means Ryker's own code let the model down, such as a missing tool or a good answer it mishandled. Prompt bug means the model followed its instructions and they led it wrong.",
         "Model mistake means the instructions were enough and the model still got it wrong. Not a problem means the answer was reasonable, and Unclear means the evidence doesn't say."
       ]},
      {"Decide",
       [
         "Accept a request to keep it as an eval case, with the messages it depends on, so the case outlives them. Dismiss one that isn't worth it. Both ask first, and the Accepted and Dismissed views let you change your mind.",
         "GitHub requests can't be kept as eval cases yet, because eval cases replay Slack and Chat messages. Download eval cases gives each accepted case as a world scenario for testdata/scenarios; mix ryker.eval_cases --output DIR writes the same files."
       ]},
      {"How long it is kept",
       [
         "Requests here are kept as long as prompts and replies, and accepted cases as long as routing examples, while you keep those for training. Forgetting or deleting a message a case quotes erases it immediately."
       ]}
    ])
  end

  defp help(:learning) do
    page("How background learning works", [
      {"What learning is",
       [
         "Ryker reads conversations in the background and keeps what it learned up to date on the Learned page. Learning doesn't post anything."
       ]},
      {"Turn it on or off",
       [
         "The switch at the top of the list turns learning on right away; turning it off asks first. While it's off, new messages wait and nothing already learned is lost.",
         "The same switch also controls the self-analysis of requests people were unhappy with, on Feedback › What to fix."
       ]},
      {"Recent passes",
       [
         "Each pass reads new messages from one conversation, and finding nothing to change is normal. Filter by outcome to see the passes that changed something.",
         "Open a batch to see what Ryker learned: the model's reason in its own words and each topic it created or updated. Each attempt opens on the Timeline with its prompt, answer, tokens and cost."
       ]},
      {"When learning needs you",
       [
         "Needs attention lists conversations where learning stopped, such as after using all its tries. Grant one more start tries the same messages again, and Drop batch gives up on them.",
         "If it stopped on a topic that lost its messages, relearn or forget that topic first. If learning can't start, the page links to the settings it's missing."
       ]}
    ])
  end

  defp help(:integrations) do
    page("How integrations work", [
      {"What this page shows",
       [
         "The services Ryker works through, each with its status and the next step."
       ]},
      {"What each one gives Ryker",
       [
         "Slack is where Ryker reads and replies, and GitHub lets it read code and open pull requests. Emisar lets it carry out fixes a person approves, and webhooks let tools such as Grafana send it alerts."
       ]},
      {"Connect or change one",
       [
         "Connect, Set up and Manage open the service's own page, which checks what you paste before saving it.",
         "Disconnecting asks first and keeps channels, repositories and history."
       ]},
      {"When something looks wrong",
       [
         "A service that needs repair says so here; open its page to see what failed and fix it."
       ]}
    ])
  end

  defp help(:slack) do
    page("How the Slack connection works", [
      {"Connect Slack",
       [
         "Paste the app token (xapp-…) and bot token (xoxb-…) from your Slack app and press Verify Slack. Ryker checks them and finds the workspace and its bot.",
         "To finish, choose who can manage Ryker."
       ]},
      {"Who can manage Ryker",
       [
         "These people can change Ryker's settings from Slack, such as a channel's setup or a new rule. Workspace admins and owners can too, unless you turn that off or Slack doesn't say who they are.",
         "New tokens for the same workspace keep the people you chose, and Slack stays on. Tokens for a different workspace switch Slack off until you choose people there."
       ]},
      {"New channels and incident rooms",
       [
         "New channels sets when Ryker replies in a channel that hasn't made its own choice: only when mentioned, also when it can clearly help, or never. Incident rooms sets how room channels are named and whether they're private."
       ]},
      {"What the states mean", [Integrations.meanings(:slack)]},
      {"When something looks wrong",
       [
         "If Slack is missing permissions, the error lists them. Add them to your Slack app, reinstall the app in the workspace, then verify again.",
         "Replace the tokens only when they changed in your Slack app. Disconnect asks first and keeps channels, instructions and history."
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
         "Enter the App ID and private key (.pem) from the App's settings on GitHub and press Verify GitHub App. If you leave the webhook secret empty, Ryker creates one.",
         "Paste the callback URL shown here into the App's webhook settings so GitHub can tell Ryker about changes."
       ]},
      {"Pull requests",
       [
         "Let Ryker open pull requests decides whether Ryker pushes a branch and opens a pull request when its work changes code. You can also set how branches are named and who commits."
       ]},
      {"What the states mean", [Integrations.meanings(:github)]},
      {"When something looks wrong",
       [
         "Repairing the App leaves your repositories as they are. Add repositories on the Repositories page."
       ]}
    ])
  end

  defp help(:emisar) do
    page("How the Emisar connection works", [
      {"What Emisar does",
       [
         "Emisar lets Ryker act on your running systems, such as restarting a service or rolling back a deploy. A person approves each risky action in Emisar before it runs, and Ryker can't approve for anyone."
       ]},
      {"Connect an account",
       [
         "Create an agent API key in Emisar under AI agents and connect it with Add account. Ryker checks the key with Emisar, stores it encrypted and starts watching the account for approvals.",
         "The first account serves every environment that doesn't have one."
       ]},
      {"Accounts and environments",
       [
         "Each environment uses at most one account, which you choose on the Environments page. Open an account to pause it, which stops new work going to it and keeps its history."
       ]},
      {"What the states mean", [Integrations.meanings(:emisar)]},
      {"When something looks wrong",
       [
         "If approval monitoring is off, tasks waiting for an approval stop and appear on Failures. Turn it back on from the account's page, where you can also replace a changed key.",
         "You can't remove an account that tasks still use; pause it instead."
       ]}
    ])
  end

  defp help(:webhooks) do
    page("How webhooks work", [
      {"What webhooks do",
       [
         "Webhooks let other systems, such as Grafana, send alerts and events to Ryker. Each sender is a source with its own address, and its work goes to the conversation and environment you choose."
       ]},
      {"Set up a sender",
       [
         "First create a signing credential; senders sign each request with its secret so Ryker knows it came from them. Then add a webhook source and choose its credential and where its work goes.",
         "Open a source to see its address and give that to the sender. Remove source is at the bottom of the source's page."
       ]},
      {"Check a payload",
       [
         "Paste one delivery under Check a payload to see the events Ryker would record from it. Nothing is saved or sent.",
         "Group by labels treats events with the same values for those labels as one ongoing situation."
       ]},
      {"What the states mean", [Integrations.meanings(:webhooks)]},
      {"When something looks wrong",
       [
         "You can't delete a credential that a source still uses; change or remove that source first."
       ]}
    ])
  end

  defp help(:settings) do
    page("How settings work", [
      {"What this page shows",
       [
         "The settings for how Ryker itself runs, each with what it controls and its current value: models, data retention, model prices, the weekly report and advanced settings."
       ]},
      {"Change a setting",
       [
         "Open a setting to change it on its own page. Each page saves separately and asks before a change that deletes data."
       ]},
      {"Where services are connected",
       [
         "Slack, GitHub, Emisar and webhooks are connected under Integrations."
       ]}
    ])
  end

  defp help(:models) do
    page("How model settings work", [
      {"What this page sets",
       [
         "The model, reasoning effort and account for each kind of work: routing messages, conversations, standard and deep work, code changes, scheduled runs, incident rooms and learning.",
         "Changes reach new work within seconds."
       ]},
      {"Fallbacks",
       [
         "Ryker uses the first model listed for each kind of work. It falls back to the next one only when the model above hits a usage limit or its sign-in stops working.",
         "Conversation, Standard and Deep work share the same accounts in the same order, because a request can move between them. Their models and efforts can differ."
       ]},
      {"Models and accounts",
       [
         "The models offered are the ones with a price under Model prices, so a Claude model appears once its price is saved there, written like claude:claude-opus-4-6.",
         "Ryker can't see which accounts the worker has signed in, so you list them under Model accounts. Sign one in with scripts/compose.sh model-login claude@work, then add it with Add account."
       ]},
      {"Choosing",
       [
         "Usage & cost shows what each kind of work costs, so you can see where a different model would matter. A model with no price shows its cost as not priced, and Add a price opens Model prices.",
         "Local routing model tries a small model you run yourself on each routing prompt after the provider model has decided. See how it compares, on its card, shows how often the two agree."
       ]},
      {"Saving",
       [
         "Each section has its own Save changes, and drafts survive a refresh. If someone else saved in the meantime, the page shows the saved version before you overwrite it."
       ]}
    ])
  end

  defp help(:local_routing) do
    page("How the local routing model comparison works", [
      {"What this page shows",
       [
         "Each live message routed while the comparison is on also goes to the small model you run yourself, after the provider model has decided. Routing doesn't wait for the local model or use its answer.",
         "Valid counts the local answers that passed routing's checks, and agreed counts the ones that matched the provider."
       ]},
      {"Reading the figures",
       [
         "Median local time is how long the local model took to answer, and median provider time is how long the provider took. Provider cost is what the provider spent routing these messages."
       ]},
      {"The tables",
       [
         "By what the provider decided shows which decisions the local model already matches: those it could take over first. What differed shows its mistakes in usable answers, and the last table shows why routing refused the rest.",
         "Latest opens the newest message of that row at its routing step."
       ]},
      {"Changing it",
       [
         "Set the model, its address and whether to compare on its card in Settings › Models."
       ]}
    ])
  end

  defp help(:retention) do
    page("How data retention works", [
      {"What this page sets",
       [
         "How long Ryker keeps each kind of data: prompts, replies and tool activity, finished work, request history, the audit trail and conversation memory. Older data is deleted automatically.",
         "If you keep routing and work examples for training, it also sets how long those stay."
       ]},
      {"Shortening a limit",
       [
         "A shorter limit deletes older data, so Ryker asks first, and deleted data can't be recovered. It also leaves less to look into later: an old request may no longer show its full prompt."
       ]},
      {"Keep the order",
       [
         "Prompts, replies and tool activity can't be kept longer than finished work, finished work not longer than request history, and request history not longer than the audit trail. The page warns when limits are out of order."
       ]},
      {"Routing examples for training",
       [
         "With Keep routing examples for training on, Ryker keeps a copy of each routing decision once its outcome is known. A copy holds the exact prompt, the model's answer, the decision, the outcome and the cost, without credentials or link query strings.",
         "Copies keep for their own limit, a year by default, after the prompts above are deleted. Turning this off deletes every copy, so Ryker asks first. Download routing examples saves them as JSON Lines for fine-tuning."
       ]},
      {"Work examples for training",
       [
         "With Keep work examples for training on, Ryker keeps a copy of each finished piece of work once its outcome is known. A copy holds the worker's instructions, each command and its output, the answers Ryker accepted or refused, the outcome and the cost.",
         "It's a separate setting because the copies hold your code and command output. Deleting or forgetting a message removes it from every copy, and Download work examples saves them as JSON Lines."
       ]}
    ])
  end

  defp help(:prices) do
    page("How model prices work", [
      {"What this page holds",
       [
         "What each model costs per million tokens of input, cached input, output and reasoning, with the day each price starts and where it came from.",
         "Leave Reasoning empty when a model's output already includes its reasoning, as Codex and Claude report it."
       ]},
      {"Where prices show up",
       [
         "The Models page warns about any model without a price. When a provider reports tokens but no cost, Usage & cost estimates the cost and lists the rates it used."
       ]},
      {"Add or remove a price",
       [
         "Add price opens a form on its own page, and clicking a price's row opens it the same way.",
         "Remove price, at the bottom of a price's page, asks first. That model's cost then shows as not priced."
       ]}
    ])
  end

  defp help(:report) do
    page("How the weekly report works", [
      {"What it says",
       [
         "Once a week Ryker posts a short update in one Slack channel, written the way a teammate would. It lists the PRs it opened that week, which of them merged, and every PR still waiting for review with how long it has waited.",
         "Then come how many messages it handled and how fast it typically replied, the questions it's waiting on, anything stuck, how people took its answers and what the week cost. Parts with nothing to report are left out."
       ]},
      {"Where it comes from",
       [
         "Ryker builds the report from its records without a model, so it can't say anything the records don't hold.",
         "A report covers the seven days before it's sent. It names a request or topic only if it came from a public channel and counts the rest."
       ]},
      {"When it posts",
       [
         "Once a week, at the day and time you choose. Turning the report on doesn't post right away; the first one goes out at the next scheduled time.",
         "If Ryker was down at that time, it posts when it's back, and after a long outage it posts a single report."
       ]},
      {"Preview",
       [
         "Preview this week's report shows what a report sent now would say. Nothing is posted until you send it.",
         "Send to the channel posts it now, titled as a preview, even while the report is off. The weekly report still posts at its day and time."
       ]},
      {"When something looks wrong",
       [
         "Invite Ryker to the channel before turning the report on. If Slack refuses the post, it shows up on Failures, where Post the report again sends the same report to the same channel."
       ]}
    ])
  end

  defp help(:advanced) do
    page("How advanced settings work", [
      {"What this page shows",
       [
         "Where Ryker's work runs and what each kind of work may do. A worker is a machine that runs the model and its tools in isolation.",
         "The bundled worker is set up for you, so most installations never need to change anything here."
       ]},
      {"Code and settings for each job",
       [
         "Ryker selects the code and settings for each job. When a job uses a repository, the worker fetches its code into an isolated working copy.",
         "Models are chosen on the Models page, and workers need no policy files."
       ]},
      {"Running now",
       [
         "Running now shows the Ryker version and each worker: whether it's taking work, its free work slots and its free disk space against the level where it stops taking work.",
         "If code changes can't run on this installation, a card above it says so and what to check."
       ]},
      {"When something looks wrong",
       [
         "When requests wait because no worker can take them, start here. Then check Working copies, because a full worker stops taking new work."
       ]}
    ])
  end

  defp help(:setup) do
    page("How setup works", [
      {"What setup does",
       [
         "Setup takes you through what Ryker needs, one step at a time: connect Slack and GitHub, add repositories, invite Ryker to a channel, choose that channel's environment and send a real request."
       ]},
      {"Steps check themselves off",
       [
         "Only the current step is open, with what it needs and one button. Ryker notices the Slack steps by itself, such as being invited or replying, and checks them off."
       ]},
      {"Emisar is recommended",
       [
         "Emisar is optional but recommended. With it, Ryker can carry out fixes on running systems after a person approves them; otherwise it can only tell you what to run."
       ]},
      {"After setup",
       [
         "Once every step is done, mention @Ryker in the channel or open Chat. You can change any step later on its own page."
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
