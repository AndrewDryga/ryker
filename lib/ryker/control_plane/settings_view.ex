defmodule Ryker.ControlPlane.SettingsView do
  @moduledoc """
  What the setup, integration and settings pages read: the durable snapshot
  plus the deployment facts an operator needs to interpret it.

  Credentials appear as configured, missing or invalid — never as values — and
  a database that cannot be read is reported as unavailable rather than as an
  installation without settings. The two are different problems and only one of
  them is fixed by filling in a form.

  A page that shows this view redraws when anything it reads changes
  (`subscriptions/0`).
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{ChannelDirectory, Environments, Integrations, ProductReadiness}
  alias Ryker.CoopFleet.ControlPlane.Workers
  alias Ryker.CoopFleet.Worker
  alias Ryker.Credentials
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.GitHub.AppJWT
  alias Ryker.GitHub.Event, as: GitHubEvent
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelConfigurations, Gateway, Names}
  alias Ryker.Work.Turn

  @type t :: %{
          snapshot: Settings.snapshot(),
          host_ref: String.t(),
          revision: pos_integer(),
          applied_revision: non_neg_integer(),
          application: :applied | :pending | {:failed, atom()},
          applying: boolean(),
          readiness: ProductReadiness.t(),
          saved_by: String.t(),
          saved_at: DateTime.t(),
          credentials: [map()],
          setup: setup(),
          github_callback_url: String.t(),
          github_events: %{received: non_neg_integer(), unreadable: non_neg_integer()},
          webhook_base_url: String.t(),
          webhook_secret_names: [String.t()] | :invalid,
          worker_installs: [
            %{ref: String.t(), workers: pos_integer(), eligible: non_neg_integer()}
          ],
          github_connection: :ready | :missing | :invalid,
          environment_channels: %{(String.t() | nil) => non_neg_integer()},
          slack_channels: [%{workspace_ref: String.t(), channel_ref: String.t()}],
          slack_managers: [%{name: String.t(), href: String.t() | nil}]
        }

  @typedoc """
  The six facts that make Ryker useful, in the order a person sets them up,
  and the channel the Slack steps point at: one with an environment once any
  has one, otherwise the first channel Ryker is in.
  """
  @type setup :: %{
          steps: %{atom() => boolean()},
          invited_channels: non_neg_integer(),
          configured_channels: non_neg_integer(),
          successful_request: boolean(),
          channel:
            %{
              workspace_ref: String.t(),
              channel_ref: String.t(),
              environment_ref: String.t() | nil,
              environment_name: String.t() | nil
            }
            | nil,
          complete: boolean()
        }

  # There is no step for creating an environment: adding the first repository
  # creates the Default one, and channels Ryker joins start in it.
  @setup_steps [:slack, :github, :repositories, :invited, :channel_environment, :request]

  @doc """
  The topics a page that shows this view listens to, as the context functions
  that subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the saved
  settings and whether the running system has applied them, the credentials,
  the Slack channels Ryker is in and its connection to Slack, and the Coop
  workers.
  """
  def subscriptions do
    [
      {Settings, :subscribe, []},
      {Settings, :subscribe_application, []},
      {Credentials, :subscribe, []},
      {ChannelConfigurations, :subscribe_channels, []},
      {Gateway, :subscribe_connection, []},
      {Workers, :subscribe_workers, []}
    ]
  end

  @doc """
  What the setup steps listen to (Setup, and the sidebar's count until setup
  is done): this view's topics, and the Slack conversations whose first
  answered request is the last step.
  """
  def setup_subscriptions,
    do: subscriptions() ++ [{Episodes, :subscribe_conversations, ["slack"]}]

  @spec fetch() :: {:ok, t()} | {:error, :settings_not_initialized | :settings_unavailable}
  def fetch do
    case Settings.fetch() do
      {:ok, snapshot} -> {:ok, view(snapshot)}
      {:error, :settings_not_initialized} -> {:error, :settings_not_initialized}
    end
  rescue
    # A table that is mid-migration, a connection that died and a domain row
    # that is somehow missing are all "could not be read". None of them is an
    # installation without settings, and treating them as one would offer to
    # create a second identity over live history.
    _error in [DBConnection.ConnectionError, Ecto.NoResultsError, Postgrex.Error] ->
      {:error, :settings_unavailable}
  end

  @doc "The view for a snapshot the caller already holds, after a save."
  @spec view(Settings.snapshot()) :: t()
  def view(%{installation: installation} = snapshot) do
    credentials = Credentials.statuses()
    joined = Enum.filter(ChannelDirectory.list(%{}), &(&1.membership == :joined))

    # What an integration's state is read from (`Integrations`), so the setup
    # steps below read the same state every page shows.
    connections = %{
      snapshot: snapshot,
      application: Settings.application_status(snapshot),
      credentials: credentials,
      github_connection: github_connection(snapshot, credentials),
      readiness: ProductReadiness.current(snapshot)
    }

    Map.merge(connections, %{
      host_ref: installation.host_ref,
      revision: installation.revision,
      applied_revision: installation.applied_revision,
      applying: connections.application == :pending and Settings.saved_by_person?(snapshot),
      saved_by: installation.saved_by,
      saved_at: installation.saved_at,
      setup: setup_status(connections, joined),
      # The channels Ryker is in, the places a webhook source can post to.
      slack_channels: Enum.map(joined, &Map.take(&1, [:workspace_ref, :channel_ref])),
      # The people chosen to manage Ryker, as the page shows them. Read here
      # rather than while the page is drawn, so a name Slack gives later
      # reaches the open page on its next refresh.
      slack_managers:
        Enum.map(snapshot.slack.operators, &Names.person(snapshot.slack.workspace_ref, &1)),
      github_callback_url: Application.fetch_env!(:ryker, :github_public_url),
      github_events: github_events(),
      webhook_base_url: Application.fetch_env!(:ryker, :webhook_public_url),
      webhook_secret_names: registered_secret_names(),
      worker_installs: worker_installs(),
      # Channels choose an environment in the Slack tables, so how many use
      # each one is read beside the snapshot rather than from it.
      environment_channels: Environments.channel_counts()
    })
  end

  # What GitHub sent in the last day, however it arrived: a callback GitHub cannot reach lists
  # every delivery as failed on GitHub's side while Ryker collects the same events (Andrew,
  # 2026-10-01: "many failed webhooks on gh").
  defp github_events do
    since = DateTime.add(DateTime.utc_now(), -86_400, :second)

    counts =
      from(event in GitHubEvent,
        where: event.inserted_at >= ^since,
        group_by: event.disposition,
        select: {event.disposition, count(event.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{received: counts |> Map.values() |> Enum.sum(), unreadable: Map.get(counts, "failed", 0)}
  end

  @doc "The required setup steps, in order."
  @spec setup_steps() :: [atom()]
  def setup_steps, do: @setup_steps

  @doc """
  How far the required setup is, for the sidebar's way back into it: nil once
  every step is done. Settings that could not be read keep the way back open
  without claiming a count.
  """
  @spec setup_progress() :: %{done: non_neg_integer() | nil, total: pos_integer()} | nil
  def setup_progress do
    case fetch() do
      {:ok, %{setup: %{complete: true}}} ->
        nil

      {:ok, %{setup: %{steps: steps}}} ->
        %{done: Enum.count(steps, fn {_step, done} -> done end), total: length(@setup_steps)}

      {:error, :settings_not_initialized} ->
        %{done: 0, total: length(@setup_steps)}

      {:error, _unavailable} ->
        %{done: nil, total: length(@setup_steps)}
    end
  end

  defp worker_installs do
    Repo.all(
      from(worker in Worker,
        where: worker.state != :revoked and is_nil(worker.revoked_at),
        group_by: worker.workspace_ref,
        order_by: worker.workspace_ref,
        select: %{
          ref: worker.workspace_ref,
          workers: count(worker.id),
          eligible: filter(count(worker.id), worker.state == :eligible)
        }
      )
    )
  end

  defp registered_secret_names do
    Credentials.statuses()
    |> Enum.filter(&(&1.kind == :webhook))
    |> Enum.map(& &1.name)
  end

  # Slack's step is done once Slack is switched on, working or not: a
  # connection that stopped says so on the done step. GitHub's is done once
  # the App is verified, which switches it on.
  defp setup_status(%{snapshot: snapshot} = connections, joined) do
    configured = Enum.filter(joined, &is_binary(&1.environment_ref))

    successful_request =
      configured
      |> Enum.map(&"slack:#{&1.workspace_ref}:#{&1.channel_ref}")
      |> successful_channel_request?()

    steps = %{
      slack: Integrations.slack(connections).status in [:on, :broken],
      github: Integrations.github(connections).status in [:off, :on],
      repositories: snapshot.repositories != [],
      invited: joined != [],
      channel_environment: configured != [],
      request: successful_request
    }

    %{
      steps: steps,
      invited_channels: length(joined),
      configured_channels: length(configured),
      successful_request: successful_request,
      channel:
        (List.first(configured) || List.first(joined))
        |> then(
          &(&1 &&
              Map.take(&1, [:workspace_ref, :channel_ref, :environment_ref, :environment_name]))
        ),
      complete: Enum.all?(@setup_steps, &Map.fetch!(steps, &1))
    }
  end

  defp github_connection(snapshot, credentials) do
    kinds = [:github_private_key, :github_webhook]
    present? = Enum.any?(credentials, &(&1.kind in kinds))

    cond do
      not present? ->
        :missing

      not verified?(credentials, kinds) or not complete_github_identity?(snapshot.github) ->
        :invalid

      true ->
        with {:ok, private_key} <- Credentials.fetch(:github_private_key, "primary"),
             {:ok, _webhook} <- Credentials.fetch(:github_webhook, "primary"),
             {:ok, _signer} <- AppJWT.new(snapshot.github.app_id, private_key) do
          :ready
        else
          _error -> :invalid
        end
    end
  end

  defp complete_github_identity?(github) do
    is_integer(github.app_id) and github.app_id > 0 and
      is_binary(github.app_slug) and github.app_slug != "" and
      is_integer(github.bot_actor_id) and github.bot_actor_id > 0 and
      is_binary(github.bot_login) and github.bot_login != ""
  end

  defp successful_channel_request?([]), do: false

  # A reply Ryker delivered in a set-up channel, however the conversation went on: one that then
  # asked the person something waits for their answer, and the step stayed open on tenant while
  # it did (2026-10-04).
  defp successful_channel_request?(conversations) do
    Repo.exists?(
      from(episode in Episode,
        join: turn in Turn,
        on: turn.episode_id == episode.id,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref in ^conversations and
            not is_nil(turn.external_receipt)
      )
    )
  end

  defp verified?(credentials, kinds) do
    Enum.all?(kinds, fn kind ->
      Enum.any?(credentials, &(&1.kind == kind and &1.verification_status == :verified))
    end)
  end
end
