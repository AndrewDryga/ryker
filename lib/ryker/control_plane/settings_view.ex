defmodule Ryker.ControlPlane.SettingsView do
  @moduledoc """
  What the setup, integration and settings pages read: the durable snapshot
  plus the deployment facts an operator needs to interpret it.

  Credentials appear as configured, missing or invalid — never as values — and
  a database that cannot be read is reported as unavailable rather than as an
  installation without settings. The two are different problems and only one of
  them is fixed by filling in a form.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{ChannelDirectory, Environments, ProductReadiness}
  alias Ryker.Credentials
  alias Ryker.Episodes.Episode
  alias Ryker.GitHub.AppJWT
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Settings.WorkerPolicies
  alias Ryker.Work.Turn

  @type t :: %{
          snapshot: Settings.snapshot(),
          host_ref: String.t(),
          revision: pos_integer(),
          applied_revision: non_neg_integer(),
          application: :applied | :pending | {:failed, atom()},
          saved_by: String.t(),
          saved_at: DateTime.t(),
          credentials: [map()],
          setup: setup(),
          github_callback_url: String.t(),
          webhook_base_url: String.t(),
          webhook_secret_names: [String.t()] | :invalid,
          workers: WorkerPolicies.catalog(),
          github_connection: :ready | :missing | :invalid,
          environment_channels: %{String.t() => non_neg_integer()}
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
    github_connection = github_connection(snapshot, credentials)
    setup = setup_status(snapshot, credentials, github_connection)

    %{
      snapshot: snapshot,
      host_ref: installation.host_ref,
      revision: installation.revision,
      applied_revision: installation.applied_revision,
      application: Settings.application_status(snapshot),
      saved_by: installation.saved_by,
      saved_at: installation.saved_at,
      credentials: credentials,
      github_connection: github_connection,
      readiness: ProductReadiness.current(snapshot),
      setup: setup,
      github_callback_url: Application.fetch_env!(:ryker, :github_public_url),
      webhook_base_url: Application.fetch_env!(:ryker, :webhook_public_url),
      webhook_secret_names: registered_secret_names(),
      workers: WorkerPolicies.catalog(snapshot.work.workspace_ref),
      # Channels choose an environment in the Slack tables, so how many use
      # each one is read beside the snapshot rather than from it.
      environment_channels: Environments.channel_counts()
    }
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

  defp registered_secret_names do
    Credentials.statuses()
    |> Enum.filter(&(&1.kind == :webhook))
    |> Enum.map(& &1.name)
  end

  defp setup_status(snapshot, credentials, github_connection) do
    joined = Enum.filter(ChannelDirectory.list(%{}), &(&1.membership == :joined))
    configured = Enum.filter(joined, &is_binary(&1.environment_ref))

    successful_request =
      configured
      |> Enum.map(&"slack:#{&1.workspace_ref}:#{&1.channel_ref}")
      |> successful_channel_request?()

    steps = %{
      slack: snapshot.slack.enabled and verified?(credentials, [:slack_app, :slack_bot]),
      github: github_connection == :ready,
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

  defp successful_channel_request?(conversations) do
    Repo.exists?(
      from(episode in Episode,
        join: turn in Turn,
        on: turn.episode_id == episode.id,
        where:
          episode.destination_transport == "slack" and episode.state == :complete and
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
