defmodule Ryker.ControlPlane.PageHelp do
  @moduledoc """
  "How this page works": the help every control-plane page carries, keyed by
  the route that serves it, and the one panel the shell renders it in.

  Andrew, 2026-09-25: how to use a page had been one line of small print
  under a few lists ("To open one, ask Ryker in the alert's Slack thread…")
  and nothing on the rest. He asked for help on every page that teaches
  without getting in the way. Andrew, 2026-10-05: the help then explained
  every visible control ("All, Needs you, In progress and Finished narrow
  the list"); it says only what the page can't: how to ask Ryker in Slack or
  Chat, what a state that isn't plain means, what Ryker does behind the
  page, and what to do when something is wrong. `PageHelpTest` holds every
  routed page to having help, keeps Ryker's internal words out and refuses
  help that explains a control.

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
    {"/memory/cases", :cases},
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
      {"What counts as a request",
       [
         "A Slack or Chat message, a GitHub event or an alert from another tool. Its timeline shows every step Ryker took, with the exact model calls and what they cost."
       ]},
      {"When work is stuck",
       [
         "Needs you lists work that is blocked or waiting for a person, and Failures says what to do about work Ryker gave up on. If no worker can take work, requests wait until one is back."
       ]},
      {"Ask Ryker", ["Mention @Ryker in a Slack channel it's in, or write to it in Chat."]}
    ])
  end

  defp help(:timeline) do
    page("How a timeline works", [
      {"The steps",
       [
         "Each message goes through Intake, Routing, Work and Answer. A step's card holds the exact request Ryker sent to the model and the answer it got.",
         "A cost marked ≈ includes an estimate from Settings › Model prices."
       ]},
      {"After the answer",
       [
         "Learning shows what Ryker took from these messages in the background, and Cleanup how the worker's session ended. Rating a finished request Needs work sends it to Feedback › What to fix."
       ]},
      {"When work is blocked",
       ["Next action links to a page that says what stopped and whether a retry should work."]}
    ])
  end

  defp help(:chat) do
    page("How Chat works", [
      {"What Chat is",
       [
         "A direct conversation with Ryker outside Slack. Ryker can do here everything it does in a Slack channel."
       ]},
      {"Environment",
       [
         "Each conversation works in one environment, which decides the repositories and Emisar account its work can use. New conversations use the default environment, and you can pick another under the message box."
       ]},
      {"Files",
       [
         "Attach up to two files, 8 MiB in total: images, PDFs and text files such as logs. Ryker transcribes voice recordings and videos up to five minutes long."
       ]}
    ])
  end

  defp help(:incident_rooms) do
    page("How incident rooms work", [
      {"Open a room",
       [
         "Ask Ryker in the alert's Slack thread: \"Open an incident room for this.\" Ryker offers the room and creates it once you confirm. It may also offer one itself while it investigates an alert.",
         "To open a room for every alert in a channel, type /ryker status there and choose Configure channel."
       ]},
      {"Needs attention",
       [
         "Setup stopped partway. The room links to what stopped on Failures, and continuing reuses the channel it already made."
       ]}
    ])
  end

  defp help(:incident_room) do
    page("How an incident room works", [
      {"Closing a room",
       [
         "Close room ends Ryker's work in the room and posts a closing note in the channel and the alert thread. The Slack channel stays until you archive it, and a closed room can't be reopened."
       ]},
      {"When the channel changes",
       [
         "If the channel is archived, Ryker pauses until someone restores it. If Ryker can't find it, add Ryker back or close the room.",
         "If the channel is deleted, the room closes and Ryker says so in the alert thread."
       ]},
      {"When setup stopped",
       [
         "See what stopped opens it on Failures. Continuing resumes at the step that stopped and posts nothing twice."
       ]}
    ])
  end

  defp help(:failures) do
    page("How failures work", [
      {"What lands here",
       [
         "Ryker retries most work several times before listing it. Affects people is work someone still waits for, such as a reply, and Housekeeping is cleanup nobody waits on."
       ]},
      {"How a failure leaves",
       [
         "It leaves once the work finishes, after your retry or by itself, or when you choose Leave it."
       ]}
    ])
  end

  defp help(:failure) do
    page("How a failure page works", [
      {"When a retry won't help",
       [
         "If something has to change first, such as a token or Ryker's access to a channel, the page links to where you change it. Fix that, then retry."
       ]},
      {"Leave it",
       [
         "Leave it hides the failure while it keeps failing the same way. Ryker's own retries don't bring it back; failing some other way does."
       ]}
    ])
  end

  defp help(:usage) do
    page("How usage and cost work", [
      {"What is counted",
       [
         "Every model call: routing, replies, investigations, tasks and background learning. The page opens on live work, and All work adds evaluation runs."
       ]},
      {"How cost is counted",
       [
         "Cost is what the provider reported. When a provider reports tokens without a cost, Ryker estimates it from Settings › Model prices and lists the rates it used. Not measured means nothing was reported."
       ]},
      {"Lowering the cost",
       [
         "The tables show which model or kind of work costs most. Choose a cheaper model for a kind of work in Settings › Models."
       ]}
    ])
  end

  defp help(:environments) do
    page("How environments work", [
      {"Repositories",
       [
         "Work can read every repository in its environment. A task that changes code uses one marked read and write, the default repository unless it picks another.",
         "A repository you add joins no environment until you choose it here."
       ]},
      {"Emisar",
       [
         "With an Emisar account, work here can ask Emisar to run actions such as a restart, and a person approves each one there. Without one, Ryker can only tell you what to run."
       ]},
      {"The default environment",
       [
         "New Chat conversations and channels that haven't chosen one use the default environment. An environment can't be removed while channels or webhook sources use it."
       ]}
    ])
  end

  defp help(:channels) do
    page("How channels work", [
      {"Add a channel",
       [
         "Invite Ryker with /invite @Ryker. It posts a welcome message with a Customize button for the channel's setup."
       ]},
      {"How Ryker takes part",
       [
         "With Replies when mentioned, Ryker answers only when someone writes @Ryker. Joins relevant conversations also lets it reply when it can clearly help, and Watches has it read and learn without replying.",
         "New channels, at the top of this page, sets this for a channel until the channel makes its own choice."
       ]},
      {"Change it from Slack",
       ["Type /ryker status in the channel and choose Configure channel."]}
    ])
  end

  defp help(:channel) do
    page("How this channel works", [
      {"Environment",
       [
         "The environment decides which repositories and Emisar account work here can use. Without one, Ryker can't use code or act on running systems in this channel."
       ]},
      {"Instructions",
       [
         "This channel's instructions add to the instructions for every conversation and win where they disagree. What applies here lists every rule, instruction and fact Ryker uses in this channel."
       ]},
      {"Ask Ryker in the channel",
       [
         "For a rule: \"When someone posts a Terraform plan here, review it for risky changes.\" For a schedule: \"Every Monday at 09:00 Berlin time, summarize open incidents here.\" Ryker shows what it will save and waits for you to confirm.",
         "To change this page's settings from Slack, type /ryker status and choose Configure channel."
       ]}
    ])
  end

  defp help(:repositories) do
    page("How repositories work", [
      {"Adding a repository",
       [
         "Connect GitHub first: Add repositories lists what the Ryker GitHub App can reach. Work uses a repository only once you choose it in an environment.",
         "Removing one takes it out of every environment and deletes Ryker's copy of its code. Past requests stay, and you can add it again."
       ]},
      {"Knowledge",
       [
         "Once a repository is set up, a model reads it and notes what it's for, how to build, test and ship it, and where to look. Every task there starts from those notes.",
         "Ryker writes nothing to the repository. It rewrites the notes after the README, AGENTS.md, CLAUDE.md, a build file or CI changes, and weekly after other code changes."
       ]},
      {"Who can ask for work",
       [
         "Anyone with write access to a repository can ask Ryker to work there, and GitHub checks that access on every request."
       ]},
      {"When something looks wrong",
       [
         "Needs attention says what stopped, such as removed GitHub access; fix the cause, then Retry setup. Not fully added means adding stopped partway, and Add it again finishes it."
       ]}
    ])
  end

  defp help(:working_copies) do
    page("How working copies work", [
      {"Cleanup",
       [
         "Ryker removes a copy once that's safe. It keeps copies with uncommitted changes or unmerged commits, so no work is lost."
       ]},
      {"When cleanup needs you",
       [
         "Resume cleanup retries the step that stopped. Discard unmerged throws away commits that were never merged and keeps uncommitted changes."
       ]},
      {"Storage",
       ["A worker that reaches its allowed space takes no new copies until space frees up."]}
    ])
  end

  defp help(:rules) do
    page("How rules work", [
      {"Add a rule",
       [
         "Tell Ryker in the channel, for example: \"When someone posts a Terraform plan here, review it for risky changes.\" Ryker shows the rule and saves it once you confirm."
       ]},
      {"What a rule does",
       [
         "When a message sets off a rule, Ryker still decides whether to reply, react or start work."
       ]}
    ])
  end

  defp help(:schedules) do
    page("How schedules work", [
      {"Add a schedule",
       [
         "Ask Ryker where the results should go, for example: \"Every Monday at 09:00 Berlin time, summarize unresolved incidents in this channel.\" Ryker shows the schedule and saves it once you confirm."
       ]},
      {"Change a schedule",
       [
         "To change what a schedule does or when, ask Ryker in the conversation where it was set up. Run now adds one extra run and leaves the schedule as it is."
       ]},
      {"Failed to start", ["Ryker couldn't begin a run, and it tries again by itself."]}
    ])
  end

  defp help(:schedule) do
    page("How this schedule works", [
      {"What it may do",
       [
         "With Read only, a run only looks. Can change the repository lets a run change code, and Can run approved operations lets it carry out actions a person approves in Emisar."
       ]},
      {"Missed runs",
       [
         "Missed means a run couldn't start within 15 minutes of its time. The next run still starts on time."
       ]},
      {"Change it",
       [
         "Ask Ryker in the conversation where the schedule was set up. Ryker shows the new version for you to confirm."
       ]}
    ])
  end

  defp help(:follow_ups) do
    page("How follow-ups work", [
      {"Where they come from",
       [
         "Ryker adds a follow-up when work has to wait, such as for a pull request to merge. You can ask for one in the conversation too: \"Check again tomorrow morning.\""
       ]},
      {"Stop one", ["Open the request it continues and choose Close as no longer needed."]}
    ])
  end

  defp help(:instructions) do
    page("How instructions work", [
      {"What they change",
       [
         "Instructions shape how Ryker works and can't give it permission to do more. A change applies from Ryker's next step, and work already running keeps the instructions it started with.",
         "For example: \"Keep replies concise. Separate observed facts from guesses.\""
       ]},
      {"For one channel",
       [
         "A channel's own instructions add to these in that channel and win where the two disagree. Set them on the channel's page."
       ]},
      {"Saved from conversations",
       [
         "Preferences and guidance are things people asked Ryker to keep in mind, such as \"Remember to keep incident updates short.\" Ryker shows what it will save, then keeps it for the time chosen once you confirm."
       ]}
    ])
  end

  defp help(:facts) do
    page("How facts work", [
      {"Add a fact",
       [
         "Tell Ryker in Chat or Slack: \"Remember that pay-gw is the payments gateway.\" Ryker shows what it will save and saves it once you confirm. A fact applies everywhere, to one repository or to one channel."
       ]},
      {"Needs review",
       [
         "Facts Ryker hasn't used in a while and facts saved more than once wait here for you to keep, edit, merge or forget."
       ]},
      {"Ask Ryker",
       [
         "In a channel, ask \"What do you remember here?\" to see the facts Ryker would use there."
       ]}
    ])
  end

  defp help(:learned) do
    page("How learned topics work", [
      {"How Ryker learns",
       [
         "Ryker reads the conversations it can see in the background, including ones it doesn't reply in, and updates a topic when it learns something new. Topics and summaries are context for later requests, never permission to act."
       ]},
      {"Not used",
       [
         "A topic that lost a message it learned from stops being used; hover over Not used to see why. Relearn rebuilds it from messages you choose, and Forget topic stops Ryker using it for good."
       ]}
    ])
  end

  defp help(:findings) do
    page("How findings work", [
      {"What the states mean",
       [
         "Explained means the evidence shows why it happened. Expected and Out of scope come with Ryker's reason, and Not explained yet means the question is still open."
       ]},
      {"Settle a finding",
       [
         "Mark explained settles one Ryker couldn't explain, once you know why it happened. Forget finding is for one that's wrong or no longer matters.",
         "Either way Ryker stops using it in later requests, and it stays in the investigation's history."
       ]}
    ])
  end

  defp help(:cases) do
    page("How cases work", [
      {"Where a case comes from",
       [
         "When a finished request's history is cleaned up, Ryker keeps a short case of it: the problem, the cause it found, what it checked and how it ended. The case stays after the history is gone."
       ]},
      {"Where it's read",
       [
         "A later request about the same problem reads the case as an example of what worked, never as proof that this time is the same. A case from a private channel, a direct message or Chat is read only there, and one marked Shadow mode only by requests in shadow mode."
       ]},
      {"Forgetting",
       [
         "Forget case erases the case's words, and no later request reads it. Editing or deleting a message the case came from, or deleting its channel, does the same."
       ]}
    ])
  end

  defp help(:people) do
    page("How People works", [
      {"What Ryker keeps",
       [
         "Ryker keeps only what people say about themselves, never what one person says about another, and nothing sensitive such as health or beliefs. Nobody approves it, so it's listed here."
       ]},
      {"Where it's used",
       [
         "Only when that person is the one asking, and it's never shared with anyone else. Something said in a direct message, a private channel, Chat or GitHub is used only there."
       ]},
      {"Forgetting",
       [
         "Editing or deleting a message forgets what it taught, and deleting a channel forgets what was said in it. After Forget this person, only what they say later is learned again."
       ]}
    ])
  end

  defp help(:feedback) do
    page("How feedback works", [
      {"Where it comes from",
       [
         "Nobody fills anything in. A reaction on Ryker's message, the same question asked again soon after, a message changed or deleted after the answer, or the tone of the next message all count."
       ]},
      {"Negative feedback",
       [
         "Frustrated, Asked again and Edited or deleted are negative. Requests people were unhappy with go to What to fix, where Ryker diagnoses each one."
       ]}
    ])
  end

  defp help(:improvement) do
    page("How What to fix works", [
      {"How Ryker diagnoses",
       [
         "While background learning is on, Ryker reads each request a few minutes after its last feedback. It says what went wrong and where, what it should have done and how sure it is, and changes nothing by itself."
       ]},
      {"What the kinds mean",
       [
         "Host bug means Ryker's own code let the model down, such as a missing tool. Prompt bug means the model followed instructions that led it wrong.",
         "Model mistake means the instructions were enough and the model still got it wrong. Not a problem means the answer was reasonable, and Unclear means the evidence doesn't say."
       ]},
      {"Eval cases",
       [
         "An accepted case keeps the messages it depends on, so it outlives them. Download eval cases gives each as a world scenario for testdata/scenarios; GitHub requests can't be kept yet."
       ]}
    ])
  end

  defp help(:learning) do
    page("How background learning works", [
      {"On and off",
       [
         "While learning is off, new messages wait and nothing learned is lost. The same switch controls the diagnosis on Feedback › What to fix.",
         "A pass that finds nothing to change is normal."
       ]},
      {"When learning needs you",
       [
         "Needs attention lists conversations where learning stopped, such as after using all its tries. Grant one more start tries again, and Drop batch gives up on those messages.",
         "If it stopped on a topic that lost its messages, relearn or forget that topic first."
       ]}
    ])
  end

  defp help(:integrations) do
    page("How integrations work", [
      {"Disconnecting", ["Disconnecting a service keeps channels, repositories and history."]},
      {"Repairs", ["A service that needs repair says so here, and its page shows what failed."]}
    ])
  end

  defp help(:slack) do
    page("How the Slack connection works", [
      {"Connect Slack",
       [
         "Paste the app token (xapp-…) and bot token (xoxb-…) from your Slack app, then choose who can manage Ryker."
       ]},
      {"Who can manage Ryker",
       [
         "They can change Ryker's settings from Slack, such as a channel's setup or a new rule. Workspace admins and owners can too, unless you turn that off.",
         "Tokens for a different workspace switch Slack off until you choose people there."
       ]},
      {"What the states mean", [Integrations.meanings(:slack)]},
      {"Missing permissions",
       [
         "The error lists them. Add them to your Slack app, reinstall the app in the workspace, then verify again."
       ]}
    ])
  end

  defp help(:github) do
    page("How the GitHub connection works", [
      {"Connect the App",
       [
         "Enter the App ID and private key (.pem) from the App's settings on GitHub, then paste the callback URL shown here into the App's webhook settings. Leave the webhook secret empty and Ryker creates one."
       ]},
      {"Access",
       [
         "GitHub decides which repositories Ryker can reach, and it checks each person's access on every request. Add repositories on the Repositories page."
       ]},
      {"What the states mean", [Integrations.meanings(:github)]}
    ])
  end

  defp help(:emisar) do
    page("How the Emisar connection works", [
      {"Connect an account",
       [
         "Create an agent API key in Emisar under AI agents and add it here. The first account serves every environment without one, and you choose others on the Environments page."
       ]},
      {"What the states mean", [Integrations.meanings(:emisar)]},
      {"When something looks wrong",
       [
         "If approval monitoring is off, tasks waiting for an approval stop and show on Failures. Turn it back on from the account's page.",
         "An account that tasks still use can't be removed; pause it instead."
       ]}
    ])
  end

  defp help(:webhooks) do
    page("How webhooks work", [
      {"Set up a sender",
       [
         "Create a signing credential first, because senders sign each request with its secret. Then add a source with that credential and where its work goes, and give the sender the source's address."
       ]},
      {"Check a payload",
       [
         "Paste one delivery to see the events Ryker would record from it; nothing is saved. Group by labels treats events with the same label values as one ongoing situation."
       ]},
      {"What the states mean", [Integrations.meanings(:webhooks)]}
    ])
  end

  defp help(:settings) do
    page("How settings work", [
      {"Where services are connected",
       ["Slack, GitHub, Emisar and webhooks are connected under Integrations."]}
    ])
  end

  defp help(:models) do
    page("How model settings work", [
      {"Shared accounts",
       [
         "Conversation, Standard and Deep work share accounts in the same order, because a request can move between them. Their models and efforts can differ."
       ]},
      {"Adding models and accounts",
       [
         "A Claude model appears once its price is saved under Model prices, written like claude:claude-opus-4-6.",
         "Ryker can't see which accounts the worker has signed in. Sign one in with scripts/compose.sh model-login claude@work, then add it under Model accounts."
       ]},
      {"Local routing model",
       [
         "A small model you run yourself can answer each routing prompt after the provider model has decided. Its card shows how often the two agree, and routing never uses its answer."
       ]}
    ])
  end

  defp help(:local_routing) do
    page("How the local routing model comparison works", [
      {"Reading the figures",
       [
         "Valid counts the local answers that passed routing's checks, and agreed counts those that matched the provider's decision."
       ]},
      {"The tables",
       [
         "By what the provider decided shows which decisions the local model already matches, the ones it could take over first. What differed shows its mistakes in usable answers."
       ]},
      {"Changing it",
       ["Set the model, its address and whether to compare on its card in Settings › Models."]}
    ])
  end

  defp help(:retention) do
    page("How data retention works", [
      {"Shortening a limit",
       [
         "A shorter limit deletes older data at once, and it can't be recovered. Old requests may then no longer show their full prompts."
       ]},
      {"Keep the order",
       [
         "Prompts, replies and tool activity can't be kept longer than finished work, finished work not longer than request history, and request history not longer than the audit trail."
       ]},
      {"Examples for training",
       [
         "Routing and work examples are copies kept for their own limit, a year by default, after the prompts above are deleted. Work examples hold your code and command output.",
         "Deleting or forgetting a message removes it from every copy, and turning either kind off deletes its copies."
       ]}
    ])
  end

  defp help(:prices) do
    page("How model prices work", [
      {"Reasoning tokens",
       [
         "Leave Reasoning empty when a model's output already includes its reasoning, as Codex and Claude report it."
       ]},
      {"A model without a price",
       ["Its cost shows as not priced, and the Models page warns about it."]}
    ])
  end

  defp help(:report) do
    page("How the weekly report works", [
      {"Where it comes from",
       [
         "Ryker builds the report from its records without a model, so it says only what the records hold. It covers the seven days before it's sent, and names a request or topic only if it came from a public channel."
       ]},
      {"When it posts",
       [
         "At the day and time you choose; turning it on doesn't post right away. If Ryker was down then, it posts once it's back."
       ]},
      {"Before you turn it on",
       [
         "Invite Ryker to the channel. If Slack refuses a post, it shows on Failures, where Post the report again sends it."
       ]}
    ])
  end

  defp help(:advanced) do
    page("How advanced settings work", [
      {"Code and settings for each job",
       [
         "Ryker selects the code and settings for each job, and the worker fetches a job's repository into an isolated working copy. Models are chosen on the Models page, and workers need no policy files."
       ]},
      {"When requests wait",
       [
         "If no worker can take work, start here: Running now shows each worker's free work slots and disk space. Then check Working copies, because a full worker takes no new work."
       ]}
    ])
  end

  defp help(:setup) do
    page("How setup works", [
      {"Steps check themselves off",
       [
         "Ryker notices the Slack steps by itself, such as being invited or replying, and checks them off."
       ]},
      {"Emisar is recommended",
       [
         "With Emisar, Ryker can carry out fixes on running systems after a person approves them. Without it, Ryker can only tell you what to run."
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
