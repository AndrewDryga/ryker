defmodule Ryker.ControlPlane.SettingsView do
  @moduledoc """
  What the settings page reads: the durable snapshot plus the deployment facts
  an operator needs to interpret it.

  Credentials appear as configured, missing or invalid — never as values — and
  a database that cannot be read is reported as unavailable rather than as an
  installation without settings. The two are different problems and only one of
  them is fixed by filling in a form.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.ChannelDirectory
  alias Ryker.{Credentials, Repo, Settings}
  alias Ryker.Episodes.Episode
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
          setup: map(),
          github_callback_url: String.t(),
          webhook_base_url: String.t(),
          webhook_secret_names: [String.t()] | :invalid,
          workers: WorkerPolicies.catalog()
        }

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
    setup = setup_status(snapshot, credentials)

    %{
      snapshot: snapshot,
      host_ref: installation.host_ref,
      revision: installation.revision,
      applied_revision: installation.applied_revision,
      application: Settings.application_status(snapshot),
      saved_by: installation.saved_by,
      saved_at: installation.saved_at,
      credentials: credentials,
      setup: setup,
      github_callback_url: Application.fetch_env!(:ryker, :github_public_url),
      webhook_base_url: Application.fetch_env!(:ryker, :webhook_public_url),
      webhook_secret_names: registered_secret_names(),
      workers: WorkerPolicies.catalog(snapshot.work.workspace_ref)
    }
  end

  @doc "Whether the one product setup checklist has been completed."
  def setup_complete? do
    case fetch() do
      {:ok, %{setup: %{complete: complete}}} -> complete
      _ -> false
    end
  end

  defp registered_secret_names do
    Credentials.statuses()
    |> Enum.filter(&(&1.kind == :webhook))
    |> Enum.map(& &1.name)
  end

  defp setup_status(snapshot, credentials) do
    channels = ChannelDirectory.list(%{})

    slack =
      snapshot.slack.enabled and verified?(credentials, [:slack_app, :slack_bot])

    github = verified?(credentials, [:github_private_key, :github_webhook])
    repositories = snapshot.repositories != []
    invited = Enum.count(channels, &(&1.membership == :joined))

    configured =
      Enum.count(channels, &(&1.membership == :joined and is_binary(&1.repository_ref)))

    configured_conversations =
      for channel <- channels,
          channel.membership == :joined,
          is_binary(channel.repository_ref),
          do: "slack:#{channel.workspace_ref}:#{channel.channel_ref}"

    successful_request = successful_channel_request?(configured_conversations)

    %{
      invited_channels: invited,
      configured_channels: configured,
      successful_request: successful_request,
      complete:
        slack and github and repositories and invited > 0 and configured > 0 and
          successful_request
    }
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
