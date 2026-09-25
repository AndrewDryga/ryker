defmodule Ryker.ControlPlane.Integrations do
  @moduledoc """
  What each service Ryker works through is connected to, and whether it works,
  in words: a dot and a word, a sentence when the word is not enough, and the
  facts that name what is connected.

  The Integrations overview, each integration's own page and the setup page
  read their states from here, so "Connected" means the same thing on all of
  them. Everything is derived from the settings view; nothing here is stored.
  """

  alias Ryker.ControlPlane.{Environments, SlackNames}

  @type state :: {:on | :busy | :off | :warn | :bad, String.t()}

  @doc """
  Slack: verified tokens, then people who can manage Ryker, then the running
  connection. `connected` is the setup step's own rule.
  """
  @spec slack(map()) :: %{
          state: state(),
          text: String.t() | nil,
          verified: boolean(),
          connected: boolean(),
          facts: [String.t()]
        }
  def slack(view) do
    slack = view.snapshot.slack
    verified = verified?(view, [:slack_app, :slack_bot])
    connected = verified and slack.enabled

    {state, text} =
      cond do
        not verified ->
          {{:off, "Not connected"}, nil}

        not slack.enabled ->
          {{:warn, "Finish connecting"},
           "Choose who can manage Ryker to finish connecting Slack."}

        true ->
          running(view.readiness.slack, slack)
      end

    %{
      state: state,
      text: text,
      verified: verified,
      connected: connected,
      facts:
        if(verified,
          do:
            reject_empty([
              slack.workspace_name || slack.workspace_ref,
              slack.bot_name && "@" <> slack.bot_name,
              connected && managers(slack.operators)
            ]),
          else: []
        )
    }
  end

  defp running(%{state: :ready}, slack) do
    workspace = slack.workspace_name || slack.workspace_ref
    bot = if slack.bot_name, do: " as @" <> slack.bot_name, else: ""
    {{:on, "Connected to #{workspace}#{bot}"}, nil}
  end

  defp running(%{state: :connecting, detail: detail}, _slack), do: {{:busy, "Connecting"}, detail}

  defp running(%{state: :runtime_unavailable, detail: detail}, _slack),
    do: {{:bad, "Not running"}, detail}

  defp running(%{state: :worker_unavailable, detail: detail}, _slack),
    do: {{:warn, "Waiting for the worker"}, detail}

  defp running(%{detail: detail}, _slack), do: {{:busy, "Setting up"}, detail}

  defp managers([]), do: nil
  defp managers([_one]), do: "1 person can manage Ryker"
  defp managers(people), do: "#{length(people)} people can manage Ryker"

  @doc "GitHub: the App Ryker works through, and whether it still works."
  @spec github(map()) :: %{
          state: state(),
          text: String.t() | nil,
          ready: boolean(),
          facts: [String.t()]
        }
  def github(view) do
    github = view.snapshot.github
    repositories = length(view.snapshot.repositories)

    {state, text} =
      case view.github_connection do
        :missing ->
          {{:off, "Not connected"}, nil}

        :invalid ->
          {{:bad, "Needs repair"}, "The saved App ID or private key no longer works."}

        :ready when github.enabled and is_binary(github.app_slug) ->
          {{:on, "Connected as #{github.app_slug}"}, nil}

        :ready when github.enabled ->
          {{:on, "Connected"}, nil}

        :ready ->
          {{:warn, "Add a repository to start"},
           "The App is verified. Ryker starts GitHub work once a repository is added."}
      end

    %{
      state: state,
      text: text,
      ready: view.github_connection == :ready,
      facts:
        if(view.github_connection == :ready,
          do:
            reject_empty([
              github.app_slug && "App " <> github.app_slug,
              count(repositories, "repository")
            ]),
          else: []
        )
    }
  end

  @doc """
  Emisar is in use only when work can reach an account that Ryker watches for
  approval decisions: an account that is not paused, with approval monitoring
  on, that an environment uses. Anything short of that says the one thing
  still missing. Once an account is connected, `unassigned` counts the
  environments whose work has no account, so no approvals at all.
  """
  @spec emisar(map()) :: %{
          status: :not_connected | :paused | :unfinished | :ready,
          state: state(),
          text: String.t() | nil,
          facts: [String.t()],
          unassigned: non_neg_integer()
        }
  def emisar(view) do
    accounts = view.snapshot.emisar_connections
    environments = view.snapshot.environments
    used = for environment <- environments, do: environment.emisar_connection_ref
    {status, state, text} = emisar_status(accounts, Enum.reject(used, &is_nil/1))

    %{
      status: status,
      state: state,
      text: text,
      facts: if(accounts == [], do: [], else: [account_names(accounts)]),
      unassigned:
        if(accounts == [],
          do: 0,
          else: Enum.count(environments, &is_nil(&1.emisar_connection_ref))
        )
    }
  end

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

  defp emisar_status([], _used), do: {:not_connected, {:off, "Not connected"}, nil}

  defp emisar_status(accounts, used) do
    active = Enum.filter(accounts, & &1.enabled_for_new_work)
    watched = for account <- active, account.monitoring_enabled, do: account.ref

    cond do
      active == [] ->
        {:paused, {:off, "Paused"}, "Every account is paused, so new work does not use Emisar."}

      Enum.any?(used, &(&1 in watched)) ->
        {:ready, {:on, "Connected"}, nil}

      used == [] and watched == [] ->
        {:unfinished, {:warn, "Not in use yet"},
         "Turn on approval monitoring for an account and give an environment that account."}

      used == [] ->
        {:unfinished, {:warn, "Not in use yet"},
         "Give an environment this account so its work sends approvals there."}

      true ->
        {:unfinished, {:warn, "Not in use yet"},
         "Turn on approval monitoring for the account your environments use, so Ryker can pick work back up after a decision."}
    end
  end

  defp account_names([account]), do: account.display_name
  defp account_names(accounts), do: count(length(accounts), "account")

  @doc "Webhooks: the senders set up to send Ryker events."
  @spec webhooks(map()) :: %{state: state(), facts: [String.t()]}
  def webhooks(view) do
    sources = view.snapshot.webhook_sources
    credentials = Enum.count(view.credentials, &(&1.kind == :webhook))

    state =
      cond do
        sources == [] -> {:off, "Not set up"}
        Enum.any?(sources, & &1.enabled) -> {:on, "On"}
        true -> {:off, "Off"}
      end

    %{
      state: state,
      facts:
        reject_empty([
          sources != [] && count(length(sources), "source"),
          credentials > 0 && count(credentials, "signing credential")
        ])
    }
  end

  @doc """
  The Integrations overview: one row per service with its state, what it
  gives Ryker, what is connected and the one action that fits. Emisar is
  optional but recommended, so an unconnected Emisar says so and leads with
  the page's one primary action.
  """
  @spec overview(map()) :: [map()]
  def overview(view) do
    slack = slack(view)
    github = github(view)
    emisar = emisar(view)
    webhooks = webhooks(view)

    [
      %{
        key: :slack,
        name: "Slack",
        href: "/integrations/slack",
        state: short(slack.state),
        text: "Ryker reads and replies in the Slack channels it is invited to.",
        meta: if(slack.text, do: [slack.text], else: slack.facts),
        tag: nil,
        action: action(slack.state, "/integrations/slack")
      },
      %{
        key: :github,
        name: "GitHub",
        href: "/integrations/github",
        state: short(github.state),
        text: "Ryker reads your code and opens pull requests through a GitHub App.",
        meta: if(github.text, do: [github.text], else: github.facts),
        tag: nil,
        action:
          action(
            github.state,
            if(github.state == {:bad, "Needs repair"},
              do: "/integrations/github#github-app",
              else: "/integrations/github"
            )
          )
      },
      emisar_row(emisar),
      %{
        key: :webhooks,
        name: "Webhooks",
        href: "/integrations/webhooks",
        state: webhooks.state,
        text: "Other systems, such as Grafana, send alerts and events to Ryker.",
        meta: webhooks.facts,
        tag: nil,
        action: %{
          label: if(webhooks.state == {:off, "Not set up"}, do: "Set up", else: "Manage"),
          href: "/integrations/webhooks",
          primary: false
        }
      }
    ]
  end

  # Emisar is optional but recommended: an unconnected Emisar says what Ryker
  # cannot do without it and leads with the page's one primary action.
  defp emisar_row(emisar) do
    %{
      key: :emisar,
      name: "Emisar",
      href: "/integrations/emisar",
      state: emisar.state,
      text:
        "Ryker carries out the operational fixes you ask for, after a person approves them in Emisar.",
      meta: emisar_meta(emisar),
      tag: if(emisar.status == :not_connected, do: "Recommended"),
      action: emisar_action(emisar.status)
    }
  end

  defp emisar_meta(%{status: :not_connected}),
    do: ["Without it, Ryker cannot act on anything that is running."]

  defp emisar_meta(%{status: :ready, facts: facts, unassigned: 0}), do: facts

  defp emisar_meta(%{status: :ready, facts: facts, unassigned: count}),
    do: facts ++ [unassigned(count)]

  defp emisar_meta(%{text: text}), do: [text]

  defp emisar_action(:not_connected),
    do: %{label: "Connect", href: "/integrations/emisar", primary: true}

  defp emisar_action(:unfinished),
    do: %{label: "Finish", href: "/integrations/emisar", primary: false}

  defp emisar_action(_ready_or_paused),
    do: %{label: "Manage", href: "/integrations/emisar", primary: false}

  # In a list the facts already name the workspace or App, so a working
  # connection is just "Connected".
  defp short({:on, _connected_to}), do: {:on, "Connected"}
  defp short(state), do: state

  defp action({:off, "Not connected"}, href), do: %{label: "Connect", href: href, primary: false}
  defp action({:bad, _problem}, href), do: %{label: "Repair", href: href, primary: false}

  defp action({:warn, "Finish connecting"}, href),
    do: %{label: "Finish", href: href, primary: false}

  defp action(_state, href), do: %{label: "Manage", href: href, primary: false}

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

  defp reject_empty(facts), do: Enum.reject(facts, &(&1 in [nil, false, ""]))
end
