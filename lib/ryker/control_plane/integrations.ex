defmodule Ryker.ControlPlane.Integrations do
  @moduledoc """
  The one account of each service Ryker works through: whether it is set up,
  connected but off, on and working, or on and broken, with the reason in
  words and the one step that moves it forward.

  QA, 2026-09-25, on one installation with verified Slack tokens and nobody
  chosen to manage Ryker: Integrations said "Finish connecting", Channels said
  "Slack is not connected", Setup counted the step as not started while
  saying "Slack is verified", and Settings › Advanced said "Not configured".
  Each page had worked the state out on its own. Every page that names an
  integration's state now reads it here: the Integrations overview and each
  integration's page, the Channels and Repositories lines, Setup, Settings ›
  Advanced and the pages' help, which explains the same words.

  Everything is derived from the settings view, and for Slack the running
  connection it carries; nothing here is stored.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{Environments, Kit, SlackNames}

  @type key :: :slack | :github | :emisar | :webhooks
  @type status :: :not_set_up | :off | :on | :broken
  @type tone :: :on | :busy | :off | :warn | :bad
  @type t :: %{
          required(:key) => key(),
          required(:name) => String.t(),
          required(:href) => String.t(),
          required(:status) => status(),
          required(:state) => {tone(), String.t()},
          required(:reason) => String.t() | nil,
          required(:facts) => [String.t()],
          required(:action) => %{label: String.t(), href: String.t()},
          optional(:unassigned) => non_neg_integer()
        }

  @names %{slack: "Slack", github: "GitHub", emisar: "Emisar", webhooks: "Webhooks"}

  # Every state each integration can be in, in the order a person meets them:
  # its status, its dot and word, what the word means (the pages' help reads
  # this), the reason shown beside it, and the one next step. A reason of nil
  # means the word says enough, or that the reason depends on what is saved
  # and is written where the state is read. Variants that share a meaning are
  # explained together in the help.
  @on_but_not_working "Slack is on but not working yet, and the page says why."
  @no_sender "No other system can send Ryker events yet."
  @source_left_out "an enabled source is not taking events, and the page says which one and why."
  @states %{
    slack: [
      not_connected: %{
        status: :not_set_up,
        state: {:off, "Not connected"},
        means: "Ryker has no working Slack tokens yet.",
        reason: "Ryker cannot read or reply in Slack until you connect it.",
        action: {"Connect Slack", "/integrations/slack"}
      },
      finish: %{
        status: :off,
        state: {:warn, "Finish connecting"},
        means: "the tokens are verified, but Slack stays off until someone can manage Ryker.",
        reason:
          "The tokens are verified, but Slack stays off until you choose who can manage Ryker.",
        action: {"Choose people", "/integrations/slack"}
      },
      connected: %{
        status: :on,
        state: {:on, "Connected"},
        means: "Ryker reads and replies in the channels it is invited to.",
        reason: nil,
        action: {"Manage", "/integrations/slack"}
      },
      connecting: %{
        status: :broken,
        state: {:busy, "Connecting"},
        means: @on_but_not_working,
        reason:
          "Ryker is opening its connection to Slack. If this lasts more than a minute, " <>
            "replace the tokens.",
        action: {"Manage", "/integrations/slack"}
      },
      starting: %{
        status: :broken,
        state: {:busy, "Starting"},
        means: @on_but_not_working,
        reason: "Ryker is applying the saved settings. Slack starts once they are applied.",
        action: {"Manage", "/integrations/slack"}
      },
      waiting: %{
        status: :broken,
        state: {:warn, "Waiting for the worker"},
        means: @on_but_not_working,
        reason:
          "Slack is on, but the worker that runs Ryker's work is not ready, so messages " <>
            "wait. Working copies shows each worker.",
        action: {"Open Working copies", "/working-copies"}
      },
      not_applied: %{
        status: :broken,
        state: {:bad, "Not running"},
        means: @on_but_not_working,
        reason: "The newest settings could not be applied, so Slack is not running.",
        action: {"Open Advanced", "/settings/advanced"}
      },
      no_incident_policy: %{
        status: :broken,
        state: {:bad, "Not running"},
        means: @on_but_not_working,
        reason:
          "Slack is on but did not start, because no worker policy for incident rooms is " <>
            "ready. Check what each kind of work may do under Advanced.",
        action: {"Open Advanced", "/settings/advanced"}
      },
      unknown: %{
        status: :broken,
        state: {:warn, "Unknown"},
        means: @on_but_not_working,
        reason: "Ryker could not read whether Slack is running. Reload the page to check again.",
        action: {"Manage", "/integrations/slack"}
      }
    ],
    github: [
      not_connected: %{
        status: :not_set_up,
        state: {:off, "Not connected"},
        means: "no GitHub App is connected yet.",
        reason: "Ryker cannot read your code or open pull requests until you connect it.",
        action: {"Connect GitHub", "/integrations/github"}
      },
      repair: %{
        status: :broken,
        state: {:bad, "Needs repair"},
        means: "the saved App ID or private key stopped working. Repair it with the current key.",
        reason: "The saved App ID or private key no longer works.",
        action: {"Repair GitHub", "/integrations/github#github-app"}
      },
      no_repository: %{
        status: :off,
        state: {:warn, "Add a repository to start"},
        means: "the App is verified, and GitHub work starts once a repository is added.",
        reason: "The App is verified. Ryker starts GitHub work once a repository is added.",
        action: {"Add repositories", "/repositories"}
      },
      connected: %{
        status: :on,
        state: {:on, "Connected"},
        means: "Ryker reads code and opens pull requests in the repositories you added.",
        reason: nil,
        action: {"Manage", "/integrations/github"}
      }
    ],
    emisar: [
      not_connected: %{
        status: :not_set_up,
        state: {:off, "Not connected"},
        means: "no Emisar account is connected, so Ryker can only tell you what to run.",
        reason: "Without it, Ryker cannot act on anything that is running.",
        action: {"Connect Emisar", "/integrations/emisar"}
      },
      paused: %{
        status: :off,
        state: {:off, "Paused"},
        means: "every account is paused, so new work does not use Emisar.",
        reason: "Every account is paused, so new work does not use Emisar.",
        action: {"Manage", "/integrations/emisar"}
      },
      not_in_use: %{
        status: :off,
        state: {:warn, "Not in use yet"},
        means:
          "an account is connected, but no work can use it yet; the page says what is missing.",
        reason: nil,
        action: {"Finish connecting", "/integrations/emisar"}
      },
      connected: %{
        status: :on,
        state: {:on, "Connected"},
        means:
          "work in the environments that use an account sends its actions there for approval.",
        reason: nil,
        action: {"Manage", "/integrations/emisar"}
      }
    ],
    webhooks: [
      not_set_up: %{
        status: :not_set_up,
        state: {:off, "Not set up"},
        means: "no webhook source is saved, so no other system can send Ryker events.",
        reason: nil,
        action: {"Set up webhooks", "/integrations/webhooks"}
      },
      off: %{
        status: :off,
        state: {:off, "Off"},
        means: "sources are saved, but none of them accepts events.",
        reason: "No source accepts events. Turn on Accept events for one to receive them.",
        action: {"Manage", "/integrations/webhooks"}
      },
      on: %{
        status: :on,
        state: {:on, "On"},
        means: "senders can deliver events to their sources' addresses.",
        reason: nil,
        action: {"Manage", "/integrations/webhooks"}
      },
      partly_running: %{
        status: :broken,
        state: {:warn, "Partly running"},
        means: @source_left_out,
        reason: nil,
        action: {"Manage", "/integrations/webhooks"}
      },
      not_running: %{
        status: :broken,
        state: {:bad, "Not running"},
        means: @source_left_out,
        reason: nil,
        action: {"Manage", "/integrations/webhooks"}
      }
    ]
  }

  @doc "Every integration, in the order the pages list them."
  @spec all(map()) :: [t()]
  def all(view), do: [slack(view), github(view), emisar(view), webhooks(view)]

  @doc """
  One integration's state from the settings a page read: settings that were
  never created mean nothing is set up yet, and settings that could not be
  read give no state at all rather than a guess.
  """
  @spec read(key(), {:ok, map()} | {:error, atom()}) :: t() | nil
  def read(:slack, {:ok, view}), do: slack(view)
  def read(:github, {:ok, view}), do: github(view)
  def read(:emisar, {:ok, view}), do: emisar(view)
  def read(:webhooks, {:ok, view}), do: webhooks(view)

  def read(:webhooks, {:error, :settings_not_initialized}),
    do: :webhooks |> state(:not_set_up, facts: []) |> Map.put(:reason, @no_sender)

  def read(key, {:error, :settings_not_initialized}),
    do: state(key, :not_connected, facts: [])

  def read(_key, {:error, _unavailable}), do: nil

  @doc """
  Slack: verified tokens, then someone who can manage Ryker (which switches
  Slack on), then the running connection. A connection switched on but not
  running says why: still connecting, the settings not applied yet, the
  worker not ready or no policy for incident rooms.
  """
  @spec slack(map()) :: t()
  def slack(view) do
    slack = view.snapshot.slack
    verified = verified?(view, [:slack_app, :slack_bot])
    workspace = slack.workspace_name || slack.workspace_ref
    bot = slack.bot_name && "@" <> slack.bot_name

    cond do
      not verified ->
        state(:slack, :not_connected, facts: [])

      not slack.enabled ->
        state(:slack, :finish, facts: facts([workspace, bot]))

      true ->
        state(:slack, running(view.readiness.slack, view.application),
          facts: facts([workspace, bot, managers(slack.operators)])
        )
    end
  end

  defp running(%{state: :ready}, _application), do: :connected
  defp running(%{state: :connecting}, _application), do: :connecting
  defp running(%{state: :runtime_unavailable}, :pending), do: :starting
  defp running(%{state: :runtime_unavailable}, {:failed, _code}), do: :not_applied
  defp running(%{state: :runtime_unavailable}, :applied), do: :no_incident_policy
  defp running(%{state: :unknown}, _application), do: :unknown

  defp running(%{state: worker}, _application)
       when worker in [:setting_up, :worker_unavailable, :policy_unavailable],
       do: :waiting

  defp managers([]), do: nil
  defp managers([_one]), do: "1 person can manage Ryker"
  defp managers(people), do: "#{length(people)} people can manage Ryker"

  @doc "GitHub: the App Ryker works through, whether it still works and whether work started."
  @spec github(map()) :: t()
  def github(view) do
    github = view.snapshot.github
    app = github.app_slug && "App " <> github.app_slug

    case view.github_connection do
      :missing ->
        state(:github, :not_connected, facts: [])

      :invalid ->
        state(:github, :repair, facts: [])

      :ready when github.enabled ->
        state(:github, :connected,
          facts: facts([app, count(length(view.snapshot.repositories), "repository")])
        )

      :ready ->
        state(:github, :no_repository, facts: facts([app]))
    end
  end

  @doc """
  Emisar is in use only when work can reach an account that Ryker watches for
  approval decisions: an account that is not paused, with approval monitoring
  on, that an environment uses. Anything short of that says the one thing
  still missing. Once an account is connected, `unassigned` counts the
  environments whose work has no account, so no approvals at all.
  """
  @spec emisar(map()) :: t()
  def emisar(view) do
    accounts = view.snapshot.emisar_connections
    environments = view.snapshot.environments
    used = environments |> Enum.map(& &1.emisar_connection_ref) |> Enum.reject(&is_nil/1)
    {variant, missing} = emisar_variant(accounts, used)

    :emisar
    |> state(variant, facts: if(accounts == [], do: [], else: [account_names(accounts)]))
    |> Map.update!(:reason, &(missing || &1))
    |> Map.put(
      :unassigned,
      if(accounts == [],
        do: 0,
        else: Enum.count(environments, &is_nil(&1.emisar_connection_ref))
      )
    )
  end

  defp emisar_variant([], _used), do: {:not_connected, nil}

  defp emisar_variant(accounts, used) do
    active = Enum.filter(accounts, & &1.enabled_for_new_work)
    watched = for account <- active, account.monitoring_enabled, do: account.ref

    cond do
      active == [] ->
        {:paused, nil}

      Enum.any?(used, &(&1 in watched)) ->
        {:connected, nil}

      used == [] and watched == [] ->
        {:not_in_use,
         "Turn on approval monitoring for an account and give an environment that account."}

      used == [] ->
        {:not_in_use, "Give an environment this account so its work sends approvals there."}

      true ->
        {:not_in_use,
         "Turn on approval monitoring for the account your environments use, so Ryker can " <>
           "pick work back up after a decision."}
    end
  end

  defp account_names([account]), do: account.display_name
  defp account_names(accounts), do: count(length(accounts), "account")

  @doc """
  What connecting an account did, by the names of the environments that use
  it now: the first account serves every environment that had none, and a
  later one waits to be chosen for one.
  """
  @spec emisar_connected([String.t()]) :: String.t()
  def emisar_connected([]),
    do:
      "Emisar account is connected. No environment uses it yet: choose it for one on the " <>
        "Environments page."

  def emisar_connected([_one] = names),
    do: "Emisar account is connected. #{Environments.sentence(names)} uses it now."

  def emisar_connected(names),
    do: "Emisar account is connected. #{Environments.sentence(names)} use it now."

  @doc "The environments whose work has no Emisar account, as one fact."
  @spec unassigned(pos_integer()) :: String.t()
  def unassigned(count), do: count(count, "environment") <> " without an Emisar account"

  @doc """
  Webhooks: the senders set up to send Ryker events. A signing credential on
  its own sends nothing, so it is a fact beside "Not set up", never a
  connection. An enabled source the running configuration left out (its
  destination not running, its environment unable to run work, its
  credential missing or too short) makes webhooks "on but not working", and
  the reason names each such source and why; until 2026-09-26 one such source
  refused every setting instead, and nothing said which.
  """
  @spec webhooks(map()) :: t()
  def webhooks(view) do
    sources = view.snapshot.webhook_sources
    credentials = Enum.count(view.credentials, &(&1.kind == :webhook))
    enabled = Enum.filter(sources, & &1.enabled)
    left_out = view.readiness.webhooks.left_out
    stopped = Enum.filter(enabled, &Map.has_key?(left_out, &1.name))

    facts =
      facts([
        sources != [] && count(length(sources), "source"),
        credentials > 0 && count(credentials, "signing credential")
      ])

    cond do
      sources == [] ->
        :webhooks
        |> state(:not_set_up, facts: facts)
        |> Map.put(
          :reason,
          if(credentials > 0,
            do: "A signing credential is ready. Add a webhook source so a sender can use it.",
            else: @no_sender
          )
        )

      stopped != [] ->
        :webhooks
        |> state(if(stopped == enabled, do: :not_running, else: :partly_running), facts: facts)
        |> Map.put(
          :reason,
          Enum.map_join(
            stopped,
            " ",
            &"#{&1.name} is not taking events: #{why(&1, left_out[&1.name], view)}"
          )
        )

      enabled != [] ->
        state(:webhooks, :on, facts: facts)

      true ->
        state(:webhooks, :off, facts: facts)
    end
  end

  @doc """
  One webhook source's own state, for its row on the Webhooks page: off,
  taking events, or left out of the running routes, with why.
  """
  @spec webhook_source(map(), map()) :: %{state: {tone(), String.t()}, reason: String.t() | nil}
  def webhook_source(view, source) do
    case {source.enabled, Map.get(view.readiness.webhooks.left_out, source.name)} do
      {false, _reason} ->
        %{state: {:off, "Off"}, reason: nil}

      {true, nil} ->
        %{state: {:on, "On"}, reason: nil}

      {true, reason} ->
        %{
          state: {:bad, "Not running"},
          reason: "Not taking events: " <> why(source, reason, view)
        }
    end
  end

  # Why the running configuration left a source out, in words; each names
  # what to change.
  defp why(_source, :slack_not_running, _view), do: "it posts to Slack, and Slack is not running."

  defp why(_source, :slack_workspace_not_served, _view),
    do:
      "it posts to a Slack channel in a workspace Ryker is not connected to. Choose one of " <>
        "the channels Ryker is in."

  defp why(_source, :github_not_running, _view),
    do: "it posts to GitHub, and GitHub is not running."

  defp why(_source, :github_repository_not_served, _view),
    do: "it posts to a GitHub repository Ryker has not added."

  defp why(_source, :conversation_not_found, _view),
    do: "it posts to a Chat conversation that no longer exists."

  defp why(source, :environment_cannot_run_work, view),
    do:
      "its environment #{environment_name(view, source.environment_ref)} cannot run work yet. " <>
        "Check what each kind of work may do under Advanced."

  defp why(source, :credential_missing, _view),
    do: "its signing credential #{source.secret_name} no longer exists. Choose another."

  defp why(source, :credential_unreadable, _view),
    do: "its signing credential #{source.secret_name} cannot be read. Create it again."

  defp why(%{auth_kind: :hmac_sha256}, :secret_too_short, _view),
    do: "its signing credential is shorter than the 32 characters a signed request needs."

  defp why(_source, :secret_too_short, _view),
    do: "its signing credential is shorter than the 16 characters a token needs."

  defp why(_source, :lifecycle_repository_unreviewed, _view),
    do: "its deployment reports name a repository with no reviewed worker policies."

  defp why(_source, :mapping_unknown_field, _view),
    do: "its field mapping names a field Ryker does not know."

  defp why(_source, _reason, _view),
    do:
      "Ryker cannot post where it sends events, or use it as it is saved. Edit it and save again."

  defp environment_name(view, ref) do
    case Environments.find(view.snapshot, ref) do
      %{display_name: name} -> name
      nil -> ref
    end
  end

  @doc """
  What each word an integration can show means, for the page's help: one
  sentence per word, and one for the words that share a meaning.
  """
  @spec meanings(key()) :: String.t()
  def meanings(key) do
    @states
    |> Map.fetch!(key)
    |> Enum.map(fn {_variant, %{state: {_tone, word}, means: means}} -> {word, means} end)
    |> Enum.uniq()
    |> Enum.chunk_by(fn {_word, means} -> means end)
    |> Enum.map_join(" ", fn group ->
      words = group |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      "#{either(words)}: #{elem(hd(group), 1)}"
    end)
  end

  defp either([one]), do: one
  defp either([first, second]), do: "#{first} or #{second}"
  defp either([first | rest]), do: first <> ", " <> either(rest)

  @doc """
  The Integrations overview: one row per service with its state, what it
  gives Ryker, why it is not working when it is not, and the one action that
  fits. Emisar is optional but recommended, so an unconnected Emisar says so
  and leads with the page's one primary action.
  """
  @spec overview(map()) :: [map()]
  def overview(view) do
    for integration <- all(view) do
      %{
        key: integration.key,
        name: integration.name,
        href: integration.href,
        state: integration.state,
        text: gives(integration.key),
        meta: overview_meta(integration),
        tag: if(recommended?(integration), do: "Recommended"),
        action: Map.put(integration.action, :primary, recommended?(integration))
      }
    end
  end

  defp gives(:slack), do: "Ryker reads and replies in the Slack channels it is invited to."
  defp gives(:github), do: "Ryker reads your code and opens pull requests through a GitHub App."

  defp gives(:emisar),
    do:
      "Ryker carries out the operational fixes you ask for, after a person approves them in Emisar."

  defp gives(:webhooks), do: "Other systems, such as Grafana, send alerts and events to Ryker."

  defp recommended?(%{key: :emisar, status: :not_set_up}), do: true
  defp recommended?(_integration), do: false

  defp overview_meta(%{key: :emisar, status: :on, facts: facts, unassigned: count})
       when count > 0,
       do: facts ++ [unassigned(count)]

  defp overview_meta(%{reason: reason, facts: facts}) when is_binary(reason),
    do: [reason | facts]

  defp overview_meta(%{facts: facts}), do: facts

  attr(:integration, :any, required: true, doc: "One integration's state, or nil when unknown")
  attr(:key, :atom, required: true)
  attr(:id, :string, required: true)

  @doc """
  One integration's state as a line above a list that needs it, such as the
  Slack channels or the repositories: its name, the dot and word, why, and
  the one next step. The same words its own page and the overview show.
  """
  def line(assigns) do
    assigns = assign(assigns, :name, Map.fetch!(@names, assigns.key))

    ~H"""
    <div class="connection-line" id={@id}>
      <p :if={@integration}>
        <strong>{@name}</strong>
        <Kit.state tone={elem(@integration.state, 0)} word={elem(@integration.state, 1)} />
        <span :if={line_text(@integration)}>{line_text(@integration)}</span>
      </p>
      <p :if={!@integration}>
        <strong>{@name}</strong>
        <span>Its state is unknown, because settings could not be read.</span>
      </p>
      <.link
        navigate={if @integration, do: @integration.action.href, else: "/integrations"}
        class="ui-button secondary"
      >{if @integration, do: @integration.action.label, else: "Open Integrations"}</.link>
    </div>
    """
  end

  defp line_text(%{reason: reason}) when is_binary(reason), do: reason
  defp line_text(%{facts: []}), do: nil
  defp line_text(%{facts: facts}), do: Enum.join(facts, " · ")

  @doc "A Slack channel as people know it, such as #ops."
  @spec channel_name(map()) :: String.t()
  def channel_name(%{workspace_ref: workspace, channel_ref: channel}),
    do: SlackNames.name(workspace, channel)

  @doc "Whether every credential of these kinds is saved and verified."
  @spec verified?(map(), [atom()]) :: boolean()
  def verified?(view, kinds) do
    Enum.all?(kinds, fn kind ->
      Enum.any?(view.credentials, &(&1.kind == kind and &1.verification_status == :verified))
    end)
  end

  @doc "A count and its noun: 1 repository, 3 repositories."
  @spec count(non_neg_integer(), String.t()) :: String.t()
  def count(1, noun), do: "1 #{noun}"
  def count(number, noun), do: "#{number} #{plural(noun)}"

  defp plural(noun) do
    cond do
      String.ends_with?(noun, ~w(ay ey oy uy)) -> noun <> "s"
      String.ends_with?(noun, "y") -> String.slice(noun, 0..-2//1) <> "ies"
      true -> noun <> "s"
    end
  end

  defp state(key, variant, facts: facts) do
    %{status: status, state: state, reason: reason, action: {label, href}} =
      @states |> Map.fetch!(key) |> Keyword.fetch!(variant)

    %{
      key: key,
      name: Map.fetch!(@names, key),
      href: "/integrations/#{key}",
      status: status,
      state: state,
      reason: reason,
      facts: facts,
      action: %{label: label, href: href}
    }
  end

  defp facts(facts), do: Enum.reject(facts, &(&1 in [nil, false, ""]))
end
